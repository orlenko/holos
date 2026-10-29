import AppKit
import HolosContent
import UniformTypeIdentifiers
import HolosSynthesis

/// The main window's Reading section (docs/design.md "Reading section"): a New Reading card (a link or a file, a voice
/// with Preview, a speed, Make Audio) over the list of readings, each made into one `.m4a` in the output folder and
/// played, shared, shown in Finder, or deleted from its row. Links and files can be dropped anywhere on the section
/// or pasted with ⌘V.
///
/// Invariants:
/// 1. Inventory refreshes retain the card's requested voice and speed, including during a natural pack reinstall.
/// 2. Only an explicit voice choice or a preferences change replaces the requested voice.
@MainActor
final class ReadingPane: NSViewController, MainSectionContent, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSMenuItemValidation {
    private let controller: ReadingController
    private let player = ReadingPlayer()
    let preview = VoicePreview()
    /// The last Preview's failure while it is shown; a new Preview clears it.
    private var previewProblem: String?
    private let field = NSTextField()
    private let chooseButton = NSButton(title: "Choose File…", target: nil, action: nil)
    let voicePopup = ReadingVoicePopup(frame: .zero)
    private let previewButton = NSButton(title: "▶ Preview", target: nil, action: nil)
    let speedSlider = NSSlider(value: ReadingSpeed.standard, minValue: ReadingSpeed.range.lowerBound,
                                       maxValue: ReadingSpeed.range.upperBound, target: nil, action: nil)
    private let speedLabel = NSTextField(labelWithString: "")
    private let makeButton = NSButton(title: "Make Audio", target: nil, action: nil)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let table = KeyTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let dropView = ReadingDropView()
    private var rows: [ReadingEntry] = []
    private var windowObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var voicesObserver: NSObjectProtocol?
    /// The card's chosen voice (nil: Automatic), kept while its pack is briefly missing (a reinstall).
    private var chosenVoice: String?
    /// The natural voice packs the menu offers (tests set it).
    var installedPacks: () -> Set<NaturalVoicePack> = { NaturalVoicesAppState.shared.installed }

