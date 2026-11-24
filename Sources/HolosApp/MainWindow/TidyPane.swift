import AppKit
import HolosAppModel
import HolosCore
import HolosDictation
import HolosMeeting

/// The main window's Tidy Up section (docs/design.md "Tidy Up"): paste or type a text (or take the last dictation,
/// or one from History), and a model on this Mac rejoins the sentences a pause split and adds paragraphs, lists and
/// quotes. The edit shows the words it removed struck through in place and the words it added underlined
/// (`TidyReview`); Copy Tidied Text copies it, and nothing is ever copied otherwise.
///
/// Invariants:
/// 1. One tidy-up or one model change at a time; Cancel stops the tidy-up, and its result is dropped.
/// 2. The clipboard is written only by Copy Tidied Text, with the edit shown.
/// 3. The input fills the panel until a tidy-up is requested. Its progress, error or edit belongs to the right pane.
@MainActor
final class TidyPane: NSViewController, MainSectionContent {
    struct Actions {
        /// Starts `voiceislocal tidy --json` on `text`; `completion` gets its result on the main actor. Nil when the
        /// tool cannot start, with the reason.
        var tidy: (_ text: String, _ engine: TidyCommand.Engine?,
                   _ completion: @escaping @MainActor (CommandResult<TidyCommand.Outcome>) -> Void)
            -> Result<CommandHandle, Error>
        /// Starts `voiceislocal setup --tidy-model` (with `--from` a file already on this Mac); `progress` gets its
        /// latest line, `done` nil or the failure. False when it cannot start.
        var install: (_ variant: TidyModel.Variant, _ from: URL?, _ progress: @escaping @MainActor (String) -> Void,
                      _ done: @escaping @MainActor (String?) -> Void) -> Bool
        /// Runs `voiceislocal setup --remove-tidy-model`; `done` gets nil or the failure.
        var remove: (_ variant: TidyModel.Variant, _ done: @escaping @MainActor (String?) -> Void) -> Bool
        /// The newest dictation since launch, if any.
        var lastDictation: () -> String?
        /// Copies `text` to the clipboard (only ever on Copy Tidied Text).
        var copy: (_ text: String) -> Bool
        var modelStatus: (TidyModel.Variant) -> DeepModelStatus = { $0.status() }
    }

    private let actions: Actions
    private let inputView: NSTextView
    private let resultView: NSTextView
    private let modelLabel = NSTextField(wrappingLabelWithString: "")
    private let modelPicker = NSPopUpButton()
    private let installButton = NSButton(title: "Install Qwen…", target: nil, action: nil)
    private let fromFileButton = NSButton(title: "Use a File Already Downloaded…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Qwen…", target: nil, action: nil)
    private let tidyButton = NSButton(title: "Tidy Up", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let lastButton = NSButton(title: "Last Dictation", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Tidied Text", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let resultStatus = NSTextField(wrappingLabelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let resultPanel = NSStackView()
    private let modelOptions = NSStackView()
    private var panelWidths: (full: NSLayoutConstraint, split: NSLayoutConstraint)?
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
        copyButton.toolTip = "Copy the tidied text, without the struck-through words"
        cancelButton.isHidden = true
        copyButton.isEnabled = false

        for label in [modelLabel, statusLabel, resultStatus, summaryLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }
        resultStatus.maximumNumberOfLines = 3
        view = makeContent(input: inputScroll, result: resultScroll)
        showModel()
        resetOutput()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeContent(input: NSScrollView, result: NSScrollView) -> NSView {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Tidying text")
        let status = NSStackView(views: [spinner, resultStatus])
        status.alignment = .centerY
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        resultPanel.orientation = .vertical
        resultPanel.alignment = .leading
        for item in [status, result, summaryLabel, copyButton] { resultPanel.addArrangedSubview(item) }
        for item in [status, result, summaryLabel] {
            item.widthAnchor.constraint(equalTo: resultPanel.widthAnchor).isActive = true
        }

        let panels = NSView()
        for item in [input, resultPanel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            panels.addSubview(item)
            item.topAnchor.constraint(equalTo: panels.topAnchor).isActive = true
            item.bottomAnchor.constraint(equalTo: panels.bottomAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: panels.leadingAnchor),
            resultPanel.trailingAnchor.constraint(equalTo: panels.trailingAnchor),
            input.widthAnchor.constraint(equalTo: resultPanel.widthAnchor),
        ])
        let full = input.trailingAnchor.constraint(equalTo: panels.trailingAnchor)
        let split = input.trailingAnchor.constraint(equalTo: resultPanel.leadingAnchor, constant: -16)
        panelWidths = (full, split)

        let modelButton = NSButton(title: "Model Options…", target: self, action: #selector(toggleModelOptions(_:)))
        modelPicker.addItem(withTitle: "Automatic")
        for engine in TidyCommand.Engine.allCases {
            let language = engine.downloadable?.englishOnly == true ? " (English)" : ""
            modelPicker.addItem(withTitle: engine.displayName + language)
            modelPicker.lastItem?.representedObject = engine.rawValue
        }
        modelPicker.setAccessibilityLabel("Tidy Up model")
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)
        let modelButtons = WrappingRowView(views: [installButton, fromFileButton, removeButton])
        modelOptions.orientation = .vertical
        modelOptions.alignment = .leading
        modelOptions.addArrangedSubview(modelPicker)
        for item in [modelLabel, modelButtons] {
            modelOptions.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: modelOptions.widthAnchor).isActive = true
        }
        modelOptions.isHidden = true
        let inputActions = WrappingRowView(views: [tidyButton, cancelButton, lastButton, modelButton])
        let stack = NSStackView(views: [panels, inputActions, statusLabel, modelOptions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 500))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        for item in [panels, inputActions, statusLabel, modelOptions] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return content
    }

