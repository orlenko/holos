import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage
import Quartz
import UniformTypeIdentifiers

/// The saved meetings (docs/meeting-design.md §5.8, §4.13; docs/design.md "Meetings list"): a list of rich rows grouped
/// by day (Today, Yesterday, This Week, then by month), each with the meeting's title (the user's name, else the title
/// Apple Intelligence wrote, else the default name), when it was and how long, the people its speaker labels name, a
/// one- or two-line summary, and badges for what needs saying (Recording, Final transcript queued, Interrupted, …).
/// A search field filters by title, summary and people. The actions on the selected meeting are buttons below the list
/// and the row's menu. Recover, Label Speakers, and the deletions run `voiceislocal` commands through the app delegate,
/// which also opens Review (PR9, §5.10); the rest (Show in Finder, the Quick Look preview, Save Transcript As…, Clean
/// Up) happen here. The meeting being recorded or saved comes first, marked "● Recording". Double-click (or Return)
/// opens what `MeetingOpenPolicy` says: the live transcript (`LiveMeetingViewController`, shown in place of the list
/// until ‹ Meetings or Escape) for that meeting, Review for a labelled one, the preview otherwise; ⌫ is Delete
/// Meeting…. The main window's Meetings section; it refreshes every 2 s while on screen, reading the listing off the
/// main actor.
@MainActor
final class MeetingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate, MainSectionContent {
    enum Action { case recover, labelSpeakers, deleteAudio, deleteMeeting }

    private enum Row {
        case group(String)
        case meeting(SessionSummary)
    }

    private let root: URL
    private let perform: (Action, SessionSummary) -> Void
    private let openReview: (SessionSummary) -> Void
    /// `MeetingController.beginUsing` and `endUsing`: Clean Up and Save Transcript As… hold the meeting while they run.
    private let beginUsing: (String, String) -> Bool
    private let endUsing: (String) -> Void
    /// The live transcript's header for a meeting (the app delegate describes the meeting state).
    private let liveHeader: (String, SessionSummary?) -> LiveMeetingHeader
    /// Learns safe phrase replacements from a live text correction.
    private let learnLiveText: (LiveHints.CorrectionLearningState, String, String) -> LiveTextLearning
    /// The app's meeting state (`MeetingController.state`).
    private var meetingState: MeetingState = .idle
    /// The live transcript shown in place of the list, if any.
    private var live: LiveMeetingViewController?
    private let listView = NSView()
    private let search = NSSearchField()
    private let table = KeyTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var buttons: [String: NSButton] = [:]
    /// Every meeting, in list order (`MeetingOpenPolicy.ordered`).
    private var sessions: [SessionSummary] = []
    /// What the table shows: the meetings that match the search, under their day headers.
    private var rows: [Row] = []
    /// The people each meeting's speaker labels name, by session ID.
    private var people: [String: [String]] = [:]
    private let peopleCache = MeetingPeopleCache()
    /// Maintenance commands running, by session ID.
    private var running: [String: String] = [:]
    /// Deep transcription passes queued or running, by session ID: what the meeting's badge says
    /// (`DeepTranscriptionSchedule.stateText`), and the one running.
    private var deepStates: [String: String] = [:]
    private var deepRunning: String?
    /// Queued meetings whose menu also offers Make Final Transcript Now (queued automatically): it upgrades them.
    private var deepQueuedAutomatically: Set<String> = []
    /// The meeting whose summary is being written now (`voiceislocal session summarize`).
    private var summarizing: String?
    /// The meeting's menu: Make Final Transcript Now (true) and Cancel Final Transcript (false) (§4.16).
    var onDeepTranscription: ((_ runNow: Bool, SessionSummary) -> Void)?
    /// The meeting's menu: Summarize Again, and Cancel Summarize while that request waits or runs.
    var onSummarize: ((SessionSummary) -> Void)?
    var onCancelSummary: ((String) -> Void)?
    /// Whether the meeting's Summarize Again is waiting or running.
    var summaryRequested: (String) -> Bool = { _ in false }
    /// Why Apple Intelligence cannot summarize here (Summarize is off with it as the tooltip); nil when it can.
    var summaryUnavailableReason: () -> String? = { nil }
    private var pendingSelection: String?
    private var refreshTask: Task<Void, Never>?
    private var loading = false
    private var previewURL: URL?

    /// On screen: the window is visible and shows this section.
    private var onScreen = false

