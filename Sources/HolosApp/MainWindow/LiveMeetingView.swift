import AppKit
import HolosCore
import HolosMeeting

/// What the live transcript's header says about its meeting.
struct LiveMeetingHeader: Equatable {
    var name: String
    var phase: LiveMeetingPhase
    /// "0:12:34", "Saving — labelling speakers 42%", a failure.
    var detail: String
}

struct LiveTextLearning {
    var learned: [Correction]?
    var owned: [Correction]?
    var problem: String?
}

/// A meeting's live transcript in the Meetings section (docs/design.md "Live transcript"): its words as they are
/// spoken, volatile ones in a secondary colour until they are final, with the microphone's echo of the call hidden
/// (`LiveTranscript`). It follows the newest words while the user is at the bottom; scrolling up stops that and shows
/// "Jump to Live" (`LiveFollow`). Reads the session four times a second while on screen, off the main actor. Once the
/// meeting is saved, the header offers what opens a finished meeting (Review or the transcript). The ‹ Meetings
/// button (Escape) goes back to the list.
@MainActor
final class LiveMeetingViewController: NSViewController, NSTextViewDelegate {
    static let refreshInterval: Duration = .milliseconds(250)

    let sessionID: String
    private let onBack: () -> Void
    private let onOpenFinished: () -> Void
    /// Reconciles safe correction pairs with the latest live edits. Arguments are the saved learning state, original
    /// recognizer text, and new text. The result records what this edit confirms and newly owns.
    private let onLearnText: (LiveHints.CorrectionLearningState, String, String) -> LiveTextLearning
    private var reader: LiveTranscriptReader
    private var header = LiveMeetingHeader(name: "", phase: .starting, detail: "")
    private var paragraphs: [LiveParagraph] = []
    private var follow = LiveFollow()
    private var refreshTask: Task<Void, Never>?
    private var reading = false
    /// The text is being replaced or scrolled by the view itself, not by the user.
    private var updating = false
    private var targets: [TargetRange] = []

    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusDot = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let finishedButton = NSButton()
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let jumpButton = NSButton()
    private let jumpPill = NSVisualEffectView()
    private let correctTextButton = NSButton()
    private let nameSpeakerButton = NSButton()
    private let editStatus = NSTextField(labelWithString: "")

    init(sessionID: String, directory: URL, onBack: @escaping () -> Void, onOpenFinished: @escaping () -> Void,
         onLearnText: @escaping (LiveHints.CorrectionLearningState, String, String) -> LiveTextLearning = {
             _, _, _ in .init()
         }) {
        self.sessionID = sessionID
        self.onBack = onBack
        self.onOpenFinished = onOpenFinished
        self.onLearnText = onLearnText
        reader = LiveTranscriptReader(session: directory)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        backButton.title = "Meetings"
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.bezelStyle = .push
        backButton.target = self
        backButton.action = #selector(back)
        // Escape goes back to the list instead of closing the window (`AppKeyboard` lets a button's Escape win).
        backButton.keyEquivalent = "\u{1b}"
        backButton.toolTip = "Back to all meetings (Escape)"
        backButton.setAccessibilityLabel("Back to Meetings")

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        statusDot.setAccessibilityElement(false)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        finishedButton.bezelStyle = .push
        finishedButton.target = self
        finishedButton.action = #selector(openFinished)
        finishedButton.keyEquivalent = "\r"
        finishedButton.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let status = NSStackView(views: [statusDot, statusLabel])
        status.spacing = 5
        let bar = NSStackView(views: [backButton, titleLabel, spacer, status, finishedButton])
        bar.spacing = 10
        bar.alignment = .centerY
        bar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.setAccessibilityLabel("Live transcript")
        textView.delegate = self
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        placeholder.stringValue = "Listening… Words appear here as they are spoken."
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        jumpButton.title = "Jump to Live"
        jumpButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        jumpButton.imagePosition = .imageLeading
        jumpButton.isBordered = false
        jumpButton.font = .systemFont(ofSize: 13, weight: .semibold)
        jumpButton.contentTintColor = .controlAccentColor
        jumpButton.toolTip = "Scroll to the newest words and follow them again"
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLive)
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        // A pill of the menu material, so it reads over the text it floats on, in either appearance.
        jumpPill.material = .menu
        jumpPill.blendingMode = .withinWindow
        jumpPill.state = .active
        jumpPill.wantsLayer = true
        jumpPill.layer?.cornerRadius = 15
        jumpPill.layer?.masksToBounds = true
        jumpPill.isHidden = true
        jumpPill.translatesAutoresizingMaskIntoConstraints = false
        jumpPill.addSubview(jumpButton)
        NSLayoutConstraint.activate([
            jumpButton.leadingAnchor.constraint(equalTo: jumpPill.leadingAnchor, constant: 14),
            jumpButton.trailingAnchor.constraint(equalTo: jumpPill.trailingAnchor, constant: -14),
            jumpButton.centerYAnchor.constraint(equalTo: jumpPill.centerYAnchor),
            jumpPill.heightAnchor.constraint(equalToConstant: 30),
        ])

