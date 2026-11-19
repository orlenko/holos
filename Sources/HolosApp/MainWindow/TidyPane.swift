import AppKit
import HolosAppModel
import HolosCore
import HolosDictation
import HolosMeeting

/// The main window's Tidy Up section (docs/design.md "Tidy Up"): paste or type a text (or take the last dictation,
/// or one from History), and a model on this Mac rejoins the sentences a pause split and adds paragraphs, lists and
/// quotes. The edit shows the words it removed struck through in place and the words it added underlined
/// (`TidyReview`); Copy Tidied Text copies it, and nothing is ever copied otherwise. The model line at the top says
/// which model tidies and installs or removes Qwen.
///
/// Invariants:
/// 1. One tidy-up or one model change at a time; Cancel stops the tidy-up, and its result is dropped.
/// 2. The clipboard is written only by Copy Tidied Text, with the edit shown.
@MainActor
final class TidyPane: NSViewController, MainSectionContent {
    struct Actions {
        /// Starts `voiceislocal tidy --json` on `text`; `completion` gets its result on the main actor. Nil when the
        /// tool cannot start, with the reason.
        var tidy: (_ text: String, _ completion: @escaping @MainActor (CommandResult<TidyCommand.Outcome>) -> Void)
            -> Result<CommandHandle, Error>
        /// Starts `voiceislocal setup --tidy-model` (with `--from` a file already on this Mac); `progress` gets its
        /// latest line, `done` nil or the failure. False when it cannot start.
        var install: (_ from: URL?, _ progress: @escaping @MainActor (String) -> Void,
                      _ done: @escaping @MainActor (String?) -> Void) -> Bool
        /// Runs `voiceislocal setup --remove-tidy-model`; `done` gets nil or the failure.
        var remove: (_ done: @escaping @MainActor (String?) -> Void) -> Bool
        /// The newest dictation since launch, if any.
        var lastDictation: () -> String?
        /// Copies `text` to the clipboard (only ever on Copy Tidied Text).
        var copy: (_ text: String) -> Bool
        /// Whether Qwen is installed (`TidyModel.status`).
        var modelStatus: () -> DeepModelStatus = { TidyModel.status() }
    }