    init(root: URL, perform: @escaping (Action, SessionSummary) -> Void,
         openReview: @escaping (SessionSummary) -> Void,
         beginUsing: @escaping (String, String) -> Bool, endUsing: @escaping (String) -> Void,
         liveHeader: @escaping (String, SessionSummary?) -> LiveMeetingHeader,
         learnLiveText: @escaping (LiveHints.CorrectionLearningState, String, String) -> LiveTextLearning = {
             _, _, _ in .init()
         }) {
        self.root = root
        self.perform = perform
        self.openReview = openReview
        self.beginUsing = beginUsing
        self.endUsing = endUsing
        self.liveHeader = liveHeader
        self.learnLiveText = learnLiveText
        super.init(nibName: nil, bundle: nil)

        search.placeholderString = "Search titles, summaries and people"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.setAccessibilityLabel("Search meetings")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meeting"))
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
        table.onReturn = { [weak self] in self?.openSelection() }
        table.onDelete = { [weak self] in self?.deleteMeeting() }
        table.setAccessibilityLabel("Meetings")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [
            button("Live Transcript", #selector(showLiveTranscript)),
            button("Review…", #selector(review)),
            button("Recover…", #selector(recover)), button("Label Speakers", #selector(labelSpeakers)),
            button("Show in Finder", #selector(showInFinder)), button("Open Transcript", #selector(openTranscript)),
            button("Save Transcript As…", #selector(saveTranscript)),
        ])
        row.spacing = 8
        let second = NSStackView(views: [
            button("Delete Audio…", #selector(deleteAudio)), button("Delete Meeting…", #selector(deleteMeeting)),
            button("Clean Up", #selector(cleanUp)),
        ])
        second.spacing = 8
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [search, scroll, row, second, statusLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(8, after: search)
        stack.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(stack)
        listView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -16),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let content = NSView()
        Self.fill(content, with: listView)
        view = content
        updateButtons()
    }

    private static func fill(_ parent: NSView, with child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredFirstResponder: NSView? { live?.preferredFirstResponder ?? table }
    var searchField: NSSearchField? { live == nil ? search : nil }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        buttons[title] = button
        return button
    }

    /// Selects the meeting once the list is read (nil keeps the selection). A live transcript of another meeting gives
    /// way to the list first, so the selection is seen (`MeetingOpenPolicy.keepsLiveView`).
    func select(sessionID: String?) {
        if let sessionID, let live, !MeetingOpenPolicy.keepsLiveView(showing: live.sessionID, goingTo: sessionID) {
            removeLive()
            listView.isHidden = false
            view.window?.makeFirstResponder(table)
        }
        pendingSelection = sessionID
        refresh()
    }

    func sectionDidShow() {
        onScreen = true
        live?.start()
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.onScreen, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    func sectionDidHide() {
        onScreen = false
        refreshTask?.cancel()
        refreshTask = nil
        live?.stop()
    }

    // MARK: - Live transcript

    /// The meeting the app follows while it starts, records, or saves (`MeetingOpenPolicy.isLive`).
    private var liveSessionID: String? {
        switch meetingState {
        case .starting(let id, _, _), .active(let id, _), .finishing(let id, _): id
        case .idle, .failed: nil
        }
    }

    /// The app's meeting state changed (every status write, about once a second while a meeting records).
    func update(meetingState state: MeetingState) {
        let previous = liveSessionID
        let previousPhase = previous.map { id in
            LiveMeetingPhase.of(sessionID: id, state: meetingState, summary: sessions.first { $0.id == id })
        }
        meetingState = state
        if liveSessionID != previous {
            // A meeting starts or ends: the list's order and its "● Recording" mark change.
            refresh()
        } else if let id = liveSessionID,
                  LiveMeetingPhase.of(sessionID: id, state: state, summary: sessions.first { $0.id == id })
                    != previousPhase {
            // Recording, paused, saving: the meeting's badge says which.
            reloadKeepingSelection()
            updateButtons()
        }
        updateLiveHeader()
    }

    /// Shows the live transcript of the meeting in `directory` in place of the list (opening a live meeting, the menu
    /// bar's Show Live Transcript…).
    func showLive(sessionID: String, directory: URL) {
        if let live, live.sessionID == sessionID {
            view.window?.makeFirstResponder(live.preferredFirstResponder)
            return
        }
        removeLive()
        let controller = LiveMeetingViewController(
            sessionID: sessionID, directory: directory,
            onBack: { [weak self] in self?.showList() },
            onOpenFinished: { [weak self] in self?.openFinished(sessionID) },
            onLearnText: learnLiveText)
        live = controller
        addChild(controller)
        listView.isHidden = true
        Self.fill(view, with: controller.view)
        updateLiveHeader()
        if onScreen { controller.start() }
        view.window?.makeFirstResponder(controller.preferredFirstResponder)
    }

    /// Back to the list, with the meeting the live transcript showed selected.
    func showList() {
        guard let shown = live else { return }
        removeLive()
        listView.isHidden = false
        select(sessionID: shown.sessionID)
        view.window?.makeFirstResponder(table)
    }

    private func removeLive() {
        guard let live else { return }
        live.stop()
        live.view.removeFromSuperview()
        live.removeFromParent()
        self.live = nil
    }

    private func updateLiveHeader() {
        guard let live else { return }
        let summary = sessions.first { $0.id == live.sessionID }
        let header = liveHeader(live.sessionID, summary)
        let action: String? = summary.flatMap { summary in
            switch MeetingOpenPolicy.finishedTarget(summary, inUse: running[summary.id] != nil,
                                                    hasExport: hasExport(summary)) {
            case .review: "Open Review"
            case .transcript: "Open Transcript"
            case .live, .none: nil
            }
        }
        live.update(header: header, finishedAction: action)
    }

    /// The live transcript's "Open Review" / "Open Transcript" once its meeting is saved.
    private func openFinished(_ sessionID: String) {
        guard let summary = sessions.first(where: { $0.id == sessionID }) else {
            NSSound.beep()
            return
        }
        switch MeetingOpenPolicy.finishedTarget(summary, inUse: running[summary.id] != nil,
                                                hasExport: hasExport(summary)) {
        case .review: openReview(summary)
        case .transcript: preview(summary)
        case .live, .none: NSSound.beep()
        }
    }

    @objc private func showLiveTranscript() {
        guard let summary = selectedSession else { return }
        guard MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID) else {
            NSSound.beep()
            return
        }
        showLive(sessionID: summary.id, directory: summary.directory)
    }

    /// The meetings the app is working on (`MeetingController.sessionsInUse`).
    func update(running: [String: String]) {
        self.running = running
        // The badges show what a running command is doing; reloading keeps the selection.
        reloadKeepingSelection()
        updateButtons()
        // A saved live view switches between Open Review and Open Transcript as commands begin and end.
        updateLiveHeader()
    }

    /// The deep transcription passes queued or running (§4.16).
    func update(deepStates: [String: String], running: String?, queuedAutomatically: Set<String> = []) {
        deepQueuedAutomatically = queuedAutomatically
        guard deepStates != self.deepStates || running != deepRunning else { return }
        self.deepStates = deepStates
        deepRunning = running
        reloadKeepingSelection()
        updateButtons()
    }

    /// The meeting whose summary is being written (§4.17), or nil.
    func update(summarizing: String?) {
        guard summarizing != self.summarizing else { return }
        self.summarizing = summarizing
        reloadKeepingSelection()
    }

    /// Reads the catalog off the main actor, then shows it.
    func refresh() {
        guard !loading else { return }
        loading = true
        let root = self.root
        let cache = peopleCache
        Task { [weak self] in
            // A meeting that misses a language is checked for its speech model, so Label Speakers is offered once
            // the language can be detected (§4.14). The people its labels name come from a cache that reads a
            // meeting's labels again only when they changed.
            let listed = await Task.detached { () -> ([SessionSummary], [String: [String]], Int64?) in
                let summaries = await SessionCatalog.checkingLanguageModels(SessionCatalog.list(root: root))
                let store = SpeakerProfileStore()
                let names = VoiceProfileService.profileNames(store: store)
                let recognition = VoiceProfileService.recognitionAllowed(store: store)
                var people: [String: [String]] = [:]
                for summary in summaries {
                    people[summary.id] = cache.people(of: summary, profileNames: names, applyRecognition: recognition)
                }
                cache.keep(only: Set(summaries.map(\.id)))
                return (summaries, people, try? VolumeFreeSpace().availableBytes(at: root))
            }.value
            guard let self else { return }
            self.loading = false
            self.show(listed.0, people: listed.1, freeBytes: listed.2)
        }
    }

    /// Shows the catalog as read: the meetings, the people each one's labels name, and the free space.
    func show(_ listed: [SessionSummary], people: [String: [String]], freeBytes: Int64?) {
        let requested = pendingSelection
        let selected = requested ?? selectedSession?.id
        pendingSelection = nil
        sessions = MeetingOpenPolicy.ordered(listed, liveSessionID: liveSessionID)
        self.people = people
        // A meeting asked for that the search hides: the search is cleared, so it is seen.
        if let requested, !search.stringValue.isEmpty,
           let summary = sessions.first(where: { $0.id == requested }),
           !MeetingListFormat.matches(summary, people: people[requested] ?? [], query: search.stringValue) {
            search.stringValue = ""
        }
        reloadRows(selecting: selected, scroll: requested != nil)
        let used = sessions.reduce(Int64(0)) { $0 + $1.bytes }
        footer.stringValue = "Meetings use \(MeetingFormat.gigabytes(used))"
            + (freeBytes.map { " · \(MeetingFormat.gigabytes($0)) free" } ?? "")
        updateButtons()
        updateLiveHeader()
    }

    /// Rebuilds the rows from `sessions` and the search, keeping the meeting `id` selected.
    private func reloadRows(selecting id: String?, scroll: Bool = false) {
        let query = search.stringValue
        let shown = sessions.filter { MeetingListFormat.matches($0, people: people[$0.id] ?? [], query: query) }
        rows = MeetingListFormat.groups(shown, now: Date()).flatMap { group in
            [Row.group(group.title)] + group.meetings.map(Row.meeting)
        }
        table.reloadData()
        // Rows move when meetings are added or removed: keep the same meeting selected, not the same row.
        if let id, let index = rowIndex(of: id) {
            if table.selectedRow != index {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            if scroll { table.scrollRowToVisible(index) }
        } else {
            table.deselectAll(nil)
        }
        if sessions.isEmpty {
            emptyLabel.stringValue = "No meetings yet.\nStart one from the menu bar; it appears here."
        } else if shown.isEmpty {
            emptyLabel.stringValue = "No meetings match “\(query)”."
        }
        emptyLabel.isHidden = !shown.isEmpty
    }

    /// Reloads the rows' contents (badges, the live phase) with the selection kept.
    private func reloadKeepingSelection() {
        reloadRows(selecting: selectedSession?.id)
    }

    private func rowIndex(of id: String) -> Int? {
        rows.firstIndex { if case .meeting(let summary) = $0 { summary.id == id } else { false } }
    }

    private func session(at row: Int) -> SessionSummary? {
        guard row >= 0, row < rows.count, case .meeting(let summary) = rows[row] else { return nil }
        return summary
    }

    private var selectedSession: SessionSummary? { session(at: table.selectedRow) }

    @objc private func searchChanged() {
        reloadKeepingSelection()
        updateButtons()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        session(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .group: return 28
        case .meeting(let summary): return MeetingRowView.height(hasSummary: summaryText(summary) != nil)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let identifier = NSUserInterfaceItemIdentifier("meetingGroup")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? MeetingGroupView
                ?? MeetingGroupView(identifier: identifier)
            cell.show(title)
            return cell
        case .meeting(let summary):
            let identifier = NSUserInterfaceItemIdentifier("meetingRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? MeetingRowView
                ?? MeetingRowView(identifier: identifier)
            let names = people[summary.id] ?? []
            let isLive = MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID)
            let phase = isLive ? LiveMeetingPhase.of(sessionID: summary.id, state: meetingState, summary: summary) : nil
            cell.show(MeetingRowView.Content(
                title: summary.displayTitle,
                detail: MeetingListFormat.detailLine(summary, people: names, now: Date()),
                summary: summaryText(summary),
                badges: MeetingListFormat.badges(summary, livePhase: phase, working: working(summary)),
                toolTip: toolTip(summary, isLive: isLive)))
            return cell
        }
    }

    /// The row's summary text: the generated one, while the meeting is not being recorded.
    private func summaryText(_ summary: SessionSummary) -> String? {
        guard !MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID),
              let text = summary.generatedSummary?.summary, !text.isEmpty else { return nil }
        return text
    }

    /// What a command, a final transcript, or the summary is doing to the meeting now.
    private func working(_ summary: SessionSummary) -> String? {
        running[summary.id] ?? deepStates[summary.id] ?? (summarizing == summary.id ? "Writing summary…" : nil)
    }

    private func toolTip(_ summary: SessionSummary, isLive: Bool) -> String {
        var lines: [String] = []
        if summary.displayTitle != summary.name { lines.append("Named “\(summary.name)”; the title was written by "
            + "Apple Intelligence from the transcript.") }
        lines.append(Self.stateText(summary) + " · " + MeetingFormat.size(summary.bytes) + " on disk")
        if isLive { lines.append("Double-click or press Return to watch the live transcript.") }
        if let message = summary.labelMessage, summary.speakerState != .labelled { lines.append(message) }
        return lines.joined(separator: "\n")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    /// The live meeting's badge text; nil once it is saved (the catalog's state then).
    static func liveStateText(_ phase: LiveMeetingPhase) -> (String, NSColor)? {
        switch phase {
        case .recording: ("● Recording", .systemRed)
        case .paused: ("● Paused", .systemOrange)
        case .starting: ("Starting…", .secondaryLabelColor)
        case .saving: ("Saving…", .secondaryLabelColor)
        case .saved, .interrupted, .failed: nil
        }
    }

    static func stateText(_ summary: SessionSummary) -> String {
        let text = switch summary.state {
        case .recording: "Recording"
        case .processing: "Processing"
        case .interrupted: "Interrupted"
        case .complete: "Saved"
        case .audioOnly: "Audio only"
        case .transcriptionIncomplete: "Transcript incomplete"
        case .incomplete: "Incomplete"
        case .failed: "Failed"
        case .recovered: "Recovered"
        case .damaged: "Damaged"
        }
        return summary.audioDeleted ? text + " · no audio" : text
    }

    // MARK: - Buttons

    /// What `MeetingActionPolicy` enables for `summary` now, the rules of the commands behind the actions. The
    /// buttons show it, and every way to an action (button, menu, ⌫, Return, double-click) checks it again when used.
    private func enabledActions(_ summary: SessionSummary?) -> Set<MeetingActionPolicy.Action> {
        MeetingActionPolicy.enabled(summary, inUse: summary.map { running[$0.id] != nil } ?? false,
                                    hasExport: summary.map(hasExport) ?? false)
    }

    /// exports/transcript.md is a regular file.
    private func hasExport(_ summary: SessionSummary) -> Bool {
        Self.isRegularFile(SessionPaths.export("md", in: summary.directory))
    }

    /// What opening `summary` shows (`MeetingOpenPolicy`).
    private func openTarget(_ summary: SessionSummary) -> MeetingOpenPolicy.Target {
        MeetingOpenPolicy.target(summary, liveSessionID: liveSessionID, inUse: running[summary.id] != nil,
                                 hasExport: hasExport(summary))
    }

    /// The selected meeting, when `action` is enabled for it; else nil, and a keyboard use beeps.
    private func selection(for action: MeetingActionPolicy.Action) -> SessionSummary? {
        guard let summary = selectedSession else { return nil }
        guard enabledActions(summary).contains(action) else {
            NSSound.beep()
            updateButtons()
            return nil
        }
        return summary
    }

    /// The buttons follow `MeetingActionPolicy`, the rules of the commands behind them.
    private func updateButtons() {
        let summary = selectedSession
        buttons["Review…"]?.isEnabled = summary.map(canReview) ?? false
        buttons["Live Transcript"]?.isEnabled = summary.map { MeetingOpenPolicy.isLive($0, liveSessionID: liveSessionID) }
            ?? false
        let enabled = enabledActions(summary)
        for (title, action) in Self.buttonActions { buttons[title]?.isEnabled = enabled.contains(action) }
        buttons["Clean Up"]?.isHidden = (summary?.derivedBytes ?? 0) == 0
        if let summary {
            var parts: [String] = []
            if let doing = running[summary.id] { parts.append(doing) }
            // While a language is missing, why and what to do stay shown, also for labelled speakers: the window's
            // own message once Label Speakers can detect it (or edited labels keep it from doing so), else the
            // record's, which names the reason and what to install.
            if let work = summary.languageWork, let message = work.message {
                parts.append(message)
            } else if let message = summary.labelMessage,
                      summary.speakerState != .labelled || summary.languageWork != nil {
                parts.append(message)
            }
            if PendingExports().contains(summary.id) {
                parts.append("The transcript files are older than the speaker labels; open Review to update them.")
            }
            statusLabel.stringValue = parts.joined(separator: " ")
        } else {
            statusLabel.stringValue = ""
        }
    }

    /// The buttons (and menu items) run by `MeetingActionPolicy`.
    private static let buttonActions: [(String, MeetingActionPolicy.Action)] = [
        ("Recover…", .recover), ("Label Speakers", .labelSpeakers), ("Show in Finder", .showInFinder),
        ("Open Transcript", .openTranscript), ("Save Transcript As…", .saveTranscript),
        ("Delete Audio…", .deleteAudio), ("Delete Meeting…", .deleteMeeting), ("Clean Up", .cleanUp),
    ]

    /// Review needs speaker labels and no recording, labelling, or command running on the meeting.
    private func canReview(_ summary: SessionSummary) -> Bool {
        MeetingOpenPolicy.canReview(summary, inUse: running[summary.id] != nil)
    }

    @objc private func review() {
        guard let summary = selectedSession else { return }
        guard canReview(summary) else {
            NSSound.beep()
            return
        }
        openReview(summary)
    }

    /// Double-click: as Return.
    @objc private func openSelected() {
        guard session(at: table.clickedRow) != nil else { return }
        openSelection()
    }

    /// Return, or a double-click (`MeetingOpenPolicy`): the live transcript of the meeting being recorded or saved,
    /// Review for a labelled meeting, else the transcript preview (when Open Transcript is enabled; otherwise a beep,
    /// as for any action that is off).
    @objc private func openSelection() {
        guard let summary = selectedSession else { return }
        switch openTarget(summary) {
        case .live: showLive(sessionID: summary.id, directory: summary.directory)
        case .review: openReview(summary)
        case .transcript, .none: openTranscript()
        }
    }

    @objc private func recover() { act(.recover, .recover) }

    @objc private func labelSpeakers() { act(.labelSpeakers, .labelSpeakers) }

    @objc private func deleteAudio() { act(.deleteAudio, .deleteAudio) }

    /// The button, and ⌫ in the list: refused (with a beep) whenever the button is off, for example while another
    /// process holds the meeting.
    @objc private func deleteMeeting() { act(.deleteMeeting, .deleteMeeting) }

    private func act(_ action: Action, _ policy: MeetingActionPolicy.Action) {
        guard let summary = selection(for: policy) else { return }
        perform(action, summary)
        updateButtons()
    }

    @objc private func showInFinder() {
        guard let summary = selection(for: .showInFinder) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([summary.directory])
    }

    /// A Quick Look preview of exports/transcript.md (read-only; Save Transcript As… gives an editable copy).
    @objc private func openTranscript() {
        guard let summary = selection(for: .openTranscript) else { return }
        preview(summary)
    }

    private func preview(_ summary: SessionSummary) {
        let url = SessionPaths.export("md", in: summary.directory)
        guard Self.isRegularFile(url) else { return }
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            view.window?.makeKeyAndOrderFront(nil)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Renders the chosen format from the session (off the main actor) and writes it where the user says.
    @objc private func saveTranscript() {
        guard let summary = selection(for: .saveTranscript) else { return }
        let panel = NSSavePanel()
        let formats = NSPopUpButton()
        formats.addItems(withTitles: ["Markdown (.md)", "Plain text (.txt)"])
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Format:"), formats])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.fileName(summary.displayTitle) + ".md"
        panel.canCreateDirectories = true
        let chooser = FormatChooser(panel: panel, popup: formats)
        formats.target = chooser
        formats.action = #selector(FormatChooser.changed)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            withExtendedLifetime(chooser) {}
            guard response == .OK, let destination = panel.url else { return }
            let format: ExportFormat = formats.indexOfSelectedItem == 1 ? .txt : .md
            self?.write(format, of: summary, to: destination)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Renders while the meeting is registered as in use, so no relabel or command replaces its labels meanwhile.
    private func write(_ format: ExportFormat, of summary: SessionSummary, to destination: URL) {
        let session = summary.directory
        let id = summary.id
        guard beginUsing(id, "Saving the transcript…") else {
            showSheet("Voice is Local could not save the transcript.", Self.inUseText(running[id]))
            return
        }
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do {
                    // People's current names, and "Remember voices": off means the kept voice samples, and the
                    // suggestions made from them, are not used, so this export names nobody automatically.
                    let store = SpeakerProfileStore()
                    let data = try SessionExports.render(
                        format, session: session, profileNames: VoiceProfileService.profileNames(store: store),
                        applyRecognition: VoiceProfileService.recognitionAllowed(store: store))
                    let target = destination.deletingLastPathComponent().resolvingSymlinksInPath()
                        .appendingPathComponent(destination.lastPathComponent)
                    try AtomicFile.write(data, to: target, permissions: 0o600)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.endUsing(id)
            guard let failure else { return }
            self.showSheet("Voice is Local could not save the transcript.", failure)
        }
    }

    /// Deletes leftover speaker-labelling renders under the processing lease, while the meeting is registered as in
    /// use: the automatic relabel skips it, instead of losing the lease race and using up an attempt.
    @objc private func cleanUp() {
        guard let summary = selection(for: .cleanUp) else { return }
        let session = summary.directory
        let id = summary.id
        guard beginUsing(id, "Cleaning up…") else {
            showSheet("Voice is Local could not clean up this meeting.", Self.inUseText(running[id]))
            return
        }
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do {
                    try MeetingController.cleanUpDerived(session: session)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.endUsing(id)
            self.refresh()
            guard let failure else { return }
            self.showSheet("Voice is Local could not clean up this meeting.", failure)
        }
    }

    private func showSheet(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private static func inUseText(_ doing: String?) -> String {
        "Voice is Local is working on this meeting" + (doing.map { " (\($0))" } ?? "") + ". Try again when it finishes."
    }

    // MARK: - Quick Look

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }

    // MARK: - Helpers

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// A file name from the meeting name: no slashes or colons, at most 100 characters.
    private static func fileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }
        let text = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Transcript" : String(text.prefix(100))
    }
}

/// Keeps the save panel's extension in step with the chosen format.
@MainActor
private final class FormatChooser: NSObject {
    private weak var panel: NSSavePanel?
    private weak var popup: NSPopUpButton?

    init(panel: NSSavePanel, popup: NSPopUpButton) {
        self.panel = panel
        self.popup = popup
    }

    @objc func changed() {
        guard let panel, let popup else { return }
        let ext = popup.indexOfSelectedItem == 1 ? "txt" : "md"
        panel.allowedContentTypes = [ext == "txt" ? .plainText : (UTType(filenameExtension: "md") ?? .plainText)]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + ext
    }
}

/// The main window, which lets the Meetings section (`previewController`, set while it shows) take control of the
/// Quick Look panel for the transcript preview. AppKit calls the
/// panel-control methods on the main thread.
@MainActor
final class PreviewingWindow: NSWindow {
    weak var previewController: (NSObject & QLPreviewPanelDataSource & QLPreviewPanelDelegate)?

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewController != nil }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = previewController
            panel.delegate = previewController
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

// MARK: - The meeting's menu

extension MeetingsPane: NSMenuDelegate {
    /// The row clicked, which becomes the selection: Open, Live Transcript, Review…, Open Transcript, Show in Finder,
    /// Save Transcript As…; Summarize Again; Make Final Transcript Now (also for a meeting queued automatically, which
    /// it upgrades), and Cancel Final Transcript while it is queued or running; Recover…, Label Speakers, Delete
    /// Audio…, Delete Meeting…. Each is enabled as its button is.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let summary = session(at: table.clickedRow) else { return }
        if table.selectedRow != table.clickedRow {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        let enabled = enabledActions(summary)
        func add(_ title: String, _ action: Selector, _ isEnabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
        let isLive = MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID)
        add("Open", #selector(openSelection), openTarget(summary) != .none || enabled.contains(.openTranscript))
        if isLive { add("Live Transcript", #selector(showLiveTranscript), true) }
        add("Review…", #selector(review), canReview(summary))
        add("Open Transcript", #selector(openTranscript), enabled.contains(.openTranscript))
        add("Show in Finder", #selector(showInFinder), enabled.contains(.showInFinder))
        add("Save Transcript As…", #selector(saveTranscript), enabled.contains(.saveTranscript))

        menu.addItem(.separator())
        let summarize = NSMenuItem(title: summary.generatedSummary == nil ? "Summarize" : "Summarize Again",
                                   action: #selector(summarizeAgain(_:)), keyEquivalent: "")
        summarize.target = self
        summarize.representedObject = summary.id
        let unavailable = summaryUnavailableReason()
        // Asked for and waiting (or running): it can be cancelled instead.
        let requested = summaryRequested(summary.id)
        summarize.toolTip = unavailable.map { "Apple Intelligence cannot summarize meetings on this Mac: \($0)." }
            ?? "Writes the title and summary again from the transcript with Apple Intelligence, on this Mac. A name "
            + "you gave the meeting is kept."
        summarize.isEnabled = onSummarize != nil && unavailable == nil && summary.transcriptID != nil && !isLive
            && summarizing != summary.id && !requested
            && MeetingSummarySchedule.isFinished(summary.state)
        menu.addItem(summarize)
        if requested {
            let cancel = NSMenuItem(title: "Cancel Summarize", action: #selector(cancelSummary(_:)), keyEquivalent: "")
            cancel.target = self
            cancel.representedObject = summary.id
            menu.addItem(cancel)
        }

        let queuedOrRunning = deepStates[summary.id] != nil || deepRunning == summary.id
        if !queuedOrRunning || deepQueuedAutomatically.contains(summary.id) {
            let item = NSMenuItem(title: "Make Final Transcript Now (relabels speakers)",
                                  action: #selector(runDeepTranscription(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = summary.id
            item.toolTip = "Transcribes the saved audio again with the local Whisper model now, also on battery, and "
                + "labels speakers again: names carry over, edits of single turns do not."
            // As the command's precheck requires: a finished meeting (not recording, processing, or interrupted) with
            // its audio.
            item.isEnabled = DeepTranscriptionSchedule.isFinished(summary.state, audioDeleted: summary.audioDeleted)
                && running[summary.id] == nil
            menu.addItem(item)
        }
        if queuedOrRunning {
            let item = NSMenuItem(title: "Cancel Final Transcript", action: #selector(cancelDeepTranscription(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = summary.id
            menu.addItem(item)
        }

        menu.addItem(.separator())
        add("Recover…", #selector(recover), enabled.contains(.recover))
        add("Label Speakers", #selector(labelSpeakers), enabled.contains(.labelSpeakers))
        add("Delete Audio…", #selector(deleteAudio), enabled.contains(.deleteAudio))
        add("Delete Meeting…", #selector(deleteMeeting), enabled.contains(.deleteMeeting))
    }

    @objc private func summarizeAgain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let summary = sessions.first(where: { $0.id == id })
        else { return }
        onSummarize?(summary)
    }

    @objc private func cancelSummary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onCancelSummary?(id)
    }

    @objc private func runDeepTranscription(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let summary = sessions.first(where: { $0.id == id })
        else { return }
        onDeepTranscription?(true, summary)
    }

    @objc private func cancelDeepTranscription(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let summary = sessions.first(where: { $0.id == id })
        else { return }
        onDeepTranscription?(false, summary)
    }
}

// MARK: - Rows

/// A day header ("Today", "This Week", "September 2026").
@MainActor
final class MeetingGroupView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }
}

/// One meeting: its title (bold) with its badges, when and how long and who on the line below, and its summary in up
/// to two lines.
@MainActor
final class MeetingRowView: NSTableCellView {
    struct Content: Equatable {
        var title: String
        var detail: String
        var summary: String?
        var badges: [MeetingListFormat.Badge]
        var toolTip: String
    }

    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let badges = NSStackView()

    /// The row's height: three lines of text and up to two of summary, or two without a summary.
    static func height(hasSummary: Bool) -> CGFloat { hasSummary ? 84 : 52 }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = title
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 2
        summary.lineBreakMode = .byWordWrapping
        summary.cell?.truncatesLastVisibleLine = true
        badges.spacing = 6
        badges.distribution = .fill
        badges.setContentHuggingPriority(.required, for: .horizontal)
        badges.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [title, NSView(), badges])
        header.spacing = 6
        header.alignment = .centerY
        let stack = NSStackView(views: [header, detail, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(5, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The summary wraps at the row's width, set before the layout so two lines are measured in the same pass.
    override func layout() {
        let width = max(100, bounds.width - 12)
        if summary.preferredMaxLayoutWidth != width { summary.preferredMaxLayoutWidth = width }
        super.layout()
    }

    /// The selected row's text turns white on the accent colour, and so do its badges.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            for case let badge as MeetingBadgeView in badges.arrangedSubviews {
                badge.emphasized = backgroundStyle == .emphasized
            }
        }
    }

    func show(_ content: Content) {
        title.stringValue = content.title
        detail.stringValue = content.detail
        summary.stringValue = content.summary ?? ""
        summary.isHidden = content.summary == nil
        for view in badges.arrangedSubviews {
            badges.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for badge in content.badges {
            let view = MeetingBadgeView(badge)
            view.emphasized = backgroundStyle == .emphasized
            badges.addArrangedSubview(view)
        }
        toolTip = content.toolTip
        var label = content.title + ". " + content.detail
        if !content.badges.isEmpty { label += ". " + content.badges.map(\.text).joined(separator: ", ") }
        if let text = content.summary { label += ". " + text }
        setAccessibilityLabel(label)
    }
}

/// A small rounded badge in the colour of its kind: red while recording, orange when paused, the accent colour for
/// work in progress, orange for what needs attention, grey for a plain fact.
@MainActor
final class MeetingBadgeView: NSTextField {
    private let kind: MeetingListFormat.Badge.Kind
    var emphasized = false {
        didSet { if emphasized != oldValue { needsDisplay = true } }
    }

    init(_ badge: MeetingListFormat.Badge) {
        kind = badge.kind
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 10, weight: .semibold)
        stringValue = badge.text
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel(badge.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: size.height + 2)
    }

    private var color: NSColor {
        switch kind {
        case .live: .systemRed
        case .paused, .warning: .systemOrange
        case .progress: .controlAccentColor
        case .note: .secondaryLabelColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let foreground: NSColor = emphasized ? .white : color
        (emphasized ? NSColor.white.withAlphaComponent(0.22) : color.withAlphaComponent(0.16)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 4, yRadius: 4).fill()
        let text = NSAttributedString(string: stringValue, attributes: [
            .font: font ?? .systemFont(ofSize: 10), .foregroundColor: foreground,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
