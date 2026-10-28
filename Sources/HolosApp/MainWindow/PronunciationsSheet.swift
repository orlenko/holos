import AppKit
import HolosCore

/// Settings › Reading › Pronunciations (docs/design.md "Pronunciations"), a sheet over the main window: the words every
/// reading voice says by a spelling. Choosing a row puts it in the fields; Save (or Return) adds the word or changes
/// its spelling, Remove (or ⌫) removes the chosen rows, and ▶ Listen says the spelling with the default reading voice
/// and speed. The app keeps the list (`pronunciations.json`); this sheet shows it and reports what each change did.
///
/// Invariants:
/// 1. `entries` is the list as last loaded; every change loads it again, so the table never shows a change unsaved.
/// 2. A sample still being made or played is stopped when the sheet closes.
@MainActor
final class PronunciationsSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// What the sheet asks of the app; each does its file work off the main actor.
    struct Store {
        /// The list, and why it could not be read (then empty).
        var load: () async -> (list: PronunciationList, problem: String?)
        /// Says `written` as `sayAs`; returns the line to show.
        var set: (_ written: String, _ sayAs: String) async -> String
        /// Removes the entries written so; returns the line to show.
        var remove: ([String]) async -> String
    }

    private static let writtenColumn = NSUserInterfaceItemIdentifier("written")
    private static let sayAsColumn = NSUserInterfaceItemIdentifier("sayAs")
    static let note = """
        Names and jargon no voice knows how to say: write each as documents have it and spell how it sounds \
        ("XIMEA", "zay mee ah"). Every reading voice uses the list, natural and Apple's, from the next part it \
        reads. A word in lower case matches in any case; one with a capital matches only as written. Only whole \
        words match. Also: voiceislocal pronunciations set XIMEA "zay mee ah".
        """

    private let store: Store
    private let preview: VoicePreview
    /// The voice and speed ▶ Listen uses: Settings › Reading's defaults.
    var readingVoice: () -> (voice: String?, speed: Double) = { (ReadingPreferences.voice, ReadingPreferences.speed) }
    private var entries: [Pronunciation] = []
    private let countLabel = NSTextField(labelWithString: "")
    private let table = KeyTableView()
    let writtenField = NSTextField()
    let sayAsField = NSTextField()
    private let listenButton = NSButton(title: "▶ Listen", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let feedbackLabel = NSTextField(wrappingLabelWithString: "")

    /// `preview`: what ▶ Listen speaks with (the app's renders natural voices through the bundled tool).
    init(store: Store, preview: VoicePreview = VoicePreview()) {
        self.store = store
        self.preview = preview
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let heading = NSTextField(labelWithString: "Pronunciations")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [heading, countLabel])
        header.spacing = 8

        for (identifier, title, width) in [(Self.writtenColumn, "Written", 200.0), (Self.sayAsColumn, "Say as", 260)] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Pronunciations")
        table.onDelete = { [weak self] in self?.removeSelected() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        writtenField.placeholderString = "As written, e.g. XIMEA"
        writtenField.setAccessibilityLabel("Word as written")
        sayAsField.placeholderString = "Say as, e.g. zay mee ah"
        sayAsField.setAccessibilityLabel("Say as")
        for field in [writtenField, sayAsField] {
            // Return saves rather than closing the sheet.
            field.target = self
            field.action = #selector(save)
        }
        listenButton.target = self
        listenButton.action = #selector(listen)
        listenButton.toolTip = "Hear the spelling with the default reading voice and speed; press again to stop"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.toolTip = "Add the word, or give a listed word this spelling"
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.toolTip = "Remove the selected words (⌫)"
        removeButton.isEnabled = false
        let fields = NSStackView(views: [writtenField, sayAsField, listenButton, saveButton, removeButton])
        fields.spacing = 8
        writtenField.widthAnchor.constraint(equalTo: sayAsField.widthAnchor, multiplier: 0.75).isActive = true

        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString: Self.note)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .push
        done.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [NSView(), done])

        let stack = NSStackView(views: [header, scroll, fields, feedbackLabel, note, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [header, scroll, fields, feedbackLabel, note, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 640).isActive = true
        view = stack

        if preview.renderNatural == nil { preview.renderNatural = VoicePreview.renderedByHelper() }
        preview.onChange = { [weak self] in self?.updateListen() }
        preview.onError = { [weak self] in self?.feedbackLabel.stringValue = $0 }
        Task { await reload() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        preview.stop()  // invariant 2
    }

    /// Loads the list and shows it, the same words still chosen (invariant 1).
    func reload() async {
        let (list, problem) = await store.load()
        let chosen = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].written : nil })
        entries = list.entries
        table.reloadData()
        table.selectRowIndexes(IndexSet(entries.indices.filter { chosen.contains(entries[$0].written) }),
                               byExtendingSelection: false)
        countLabel.stringValue = entries.count == 1 ? "1 word" : "\(entries.count) words"
        if let problem { feedbackLabel.stringValue = problem }
        saveButton.isEnabled = problem == nil
        updateRemove()
    }

    @objc func save() {
        let written = writtenField.stringValue, sayAs = sayAsField.stringValue
        guard WordList.cleaned(written) != nil, WordList.cleaned(sayAs) != nil else {
            feedbackLabel.stringValue = "Type the word as written and how to say it."
            return
        }
        Task {
            feedbackLabel.stringValue = await store.set(written, sayAs)
            await reload()
        }
    }

    @objc func removeSelected() {
        let chosen = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].written : nil }
        guard !chosen.isEmpty else { return }
        Task {
            feedbackLabel.stringValue = await store.remove(chosen)
            await reload()
        }
    }

    /// Says the spelling in the field (else the chosen row's), or stops the one being said.
    @objc func listen() {
        if preview.isSpeaking {
            preview.stop()
            return
        }
        let typed = WordList.cleaned(sayAsField.stringValue)
        guard let text = typed ?? (table.selectedRow >= 0 ? entries[table.selectedRow].sayAs : nil) else {
            feedbackLabel.stringValue = "Type how to say the word, then listen."
            return
        }
        let (voice, speed) = readingVoice()
        preview.speak(voiceIdentifier: voice, speed: speed, text: text)
    }

    private func updateListen() {
        listenButton.title = preview.isSpeaking ? "■ Stop" : "▶ Listen"
    }

    private func updateRemove() {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    @objc private func close() {
        dismiss(self)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    /// The written forms shown, in order.
    var shownWords: [String] { entries.map(\.written) }

    func choose(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let field = NSTextField(labelWithString: tableColumn?.identifier == Self.sayAsColumn ? entry.sayAs : entry.written)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// A row chosen alone goes in the fields, to change its spelling or listen to it.
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemove()
        guard table.selectedRowIndexes.count == 1, entries.indices.contains(table.selectedRow) else { return }
        writtenField.stringValue = entries[table.selectedRow].written
        sayAsField.stringValue = entries[table.selectedRow].sayAs
    }
}
