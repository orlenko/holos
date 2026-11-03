import AppKit
import HolosCore

/// The main window's History section (docs/design.md "Dictation history"): the dictations kept on this Mac, grouped
/// by day, with a search field; the selected one's text, the text as heard (changed words highlighted), what
/// happened to it, and its actions. Copy and Copy As Heard are the only ways its text reaches the clipboard.
///
/// Invariants:
/// 1. The empty view shows exactly when the filtered list has no rows.
/// 2. With no dictations, an unreadable file, a newer build's dictations or history being off is said before dictation's
///    own state, and only dictation being off offers an action.
@MainActor
final class HistoryPane: NSViewController, MainSectionContent, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation, NSSplitViewDelegate {
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
        /// The empty section's Turn On Dictation, and the name of the hold-to-talk key it mentions.
        var turnOnDictation: () -> Void = {}
        var shortcutTitle: () -> String = { "Right Option" }
    }

    private enum Row {
        case day(String)
        case record(DictationRecord)
    }

    /// The list's narrowest when there is room: its search field's placeholder reads whole.
    static let listMinimumWidth: CGFloat = 200
    /// Narrower still only when the window is too narrow for the list's and the detail's minimums side by side (the
    /// main window at its narrowest, beside a call's window).
    static let listNarrowestWidth: CGFloat = 150
    static let detailMinimumWidth: CGFloat = 240
    /// Where the list's width is kept once the divider is dragged.
    static let listWidthKey = "VoiceIsLocalHistoryListWidth"

    /// The list's width before the divider is dragged: 40% of the section, from 220 to 360 points.
    static func defaultListWidth(paneWidth: CGFloat) -> CGFloat {
        min(max((paneWidth * 0.4).rounded(), 220), 360)
    }

    /// The list's width in a section `paneWidth` wide: the one the divider was dragged to (`preferred`), else the
    /// default; never under `listMinimumWidth` unless the detail would get less than `detailMinimumWidth`.
    static func listWidth(preferred: CGFloat?, paneWidth: CGFloat, divider: CGFloat) -> CGFloat {
        let widest = paneWidth - divider - detailMinimumWidth
        let wanted = max(preferred ?? defaultListWidth(paneWidth: paneWidth), listMinimumWidth)
        return max(min(wanted, widest), listNarrowestWidth).rounded()
    }

    private let actions: Actions
    private let defaults: UserDefaults
    let split = HistorySplitView()
    private let listPane = NSView()
    /// The width the divider was last dragged to (kept in `defaults`); nil until then.
    private var preferredListWidth: CGFloat?
    /// The split's width the list was last sized for: the list is sized again when it changes.
    private var sizedForWidth: CGFloat = 0
    private var records: [DictationRecord] = []
    private var retention = HistoryRetention.standard
    /// Dictations a newer Voice is Local recorded: not listed, but Clear History deletes them.
    private var hidden = 0
    /// The history file could not be read.
    private var unreadable = false
    private var rows: [Row] = []
    private let search = NSSearchField()
    private let table = KeyTableView()
    private let emptyView = SectionEmptyView()
    /// Dictation is off: with no history, the section says how to turn it on.
    private var dictationOff = false
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

    /// `defaults`: where the list's dragged width is kept.
    init(actions: Actions, defaults: UserDefaults = .standard) {
        self.actions = actions
        self.defaults = defaults
        let saved = defaults.double(forKey: Self.listWidthKey)
        preferredListWidth = saved > 0 ? CGFloat(saved) : nil
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
        // Short enough to read whole in the list at its minimum width (`listMinimumWidth`).
        search.placeholderString = "Search dictations"
        search.toolTip = "Search the dictations' text and app names"
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

        emptyView.isHidden = true
        emptyView.onAction = { [weak self] in self?.actions.turnOnDictation() }

        let listStack = NSStackView(views: [search, scroll])
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 0, right: 12)
        search.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -24).isActive = true
        scroll.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        listStack.translatesAutoresizingMaskIntoConstraints = false
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(listStack)
        listPane.addSubview(emptyView)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listPane.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: listPane.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: listPane.centerYAnchor),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: listPane.widthAnchor, constant: -16),
            listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.listNarrowestWidth),
        ])
        // The list's width is set by moving the divider (`sizeList`), not by a width constraint, so a drag can move
        // it (a width constraint tied with the detail's holding priority left the split's layout ambiguous, and
        // AppKit would not move the divider at all). Each time the section's width changes the list gets its width
        // again (`viewDidLayout`); a drag stops at `listMinimumWidth` (`constrainMinCoordinate`).
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.onDividerDragged = { [weak self] in self?.dividerDragged() }
        split.addArrangedSubview(listPane)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.detailMinimumWidth).isActive = true

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

        // Pinned edge to edge: the split's frame is fully set by constraints, which AppKit needs before it lets the
        // divider be dragged.
        let root = NSView()
        for view in [split, separator, footerRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            separator.topAnchor.constraint(equalTo: split.bottomAnchor),
            footerRow.topAnchor.constraint(equalTo: separator.bottomAnchor),
            footerRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        footerRow.setContentHuggingPriority(.required, for: .vertical)
        footerRow.setContentCompressionResistancePriority(.required, for: .vertical)
        return root
    }

    /// The list's width now.
    var listWidth: CGFloat { listPane.frame.width }

    /// The section changed width (the window resized, the sidebar was shown or hidden): the list gets its width
    /// again (`listWidth(preferred:paneWidth:divider:)`), so a narrow window does not leave it narrow.
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = split.bounds.width
        guard width > 0, width != sizedForWidth else { return }
        sizedForWidth = width
        sizeList()
    }

    private func sizeList() {
        let target = Self.listWidth(preferred: preferredListWidth, paneWidth: split.bounds.width,
                                    divider: split.dividerThickness)
        guard abs(listPane.frame.width - target) > 0.5 else { return }
        split.setPosition(target, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
    }

    /// A drag of the divider keeps the list `listMinimumWidth` wide (less only when the detail would get less than its
    /// minimum) and the detail `detailMinimumWidth` wide.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, Self.listWidth(preferred: Self.listNarrowestWidth, paneWidth: splitView.bounds.width,
                                                    divider: splitView.dividerThickness))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let widest = splitView.bounds.width - splitView.dividerThickness - Self.detailMinimumWidth
        return min(proposedMaximumPosition, max(widest, Self.listNarrowestWidth))
    }

    /// The divider was dragged: the list's width is kept for the next time, and the next launch.
    private func dividerDragged() {
        let width = listPane.frame.width.rounded()
        guard width > 0, width != preferredListWidth else { return }
        preferredListWidth = width
        defaults.set(Double(width), forKey: Self.listWidthKey)
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
            emptyView.show(Self.emptyContent(unreadable: unreadable, hidden: hidden, recording: retention.records,
                                             dictationOff: dictationOff, shortcut: actions.shortcutTitle()))
        } else if filtered.isEmpty {
            emptyView.show(.init(text: "No dictations match “\(search.stringValue)”."))
        }
        emptyView.isHidden = !filtered.isEmpty  // invariant 1
        showSelection()
    }

    /// What the list says with no dictations at all (invariant 2).
    static func emptyContent(unreadable: Bool, hidden: Int, recording: Bool, dictationOff: Bool,
                             shortcut: String) -> SectionEmptyView.Content {
        if unreadable {
            return .init(title: "History could not be read",
                         text: "It may still keep dictations on this Mac; Clear History… deletes them.")
        }
        if hidden > 0 {
            let one = hidden == 1
            return .init(text: "\(hidden) \(one ? "dictation was" : "dictations were") recorded by a newer Voice is "
                + "Local and \(one ? "is" : "are") not shown here. Clear History… deletes \(one ? "it" : "them").")
        }
        guard recording else {
            return .init(symbol: "clock", title: "History is off", text: "Turn it on in Settings › Dictation history.")
        }
        let finish = "speak, and release. Each dictation you finish appears here."
        guard dictationOff else {
            return .init(symbol: "mic", title: "No dictations yet", text: "Hold \(shortcut) in any app, \(finish)")
        }
        return .init(symbol: "mic", title: "Dictation is off",
                     text: "Turn it on, then hold \(shortcut) in any app, \(finish)", action: "Turn On Dictation",
                     prominent: true)
    }

    /// Dictation turned on or off (`MainWindowController.updateStatus`).
    func showDictation(off: Bool) {
        guard off != dictationOff else { return }
        dictationOff = off
        reloadRows(selecting: selectedRecord?.id)
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
            state = .none
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

/// History's list and detail. A drag of the divider runs inside `mouseDown` (AppKit tracks it there); when it moved
/// the divider, `onDividerDragged` says so. Resizing the window moves the divider too, and is not a drag.
@MainActor
final class HistorySplitView: NSSplitView {
    var onDividerDragged: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let before = subviews.first?.frame.width
        super.mouseDown(with: event)
        if subviews.first?.frame.width != before { onDividerDragged?() }
    }
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
