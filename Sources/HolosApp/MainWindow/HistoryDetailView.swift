import AppKit
import HolosCore

/// The selected dictation: app and time, the text as written, the text as heard with the changed words marked, the
/// result, language, fixes, and length, and Copy, Copy As Heard, Correct…, Delete.
///
/// Invariants:
/// 1. A hidden button does not answer its shortcut.
/// 2. A dictation that never had audio shows no audio row, since nothing is wrong; audio that went missing says so.
@MainActor
final class HistoryDetailView: NSView {
    var onCopy: ((_ heard: Bool) -> Void)?
    var onCorrect: (() -> Void)?
    var onDelete: (() -> Void)?
    var onPlay: (() -> Void)?
    var onRunAgain: (() -> Void)?
    var onCopyNewResult: (() -> Void)?
    var onUpdateHistory: (() -> Void)?

    /// The selected dictation's audio: playable (and whether it plays, "0:03 / 0:12"), or why there is none.
    enum AudioState {
        case available(playing: Bool, time: String)
        /// Kept once, and no longer on this Mac.
        case missing(String)
        /// None was kept for this dictation.
        case none
    }

    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let audioTime = NSTextField(labelWithString: "")
    private let runAgainButton = NSButton(title: "Run Again", target: nil, action: nil)
    private let audioRow = NSStackView()
    private let comparison = RerunComparisonView()

    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let heardHeading = NSTextField(labelWithString: "As heard, before fixes")
    private let heard = NSTextField(wrappingLabelWithString: "")
    private let restHeading = NSTextField(labelWithString: "Not written — what Copy copies")
    private let rest = NSTextField(wrappingLabelWithString: "")
    private let grid = NSGridView()
    private var values: [String: NSTextField] = [:]
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let copyHeardButton = NSButton(title: "Copy As Heard", target: nil, action: nil)
    private let correctButton = NSButton(title: "Correct…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let feedback = NSTextField(labelWithString: "")
    /// Copy, Copy As Heard, Correct…, Delete…, and the feedback, wrapping when the detail is narrow.
    private lazy var actionRow = WrappingRowView(views: [copyButton, copyHeardButton, correctButton, deleteButton,
                                                         feedback])
    private let content = NSStackView()
    private let empty = NSTextField(labelWithString: "")
    private var feedbackTask: Task<Void, Never>?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        text.font = .systemFont(ofSize: 15)
        text.isSelectable = true
        text.setAccessibilityLabel("Dictation text")
        heardHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        heardHeading.textColor = .secondaryLabelColor
        heard.isSelectable = true
        heard.allowsEditingTextAttributes = true  // keeps the highlight when selected
        heard.setAccessibilityLabel("Text as heard, before fixes")
        restHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        restHeading.textColor = .secondaryLabelColor
        rest.font = .systemFont(ofSize: 13)
        rest.isSelectable = true
        rest.setAccessibilityLabel("Text not written, what Copy copies")

        grid.rowSpacing = 6
        grid.columnSpacing = 14
        for name in ["Result", "Language", "Fixes", "Length"] {
            let label = NSTextField(labelWithString: name)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            let value = NSTextField(wrappingLabelWithString: "")
            value.font = .systemFont(ofSize: 12)
            value.isSelectable = true
            value.setAccessibilityLabel(name)
            values[name] = value
            grid.addRow(with: [label, value])
        }
        grid.column(at: 0).xPlacement = .leading

        for (button, action) in [(copyButton, #selector(copyPressed)), (copyHeardButton, #selector(copyHeardPressed)),
                                 (correctButton, #selector(correctPressed)), (deleteButton, #selector(deletePressed))] {
            button.target = self
            button.action = action
            button.bezelStyle = .push
        }
        copyButton.toolTip = "Copy the text to the clipboard (⌘C in the list)"
        copyHeardButton.keyEquivalent = "c"
        copyHeardButton.keyEquivalentModifierMask = [.command, .shift]
        copyHeardButton.toolTip = "Copy the text as heard, before fixes (⇧⌘C)"
        correctButton.keyEquivalent = "e"
        correctButton.keyEquivalentModifierMask = .command
        correctButton.toolTip = "Fix misheard words in Corrections (⌘E)"
        deleteButton.toolTip = "Delete this dictation from History (⌫ in the list)"
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        // In a narrow window the labels truncate and the buttons wrap (`actionRow`).
        for label in [title, subtitle, heardHeading, restHeading] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        audioTime.lineBreakMode = .byTruncatingTail
        audioTime.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = actionRow

        playButton.target = self
        playButton.action = #selector(playPressed)
        playButton.bezelStyle = .push
        playButton.controlSize = .small
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.imagePosition = .imageLeading
        playButton.toolTip = "Play the dictation's audio (Space in the list)"
        audioTime.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        audioTime.textColor = .secondaryLabelColor
        audioTime.setAccessibilityLabel("Audio position")
        runAgainButton.target = self
        runAgainButton.action = #selector(runAgainPressed)
        runAgainButton.bezelStyle = .push
        runAgainButton.controlSize = .small
        runAgainButton.keyEquivalent = "r"
        runAgainButton.keyEquivalentModifierMask = .command
        runAgainButton.toolTip = "Recognize the saved audio again with today's language, corrections, filler "
            + "removal, and Apple Intelligence fix, and compare (⌘R). Nothing is typed or copied."
        for view in [playButton, audioTime, runAgainButton] { audioRow.addArrangedSubview(view) }
        audioRow.spacing = 8
        audioRow.alignment = .centerY
        comparison.onCopy = { [weak self] in self?.onCopyNewResult?() }
        comparison.onUpdate = { [weak self] in self?.onUpdateHistory?() }
        comparison.isHidden = true

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        let separator = NSBox.hairline()
        for view in [header, audioRow, comparison, text, restHeading, rest, heardHeading, heard, separator, grid,
                     buttons] {
            content.addArrangedSubview(view)
        }
        comparison.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.setCustomSpacing(4, after: restHeading)
        content.setCustomSpacing(4, after: heardHeading)
        content.setCustomSpacing(18, after: heard)
        content.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Wrapping labels need the width they wrap at.
    override func layout() {
        super.layout()
        // Small floors, so the detail at its narrowest (`HistoryPane.detailMinimumWidth`) is not held wider.
        let width = max(100, bounds.width - 48)
        for label in [text, heard, rest] + Array(values.values) {
            let target = label === text || label === heard || label === rest ? width : max(60, width - 90)
            if label.preferredMaxLayoutWidth != target { label.preferredMaxLayoutWidth = target }
        }
    }

    func show(_ record: DictationRecord?, emptyText: String) {
        feedbackTask?.cancel()
        feedback.stringValue = ""
        // With nothing selected the actions (and their keys: ⇧⌘C, ⌘E, ⌘R) are off, not merely hidden; `showAudio`
        // turns Play and Run Again on for a dictation with audio.
        for button in [copyButton, copyHeardButton, correctButton, deleteButton] { button.isEnabled = record != nil }
        if record == nil {
            playButton.isEnabled = false
            runAgainButton.isEnabled = false
        }
        guard let record else {
            content.isHidden = true
            empty.stringValue = emptyText
            empty.isHidden = emptyText.isEmpty
            return
        }
        content.isHidden = false
        empty.isHidden = true
        title.stringValue = record.app ?? "Unknown app"
        title.toolTip = title.stringValue  // whole when a narrow window cuts it short
        subtitle.stringValue = dateFormatter.string(from: record.date)
        text.stringValue = record.text
        // A partly written dictation shows both: the whole text, and the rest Copy copies (as Copy Result did).
        restHeading.isHidden = record.unwritten == nil
        rest.isHidden = record.unwritten == nil
        rest.stringValue = record.unwritten?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        copyButton.toolTip = record.unwritten == nil
            ? "Copy the text to the clipboard (⌘C in the list)"
            : "Copy the part that was not written, as Copy Result did (⌘C in the list)"
        let differs = Self.offersCopyAsHeard(record)
        heardHeading.isHidden = !differs
        heard.isHidden = !differs
        copyHeardButton.isHidden = !differs
        copyHeardButton.isEnabled = differs  // a hidden button must not answer ⇧⌘C either
        actionRow.viewsChanged()
        if differs { heard.attributedStringValue = Self.highlighted(record.heard, comparedTo: record.text) }
        values["Result"]?.stringValue = record.resultText
        values["Language"]?.stringValue = DictationLanguage.name(of: record.language)
        values["Fixes"]?.stringValue = record.fixesText
        values["Length"]?.stringValue = record.lengthText
        needsLayout = true
    }

    func focusText() {
        window?.makeFirstResponder(text)
    }

    /// The audio row: ▶/⏸ and the position, and Run Again (off while one runs); or why there is no audio.
    func showAudio(_ state: AudioState, running: Bool) {
        switch state {
        case .available(let playing, let time):
            audioRow.isHidden = false
            playButton.isHidden = false
            playButton.isEnabled = true
            playButton.title = playing ? "Pause" : "Play"
            playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                       accessibilityDescription: nil)
            audioTime.stringValue = time
            audioTime.toolTip = nil
            runAgainButton.isHidden = false
            runAgainButton.isEnabled = !running
        case .missing(let reason):
            audioRow.isHidden = false
            hideAudioControls()
            audioTime.stringValue = reason
            audioTime.toolTip = reason  // whole when a narrow window cuts it short
        case .none:
            audioRow.isHidden = true  // invariant 2
            hideAudioControls()
            audioTime.stringValue = ""
            audioTime.toolTip = nil
        }
        needsLayout = true
    }

    private func hideAudioControls() {
        playButton.isHidden = true
        playButton.isEnabled = false
        runAgainButton.isHidden = true
        runAgainButton.isEnabled = false  // invariant 1: ⌘R
    }

    /// The Run Again result for the selected dictation; nil hides it.
    func showRerun(_ state: RerunComparisonView.State?) {
        comparison.isHidden = state == nil
        if let state { comparison.show(state) }
        needsLayout = true
    }

    func showFeedback(_ message: String) {
        feedback.stringValue = message
        actionRow.viewsChanged()
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.feedback.stringValue = ""
            self?.actionRow.viewsChanged()
        }
    }

    /// Copy As Heard (and its ⇧⌘C) is offered only when the fixes changed the text.
    static func offersCopyAsHeard(_ record: DictationRecord) -> Bool { record.wasFixed }

    /// The text as heard, with the words the fixes changed or removed marked.
    static func highlighted(_ heard: String, comparedTo written: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: heard, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        for range in WordDiff.changedRanges(in: heard, comparedTo: written) {
            result.addAttributes([
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.25),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.systemOrange,
            ], range: NSRange(range, in: heard))
        }
        return result
    }

    @objc private func playPressed() { onPlay?() }
    @objc private func runAgainPressed() { onRunAgain?() }
    @objc private func copyPressed() { onCopy?(false) }
    @objc private func copyHeardPressed() { onCopy?(true) }
    @objc private func correctPressed() { onCorrect?() }
    @objc private func deletePressed() { onDelete?() }
}