    init(controller: ReadingController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        view = makeContent()
        controller.onChange = { [weak self] in self?.reload() }
        controller.onProgress = { [weak self] id in self?.reloadRow(id) }
        player.onChange = { [weak self] in self?.playerChanged() }
        player.onError = { [weak self] problem in self?.showMessage(problem, problem: true) }
        preview.onChange = { [weak self] in self?.updatePreviewButton() }
        preview.onError = { [weak self] in self?.previewProblem = $0; self?.showMessage($0, problem: true) }
        preview.renderNatural = VoicePreview.renderedByHelper()
        // Natural voices installed: the menu offers them, and the card keeps the voice and speed chosen in it.
        voicesObserver = NotificationCenter.default.addObserver(
            forName: ReadingVoices.installedChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVoices() }
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: ReadingPreferences.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        applyPreferences()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredFirstResponder: NSView? { field }

    func sectionDidShow() {
        refreshVoices()
        controller.recheck()
        reload()
        if windowObserver == nil, let window = view.window {
            // Nothing keeps playing once the window is closed: its controls are gone with it.
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.player.stop()
                    self?.preview.stop()
                }
            }
        }
    }

    func sectionDidHide() {
        preview.stop()
    }

    /// Back from Finder: a file moved or deleted there shows.
    func sectionWindowDidBecomeKey() {
        // A drive reconnected or a file put back meanwhile: a reading whose identity is still unknown is checked again.
        controller.recheck()
        reload()
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        field.placeholderString = "Paste a link, or drop a PDF, Word, HTML, Markdown or text file here"
        field.delegate = self
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("Link or file to read")
        chooseButton.target = self
        chooseButton.action = #selector(chooseFile)
        chooseButton.bezelStyle = .push
        chooseButton.toolTip = "Choose one or more documents to read"

        voicePopup.setAccessibilityLabel("Voice")
        voicePopup.onChoose = { [weak self] in self?.chosenVoice = $0 }
        // The full choice remains accessible when this button narrows with the section.
        let voiceWidth = voicePopup.widthAnchor.constraint(equalToConstant: 340)
        voiceWidth.priority = .defaultLow
        voiceWidth.isActive = true
        voicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        voicePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewButton.target = self
        previewButton.action = #selector(togglePreview)
        previewButton.bezelStyle = .push
        previewButton.toolTip = "Hear a short sample with this voice and speed; press again to stop"
        speedSlider.numberOfTickMarks = 7
        speedSlider.allowsTickMarkValuesOnly = true
        speedSlider.target = self
        speedSlider.action = #selector(speedChanged)
        speedSlider.setAccessibilityLabel("Speed")
        // 150 points, narrower in a narrow window so Make Audio stays in the card.
        let speedWidth = speedSlider.widthAnchor.constraint(equalToConstant: 150)
        speedWidth.priority = .defaultLow
        speedWidth.isActive = true
        speedSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        makeButton.target = self
        makeButton.action = #selector(makeAudio)
        makeButton.bezelStyle = .push
        makeButton.keyEquivalent = "\r"
        makeButton.isEnabled = false
        makeButton.toolTip = "Make one audio file of the link or file (Return)"
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.isHidden = true

        let sourceRow = NSStackView(views: [field, chooseButton])
        sourceRow.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Two rows, so everything fits the section's narrowest width (400 pt, the window with its sidebar hidden):
        // the voice with Preview, then the speed with Make Audio at the end.
        let voiceLabel = NSTextField(labelWithString: "Voice")
        let speedTitle = NSTextField(labelWithString: "Speed")
        for label in [voiceLabel, speedTitle] {
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let voiceRow = NSStackView(views: [voiceLabel, voicePopup, previewButton])
        voiceRow.spacing = 8
        voiceRow.alignment = .centerY
        let speedRow = NSStackView(views: [speedTitle, speedSlider, speedLabel, NSView(), makeButton])
        speedRow.spacing = 8
        speedRow.alignment = .centerY
        let heading = NSTextField(labelWithString: "New reading")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let cardStack = NSStackView(views: [sourceRow, voiceRow, speedRow, messageLabel])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        let card = CardView()
        card.addSubview(cardStack)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("New reading")
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            sourceRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            speedRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            voiceRow.widthAnchor.constraint(lessThanOrEqualTo: cardStack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reading"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAutomaticRowHeights = false
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onSpace = { [weak self] in
            self?.playSelected()
            return true
        }
        table.target = self
        table.doubleAction = #selector(playSelected)
        table.setAccessibilityLabel("Readings")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let listHeading = NSTextField(labelWithString: "Readings")
        listHeading.font = .systemFont(ofSize: 13, weight: .semibold)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.stringValue = "No readings yet.\nPaste a link or drop a document above: it becomes one audio file "
            + "you can play here or send to your phone."
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        let openFolder = NSButton(title: "Open Folder", target: self, action: #selector(openFolder))
        openFolder.bezelStyle = .push
        openFolder.controlSize = .small
        openFolder.toolTip = "Show the folder the audio files are saved in"
        let footerRow = NSStackView(views: [footer, NSView(), openFolder])
        footerRow.alignment = .centerY
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [heading, card, listHeading, scroll, footerRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [card, scroll, footerRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        dropView.addSubview(stack)
        dropView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: dropView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
        // A drop of things that cannot be read is taken too, so the reason shows under the card.
        dropView.accepts = { [weak self] pasteboard in
            // Told from what the pasteboard offers alone: nothing is looked up while a drag passes over.
            self?.offered(pasteboard).isEmpty == false
        }
        dropView.onDrop = { [weak self] pasteboard in self?.takeDrop(pasteboard) ?? false }
        dropView.onShareKey = { [weak self] in self?.shareSelected() ?? false }
        return dropView
    }

    // MARK: - New reading
    private var selectedVoice: String? { voicePopup.selectedID }

    /// The card's voice and speed follow Settings › Reading.
    private func applyPreferences() {
        refreshVoices(selecting: ReadingPreferences.voice)
        speedSlider.doubleValue = ReadingPreferences.speed
        speedLabel.stringValue = ReadingSpeed.label(speedSlider.doubleValue)
        footer.stringValue = footerText
    }

    private var footerText: String {
        if let notice = controller.notice { return notice }
        return "Audio files are saved in \(ReadingPreferences.folderText) (Settings › Reading). Nothing is uploaded: "
            + "the only things fetched are the page you paste and, when you download them, the natural voices."
    }

    /// Refreshes the picker while retaining the card's choice (invariant 1).
    private func refreshVoices(selecting id: String?? = nil) {
        if let id { chosenVoice = id }
        ReadingVoicePopup.fill(voicePopup, selecting: chosenVoice, installed: installedPacks())
    }

    func controlTextDidChange(_ notification: Notification) {
        inputGeneration += 1
        makeButton.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        showMessage(nil)
    }

    @objc private func makeAudio() {
        let text = field.stringValue
        makeButton.isEnabled = false
        inputGeneration += 1
        let asked = inputGeneration
        Task { @MainActor [weak self] in
            // A path is looked up off the main actor (it may be on a share that stopped answering).
            let parsed = try? await offMain { ReadingSourceParser.parse(text) }
            // Another source was typed, dropped, or chosen meanwhile: this one is not added.
            guard let self, asked == self.inputGeneration else { return }
            defer { self.makeButton.isEnabled = !self.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            switch parsed {
            case .success(let source)?:
                // The field is emptied once the reading is added (unless it was changed meanwhile).
                guard await self.add([source]), self.field.stringValue == text else { return }
                self.field.stringValue = ""
            case .failure(let problem)?:
                self.showMessage(problem.message, problem: true)
            case nil:
                break
            }
        }
    }

    /// Adds the readings; false (with the reason shown) when the list takes none.
    @discardableResult
    private func add(_ sources: [ReadingSource]) async -> Bool {
        let (voice, speed) = (chosenVoice, speedSlider.doubleValue)  // chosen, even before its pack is offered
        var last: UUID?
        for source in sources {
            do {
                last = try await controller.add(source, voice: voice, speed: speed)
            } catch {
                showMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, problem: true)
                return false
            }
        }
        if let last { select(last) }
        showMessage(sources.count == 1
            ? "Added. The audio file appears in the list below when it is made."
            : "Added \(sources.count) readings; they are made one after another.")
        return true
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DocumentLoader.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose \(ReadingSourceParser.kinds) to read aloud."
        panel.prompt = "Choose"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                _ = self?.take(Offered(files: panel.urls, urls: [], strings: []))
            }
        }
    }

    /// A drop, a paste, or files chosen: one source goes in the field, for a voice and Make Audio; several are added
    /// at once with the card's voice and speed.
    private func take(_ found: (sources: [ReadingSource], problems: [ReadingSourceProblem])) async {
        if found.sources.count == 1, let source = found.sources.first {
            field.stringValue = source.fieldText
            makeButton.isEnabled = true
            view.window?.makeFirstResponder(field)
            showMessage(found.problems.first?.message ?? "Choose a voice and speed, then Make Audio (Return).",
                        problem: !found.problems.isEmpty)
        } else if found.sources.count > 1 {
            if await add(found.sources), let problem = found.problems.first {
                showMessage(problem.message, problem: true)
            }
        } else if let problem = found.problems.first {
            showMessage(problem.message, problem: true)
        }
    }

    /// Takes what `offered` holds (see `take(_:)`), its paths looked up off the main actor (they may be on a share
    /// that stopped answering). Returns whether it offers anything, told from what is offered alone (what cannot be
    /// read is explained under the card): only then is a drop taken or a paste not refused. A result that comes after
    /// the field was typed in, or after another drop, paste, or choice, is dropped.
    @discardableResult
    private func take(_ offered: Offered) -> Bool {
        guard !offered.isEmpty else { return false }
        inputGeneration += 1
        let asked = inputGeneration
        Task { @MainActor [weak self] in
            guard let found = try? await offMain({ offered.parsed }), let self, asked == self.inputGeneration else {
                return
            }
            await self.take(found)
        }
        return true
    }

    /// Counts what the user did with the card's source (typed, dropped, pasted, chose), so a look-up that ends after
    /// another does not overwrite it.
    private var inputGeneration = 0

    /// A drop is taken when anything in it can be used or explained under the card (a folder or an unreadable file
    /// says why): only a drop of nothing at all is refused, so AppKit shows failure only then.
    private func takeDrop(_ pasteboard: NSPasteboard) -> Bool {
        take(offered(pasteboard))
    }

    /// What a pasteboard offers: file URLs, web URLs, and text.
    private struct Offered: Sendable {
        var files: [URL]
        var urls: [URL]
        var strings: [String]

        /// The sources, each path looked up (not on the main actor).
        var parsed: (sources: [ReadingSource], problems: [ReadingSourceProblem]) {
            ReadingSourceParser.sources(fileURLs: files, urls: urls, strings: strings)
        }

        /// Nothing is offered (no file, link, or text other than spaces).
        var isEmpty: Bool {
            files.isEmpty && urls.isEmpty && strings.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private func offered(_ pasteboard: NSPasteboard) -> Offered {
        Offered(files: pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [],
                urls: pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [],
                strings: pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] ?? [])
    }

    /// ⌘V outside the field: the link or files on the clipboard go in as a drop would.
    @objc func paste(_ sender: Any?) {
        if !take(offered(NSPasteboard.general)) { NSSound.beep() }
    }

    @objc private func speedChanged() {
        speedLabel.stringValue = ReadingSpeed.label(speedSlider.doubleValue)
        if preview.isSpeaking { startPreview() }
    }

    @objc func togglePreview() {
        if preview.isSpeaking { preview.stop() } else {
            player.pause()
            startPreview()
        }
    }

    /// Speaks the sample, clearing the previous Preview's failure (one of this attempt is shown when it comes).
    private func startPreview() {
        if let shown = previewProblem, messageLabel.stringValue == shown { showMessage(nil) }
        previewProblem = nil
        preview.speak(voiceIdentifier: selectedVoice, speed: speedSlider.doubleValue)
    }

    var message: String? { messageLabel.isHidden ? nil : messageLabel.stringValue }  // the card's message (tests)

    private func updatePreviewButton() {
        previewButton.title = preview.isSpeaking ? "■ Stop" : "▶ Preview"
    }

    private func showMessage(_ text: String?, problem: Bool = false) {
        messageLabel.stringValue = text ?? ""
        messageLabel.textColor = problem ? .systemOrange : .secondaryLabelColor
        messageLabel.isHidden = text == nil
    }

    @objc private func openFolder() {
        let folder = ReadingPreferences.folder
        let (isDefault, shown) = (ReadingPreferences.isDefaultFolder, ReadingPreferences.folderText)
        // Looked up off the main actor: the folder may be on a share that stopped answering.
        Task { @MainActor [weak self] in
            let exists = (try? await offMain { FileManager.default.fileExists(atPath: folder.path) }) ?? false
            guard let self else { return }
            if exists {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } else if isDefault {
                self.showMessage("\(shown) does not exist yet; it is made with the first reading.")
            } else {
                // A folder chosen in Settings is never made in its place (see `ReadingLibrary.outputFolder`).
                self.showMessage("\(shown), chosen in Settings › Reading, is not available. Connect its disk, or "
                    + "choose another folder there.", problem: true)
            }
        }
    }

    // MARK: - List

    private func reload() {
        let selected = selectedEntry?.id
        rows = controller.entries
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        emptyLabel.isHidden = !rows.isEmpty
        footer.stringValue = footerText
        footer.textColor = controller.notice == nil ? .secondaryLabelColor : .systemOrange
        stopPlaybackOfGoneFile()
    }

    /// The reading being played left the list, or the last check of its file found it moved, deleted, or replaced
    /// (its row now offers no Pause): playback stops rather than go on with no control to stop it. Looks nothing up
    /// (see `ReadingController.refreshFiles`). Returns whether it stopped (the player then reports the change itself).
    @discardableResult
    private func stopPlaybackOfGoneFile() -> Bool {
        guard let playing = player.entryID else { return false }
        if let entry = rows.first(where: { $0.id == playing }), entry.state == .done,
           controller.fileProblem(entry) == nil { return false }
        player.unload()
        return true
    }

    private func reloadRow(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }), let entry = controller.entry(id) else { return }
        rows[index] = entry
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ReadingRowView {
            configure(cell, entry)
        }
    }

    private func select(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    private var selectedEntry: ReadingEntry? {
        let row = table.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 72 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("readingRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ReadingRowView
            ?? ReadingRowView(identifier: identifier)
        cell.onAction = { [weak self, weak cell] id, action in
            guard let cell else { return }
            self?.perform(action, on: id, from: cell)
        }
        configure(cell, rows[row])
        return cell
    }

    private func configure(_ cell: ReadingRowView, _ entry: ReadingEntry) {
        // A made reading whose file was moved, deleted, or replaced by another file shows as missing; one whose drive
        // or share is not connected, as unavailable. From the controller's last check of the files: nothing is
        // looked up here (a share that stopped answering would hold the window).
        let problem = controller.fileProblem(entry)
        var playback: ReadingRowView.Playback?
        if player.entryID == entry.id {
            playback = ReadingRowView.Playback(playing: player.isPlaying, current: player.position?.current,
                                               duration: player.position?.duration)
        }
        let size = problem != nil ? nil : controller.finishedFile(entry)?.size
        cell.show(entry, activity: controller.activity[entry.id], fileProblem: problem, size: size, playback: playback)
    }

    /// The player's state or position changed (twice a second while it plays): only the rows it concerns, the one
    /// loaded and the one loaded before, are shown again, so a tick never looks up every visible reading's file.
    private func playerChanged() {
        // Each tick checks too: a file moved or replaced while it plays stops it before its row loses Pause.
        if stopPlaybackOfGoneFile() { return }
        let concerned = Set([player.entryID, lastPlayerEntry].compactMap { $0 })
        lastPlayerEntry = player.entryID
        for id in concerned { reloadRow(id) }
    }

    /// The reading the player had loaded when it last changed, so its row is shown again once another is loaded.
    private var lastPlayerEntry: UUID?

    // MARK: - Row actions

    private func perform(_ action: ReadingRowView.Action, on id: UUID, from cell: ReadingRowView) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        switch action {
        case .play: play(id)
        case .stop:
            if let problem = controller.stop(id) { showMessage(problem, problem: true) }
        case .retry:
            if let problem = controller.retry(id) { showMessage(problem, problem: true) }
        case .showText: showText(id)
        case .share: share(id, from: cell.shareAnchor)
        case .reveal: reveal(id)
        case .delete: confirmDelete(id)
        }
    }

    /// Space, double-click, ▶ Play: plays, pauses, or continues the selected finished reading.
    @objc private func playSelected() {
        guard let entry = selectedEntry else { return }
        play(entry.id)
    }

    private func play(_ id: UUID) {
        preview.stop()
        if player.toggleLoaded(id) { return }
        guard let entry = controller.entry(id), entry.state == .done, controller.fileProblem(entry) == nil else {
            NSSound.beep()
            return
        }
        // Played from the file opened and checked off the main actor, never the path (see
        // `ReadingController.openFinishedFile`). The player counts the request from now, so a later Play, Stop, or
        // Pause wins over this one while its file is opened.
        let controller = controller
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let played = try await self.player.play(id) { await controller.openFinishedFile(entry) }
                if !played { NSSound.beep() }
            } catch {
                self.showMessage("“\(entry.title)” could not be played: \(error.localizedDescription)", problem: true)
            }
        }
    }

    /// ⌘⇧S: Share… for the selected reading.
    private func shareSelected() -> Bool {
        guard let entry = selectedEntry, let index = table.selectedRowIndexes.first else { return false }
        let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ReadingRowView
        return share(entry.id, from: cell?.shareAnchor ?? table)
    }

    @discardableResult
    private func share(_ id: UUID, from anchor: NSView) -> Bool {
        guard let entry = controller.entry(id), entry.state == .done, controller.fileProblem(entry) == nil else {
            NSSound.beep()
            return false
        }
        // The services read a copy made from the file opened and checked (off the main actor: a clone where the
        // volume can, else its bytes), so a file put at its path meanwhile is never the one sent.
        Task { @MainActor [weak self, weak anchor] in
            guard let self else { return }
            do {
                let copy = try await self.controller.shareableCopy(entry)
                guard let anchor, anchor.window != nil else { return }
                let picker = NSSharingServicePicker(items: [copy])
                let rect = anchor === self.table ? self.table.rect(ofRow: max(0, self.table.selectedRow)) : anchor.bounds
                picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
            } catch {
                self.showMessage("“\(entry.title)” could not be shared: \(error.localizedDescription)", problem: true)
            }
        }
        return true
    }

    /// Show Text: the reading's saved text in a sheet, read off the main actor (a book's is megabytes).
    func showText(_ id: UUID) {
        guard let entry = controller.entry(id) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let document = try await self.controller.savedText(id) else {
                    self.showMessage("The text of “\(entry.title)” was not kept: an earlier version of Voice is "
                        + "Local made it, and kept only its audio.", problem: true)
                    return
                }
                self.presentAsSheet(ReadingTextSheet(title: entry.title, text: document.plainText))
            } catch {
                self.showMessage("The text of “\(entry.title)” could not be read: \(error.localizedDescription)",
                                 problem: true)
            }
        }
    }

    private func reveal(_ id: UUID) {
        guard let entry = controller.entry(id), entry.state == .done, controller.fileProblem(entry) == nil,
              let url = entry.outputURL else {
            NSSound.beep()
            return
        }
        // Shown only while it is the file the reading made (checked off the main actor).
        Task { @MainActor [weak self] in
            guard let self, await self.controller.openFinishedFile(entry) != nil else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func deleteSelected() {
        guard let entry = selectedEntry else { return }
        confirmDelete(entry.id)
    }

    private func confirmDelete(_ id: UUID) {
        guard let entry = controller.entry(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(entry.title)”?"
        alert.informativeText = switch entry.state {
        case .done: "The audio file moves to the Trash, and the reading leaves this list."
        case .queued, .rendering: "The reading stops, what was rendered so far is deleted, and it leaves this list."
        case .failed, .stopped: "What was rendered so far is deleted, and the reading leaves this list."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let delete = { [weak self] in
            guard let self else { return }
            let index = self.table.selectedRow
            if self.player.entryID == id { self.player.unload() }
            Task { @MainActor [weak self] in
                // The row leaves the list at once; its files are removed off the main actor.
                guard let outcome = await self?.controller.delete(id), let self else { return }
                switch outcome {
                case .kept(let problem):
                    self.showMessage(problem, problem: true)
                case .deleted(let note):
                    // An earlier failure's message no longer holds.
                    self.showMessage(note, problem: note != nil)
                    // The row that takes its place is selected, so ⌫ can go on down the list.
                    if index >= 0, !self.rows.isEmpty, self.table.selectedRow < 0 {
                        self.table.selectRowIndexes(IndexSet(integer: min(index, self.rows.count - 1)),
                                                    byExtendingSelection: false)
                    }
                }
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { MainActor.assumeIsolated { delete() } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            delete()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paste(_:)):
            let pasteboard = NSPasteboard.general
            return pasteboard.canReadObject(forClasses: [NSURL.self, NSString.self], options: nil)
        default:
            return true
        }
    }
}
