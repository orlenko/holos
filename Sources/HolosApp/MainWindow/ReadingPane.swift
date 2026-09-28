import AppKit
import HolosContent
import UniformTypeIdentifiers
import HolosSynthesis

/// The main window's Reading section (docs/design.md "Reading section"): a New Reading card (a link or a file, a voice
/// with Preview, a speed, Make Audio) over the list of readings, each made into one `.m4a` in the output folder and
/// played, shared, shown in Finder, or deleted from its row. Links and files can be dropped anywhere on the section
/// or pasted with ⌘V.
@MainActor
final class ReadingPane: NSViewController, MainSectionContent, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSMenuItemValidation {
    private let controller: ReadingController
    private let player = ReadingPlayer()
    private let preview = VoicePreview()
    private let field = NSTextField()
    private let chooseButton = NSButton(title: "Choose File…", target: nil, action: nil)
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previewButton = NSButton(title: "▶ Preview", target: nil, action: nil)
    private let speedSlider = NSSlider(value: ReadingSpeed.standard, minValue: ReadingSpeed.range.lowerBound,
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

    init(controller: ReadingController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        view = makeContent()
        controller.onChange = { [weak self] in self?.reload() }
        controller.onProgress = { [weak self] id in self?.reloadRow(id) }
        player.onChange = { [weak self] in self?.playerChanged() }
        preview.onChange = { [weak self] in self?.updatePreviewButton() }
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
        // Wide enough for "Ava (Premium) — English (United States)", narrower when the section is.
        let voiceWidth = voicePopup.widthAnchor.constraint(equalToConstant: 340)
        voiceWidth.priority = .defaultLow
        voiceWidth.isActive = true
        voicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
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
        speedSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
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
        // Two rows, so everything fits the section's narrowest width (600 pt, the window at 900 pt): the voice with
        // Preview, then the speed with Make Audio at the end.
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
            guard let found = self?.sources(in: pasteboard) else { return false }
            return !found.sources.isEmpty || !found.problems.isEmpty
        }
        dropView.onDrop = { [weak self] pasteboard in self?.take(pasteboard) ?? false }
        dropView.onShareKey = { [weak self] in self?.shareSelected() ?? false }
        return dropView
    }

    // MARK: - New reading