        correctTextButton.title = "Correct Text…"
        correctTextButton.target = self
        correctTextButton.action = #selector(correctText)
        correctTextButton.toolTip = "Correct the selected finalized phrase and learn safe word corrections"
        nameSpeakerButton.title = "Name Speaker…"
        nameSpeakerButton.target = self
        nameSpeakerButton.action = #selector(nameSpeaker)
        nameSpeakerButton.toolTip = "Attach a speaker name to the selected finalized phrase"
        editStatus.textColor = .secondaryLabelColor
        editStatus.font = .systemFont(ofSize: 11)
        editStatus.lineBreakMode = .byTruncatingTail
        editStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let editSpacer = NSView()
        editSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let editBar = NSStackView(views: [correctTextButton, nameSpeakerButton, editSpacer, editStatus])
        editBar.spacing = 8
        editBar.alignment = .centerY
        editBar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for view in [bar, separator, scroll, editBar, placeholder, jumpPill] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: editBar.topAnchor),
            editBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            editBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            editBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            editBar.heightAnchor.constraint(equalToConstant: 30),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -80),
            jumpPill.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            jumpPill.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -16),
        ])
        view = root
        apply(header)
    }

    var preferredFirstResponder: NSView { textView }

    // MARK: - Updates

    /// The header: the meeting's name, phase, and progress, and (once saved) what opens it (nil: nothing does).
    func update(header: LiveMeetingHeader, finishedAction: String?) {
        let phaseChanged = header.phase != self.header.phase
        self.header = header
        guard isViewLoaded else { return }
        apply(header)
        finishedButton.title = finishedAction ?? ""
        finishedButton.isHidden = finishedAction == nil || header.phase != .saved
        if phaseChanged { refresh() }
    }

    private func apply(_ header: LiveMeetingHeader) {
        titleLabel.stringValue = header.name
        titleLabel.toolTip = header.name
        statusLabel.stringValue = header.detail
        statusLabel.toolTip = header.detail
        let (tint, word): (NSColor, String) = switch header.phase {
        case .starting: (.systemOrange, "Starting")
        case .recording: (.systemRed, "Recording")
        case .paused: (.systemOrange, "Paused")
        case .saving: (.systemBlue, "Saving")
        case .saved: (.systemGreen, "Saved")
        case .interrupted: (.systemOrange, "Interrupted")
        case .failed: (.systemOrange, "Failed")
        }
        statusDot.contentTintColor = tint
        statusLabel.setAccessibilityLabel("\(word). \(header.detail)")
        placeholder.stringValue = header.phase.capturing || header.phase == .saving
            ? "Listening… Words appear here as they are spoken." : "Nothing was transcribed."
        updateEditButtons()
    }

    /// Starts reading the session (the section came on screen with this view).
    func start() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Reads what changed, off the main actor, and shows it.
    private func refresh() {
        guard !reading else { return }
        reading = true
        let current = reader
        let includeVolatile = header.phase.includesVolatileText
        Task { [weak self] in
            let (updated, built) = await Task.detached { () -> (LiveTranscriptReader, [LiveParagraph]?) in
                var next = current
                next.read(includeVolatile: includeVolatile)
                guard next.revision != current.revision || next.volatile != current.volatile
                    || next.hints != current.hints
                    || next.mode != current.mode else { return (next, nil) }
                let echo = next.mode.flatMap(LiveTranscript.echoParameters(mode:))
                return (next, LiveTranscript.paragraphs(finals: next.finals, volatile: next.volatile, echo: echo,
                                                        hints: next.hints))
            }.value
            guard let self else { return }
            self.reading = false
            self.reader = updated
            if let built { self.show(built) }
        }
    }

    /// Shows `paragraphs`, following the newest words when the view follows them.
    func show(_ paragraphs: [LiveParagraph]) {
        _ = view
        placeholder.isHidden = !paragraphs.isEmpty
        guard paragraphs != self.paragraphs else { return }
        self.paragraphs = paragraphs
        updating = true
        let rendered = Self.render(paragraphs)
        targets = rendered.targets
        textView.textStorage?.setAttributedString(rendered.text)
        if follow.scrollsToNewWords { textView.scrollToEndOfDocument(nil) }
        updating = false
        updateJump()
        updateEditButtons()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard follow.scrollsToNewWords, !paragraphs.isEmpty else { return }
        updating = true
        textView.scrollToEndOfDocument(nil)
        updating = false
    }

    // MARK: - Following

    @objc private func scrolled() {
        guard !updating else { return }
        let clip = scroll.contentView
        follow.moved(distanceFromBottom: Double(textView.frame.maxY - clip.bounds.maxY))
        updateJump()
    }

    @objc private func jumpToLive() {
        follow.jumpToLive()
        updating = true
        textView.scrollToEndOfDocument(nil)
        updating = false
        updateJump()
        view.window?.makeFirstResponder(textView)
    }

    private func updateJump() {
        jumpPill.isHidden = !follow.showsJumpToLive || paragraphs.isEmpty
    }

    @objc private func back() { onBack() }

    @objc private func openFinished() { onOpenFinished() }

    // MARK: - Live corrections

    func textViewDidChangeSelection(_ notification: Notification) { updateEditButtons() }

    private struct TargetRange {
        var range: NSRange
        var hint: LiveHint
        var speakerName: String?
    }

    private func selectedTarget() -> TargetRange? {
        let selected = textView.selectedRange()
        let matches = targets.filter { target in
            if selected.length == 0 {
                return selected.location >= target.range.location && selected.location < NSMaxRange(target.range)
            }
            return NSIntersectionRange(selected, target.range).length > 0
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func updateEditButtons() {
        guard isViewLoaded else { return }
        let enabled = header.phase.capturing && selectedTarget() != nil
        correctTextButton.isEnabled = enabled
        nameSpeakerButton.isEnabled = enabled
    }

    @objc private func correctText() {
        guard let target = selectedTarget() else { return }
        let field = NSTextField(string: target.hint.heard)
        field.frame.size = NSSize(width: 360, height: 24)
        let alert = NSAlert()
        alert.messageText = "Correct this phrase"
        alert.informativeText = "The correction is matched to this time in the final transcript. Safe misheard-word changes are also learned for the future."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Correction")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let corrected = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != target.hint.heard else { return }
        let originalHeard = LiveHints.originalHeard(for: target.hint, among: reader.hints)
        let learningState = LiveHints.correctionLearningState(for: target.hint, among: reader.hints)
        var hint = target.hint
        hint.id = UUID().uuidString
        hint.at = Date()
        hint.action = .replaceText(corrected)
        hint.learned = nil
        hint.owned = nil
        guard save(hint, success: "Text correction saved") else { return }
        let learning = onLearnText(learningState, originalHeard, corrected)
        var problems: [String] = []
        if let problem = learning.problem { problems.append("could not learn it: \(problem)") }
        if let learned = learning.learned, let owned = learning.owned {
            do {
                try LiveHintStore.recordLearning(learned, owned: owned, for: hint.id, session: reader.session)
                refresh()
            } catch {
                problems.append("could not record its correction rules: \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty {
            editStatus.stringValue = "Timed correction saved; " + problems.joined(separator: "; ")
        }
    }

    @objc private func nameSpeaker() {
        guard let target = selectedTarget() else { return }
        let field = NSTextField(string: target.speakerName ?? "")
        field.placeholderString = "Speaker name"
        field.frame.size = NSSize(width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "Name the speaker of this phrase"
        alert.informativeText = "After speaker labelling, the speaker at this time will use this name."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Name")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let name = SpeakerEditor.cleanName(field.stringValue) else { return }
        var hint = target.hint
        hint.id = UUID().uuidString
        hint.at = Date()
        hint.action = .nameSpeaker(name)
        _ = save(hint, success: "Speaker name saved")
    }

    @discardableResult
    private func save(_ hint: LiveHint, success: String) -> Bool {
        guard header.phase.capturing else {
            editStatus.stringValue = "The meeting is no longer recording; this change was not saved."
            return false
        }
        do {
            try LiveHintStore.append(hint, session: reader.session)
            editStatus.stringValue = success
            refresh()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "The live correction could not be saved"
            alert.runModal()
            return false
        }
    }

    // MARK: - Text

    static func trackName(_ track: String) -> String {
        track == "system" ? "System" : "Mic"
    }

    /// One paragraph per turn: a small header (a dot in the track's colour, the track, the time), then its words,
    /// final ones in the label colour and volatile ones in the secondary label colour.
    static func attributed(_ paragraphs: [LiveParagraph]) -> NSAttributedString {
        render(paragraphs).text
    }

    private static func render(_ paragraphs: [LiveParagraph]) -> (text: NSAttributedString, targets: [TargetRange]) {
        let result = NSMutableAttributedString()
        var targets: [TargetRange] = []
        let body = NSFont.systemFont(ofSize: 14)
        let small = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for (index, paragraph) in paragraphs.enumerated() {
            let headerStyle = NSMutableParagraphStyle()
            headerStyle.paragraphSpacingBefore = index == 0 ? 0 : 14
            headerStyle.paragraphSpacing = 3
            let dotColor: NSColor = paragraph.track == "system" ? .systemPurple : .systemBlue
            result.append(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: dotColor, .paragraphStyle: headerStyle,
                .baselineOffset: 1,
            ]))
            let label = paragraph.speakerName.map { "\($0) · \(trackName(paragraph.track))" }
                ?? trackName(paragraph.track)
            result.append(NSAttributedString(
                string: "\(label)  \(MeetingFormat.clock(paragraph.start))\n",
                attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: headerStyle]))
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 3
            for (runIndex, run) in paragraph.runs.enumerated() {
                let text = (runIndex == 0 ? "" : " ") + run.text
                let location = result.length + (runIndex == 0 ? 0 : 1)
                result.append(NSAttributedString(string: text, attributes: [
                    .font: body, .paragraphStyle: bodyStyle,
                    .foregroundColor: run.isFinal ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]))
                if run.isFinal, let segmentID = run.segmentID, let firstWord = run.firstWord,
                   let endWord = run.endWord, let start = run.start, let end = run.end {
                    targets.append(TargetRange(
                        range: NSRange(location: location, length: run.text.utf16.count),
                        hint: LiveHint(segmentID: segmentID, track: paragraph.track, firstWord: firstWord,
                                       endWord: endWord, start: start, end: end, heard: run.text,
                                       action: .replaceText(run.text)),
                        speakerName: run.speakerName))
                }
            }
            if index < paragraphs.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: bodyStyle]))
            }
        }
        return (result, targets)
    }
}