    private let actions: Actions
    private let inputView: NSTextView
    private let resultView: NSTextView
    private let modelLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install Qwen…", target: nil, action: nil)
    private let fromFileButton = NSButton(title: "Use a File Already Downloaded…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Qwen…", target: nil, action: nil)
    private let tidyButton = NSButton(title: "Tidy Up", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let lastButton = NSButton(title: "Last Dictation", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Tidied Text", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private var running: CommandHandle?
    /// Counts tidy-ups, so a cancelled one's late result is dropped (invariant 1).
    private var generation = 0
    private var installing: String?
    private var review: TidyReview?

    init(actions: Actions) {
        self.actions = actions
        let inputScroll = NSTextView.scrollableTextView()
        inputView = inputScroll.documentView as! NSTextView
        let resultScroll = NSTextView.scrollableTextView()
        resultView = resultScroll.documentView as! NSTextView
        super.init(nibName: nil, bundle: nil)

        for (textView, label) in [(inputView, "Text to tidy"), (resultView, "Tidied text")] {
            textView.setAccessibilityLabel(label)
            textView.isRichText = false
            textView.font = .systemFont(ofSize: 14)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
        }
        resultView.isEditable = false
        resultView.isRichText = true
        // Not selectable: a copy from it would take the struck-through words; Copy Tidied Text takes the edit.
        resultView.isSelectable = false
        inputScroll.borderType = .bezelBorder
        resultScroll.borderType = .bezelBorder
        inputScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        for (button, action) in [(installButton, #selector(install)), (fromFileButton, #selector(installFromFile)),
                                 (removeButton, #selector(remove)), (tidyButton, #selector(tidy)),
                                 (cancelButton, #selector(cancel)), (lastButton, #selector(loadLast)),
                                 (copyButton, #selector(copyTidied))] {
            button.target = self
            button.action = action
        }
        tidyButton.keyEquivalent = "\r"
        tidyButton.keyEquivalentModifierMask = .command
        tidyButton.toolTip = "Tidy the text with the model on this Mac (⌘↩)"
        lastButton.toolTip = "Put the newest dictation in the box, replacing what is there"
        installButton.toolTip = "Download Qwen3.5 9B (about 5.7 GB) from Hugging Face; it runs on this Mac"
        fromFileButton.toolTip = "Copy \(TidyModel.fileName), already on this Mac, instead of downloading it"
        copyButton.toolTip = "Copy the tidied text, without the struck-through words"
        cancelButton.isHidden = true
        copyButton.isEnabled = false

        for label in [modelLabel, statusLabel, summaryLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }
        let modelButtons = WrappingRowView(views: [installButton, fromFileButton, removeButton])
        let inputActions = NSStackView(views: [tidyButton, cancelButton, lastButton])
        inputActions.spacing = 8
        let stack = NSStackView(views: [
            heading("Model"), modelLabel, modelButtons,
            heading("Text"), inputScroll, inputActions, statusLabel,
            heading("Tidied"), resultScroll, summaryLabel, copyButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: modelButtons)
        stack.setCustomSpacing(18, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let content = NSScrollView()
        content.hasVerticalScroller = true
        content.drawsBackground = false
        content.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
            document.widthAnchor.constraint(equalTo: content.contentView.widthAnchor),
        ])
        for view in [modelLabel, modelButtons, inputScroll, statusLabel, resultScroll, summaryLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = content
        showModel()
        showResult(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    var preferredFirstResponder: NSView? { inputView }

    func sectionDidShow() { showModel() }
    func sectionWindowDidBecomeKey() { showModel() }

    /// Puts `text` in the box (History's Tidy Up…), replacing what is there, and clears the last edit; while a
    /// tidy-up runs, says so and keeps the box.
    func load(_ text: String) {
        guard running == nil else {
            statusLabel.stringValue = "A tidy-up is running. Cancel it to tidy another text."
            return
        }
        inputView.string = text
        showResult(nil)
        statusLabel.stringValue = ""
    }

    // MARK: - Model

    private func showModel() {
        let status = actions.modelStatus()
        let busy = installing != nil || running != nil
        if let installing {
            modelLabel.stringValue = installing
        } else {
            switch status {
            case .installed:
                modelLabel.stringValue = "\(TidyModel.displayName) tidies on this Mac."
            case .downloading:
                modelLabel.stringValue = "\(TidyModel.displayName) is being installed by another process."
            case .notInstalled:
                modelLabel.stringValue = "Apple's on-device model tidies (English and French; Apple Intelligence on). "
                    + "\(TidyModel.displayName) makes better paragraphs and lists and knows more languages: about "
                    + "5.7 GB, it runs on this Mac."
            }
        }
        installButton.isHidden = status == .installed
        fromFileButton.isHidden = status == .installed
        removeButton.isHidden = status != .installed
        for button in [installButton, fromFileButton, removeButton] { button.isEnabled = !busy && status != .downloading }
        tidyButton.isEnabled = running == nil && installing == nil
    }

    @objc private func install() { startInstall(from: nil) }

    @objc private func installFromFile() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose \(TidyModel.fileName). It is checked, then copied; your file stays where it is."
        panel.prompt = "Use File"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startInstall(from: url)
        }
    }

    private func startInstall(from file: URL?) {
        guard installing == nil, running == nil else { return }
        installing = file == nil ? "Starting the download…" : "Checking \(file!.lastPathComponent)…"
        let started = actions.install(file, { [weak self] line in
            guard let self, self.installing != nil else { return }
            self.installing = line
            self.showModel()
        }, { [weak self] failure in
            guard let self else { return }
            self.installing = nil
            self.showModel()
            self.modelLabel.stringValue = failure.map { "Qwen was not installed: \($0)" } ?? self.modelLabel.stringValue
        })
        if !started {
            installing = nil
            showModel()
            modelLabel.stringValue = "Qwen cannot be installed: the voiceislocal tool could not start."
            return
        }
        showModel()
    }

    @objc private func remove() {
        guard let window = view.window, installing == nil, running == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(TidyModel.displayName)?"
        alert.informativeText = "Its file (about 5.7 GB) is deleted from Voice is Local's folder. Tidy Up then uses "
            + "Apple's on-device model. You can install Qwen again at any time."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.installing = "Removing…"
            self.showModel()
            let started = self.actions.remove { [weak self] failure in
                guard let self else { return }
                self.installing = nil
                self.showModel()
                if let failure { self.modelLabel.stringValue = "Qwen was not removed: \(failure)" }
            }
            if !started {
                self.installing = nil
                self.showModel()
                self.modelLabel.stringValue = "Qwen cannot be removed: the voiceislocal tool could not start."
            }
        }
    }

    // MARK: - Tidying

    @objc private func loadLast() {
        guard running == nil else { return }
        guard let text = actions.lastDictation(), !text.isEmpty else {
            statusLabel.stringValue = "No dictation since Voice is Local started. History's Tidy Up… opens an earlier one."
            return
        }
        load(text)
    }

    @objc private func tidy() {
        let text = inputView.string
        guard running == nil, installing == nil else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusLabel.stringValue = "Paste or type a text first, or use Last Dictation."
            return
        }
        guard text.utf8.count <= Self.maximumBytes else {
            statusLabel.stringValue = "The text is longer than Tidy Up takes (1 MB). Tidy it in parts."
            return
        }
        generation += 1
        let ticket = generation
        let model = actions.modelStatus() == .installed ? TidyModel.displayName : "Apple's on-device model"
        switch actions.tidy(text, { [weak self] result in
            guard let self, self.generation == ticket else { return }
            self.running = nil
            self.finished(result)
        }) {
        case .success(let handle):
            running = handle
            statusLabel.stringValue = "Tidying with \(model)… A long text takes a minute or more."
            showResult(nil)
            setRunning(true)
        case .failure(let error):
            statusLabel.stringValue = "Cannot tidy: \(error.localizedDescription)"
        }
    }

    @objc private func cancel() {
        generation += 1
        running?.terminate()
        running = nil
        setRunning(false)
        statusLabel.stringValue = "Cancelled."
    }

    /// The most text `voiceislocal tidy` takes (`Tidy.maximumBytes`).
    static let maximumBytes = 1_000_000

    private func setRunning(_ on: Bool) {
        lastButton.isEnabled = !on
        cancelButton.isHidden = !on
        inputView.isEditable = !on
        showModel()
    }

    private func finished(_ result: CommandResult<TidyCommand.Outcome>) {
        setRunning(false)
        guard let outcome = result.outcome else {
            statusLabel.stringValue = "Not tidied: " + (result.lastErrorLine ?? "the voiceislocal tool stopped (code \(result.code)).")
            return
        }
        let total = outcome.parts.count
        let kept = outcome.parts.enumerated().compactMap { index, part in
            part.kept.map { total == 1 ? "The text was left as it was: \($0)." : "Part \(index + 1) of \(total) was left as it was: \($0)." }
        }
        if outcome.nothingTidied {
            statusLabel.stringValue = kept.joined(separator: " ")
            showResult(nil)
            return
        }
        let engine = outcome.engine == .qwen ? TidyModel.displayName : "Apple's on-device model"
        statusLabel.stringValue = (["Tidied with \(engine)."] + kept).joined(separator: " ")
        showResult(TidyReview(text: outcome.text, changes: outcome.changes))
    }

    /// The edit with removed words struck through and added ones underlined; nil clears it.
    private func showResult(_ review: TidyReview?) {
        self.review = review
        copyButton.isEnabled = review != nil
        guard let review else {
            resultView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            resultView.setAccessibilityValue("")
            summaryLabel.stringValue = ""
            return
        }
        let shown = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        for segment in review.segments {
            var attributes = base
            switch segment.kind {
            case .kept: break
            case .added:
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = NSColor.systemGreen
            case .removed:
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = NSColor.systemRed
            }
            shown.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        resultView.textStorage?.setAttributedString(shown)
        resultView.setAccessibilityValue(review.spokenText)
        summaryLabel.stringValue = review.summary
    }

    @objc private func copyTidied() {
        guard let review, !review.text.isEmpty else { return }
        statusLabel.stringValue = actions.copy(review.text)
            ? "Copied the tidied text (without the struck-through words)." : "Clipboard write failed."
    }
}