    @objc private func toggleModelOptions(_ sender: NSButton) {
        modelOptions.isHidden.toggle()
        sender.title = modelOptions.isHidden ? "Model Options…" : "Hide Model Options"
        (sender.superview as? WrappingRowView)?.viewsChanged()
    }

    var preferredFirstResponder: NSView? { inputView }

    func sectionDidShow() { showModel() }
    func sectionWindowDidBecomeKey() { showModel() }

    /// Puts `text` in the box (History's Tidy Up…), replacing what is there, and clears the last edit; while a
    /// tidy-up runs, says so and keeps the box.
    func load(_ text: String) {
        guard running == nil else {
            showInputStatus("A tidy-up is running. Cancel it to tidy another text.")
            return
        }
        inputView.string = text
        resetOutput()
    }

    // MARK: - Model

    private var selectedEngine: TidyCommand.Engine? {
        (modelPicker.selectedItem?.representedObject as? String).flatMap(TidyCommand.Engine.init(rawValue:))
    }

    private var selectedVariant: TidyModel.Variant? {
        selectedEngine == nil ? .qwen : selectedEngine?.downloadable
    }

    @objc private func modelChanged() { showModel() }

    private func showModel() {
        let variant = selectedVariant
        let status = variant.map(actions.modelStatus)
        let busy = installing != nil || running != nil
        if let installing {
            modelLabel.stringValue = installing
        } else if let variant {
            switch status {
            case .installed:
                modelLabel.stringValue = "\(variant.displayName) tidies on this Mac."
            case .downloading:
                modelLabel.stringValue = "\(variant.displayName) is being installed by another process."
            default:
                let fallback = selectedEngine == nil ? "Automatic uses Apple's on-device model until Qwen is installed. " : ""
                modelLabel.stringValue = fallback + "Download \(variant.displayName) (\(variant.downloadSize)) to use it on this Mac."
            }
        } else {
            modelLabel.stringValue = "Apple's on-device model tidies English and French with Apple Intelligence on."
        }
        installButton.title = variant == .qwen ? "Install Qwen…" : "Download Model…"
        removeButton.title = variant == .qwen ? "Remove Qwen…" : "Remove Model…"
        installButton.isHidden = variant == nil || status == .installed
        fromFileButton.isHidden = installButton.isHidden
        removeButton.isHidden = status != .installed
        for button in [installButton, fromFileButton, removeButton] { button.isEnabled = !busy && status != .downloading }
        (installButton.superview as? WrappingRowView)?.viewsChanged()
        modelPicker.isEnabled = !busy
        tidyButton.isEnabled = running == nil && installing == nil
    }

    @objc private func install() { startInstall(from: nil) }

