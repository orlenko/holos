import AppKit
import HolosCore

/// The main window's History section (docs/design.md "Dictation history"): the dictations kept on this Mac, grouped
/// by day, with a search field; the selected one's text, the text as heard (changed words highlighted), what
/// happened to it, and its actions. Copy and Copy As Heard are the only ways its text reaches the clipboard.
@MainActor
final class HistoryPane: NSViewController, MainSectionContent, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation {
    struct Actions {
        /// Copies `text` to the clipboard (only ever on the user's Copy).
        var copy: (_ text: String) -> Bool
        /// Correct…: opens Corrections with this dictation.
        var correct: (DictationRecord) -> Void
        var delete: (DictationRecord) -> Void
        var clear: () -> Void
        /// The dictation's saved audio file, when it is still on this Mac.
        var audioURL: (DictationRecord) -> URL?
        /// Run Again: recognizes the dictation's saved audio again with today's settings. Nothing is written into
        /// any app and nothing is copied.
        var rerun: @MainActor (DictationRecord) async throws -> DictationRerunReport
        /// Update History: keeps a Run Again result as the dictation's text.
        var update: (DictationRecord, DictationRerunReport) -> Void
    }

    private enum Row {
        case day(String)
        case record(DictationRecord)
    }

    private let actions: Actions
    private var records: [DictationRecord] = []
    private var retention = HistoryRetention.standard
    /// Dictations a newer Voice is Local recorded: not listed, but Clear History deletes them.
    private var hidden = 0
    /// The history file could not be read.
    private var unreadable = false
    private var rows: [Row] = []
    private let search = NSSearchField()
    private let table = KeyTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let clearButton = NSButton(title: "Clear History…", target: nil, action: nil)
    private let detail = HistoryDetailView()
    private let player = HistoryAudioPlayer()
    /// The last Run Again and its dictation: shown while that dictation is selected.
    private var rerun: (id: UUID, state: RerunComparisonView.State)?
    private var rerunTask: Task<Void, Never>?
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    init(actions: Actions) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        view = makeContent()
        detail.onCopy = { [weak self] heard in self?.copySelected(heard: heard) }
        detail.onCorrect = { [weak self] in self?.correctSelected() }
        detail.onDelete = { [weak self] in self?.deleteSelected() }
        detail.onPlay = { [weak self] in _ = self?.togglePlay() }
        detail.onRunAgain = { [weak self] in self?.runAgain() }
        detail.onCopyNewResult = { [weak self] in self?.copyNewResult() }
        detail.onUpdateHistory = { [weak self] in self?.updateHistory() }
        player.onChange = { [weak self] in self?.showAudio() }
        showSelection()
    }

    func sectionDidHide() {
        player.stop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var searchField: NSSearchField? { search }
    var preferredFirstResponder: NSView? { table }

    // MARK: - Layout

    private func makeContent() -> NSView {
        search.placeholderString = "Search dictations and apps"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.setAccessibilityLabel("Search history")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dictation"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.floatsGroupRows = true
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onReturn = { [weak self] in self?.openSelected() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onSpace = { [weak self] in self?.togglePlay() ?? false }
        table.setAccessibilityLabel("Dictations")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        let listStack = NSStackView(views: [search, scroll])
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 0, right: 12)
        search.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -24).isActive = true
        scroll.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        let listPane = NSView()
        listStack.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(listStack)
        listPane.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listPane.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listPane.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listPane.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: listPane.widthAnchor, constant: -40),
            listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "VoiceIsLocalHistorySplit"
        split.addArrangedSubview(listPane)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        let listWidth = listPane.widthAnchor.constraint(equalToConstant: 340)
        listWidth.priority = .defaultLow
        listWidth.isActive = true

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        clearButton.bezelStyle = .push
        clearButton.controlSize = .small
        let footerRow = NSStackView(views: [footer, NSView(), clearButton])
        footerRow.alignment = .centerY
        footerRow.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 10, right: 16)
        let separator = NSBox.hairline()

        let root = NSStackView(views: [split, separator, footerRow])
        root.orientation = .vertical
        root.spacing = 0
        for view in [split, separator, footerRow] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        return root
    }

    // MARK: - Data

    /// What Clear History deletes, for its questions; nil when there is nothing to clear. `count` is every dictation
    /// the file keeps (a newer build's too); `unreadable` says the file could not be read, so what it keeps is unknown.
    static func clearTarget(count: Int, unreadable: Bool) -> (phrase: String, sentence: String)? {
        if count > 0 {
            let dictations = "\(count) \(count == 1 ? "dictation" : "dictations")"
            return ("the \(dictations) already kept",
                    "All \(dictations) kept on this Mac are deleted, with their audio.")
        }
        guard unreadable else { return nil }
        return ("what the history file keeps (it could not be read)",
                "Whatever the history file keeps is deleted; it could not be read, so it may hold dictations.")
    }

    /// Shows `records` (oldest first, as stored) under `retention`'s footer, keeping the selected dictation.
    /// `problem` is what is wrong with the history (a write that failed, or a read that failed: `unreadable`);
    /// `hidden` counts dictations a newer Voice is Local recorded, not shown here but deleted by Clear History.
    func update(records: [DictationRecord], retention: HistoryRetention, problem: String?, hidden: Int,
                unreadable: Bool) {
        let selected = selectedRecord?.id
        self.records = records
        self.retention = retention
        self.hidden = hidden
        self.unreadable = unreadable
        if let problem {
            footer.stringValue = problem
            footer.textColor = .systemOrange
        } else {
            footer.stringValue = retention.footerText + " Nothing is copied unless you choose Copy."
            footer.textColor = .secondaryLabelColor
        }
        clearButton.isEnabled = Self.clearTarget(count: records.count + hidden, unreadable: unreadable) != nil
        reloadRows(selecting: selected)
    }

    private func reloadRows(selecting id: UUID?) {
        let filtered = records.filter { $0.matches(search.stringValue) }
        rows = HistoryDay.groups(filtered, now: Date()).flatMap { group in
            [Row.day(group.title)] + group.records.map(Row.record)
        }
        table.reloadData()
        if let id, let index = rows.firstIndex(where: { if case .record(let r) = $0 { r.id == id } else { false } }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let first = rows.firstIndex(where: { if case .record = $0 { true } else { false } }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        if records.isEmpty {
            emptyLabel.stringValue = if unreadable {
                "History could not be read.\nIt may still keep dictations on this Mac; Clear History… deletes them."
            } else if hidden > 0 {
                "\(hidden) \(hidden == 1 ? "dictation was" : "dictations were") recorded by a newer Voice is Local "
                    + "and \(hidden == 1 ? "is" : "are") not shown here.\nClear History… deletes \(hidden == 1 ? "it" : "them")."
            } else if retention.records {
                "No dictations yet.\nEach dictation you finish appears here."
            } else {
                "History is off.\nTurn it on in Settings › History and privacy."
            }
        } else if filtered.isEmpty {
            emptyLabel.stringValue = "No dictations match “\(search.stringValue)”."
        }
        emptyLabel.isHidden = !filtered.isEmpty
        showSelection()
    }

    private var selectedRecord: DictationRecord? {
        let row = table.selectedRow
        guard row >= 0, row < rows.count, case .record(let record) = rows[row] else { return nil }
        return record
    }

    private func showSelection() {
        let record = selectedRecord
        // Another dictation, or none: its audio stops.
        if player.id != nil, player.id != record?.id { player.stop() }
        detail.show(record, emptyText: records.isEmpty ? "" : "Select a dictation to see it here.")
        showAudio()
        detail.showRerun(record.flatMap { record in rerun.flatMap { $0.id == record.id ? $0.state : nil } })
    }

    /// The selected dictation's audio row: its player, or why there is no audio.
    private func showAudio() {
        guard let record = selectedRecord else { return }
        let state: HistoryDetailView.AudioState
        if actions.audioURL(record) != nil {
            let loaded = player.id == record.id
            let duration = loaded ? player.duration ?? record.audio?.seconds ?? 0 : record.audio?.seconds ?? 0
            state = .available(playing: loaded && player.isPlaying,
                               time: HistoryAudioPlayer.timeText(loaded ? player.position : 0, of: duration))
        } else if record.audio != nil {
            state = .missing("The audio is no longer on this Mac.")
        } else {
            state = .missing("No audio was kept for this dictation.")
        }
        detail.showAudio(state, running: rerunTask != nil)
    }

    /// ▶/⏸, or Space in the list: false when the selected dictation has no audio (Space then does what it does).
    private func togglePlay() -> Bool {
        guard let record = selectedRecord, let url = actions.audioURL(record) else { return false }
        do {
            try player.toggle(id: record.id, url: url)
        } catch {
            detail.showFeedback("The audio could not be played.")
        }
        return true
    }

    /// Run Again (⌘R): the selected dictation's audio through the recognizer and today's text steps.
    private func runAgain() {
        guard rerunTask == nil, let record = selectedRecord, actions.audioURL(record) != nil else { return }
        rerun = (record.id, .running)
        rerunTask = Task { [weak self] in
            guard let self else { return }
            let state: RerunComparisonView.State
            do {
                state = .done(try await self.actions.rerun(record))
            } catch {
                state = .failed(error.localizedDescription)
            }
            self.rerunTask = nil
            if self.rerun?.id == record.id { self.rerun = (record.id, state) }
            self.showSelection()
        }
        showSelection()
    }

    private var selectedReport: DictationRerunReport? {
        guard let record = selectedRecord, let rerun, rerun.id == record.id,
              case .done(let report) = rerun.state else { return nil }
        return report
    }

    /// Copy New Result: the text Run Again would write, only on this request.
    private func copyNewResult() {
        guard let report = selectedReport else { return }
        detail.showFeedback(actions.copy(report.written.now) ? "Copied the new result." : "Clipboard write failed.")
    }

    /// Update History…: after a confirmation, the new result replaces the dictation's text.
    private func updateHistory() {
        guard let record = selectedRecord, let report = selectedReport else { return }
        confirm("Replace this dictation's text with the new result?",
                "History keeps the new text as written and as heard. Text already written into "
                    + "\(record.app ?? "the app") stays as it is.", button: "Update History") { [weak self] in
            guard let self, self.selectedRecord?.id == record.id else { return }
            self.actions.update(record, report)
            self.rerun = nil
            self.showSelection()
            self.detail.showFeedback("History updated.")
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .day = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .record = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .day = rows[row] { return 26 }
        return 66
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .day(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let cell = NSTableCellView()
            cell.textField = label
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .record(let record):
            let identifier = NSUserInterfaceItemIdentifier("historyRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryRowView
                ?? HistoryRowView(identifier: identifier)
            cell.show(record, time: timeFormatter.string(from: record.date))
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelection()
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        reloadRows(selecting: selectedRecord?.id)
    }

    /// Return or double-click: the keyboard focus moves to the dictation's text.
    @objc private func openSelected() {
        guard selectedRecord != nil else { return }
        detail.focusText()
    }

    /// ⌘C with the list focused copies the selected dictation (a selection in the text copies itself first).
    @objc func copy(_ sender: Any?) {
        copySelected(heard: false)
    }

    /// ⇧⌘C.
    @objc func copyAsHeard(_ sender: Any?) {
        copySelected(heard: true)
    }

    /// Copy copies what Copy Result offered: the part not written of a partly written dictation, else the text.
    /// Copy As Heard exists only for a dictation the fixes changed (its button shows only then).
    private func copySelected(heard: Bool) {
        guard let record = selectedRecord, !heard || HistoryDetailView.offersCopyAsHeard(record) else { return }
        let copied = actions.copy(heard ? record.heard : record.copyText)
        let done = heard ? "Copied the text as heard." : record.unwritten == nil ? "Copied." : "Copied the part not written."
        detail.showFeedback(copied ? done : "Clipboard write failed.")
    }

    private func correctSelected() {
        guard let record = selectedRecord else { return }
        actions.correct(record)
    }

    /// The Edit menu's Copy (⌘C) and the Copy As Heard key follow the buttons: on only for a selected dictation that
    /// has them.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): selectedRecord != nil
        case #selector(copyAsHeard(_:)): selectedRecord.map(HistoryDetailView.offersCopyAsHeard) ?? false
        default: true
        }
    }

    private func deleteSelected() {
        guard let record = selectedRecord else { return }
        confirm("Delete this dictation?", "It is removed from History on this Mac, with its audio. Text already "
                    + "written into \(record.app ?? "the app") stays there.", button: "Delete") { [weak self] in
            guard let self else { return }
            // The next row keeps the selection where it was.
            let index = self.table.selectedRow
            self.actions.delete(record)
            let next = self.rows.indices.dropFirst(index).first { i in
                if case .record(let r) = self.rows[i] { r.id != record.id } else { false }
            }
            if let next, case .record(let r) = self.rows[next] { self.reloadRows(selecting: r.id) }
        }
    }

    @objc private func clearHistory() {
        guard let kept = Self.clearTarget(count: records.count + hidden, unreadable: unreadable) else { return }
        confirm("Clear History?", "\(kept.sentence) Text already written into other apps stays there.",
                button: "Clear History") { [weak self] in self?.actions.clear() }
    }

    private func confirm(_ title: String, _ text: String, button: String, then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { action() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}

// MARK: - Row

/// A list row: time, app, badge, and a two-line preview.
@MainActor
final class HistoryRowView: NSTableCellView {
    private let time = NSTextField(labelWithString: "")
    private let app = NSTextField(labelWithString: "")
    private let badge = BadgeLabel()
    private let preview = NSTextField(wrappingLabelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        app.font = .systemFont(ofSize: 12, weight: .semibold)
        app.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.truncatesLastVisibleLine = true
        textField = preview
        let header = NSStackView(views: [app, badge, NSView(), time])
        header.spacing = 6
        header.alignment = .centerY
        app.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let width = max(100, bounds.width - 12)
        if preview.preferredMaxLayoutWidth != width { preview.preferredMaxLayoutWidth = width }
    }

    func show(_ record: DictationRecord, time text: String) {
        time.stringValue = text
        app.stringValue = record.app ?? "Unknown app"
        preview.stringValue = record.text.replacingOccurrences(of: "\n", with: " ")
        badge.show(record.badge, warning: record.badge != nil && record.badge != "Fixed")
        var label = "\(record.app ?? "Unknown app"), \(text)"
        if let badge = record.badge { label += ", \(badge)" }
        setAccessibilityLabel(label + ". " + record.text)
    }
}

/// A small rounded badge ("Fixed", "Not inserted").
@MainActor
final class BadgeLabel: NSTextField {
    private var warning = false

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 10, weight: .semibold)
        wantsLayer = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 10, height: size.height + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = warning ? .systemOrange : .controlAccentColor
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let text = NSAttributedString(string: stringValue, attributes: [
            .font: font ?? .systemFont(ofSize: 10), .foregroundColor: color,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    func show(_ text: String?, warning: Bool) {
        self.warning = warning
        stringValue = text ?? ""
        isHidden = text == nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

// MARK: - Detail

/// The selected dictation: app and time, the text as written, the text as heard with the changed words marked, the
/// result, language, fixes, and length, and Copy, Copy As Heard, Correct…, Delete.
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
        case missing(String)
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
        grid.column(at: 0).xPlacement = .trailing

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
        let buttons = NSStackView(views: [copyButton, copyHeardButton, correctButton, deleteButton, feedback])
        buttons.spacing = 8

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
        let width = max(200, bounds.width - 48)
        for label in [text, heard, rest] + Array(values.values) {
            let target = label === text || label === heard || label === rest ? width : max(120, width - 90)
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
            playButton.isHidden = false
            playButton.isEnabled = true
            playButton.title = playing ? "Pause" : "Play"
            playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                       accessibilityDescription: nil)
            audioTime.stringValue = time
            runAgainButton.isHidden = false
            runAgainButton.isEnabled = !running
        case .missing(let reason):
            playButton.isHidden = true
            playButton.isEnabled = false
            audioTime.stringValue = reason
            runAgainButton.isHidden = true
            runAgainButton.isEnabled = false  // a hidden button must not answer ⌘R either
        }
    }

    /// The Run Again result for the selected dictation; nil hides it.
    func showRerun(_ state: RerunComparisonView.State?) {
        comparison.isHidden = state == nil
        if let state { comparison.show(state) }
        needsLayout = true
    }

    func showFeedback(_ message: String) {
        feedback.stringValue = message
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.feedback.stringValue = ""
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

/// A section that is not built yet, or not available: a title, a line of text, and an optional button.
@MainActor
final class PlaceholderPane: NSViewController, MainSectionContent {
    private let action: (() -> Void)?

    init(title: String, text: String, button: String? = nil, action: (() -> Void)? = nil) {
        self.action = action
        super.init(nibName: nil, bundle: nil)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: text)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 420
        var views: [NSView] = [heading, body]
        if let button {
            let control = NSButton(title: button, target: self, action: #selector(pressed))
            control.bezelStyle = .push
            views.append(control)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func pressed() { action?() }
}
