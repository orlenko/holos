import AppKit
import AVFoundation
import HolosCore

/// Plays one dictation's saved audio in History (▶/⏸, Space in the list). One at a time; stopped when another
/// dictation is selected or the section leaves the screen.
@MainActor
final class HistoryAudioPlayer {
    private var player: AVAudioPlayer?
    /// The dictation whose audio is loaded.
    private(set) var id: UUID?
    private var ticker: Task<Void, Never>?
    /// Called while playing (a few times a second) and when playback starts, pauses, or ends.
    var onChange: (() -> Void)?

    var isPlaying: Bool { player?.isPlaying ?? false }
    var position: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval? { player?.duration }

    /// Plays dictation `id`'s audio at `url`, or pauses it when it is playing.
    func toggle(id: UUID, url: URL) throws {
        if self.id != id || player == nil {
            stop()
            let made = try AVAudioPlayer(contentsOf: url)
            made.prepareToPlay()
            player = made
            self.id = id
        }
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            ticker?.cancel()
            ticker = nil
        } else {
            guard player.play() else { throw HolosError.io("The audio could not be played.") }
            startTicker()
        }
        onChange?()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        id = nil
        onChange?()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.onChange?()
                if !self.isPlaying {
                    // Played to the end: back to the start, ready to play again.
                    self.player?.currentTime = 0
                    self.ticker = nil
                    self.onChange?()
                    return
                }
            }
        }
    }

    /// "0:03 / 0:12".
    static func timeText(_ position: TimeInterval, of duration: TimeInterval) -> String {
        "\(clock(position)) / \(clock(duration))"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// History's Run Again result for the selected dictation: as heard and as written, then and now (the words that
/// differ marked), what each step did now, and the steps that behaved differently from then; Copy New Result and
/// Update History…. Nothing reaches the clipboard or History unless one of those is chosen.
@MainActor
final class RerunComparisonView: NSView {
    enum State {
        case running
        case failed(String)
        case done(DictationRerunReport)
    }

    var onCopy: (() -> Void)?
    var onUpdate: (() -> Void)?

    private let heading = NSTextField(labelWithString: "Run Again — with today's settings")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let grid = NSGridView()
    private var values: [String: NSTextField] = [:]
    private let copyButton = NSButton(title: "Copy New Result", target: nil, action: nil)
    private let updateButton = NSButton(title: "Update History…", target: nil, action: nil)
    private let buttons: WrappingRowView
    private static let rows = ["Heard then", "Heard now", "Written then", "Written now", "Steps", "Different"]

    override init(frame frameRect: NSRect) {
        buttons = WrappingRowView(views: [copyButton, updateButton])
        super.init(frame: frameRect)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        for name in Self.rows {
            let label = NSTextField(labelWithString: name)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            let value = NSTextField(wrappingLabelWithString: "")
            value.font = .systemFont(ofSize: 12)
            value.isSelectable = true
            value.allowsEditingTextAttributes = true  // keeps the marks when selected
            value.setAccessibilityLabel(name)
            values[name] = value
            grid.addRow(with: [label, value])
        }
        grid.column(at: 0).xPlacement = .trailing
        copyButton.target = self
        copyButton.action = #selector(copyPressed)
        copyButton.toolTip = "Copy the new result to the clipboard; nothing else is copied"
        updateButton.target = self
        updateButton.action = #selector(updatePressed)
        updateButton.toolTip = "Keep the new result as this dictation's text in History"
        for button in [copyButton, updateButton] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        let top = NSStackView(views: [heading, spinner])
        top.spacing = 6
        let stack = NSStackView(views: [top, status, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = CardView()
        box.addSubview(stack)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Run Again")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Small floors, so a narrow window (the History detail at its narrowest) is not held wider.
        let width = max(60, bounds.width - 24 - 110)
        for label in values.values where label.preferredMaxLayoutWidth != width { label.preferredMaxLayoutWidth = width }
        let statusWidth = max(80, bounds.width - 24)
        if status.preferredMaxLayoutWidth != statusWidth { status.preferredMaxLayoutWidth = statusWidth }
    }

    func show(_ state: State) {
        switch state {
        case .running:
            spinner.startAnimation(nil)
            status.stringValue = "Recognizing the saved audio again…"
            status.isHidden = false
            grid.isHidden = true
            buttons.isHidden = true
        case .failed(let message):
            spinner.stopAnimation(nil)
            status.stringValue = "Run Again failed: \(message)"
            status.isHidden = false
            grid.isHidden = true
            buttons.isHidden = true
        case .done(let report):
            spinner.stopAnimation(nil)
            status.isHidden = false
            status.stringValue = report.changed
                ? "The text would be written differently now."
                : "The text would be written the same way now."
            if report.languageNow != report.languageThen {
                status.stringValue += " Language: \(DictationLanguage.name(of: report.languageNow)) now, "
                    + "\(DictationLanguage.name(of: report.languageThen)) then."
            }
            values["Heard then"]?.attributedStringValue = Self.marked(report.heard.then, comparedTo: report.heard.now,
                                                                      color: .systemOrange)
            values["Heard now"]?.attributedStringValue = Self.marked(report.heard.now, comparedTo: report.heard.then,
                                                                     color: .systemGreen)
            values["Written then"]?.attributedStringValue = Self.marked(report.written.then,
                                                                        comparedTo: report.written.now,
                                                                        color: .systemOrange)
            values["Written now"]?.attributedStringValue = Self.marked(report.written.now,
                                                                       comparedTo: report.written.then,
                                                                       color: .systemGreen)
            values["Steps"]?.stringValue = report.steps.map(\.summary).joined(separator: "\n")
            values["Different"]?.stringValue = report.changedBy.isEmpty
                ? "No step behaved differently from then."
                : report.changedBy.map(\.title).joined(separator: ", ")
            grid.isHidden = false
            buttons.isHidden = false
            copyButton.isEnabled = !report.written.now.isEmpty
            updateButton.isEnabled = !report.written.now.isEmpty && report.changed
        }
        needsLayout = true
    }

    /// `text` with the words that are not in `other` marked in `color`.
    static func marked(_ text: String, comparedTo other: String, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text.isEmpty ? "(nothing)" : text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
        ])
        guard !text.isEmpty else { return result }
        for range in WordDiff.changedRanges(in: text, comparedTo: other) {
            result.addAttributes([
                .backgroundColor: color.withAlphaComponent(0.25),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: color,
            ], range: NSRange(range, in: text))
        }
        return result
    }

    @objc private func copyPressed() { onCopy?() }
    @objc private func updatePressed() { onUpdate?() }
}