    @objc private func installFromFile() {
        guard let window = view.window, let variant = selectedVariant else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose \(variant.fileName). It is checked, then copied; your file stays where it is."
        panel.prompt = "Use File"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startInstall(from: url)
        }
    }

    private func startInstall(from file: URL?) {
        guard installing == nil, running == nil, let variant = selectedVariant else { return }
        installing = file == nil ? "Starting the download…" : "Checking \(file!.lastPathComponent)…"
        let started = actions.install(variant, file, { [weak self] line in
            guard let self, self.installing != nil else { return }
            self.installing = line
            self.showModel()
        }, { [weak self] failure in
            guard let self else { return }
            self.installing = nil
            self.showModel()
            self.modelLabel.stringValue = failure.map { "\(variant.displayName) was not installed: \($0)" }
                ?? self.modelLabel.stringValue
        })
        if !started {
            installing = nil
            showModel()
            modelLabel.stringValue = "The download could not start because the voiceislocal tool is unavailable."
            return
        }
        showModel()
    }

    @objc private func remove() {
        guard let window = view.window, installing == nil, running == nil, let variant = selectedVariant else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(variant.displayName)?"
        alert.informativeText = "This frees about \(variant.downloadSize) on this Mac. You can download it again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.installing = "Removing…"
            self.showModel()
            let started = self.actions.remove(variant) { [weak self] failure in
                guard let self else { return }
                self.installing = nil
                self.showModel()
                if let failure { self.modelLabel.stringValue = "\(variant.displayName) was not removed: \(failure)" }
            }
            if !started {
                self.installing = nil
                self.showModel()
                self.modelLabel.stringValue = "The model could not be removed because the voiceislocal tool is unavailable."
            }
        }
    }

    // MARK: - Tidying

    @objc private func loadLast() {
        guard running == nil else { return }
        guard let text = actions.lastDictation(), !text.isEmpty else {
            showInputStatus("No dictation since Voice is Local started. History's Tidy Up… opens an earlier one.")
            return
        }
        load(text)
    }

    @objc private func tidy() {
        let text = inputView.string
        guard running == nil, installing == nil else { return }
        showInputStatus(nil)
        setOutputVisible(true)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("Paste or type a text first, or use Last Dictation.")
            return
        }
        guard text.utf8.count <= Self.maximumBytes else {
            showError("The text is longer than Tidy Up takes (1 MB). Tidy it in parts.")
            return
        }
        generation += 1
        let ticket = generation
        let engine = selectedEngine ?? (actions.modelStatus(.qwen) == .installed ? .qwen : .apple)
        switch actions.tidy(text, selectedEngine, { [weak self] result in
            guard let self, self.generation == ticket else { return }
            self.running = nil
            self.finished(result)
        }) {
        case .success(let handle):
            running = handle
            showResult(nil)
            showResultStatus("Tidying with \(engine.displayName)…", animating: true)
            setRunning(true)
        case .failure(let error):
            showError("Cannot tidy: \(error.localizedDescription)")
        }
    }

    @objc private func cancel() {
        generation += 1
        running?.terminate()
        running = nil
        setRunning(false)
        resetOutput()
        showInputStatus("Cancelled.")
    }

    /// The most text `voiceislocal tidy` takes (`Tidy.maximumBytes`).
    static let maximumBytes = 1_000_000

    private func setRunning(_ on: Bool) {
        lastButton.isEnabled = !on
        cancelButton.isHidden = !on
        (cancelButton.superview as? WrappingRowView)?.viewsChanged()
        inputView.isEditable = !on
        showModel()
    }

    private func setOutputVisible(_ visible: Bool) {
        guard let panelWidths else { return }
        let (active, inactive) = visible ? (panelWidths.split, panelWidths.full) : (panelWidths.full, panelWidths.split)
        inactive.isActive = false
        active.isActive = true
        resultPanel.isHidden = !visible
    }

    private func resetOutput() {
        setOutputVisible(false)
        showInputStatus(nil)
        showResultStatus(nil)
        showResult(nil)
    }

    private func showInputStatus(_ message: String?) {
        statusLabel.stringValue = message ?? ""
        statusLabel.isHidden = message == nil
    }

    private func showResultStatus(_ message: String?, animating: Bool = false) {
        resultStatus.stringValue = message ?? ""
        resultStatus.toolTip = message
        resultStatus.superview?.isHidden = message == nil
        spinner.isHidden = !animating
        if animating { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func showError(_ message: String) {
        showResult(nil)
        showResultStatus(nil)
        resultView.textStorage?.setAttributedString(NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
        ]))
        resultView.setAccessibilityValue(message)
    }

    private func finished(_ result: CommandResult<TidyCommand.Outcome>) {
        setRunning(false)
        showInputStatus(nil)
        guard let outcome = result.outcome else {
            showError("Not tidied: " + (result.lastErrorLine ?? "the voiceislocal tool stopped (code \(result.code))."))
            return
        }
        let total = outcome.parts.count
        let kept = outcome.parts.enumerated().compactMap { index, part in
            part.kept.map { total == 1 ? "The text was left as it was: \($0)." : "Part \(index + 1) of \(total) was left as it was: \($0)." }
        }
        if outcome.nothingTidied {
            showError(kept.isEmpty ? "The text could not be tidied." : kept.joined(separator: " "))
            return
        }
        showResultStatus((["Tidied with \(outcome.engine.displayName)."] + kept).joined(separator: " "))
        showResult(TidyReview(text: outcome.text, changes: outcome.changes))
    }

    /// The edit with removed words struck through and added ones underlined; nil clears it.
    private func showResult(_ review: TidyReview?) {
        self.review = review
        copyButton.isEnabled = review != nil
        summaryLabel.isHidden = review == nil
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
        showInputStatus(actions.copy(review.text)
            ? "Copied the tidied text (without the struck-through words)." : "Clipboard write failed.")
    }
}
