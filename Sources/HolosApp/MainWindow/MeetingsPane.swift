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
/// Up, Rename) happen here. The meeting being recorded or saved comes first, marked "● Recording". Double-click (or
/// Return) opens what `MeetingOpenPolicy` says: the live transcript (`LiveMeetingViewController`, shown in place of the
/// list until ‹ Meetings or Escape) for that meeting, Review for a labelled one, the preview otherwise; ⌫ is Delete
/// Meeting…. Rename… (the menu, ⌘R, or a double-click on the title's text) edits the name in the row: Return saves it
/// as the user's (an empty name gives back the generated title), Escape cancels (`SessionRenameCommand`, §4.17). The
/// main window's Meetings section; it refreshes every 2 s while on screen, reading the listing off the main actor.
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
    /// The rows of `buttons` under the list; they wrap when the section is narrow.
    private var actionRows: [WrappingRowView] = []
    /// Every meeting, in list order (`MeetingOpenPolicy.ordered`).
    private var sessions: [SessionSummary] = []
    /// What the table shows: the meetings that match the search, under their day headers.
    private var rows: [Row] = []
    /// The people each meeting's speaker labels name, by session ID.
    private var people: [String: [String]] = [:]
    private let peopleCache = MeetingPeopleCache()
    /// Whether each meeting's transcript files are out of date (`SessionExports.filesState`), read again only when a
    /// file or the title changed; and the meetings whose files are (Update Transcript Files).
    private let filesCache = TranscriptFilesCache()
    private var staleFiles: Set<String> = []
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
    /// The app's echo catch-up (`EchoCatchUpSchedule`, §5.11): the queued meetings' badges by session ID, and how the
    /// runs that did not finish in this launch ended (a badge and the status line say so).
    private var echoStates: [String: String] = [:]
    private var echoProblems: [String: EchoCatchUpSchedule.RunEnd] = [:]
    /// The meeting's menu: Make Final Transcript Now (true) and Cancel Final Transcript (false) (§4.16).
    var onDeepTranscription: ((_ runNow: Bool, SessionSummary) -> Void)?
    /// The meeting's menu: Summarize Again, and Cancel Summarize while that request waits or runs.
    var onSummarize: ((SessionSummary) -> Void)?
    var onCancelSummary: ((String) -> Void)?
    /// Whether the meeting's Summarize Again is waiting or running.
    var summaryRequested: (String) -> Bool = { _ in false }
    /// Why Apple Intelligence cannot summarize here (Summarize is off with it as the tooltip); nil when it can.
    var summaryUnavailableReason: () -> String? = { nil }
    /// Runs a rename (the app delegate: `MeetingRenameRun`); `renameEnded` reports.
    var runRename: ((SessionSummary, MeetingRenameRequest) -> Void)?
    /// The title a meeting shows changed (its ID): a rename here, or a change the catalog read shows (a rename in
    /// Terminal, a new generated title). Review follows; the live transcript's header follows the list.
    var onTitleChanged: ((String) -> Void)?
    /// The name being edited in the list, with the meeting as it was when the editor opened (what is saved is compared
    /// with that); the rows are not rebuilt meanwhile.
    private var renaming: MeetingRenameEdit?
    /// The rows were asked to be rebuilt while a name was edited: they are once it ends.
    private var reloadDeferred = false
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
        table.onRename = { [weak self] in self?.renameSelected() }
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

        // Rows that wrap, so the section fits the window at its narrowest (beside a call's window).
        let row = WrappingRowView(views: [
            button("Live Transcript", #selector(showLiveTranscript)),
            button("Review…", #selector(review)),
            button("Recover…", #selector(recover)), button("Label Speakers", #selector(labelSpeakers)),
            button("Show in Finder", #selector(showInFinder)), button("Open Transcript", #selector(openTranscript)),
            button("Save Transcript As…", #selector(saveTranscript)),
        ])
        let second = WrappingRowView(views: [
            button("Delete Audio…", #selector(deleteAudio)), button("Delete Meeting…", #selector(deleteMeeting)),
            button("Clean Up", #selector(cleanUp)),
        ])
        actionRows = [row, second]
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
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            second.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    /// The echo catch-up's queued meetings and its runs that did not finish (§5.11).
    func update(echoStates: [String: String], problems: [String: EchoCatchUpSchedule.RunEnd]) {
        guard echoStates != self.echoStates || problems != echoProblems else { return }
        self.echoStates = echoStates
        echoProblems = problems
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
            // Whether each finished meeting's transcript files are out of date is read from the files (cached until
            // a file or the title changes), whoever wrote them. A Review's failed rewrite (`PendingExports`) is
            // checked against what the saved labels would write, and forgotten once the files match.
            let reviewPending = PendingExports().sessionIDs
            // Read before the check, so a mark set again meanwhile (a review that failed again) is kept.
            let reviewGenerations = Dictionary(uniqueKeysWithValues: reviewPending.map {
                ($0, PendingExports().generation($0))
            })
            let filesCache = self?.filesCache
            let listed = await Task.detached {
                () -> ([SessionSummary], [String: [String]], Int64?, Set<String>, Set<String>) in
                let summaries = await SessionCatalog.checkingLanguageModels(SessionCatalog.list(root: root))
                let store = SpeakerProfileStore()
                let names = VoiceProfileService.profileNames(store: store)
                let recognition = VoiceProfileService.recognitionAllowed(store: store)
                var people: [String: [String]] = [:]
                for summary in summaries {
                    people[summary.id] = cache.people(of: summary, profileNames: names, applyRecognition: recognition)
                }
                cache.keep(only: Set(summaries.map(\.id)))
                var stale: Set<String> = []
                for summary in summaries where MeetingSummarySchedule.isFinished(summary.state)
                    && (summary.transcriptID != nil || summary.nameCopyIsStale) {
                    if filesCache?.state(of: summary) == .stale { stale.insert(summary.id) }
                }
                filesCache?.keep(only: Set(summaries.map(\.id)))
                let selfName = VoiceProfileService.ownName(store: store)
                let reviewMadeUp = Set(summaries.filter {
                    reviewPending.contains($0.id) && SessionExports.filesMatchLabels(
                        session: $0.directory, profileNames: names, applyRecognition: recognition, selfName: selfName)
                }.map(\.id))
                return (summaries, people, try? VolumeFreeSpace().availableBytes(at: root), stale, reviewMadeUp)
            }.value
            guard let self else { return }
            self.loading = false
            self.staleFiles = listed.3
            for id in listed.4 where self.running[id] == nil {
                PendingExports().clear(id, ifGeneration: reviewGenerations[id] ?? 0)
            }
            self.show(listed.0, people: listed.1, freeBytes: listed.2)
        }
    }

    /// Shows the catalog as read: the meetings, the people each one's labels name, and the free space.
    func show(_ listed: [SessionSummary], people: [String: [String]], freeBytes: Int64?) {
        let requested = pendingSelection
        let selected = requested ?? selectedSession?.id
        pendingSelection = nil
        let shownTitles = Dictionary(sessions.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        sessions = MeetingOpenPolicy.ordered(listed, liveSessionID: liveSessionID)
        for id in MeetingListFormat.titlesChanged(from: shownTitles, to: sessions) { onTitleChanged?(id) }
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

    /// Rebuilds the rows from `sessions` and the search, keeping the meeting `id` selected. Not while a name is edited
    /// (the editor is in a row): then once the editing ends.
    private func reloadRows(selecting id: String?, scroll: Bool = false) {
        if renaming != nil {
            reloadDeferred = true
            return
        }
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
                badges: badges(summary, livePhase: phase),
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

    /// What a command, a final transcript, the summary, or the echo catch-up is doing to the meeting now.
    private func working(_ summary: SessionSummary) -> String? {
        running[summary.id] ?? deepStates[summary.id] ?? (summarizing == summary.id ? "Writing summary…" : nil)
            ?? echoStates[summary.id]
    }

    /// The meeting's row badges (`MeetingListFormat.badges`).
    func badges(_ summary: SessionSummary, livePhase: LiveMeetingPhase?) -> [MeetingListFormat.Badge] {
        var echoFailed = false
        if case .failed? = echoProblems[summary.id] { echoFailed = true }
        return MeetingListFormat.badges(summary, livePhase: livePhase, working: working(summary),
                                        echoNotRemoved: echoFailed)
    }

    /// The line under the buttons, about the selected meeting.
    var statusText: String { statusLabel.stringValue }

    private func toolTip(_ summary: SessionSummary, isLive: Bool) -> String {
        var lines: [String] = []
        if summary.displayTitle != summary.name { lines.append("Named “\(summary.name)”; the title was written by "
            + "Apple Intelligence from the transcript.") }
        lines.append(Self.stateText(summary) + " · " + MeetingFormat.size(summary.bytes) + " on disk")
        if isLive {
            lines.append("Double-click or press Return to watch the live transcript.")
        } else if enabledActions(summary).contains(.rename) {
            lines.append("Double-click the title or press ⌘R to rename the meeting.")
        }
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
                                    hasExport: summary.map(hasExport) ?? false,
                                    transcriptFiles: summary.map { SessionExports.hasTranscriptFiles(session: $0.directory) })
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
        let cleanUpHidden = (summary?.derivedBytes ?? 0) == 0
        if buttons["Clean Up"]?.isHidden != cleanUpHidden {
            buttons["Clean Up"]?.isHidden = cleanUpHidden
            actionRows.forEach { $0.viewsChanged() }
        }
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
            // The echo catch-up did not finish on it in this launch: why, in the command's words.
            if running[summary.id] == nil,
               let problem = echoProblems[summary.id].flatMap(EchoCatchUpSchedule.problemText) {
                parts.append(problem)
            }
            if PendingExports().contains(summary.id) {
                parts.append("The transcript files are older than the speaker labels; open Review to update them.")
            }
            // Not while a command works on it (a rename rewriting them).
            if staleFiles.contains(summary.id), running[summary.id] == nil {
                parts.append(summary.transcriptID == nil
                    ? "The meeting's rename did not finish; right-click it and choose Finish Rename."
                    : "The transcript files are out of date (another title, or a rewrite that did not finish); "
                        + "right-click the meeting and choose Update Transcript Files.")
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

    /// Double-click: on the title's text, Rename (when it can be renamed); elsewhere, as Return.
    @objc private func openSelected() {
        let row = table.clickedRow
        guard let summary = session(at: row) else { return }
        if enabledActions(summary).contains(.rename), let event = NSApp.currentEvent,
           let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MeetingRowView,
           cell.titleTextContains(event.locationInWindow) {
            beginRename(summary)
            return
        }
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

    // MARK: - Rename

    /// ⌘R, and the menu's Rename…: edits the selected meeting's name in its row.
    @objc private func renameSelected() {
        guard let summary = selection(for: .rename) else { return }
        beginRename(summary)
    }

    /// The editor in the meeting's row, with the title it shows selected. Return saves (an empty name: the generated
    /// title), Escape cancels.
    private func beginRename(_ summary: SessionSummary) {
        guard renaming == nil, let index = rowIndex(of: summary.id) else { return }
        if table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        table.scrollRowToVisible(index)
        guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? MeetingRowView else { return }
        let edit = MeetingRenameEdit(summary)
        renaming = edit
        let id = summary.id
        let placeholder = summary.currentGeneratedTitle.map { "Leave empty to use “\($0)”" }
            ?? "Leave empty to use the default name"
        cell.beginRenaming(edit.text, placeholder: placeholder,
                           commit: { [weak self] text in self?.endRename(id, saving: text) },
                           cancel: { [weak self] in self?.endRename(id, saving: nil) })
    }

    /// The editor closed: the rows are rebuilt if they were asked to be meanwhile, and the name is saved when it
    /// changes the title the editor opened with (`saving` nil: cancelled). A refresh while it was open (a summary
    /// finished) does not count as an edit.
    private func endRename(_ id: String, saving text: String?) {
        guard let edit = renaming, edit.sessionID == id else { return }
        renaming = nil
        if reloadDeferred {
            reloadDeferred = false
            reloadKeepingSelection()
        }
        guard let text, let request = edit.request(typed: text) else { return }
        rename(sessions.first(where: { $0.id == id }) ?? edit.original, to: request)
    }

    /// The menu's Update Transcript Files, for files out of date (`SessionExports.filesState`): the rename the meeting
    /// has now (`MeetingRenameRequest.retry`), which writes no name and rewrites the files for the title shown and the
    /// saved labels.
    @objc private func updateTranscriptFiles(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let summary = sessions.first(where: { $0.id == id }),
              enabledActions(summary).contains(.rename) else { return }
        rename(summary, to: .retry(summary))
    }

    /// The menu's Use Generated Title.
    @objc private func useGeneratedTitle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let summary = sessions.first(where: { $0.id == id }),
              enabledActions(summary).contains(.rename) else { return }
        rename(summary, to: .generated)
    }

    /// Asks the app to run the rename (`runRename`: `voiceislocal session rename` as a detached child, the meeting
    /// registered as in use meanwhile); `renameEnded` reports.
    private func rename(_ summary: SessionSummary, to request: MeetingRenameRequest) {
        runRename?(summary, request)
    }

    /// The rename command of `summary` ended: `outcome` is its result (nil when it gave none, with `failure` saying
    /// why). The new title shows at once (the next read of the catalog says the same), and a failure says why.
    func renameEnded(_ summary: SessionSummary, outcome: SessionRenameCommand.Outcome?, failure: String?) {
        let id = summary.id
        let shown = Self.short(summary.displayTitle)
        if let outcome, outcome.renamed || outcome.status == .unchanged, let name = outcome.name,
           let source = outcome.nameSource,
           let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].name = name
            sessions[index].nameSource = source
            // The manifest's copy follows when the rename wrote it; the next read of the catalog says.
            sessions[index].manifestName = name
            reloadKeepingSelection()
            updateLiveHeader()
            onTitleChanged?(id)
        }
        refresh()
        updateButtons()
        if let alert = MeetingRenameRun.alert(for: outcome, shown: shown, failure: failure,
                                              repair: MeetingRenameRun.repairTitle(summary)) {
            showSheet(alert.title, alert.text)
        }
    }

    /// At most 60 characters of a title, for alerts.
    private static func short(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(59)) + "…" : text
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
    /// The row clicked, which becomes the selection: the item double-click and Return use, named for what it opens
    /// (Open Live Transcript, Open Review, or Open Transcript), then Review… and Show Transcript File unless that item
    /// already does the same (`MeetingOpenPolicy.menuItems`), Show in Finder, Save Transcript As…; Rename… (⌘R),
    /// while the user's name hides a generated title Use Generated Title, and after a rename whose transcript files
    /// could not be rewritten Update Transcript Files;
    /// Summarize Again; Make Final Transcript Now (also for a meeting queued automatically, which
    /// it upgrades), and Cancel Final Transcript while it is queued or running; Recover…, Label Speakers, Delete
    /// Audio…, Delete Meeting…. Each is enabled as its button is.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let summary = session(at: table.clickedRow) else { return }
        if table.selectedRow != table.clickedRow {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        let enabled = enabledActions(summary)
        @discardableResult
        func add(_ title: String, _ action: Selector, _ isEnabled: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = isEnabled
            menu.addItem(item)
            return item
        }
        let isLive = MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID)
        for open in MeetingOpenPolicy.menuItems(summary, liveSessionID: liveSessionID, inUse: running[summary.id] != nil,
                                                hasExport: hasExport(summary)) {
            switch open.action {
            case .open:
                // What double-click and Return open. No ↩ key equivalent: a context menu's items stay attached to the
                // table, so an unmodified Return here would open the meeting from the search field or the rename
                // editor too; the table handles Return itself (`table.onReturn`).
                add(open.title, #selector(openSelection), open.isEnabled)
            case .review: add(open.title, #selector(review), open.isEnabled)
            case .transcriptFile: add(open.title, #selector(openTranscript), open.isEnabled)
            }
        }
        add("Show in Finder", #selector(showInFinder), enabled.contains(.showInFinder))
        add("Save Transcript As…", #selector(saveTranscript), enabled.contains(.saveTranscript))

        menu.addItem(.separator())
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameSelected), keyEquivalent: "r")
        rename.keyEquivalentModifierMask = .command
        rename.target = self
        rename.isEnabled = enabled.contains(.rename)
        rename.toolTip = MeetingActionPolicy.renameRefusal(
            summary, hasExport: SessionExports.hasTranscriptFiles(session: summary.directory))
            ?? ("Gives the meeting a name of your own, which no title Apple Intelligence writes replaces. "
                + "You can also double-click its title.")
        menu.addItem(rename)
        // Offered while the user's name hides a generated title.
        if summary.nameSource.isUser, let generated = summary.currentGeneratedTitle {
            let item = NSMenuItem(title: "Use Generated Title", action: #selector(useGeneratedTitle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = summary.id
            item.isEnabled = enabled.contains(.rename)
            item.toolTip = "Shows “\(generated)”, the title Apple Intelligence wrote, instead of “\(summary.name)”."
            menu.addItem(item)
        }
        // Transcript files out of date, read from the files: rewritten for the title shown.
        if staleFiles.contains(summary.id), running[summary.id] == nil {
            let item = NSMenuItem(title: MeetingRenameRun.repairTitle(summary),
                                  action: #selector(updateTranscriptFiles(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = summary.id
            item.isEnabled = enabled.contains(.rename)
            item.toolTip = MeetingActionPolicy.renameRefusal(
                summary, hasExport: SessionExports.hasTranscriptFiles(session: summary.directory))
                ?? "Writes the meeting's transcript files again with its title and speakers; nothing is summarized "
                + "again."
            menu.addItem(item)
        }

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
/// to two lines. While the meeting is renamed, an editor takes the place of the title and its badges: Return (or
/// leaving it) saves, Escape cancels.
@MainActor
final class MeetingRowView: NSTableCellView, NSTextFieldDelegate {
    struct Content: Equatable {
        var title: String
        var detail: String
        var summary: String?
        var badges: [MeetingListFormat.Badge]
        var toolTip: String
    }

    private let title = NSTextField(labelWithString: "")
    private let editor = NSTextField(string: "")
    private let detail = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let badges = NSStackView()
    /// While renaming: what Return (or leaving the editor) and Escape do. Each is called once per rename.
    private var onCommit: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    var isRenaming: Bool { onCommit != nil }
    private weak var header: NSStackView?
    /// Pushes the badges to the right; hidden while renaming, so the editor alone spans the line.
    private let spacer = NSView()
    /// The editor spans the title line while it shows (set when it is attached to the line).
    private var editorWidth: NSLayoutConstraint?

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
        editor.font = .systemFont(ofSize: 13, weight: .semibold)
        editor.bezelStyle = .roundedBezel
        editor.lineBreakMode = .byTruncatingTail
        editor.usesSingleLineMode = true
        editor.cell?.isScrollable = true
        editor.cell?.wraps = false
        editor.delegate = self
        editor.isHidden = true
        editor.setAccessibilityLabel("Meeting name")
        editor.toolTip = "Return saves the name, Escape cancels. Leave it empty to use the title Apple Intelligence "
            + "wrote."
        editor.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, editor, spacer, badges])
        header.spacing = 6
        header.alignment = .centerY
        self.header = header
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

    // MARK: - Renaming

    /// Whether `point` (in window coordinates) is on the title's text, not the empty space after it.
    func titleTextContains(_ point: NSPoint) -> Bool {
        guard !isRenaming, !title.isHidden else { return false }
        let local = title.convert(point, from: nil)
        let width = min(title.bounds.width, title.attributedStringValue.size().width + 4)
        return local.x >= 0 && local.x <= width && local.y >= 0 && local.y <= title.bounds.height
    }

    /// Shows the editor in place of the title and its badges, with `text` selected and `placeholder` shown when it is
    /// emptied, and gives it the keyboard.
    func beginRenaming(_ text: String, placeholder: String, commit: @escaping (String) -> Void,
                       cancel: @escaping () -> Void) {
        onCommit = commit
        onCancel = cancel
        editor.stringValue = text
        editor.placeholderString = placeholder
        title.isHidden = true
        badges.isHidden = true
        spacer.isHidden = true
        editor.isHidden = false
        if editorWidth == nil, let header {
            editorWidth = editor.widthAnchor.constraint(equalTo: header.widthAnchor)
        }
        editorWidth?.isActive = true
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    /// Back to the title, without saving (the pane saves what `commit` was given).
    func endRenaming() {
        onCommit = nil
        onCancel = nil
        editorWidth?.isActive = false
        editor.isHidden = true
        title.isHidden = false
        badges.isHidden = false
        spacer.isHidden = false
    }

    /// A row scrolled away while it was renamed is cancelled before the view shows another meeting.
    override func prepareForReuse() {
        super.prepareForReuse()
        finish(saving: false)
    }

    private func finish(saving: Bool) {
        guard let commit = onCommit, let cancel = onCancel else { return }
        let text = editor.stringValue
        // Return or Escape: the keyboard goes back to the list. Leaving the editor by a click keeps it where it went.
        let hadKeyboard = (window?.firstResponder as? NSText)?.delegate === editor
        endRenaming()
        if hadKeyboard {
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            window?.makeFirstResponder(view)
        }
        if saving { commit(text) } else { cancel() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(saving: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            finish(saving: false)
            return true
        default:
            return false
        }
    }

    /// Leaving the editor (a click elsewhere, Tab) saves the name, as in the Finder.
    func controlTextDidEndEditing(_ notification: Notification) {
        finish(saving: true)
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