    private var selectedVoice: String? { voicePopup.selectedItem?.representedObject as? String }

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
            + "the only thing fetched is the page you paste."
    }

    /// Rebuilds the voice menu (voices can be installed while Voice is Local runs), keeping the choice.
    private func refreshVoices(selecting id: String?? = nil) {
        ReadingVoicePopup.fill(voicePopup, selecting: id ?? selectedVoice)
    }

    func controlTextDidChange(_ notification: Notification) {
        makeButton.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        showMessage(nil)
    }

    @objc private func makeAudio() {
        switch ReadingSourceParser.parse(field.stringValue) {
        case .success(let source):
            guard add([source]) else { return }
            field.stringValue = ""
            makeButton.isEnabled = false
        case .failure(let problem):
            showMessage(problem.message, problem: true)
        }
    }

    /// Adds the readings; false (with the reason shown) when the list takes none.
    @discardableResult
    private func add(_ sources: [ReadingSource]) -> Bool {
        var last: UUID?
        for source in sources {
            do {
                last = try controller.add(source, voice: selectedVoice, speed: speedSlider.doubleValue)
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
                _ = self?.take(ReadingSourceParser.sources(fileURLs: panel.urls, urls: [], strings: []))
            }
        }
    }

    /// A drop, a paste, or files chosen: one source goes in the field, for a voice and Make Audio; several are added
    /// at once with the card's voice and speed.
    @discardableResult
    private func take(_ found: (sources: [ReadingSource], problems: [ReadingSourceProblem])) -> Bool {
        if found.sources.count == 1, let source = found.sources.first {
            field.stringValue = source.fieldText
            makeButton.isEnabled = true
            view.window?.makeFirstResponder(field)
            showMessage(found.problems.first?.message ?? "Choose a voice and speed, then Make Audio (Return).",
                        problem: !found.problems.isEmpty)
        } else if found.sources.count > 1 {
            if add(found.sources), let problem = found.problems.first { showMessage(problem.message, problem: true) }
        } else if let problem = found.problems.first {
            showMessage(problem.message, problem: true)
        }
        return !found.sources.isEmpty
    }

    private func take(_ pasteboard: NSPasteboard) -> Bool {
        take(sources(in: pasteboard))
    }

    private func sources(in pasteboard: NSPasteboard) -> (sources: [ReadingSource], problems: [ReadingSourceProblem]) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] ?? []
        return ReadingSourceParser.sources(fileURLs: files, urls: urls, strings: strings)
    }

    /// ⌘V outside the field: the link or files on the clipboard go in as a drop would.
    @objc func paste(_ sender: Any?) {
        if !take(NSPasteboard.general) { NSSound.beep() }
    }

    @objc private func speedChanged() {
        speedLabel.stringValue = ReadingSpeed.label(speedSlider.doubleValue)
        if preview.isSpeaking { preview.speak(voiceIdentifier: selectedVoice, speed: speedSlider.doubleValue) }
    }

    @objc private func togglePreview() {
        if preview.isSpeaking { preview.stop() } else {
            player.pause()
            preview.speak(voiceIdentifier: selectedVoice, speed: speedSlider.doubleValue)
        }
    }

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
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            showMessage("\(ReadingPreferences.folderText) does not exist yet; it is made with the first reading.")
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

    /// The reading being played left the list, or its file was moved, deleted, or replaced (its row now offers no
    /// Pause): playback stops rather than go on with no control to stop it. Returns whether it stopped (the player
    /// then reports the change itself).
    @discardableResult
    private func stopPlaybackOfGoneFile() -> Bool {
        guard let playing = player.entryID,
              rows.first(where: { $0.id == playing }).flatMap(controller.finishedFile) == nil else { return false }
        player.stop()
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
        // or share is not connected, as unavailable.
        let file = controller.finishedFile(entry)
        let problem = controller.fileProblem(entry)
        var playback: ReadingRowView.Playback?
        if player.entryID == entry.id {
            playback = ReadingRowView.Playback(playing: player.isPlaying, current: player.position?.current,
                                               duration: player.position?.duration)
        }
        let size: Int64? = problem != nil ? nil : file.flatMap { Self.fileSize($0) }
        cell.show(entry, activity: controller.activity[entry.id], fileProblem: problem, size: size, playback: playback)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return Int64(size)
    }

    private func playerChanged() {
        // Each tick checks too: a file moved or replaced while it plays stops it before its row loses Pause.
        if stopPlaybackOfGoneFile() { return }
        for (index, entry) in rows.enumerated() {
            guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ReadingRowView else {
                continue
            }
            configure(cell, entry)
        }
    }

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
        guard let url = controller.entry(id).flatMap(controller.finishedFile) else {
            NSSound.beep()
            return
        }
        preview.stop()
        do {
            try player.toggle(id, url: url)
        } catch {
            showMessage("\(url.lastPathComponent) could not be played: \(error.localizedDescription)", problem: true)
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
        guard let url = controller.entry(id).flatMap(controller.finishedFile) else {
            NSSound.beep()
            return false
        }
        let picker = NSSharingServicePicker(items: [url])
        let rect = anchor === table ? table.rect(ofRow: max(0, table.selectedRow)) : anchor.bounds
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        return true
    }

    private func reveal(_ id: UUID) {
        guard let url = controller.entry(id).flatMap(controller.finishedFile) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
            if self.player.entryID == id { self.player.stop() }
            Task { @MainActor [weak self] in
                // The row leaves the list at once; its files are removed off the main actor.
                guard let problem = await self?.controller.delete(id), let self else {
                    // The row that takes its place is selected, so ⌫ can go on down the list.
                    if let self, index >= 0, !self.rows.isEmpty, self.table.selectedRow < 0 {
                        self.table.selectRowIndexes(IndexSet(integer: min(index, self.rows.count - 1)),
                                                    byExtendingSelection: false)
                    }
                    return
                }
                self.showMessage(problem, problem: true)
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

// MARK: - Voice menu

/// Fills a voice pop-up: "Automatic — best voice for the text's language", then the voices that speak the user's
/// languages, then the others (`ReadingVoiceMenu`), each item's `representedObject` the voice's identifier.
@MainActor
enum ReadingVoicePopup {
    static let automaticTitle = "Automatic — best voice for the text's language"

    /// `selecting` nil: Automatic. A voice that is not installed falls back to Automatic.
    static func fill(_ popup: NSPopUpButton, selecting id: String?) {
        let items = ReadingVoiceMenu.items(NativeSpeechRenderer.voices(), preferredLanguages: Locale.preferredLanguages)
        popup.removeAllItems()
        let automatic = NSMenuItem(title: automaticTitle, action: nil, keyEquivalent: "")
        popup.menu?.addItem(automatic)
        var previousPreferred: Bool?
        for item in items {
            if previousPreferred != item.preferred { popup.menu?.addItem(.separator()) }
            previousPreferred = item.preferred
            let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            entry.representedObject = item.id
            popup.menu?.addItem(entry)
        }
        if let id, let index = popup.menu?.items.firstIndex(where: { $0.representedObject as? String == id }) {
            popup.selectItem(at: index)
        } else {
            popup.select(automatic)
        }
    }
}

// MARK: - Drop target

/// The Reading section's root: takes dropped files and links anywhere on it (highlighted while one is over it), and
/// ⌘⇧S (Share…).
@MainActor
final class ReadingDropView: NSView {
    var accepts: ((NSPasteboard) -> Bool)?
    var onDrop: ((NSPasteboard) -> Bool)?
    var onShareKey: (() -> Bool)?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = accepts?(sender.draggingPasteboard) ?? false
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        highlighted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        return onDrop?(sender.draggingPasteboard) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10)
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s" {
            if onShareKey?() == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Row

/// A reading in the list: its title and source, then either its progress with Stop, or its details with Play,
/// Share…, Show in Finder, and Delete…, or its error with Try Again.
@MainActor
final class ReadingRowView: NSTableCellView {
    enum Action { case play, stop, retry, share, reveal, delete }

    /// The player's state for the reading it has loaded.
    struct Playback {
        var playing: Bool
        var current: Double?
        var duration: Double?
    }

    var onAction: ((UUID, Action) -> Void)?
    private var entryID: UUID?
    private let title = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let position = NSTextField(labelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let shareButton = NSButton(title: "Share…", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private var primaryAction: Action = .play

    var shareAnchor: NSView { shareButton }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        source.font = .systemFont(ofSize: 11)
        source.textColor = .secondaryLabelColor
        source.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 140).isActive = true
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        position.textColor = .secondaryLabelColor
        for (button, selector) in [(primary, #selector(primaryPressed)), (shareButton, #selector(sharePressed)),
                                   (revealButton, #selector(revealPressed)), (deleteButton, #selector(deletePressed))] {
            button.target = self
            button.action = selector
            button.bezelStyle = .push
            button.controlSize = .small
        }
        shareButton.toolTip = "Send the audio file with AirDrop, Messages, Mail… (⇧⌘S)"
        deleteButton.toolTip = "Delete this reading and its audio file (⌫)"
        textField = title

        let statusRow = NSStackView(views: [progress, status])
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        let text = NSStackView(views: [title, source, statusRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let buttons = NSStackView(views: [position, primary, shareButton, revealButton, deleteButton])
        buttons.spacing = 6
        buttons.alignment = .centerY
        buttons.setHuggingPriority(.required, for: .horizontal)
        for view in [text, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [title, source, status] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ entry: ReadingEntry, activity: ReadingController.Activity?, fileProblem: ReadingController.FileProblem?,
              size: Int64?, playback: Playback?) {
        entryID = entry.id
        title.stringValue = entry.title
        source.stringValue = entry.source.label
        status.textColor = .secondaryLabelColor
        progress.isHidden = true
        position.isHidden = true
        var buttons: [NSButton] = []
        switch entry.state {
        case .queued:
            status.stringValue = "Waiting — starts when the reading before it is made"
            setPrimary("Stop", .stop, help: "Take this reading out of the queue; Resume adds it back")
            buttons = [primary]
        case .rendering:
            switch activity {
            case .rendering(let part, let total)?:
                status.stringValue = "Rendering part \(part) of \(total)"
                progress.isHidden = false
                progress.doubleValue = Double(part - 1) / Double(max(1, total))
            case .joining(let parts)?:
                status.stringValue = "Joining \(parts) \(parts == 1 ? "part" : "parts") into one file…"
                progress.isHidden = false
                progress.doubleValue = 1
            case .loading?, nil:
                if case .web = entry.source { status.stringValue = "Loading the page…" }
                else { status.stringValue = "Reading the file…" }
            }
            setPrimary("Stop", .stop, help: "Stop making this reading; Resume continues where it stopped")
            buttons = [primary]
        case .done where fileProblem == .missing:
            status.stringValue = "The file made for it is no longer at "
                + "\(entry.output.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "its place")."
            status.textColor = .systemOrange
            buttons = [deleteButton]
        case .done where fileProblem != nil:
            // Delete refuses until the file can be looked for, so it stays offered for when the drive is back.
            if case .unavailable(let reason)? = fileProblem {
                status.stringValue = "Unavailable — \(reason)."
            }
            status.textColor = .systemOrange
            buttons = [deleteButton]
        case .done:
            var details: [String] = []
            if let duration = entry.duration { details.append(ReadingLibrary.durationText(duration)) }
            if let chapters = entry.chapters, chapters > 0 { details.append("\(chapters) \(chapters == 1 ? "chapter" : "chapters")") }
            if let size { details.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
            if let voice = entry.voiceName { details.append(voice) }
            if abs(entry.speed - ReadingSpeed.standard) > 0.001 { details.append(ReadingSpeed.label(entry.speed)) }
            status.stringValue = details.joined(separator: " · ")
            if let message = entry.message {
                status.stringValue += " — \(message)"
            }
            let playing = playback?.playing ?? false
            setPrimary(playing ? "❚❚ Pause" : "▶ Play", .play, help: "Play or pause here (Space)")
            if let current = playback?.current, let duration = playback?.duration {
                position.isHidden = false
                position.stringValue = "\(ReadingLibrary.clockText(current)) / \(ReadingLibrary.clockText(duration))"
            }
            buttons = [primary, shareButton, revealButton, deleteButton]
        case .failed:
            status.stringValue = entry.message ?? "The reading failed."
            status.textColor = .systemOrange
            setPrimary("Try Again", .retry, help: "Make it again; parts already rendered are kept")
            buttons = [primary, deleteButton]
        case .stopped:
            var text = "Stopped"
            if let part = entry.part, let parts = entry.parts { text += " at part \(part) of \(parts)" }
            status.stringValue = text + (entry.message.map { ". \($0)" } ?? ".")
            setPrimary("Resume", .retry, help: "Continue where it stopped")
            buttons = [primary, deleteButton]
        }
        for button in [primary, shareButton, revealButton, deleteButton] {
            button.isHidden = !buttons.contains(button)
        }
        status.toolTip = status.stringValue
        let label = [entry.title, entry.source.label, status.stringValue].joined(separator: ", ")
        setAccessibilityLabel(label)
        for button in buttons { button.setAccessibilityLabel("\(button.title) — \(entry.title)") }
    }

    private func setPrimary(_ title: String, _ action: Action, help: String) {
        primary.title = title
        primaryAction = action
        primary.toolTip = help
    }

    @objc private func primaryPressed() { send(primaryAction) }
    @objc private func sharePressed() { send(.share) }
    @objc private func revealPressed() { send(.reveal) }
    @objc private func deletePressed() { send(.delete) }

    private func send(_ action: Action) {
        guard let entryID else { return }
        onAction?(entryID, action)
    }
}
