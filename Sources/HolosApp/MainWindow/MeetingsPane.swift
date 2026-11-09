import AppKit
import HolosAppModel
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage
import Quartz
import UniformTypeIdentifiers

/// The main window's meeting list and inline meeting screen (docs/design.md "Meetings list").
/// Rows group by day and show title, people, summary, state, and processing progress. Start Recording… and the ··· of
/// the selection are beside the search; a row shows Open and its own ··· when selected or under the pointer. The
/// Advanced menu holds exports, recovery, processing, Finder, and Rename (⌘R).
///
/// Invariants:
/// 1. Double-click and Return open the same inline meeting screen in every processing state.
/// 2. Leaving an embedded review passes through its save gate before detaching the screen.
/// 3. Catalog refreshes preserve selection by meeting ID and publish progress with the rows.
/// 4. Catalog and processing-record reads run off the main actor.
/// 5. The empty view shows exactly when no meeting row is shown; Start Recording… beside the search shows unless the
///    list is empty (the empty view has it then).
@MainActor
final class MeetingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate, MainSectionContent {
    enum Action { case recover, labelSpeakers, deleteAudio, deleteMeeting }

    private enum Row {
        case group(String)
        case meeting(SessionSummary)
    }

    private let root: URL
    let perform: (Action, SessionSummary) -> Void
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
    private(set) var live: LiveMeetingViewController?
    private let listView = NSView()
    private let search = NSSearchField()
    let table = KeyTableView()
    private let emptyView = SectionEmptyView()
    private let footer = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// The section's one task: its accent colour marks it, and no Return key does (Return opens the selected meeting).
    let startButton = NSButton(title: "Start Recording…", target: nil, action: nil)
    /// The selection's actions (`selectionMenu`): off with nothing selected.
    let selectionActions = MeetingActionsButton()
    /// Every meeting, in list order (`MeetingOpenPolicy.ordered`).
    private(set) var sessions: [SessionSummary] = []
    /// What the table shows: the meetings that match the search, under their day headers.
    private var rows: [Row] = []
    /// The people each meeting's speaker labels name, by session ID.
    private var people: [String: [String]] = [:]
    private let peopleCache = MeetingPeopleCache()
    /// Whether each meeting's transcript files are out of date (`SessionExports.filesState`), read again only when a
    /// file or the title changed; and the meetings whose files are (Update Transcript Files).
    let listState = MeetingListState()
    private var filesCache: TranscriptFilesCache { listState.filesCache }
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
    /// Delete Meeting… or Delete Audio… on several selected meetings (the app delegate confirms once, then deletes each
    /// through the single deletion's path).
    var performBulk: ((Action, MeetingBulkPlan) -> Void)?
    /// A deletion of several meetings running (`update(bulkStatus:)`): its progress on the status line. The meetings
    /// still waiting are in `running` ("Waiting to move to the Trash…"), reserved in the app's meetings in use.
    private var bulkStatus: String?
    /// A deletion of several meetings as the list was when it began (`bulkDeletionStarted`): its targets and the
    /// shown order then; `endedAfterRead`, once it ended, the last read begun before (a later one picks the selection).
    private struct BulkSelection {
        var targets: Set<String>
        var order: [String]
        var endedAfterRead: Int?
    }
    private var bulkSelection: BulkSelection?
    /// Reads of the catalog begun (`refresh`), and one more asked for while a read ran.
    private(set) var readsStarted = 0
    private var refreshAgain = false
    /// The selection count VoiceOver was last told about.
    private var announcedCount = 0
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
    /// Stop and Save…, Pause, or Resume of the meeting (its ID) being recorded, from the live transcript's header or
    /// the meeting's menu (the app delegate: `performMeetingRecordingCommand`, the menu bar's path).
    var onRecordingCommand: ((MeetingRecordingCommand, String) -> Void)?
    /// The title a meeting shows changed (its ID): a rename here, or a change the catalog read shows (a rename in
    /// Terminal, a new generated title). Review follows; the live transcript's header follows the list.
    var onTitleChanged: ((String) -> Void)?
    /// The name being edited in the list, with the meeting as it was when the editor opened (what is saved is compared
    /// with that); the rows are not rebuilt meanwhile.
    private var renaming: MeetingRenameEdit?
    /// The rows were asked to be rebuilt while a name was edited: they are once it ends.
    private var reloadDeferred = false
    private var pendingSelection: String?
    private var loading = false
    private var previewURL: URL?

    /// On screen: the window is visible and shows this section.
    private(set) var onScreen = false

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

        MeetingGridColumn.allCases.forEach { table.addTableColumn($0.makeColumn()) }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsColumnReordering = false
        table.style = .fullWidth
        table.floatsGroupRows = true
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(openSelected)
        table.onMouseDown = { [weak self] in self?.listState.renameCandidate = self?.selectedSession?.id }
        table.onReturn = { [weak self] in self?.openSelection() }
        table.onDelete = { [weak self] in self?.deleteMeeting() }
        table.onRename = { [weak self] in self?.renameSelected() }
        table.setAccessibilityLabel("Meetings")
        table.setAccessibilityHelp("Shift-click selects a range of meetings, Command-click adds or removes one.")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        fitColumnsToWidth()
        readWhenTheWindowBecomesKey()

        emptyView.isHidden = true
        emptyView.onAction = { [weak self] in self?.startRecording() }
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        startButton.bezelStyle = .push
        startButton.bezelColor = .controlAccentColor
        startButton.target = self
        startButton.action = #selector(startRecording)
        startButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        selectionActions.makeMenu = { [weak self] in self?.selectionMenu() }
        selectionActions.toolTip = "Actions for the selected meetings"
        selectionActions.setAccessibilityLabel("Actions for the selected meetings")
        selectionActions.setContentCompressionResistancePriority(.required, for: .horizontal)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [search, startButton, selectionActions])
        header.spacing = 8
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [header, scroll, statusLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(8, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(stack)
        listView.addSubview(emptyView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            emptyView.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
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

    /// Selects the meeting after the current review saves pending edits (nil keeps the selection).
    func select(sessionID: String?) {
        if let sessionID, !prepareMeetingNavigation(to: sessionID, replay: { [weak self] in
            self?.select(sessionID: sessionID)
        }) { return }
        pendingSelection = sessionID
        refresh()
    }

    func sectionDidShow() {
        onScreen = true
        live?.start()
        live?.embeddedReview?.reloadAll()
        refresh()
    }

    func sectionDidHide() {
        onScreen = false
        stopReadingAgain()
        live?.stop(); live?.contentState.afterClose = nil
    }

    // MARK: - Live transcript

    /// The app itself is working on a meeting (`readAgainWhileWorking`).
    var appIsWorking: Bool { liveSessionID != nil || !running.isEmpty || deepRunning != nil || summarizing != nil }

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
        updateButtons()
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
        refreshLiveHeader()
    }

    /// Opens the meeting screen after the previous review saves its edits.
    func showLive(sessionID: String, directory: URL) {
        if let live, live.sessionID == sessionID {
            live.contentState.afterClose = nil; view.window?.makeFirstResponder(live.preferredFirstResponder)
            return
        }
        guard prepareMeetingNavigation(to: sessionID, replay: { [weak self] in
            self?.showLive(sessionID: sessionID, directory: directory)
        }) else { return }
        let controller = LiveMeetingViewController(
            sessionID: sessionID, directory: directory,
            onBack: { [weak self] in self?.live?.contentState.closeMainWindow = false; self?.showList() },
            onOpenFinished: { [weak self] in self?.showLive(sessionID: sessionID, directory: directory) },
            onLearnText: learnLiveText,
            onRecordingCommand: { [weak self] command in self?.onRecordingCommand?(command, sessionID) })
        live = controller
        controller.contentState.more.makeMenu = { [weak self] in self?.advancedMenu(sessionID: sessionID) }
        addChild(controller)
        listView.isHidden = true
        Self.fill(view, with: controller.view)
        refreshLiveHeader()
        if onScreen { controller.start() }
        view.window?.makeFirstResponder(controller.preferredFirstResponder)
    }

    var activeMeetingID: String? { live?.sessionID }
    var activeMeeting: SessionSummary? { sessions.first { $0.id == live?.sessionID } }
    var canPresentReview: Bool { onScreen && view.window?.isVisible == true }
    var canStartRecording: Bool { onStartRecording != nil && liveSessionID == nil }

    func installReview(_ review: ReviewWindow) -> Bool {
        guard let live, live.sessionID == review.sessionID else { return false }
        if live.embeddedReview === review { return true }
        let previous = live.view
        guard live.embedReview(review, onClose: { [weak self] in self?.reviewSurfaceClosed() }) else {
            live.contentState.requestedReview = false; return false
        }
        previous.removeFromSuperview()
        listView.isHidden = true
        Self.fill(view, with: live.view)
        return true
    }

    /// Back to the list, with the meeting the live transcript showed selected.
    func showList() {
        guard let shown = live else { return }
        shown.contentState.afterClose = nil
        if let review = shown.embeddedReview, !review.isClosing {
            if review.windowShouldClose(review.window) { review.startClosing() }
            return
        }
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

    /// The live transcript's header as the app delegate describes the meeting now (a command just sent changes its
    /// controls before the meeting's state does).
    func refreshLiveHeader() {
        guard let live else { return }
        let summary = sessions.first { $0.id == live.sessionID }
        let header = liveHeader(live.sessionID, summary)
        live.update(header: header, finishedAction: nil)
        live.contentState.progress.show(listState.progress[live.sessionID])
        if onScreen, !live.contentState.requestedReview, let summary, canReview(summary) {
            live.contentState.requestedReview = true
            openReview(summary)
        }
    }

    /// The meetings the app is working on (`MeetingController.sessionsInUse`).
    func update(running: [String: String]) {
        self.running = running
        readAgainWhileWorking()
        // The badges show what a running command is doing; reloading keeps the selection.
        reloadKeepingSelection()
        updateButtons()
        refreshLiveHeader()
    }

    /// The deep transcription passes queued or running (§4.16).
    func update(deepStates: [String: String], running: String?, queuedAutomatically: Set<String> = []) {
        deepQueuedAutomatically = queuedAutomatically
        guard deepStates != self.deepStates || running != deepRunning else { return }
        self.deepStates = deepStates
        deepRunning = running
        readAgainWhileWorking()
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
        readAgainWhileWorking()
        reloadKeepingSelection()
    }

    /// A deletion of several meetings: its progress for the status line; nil once it ended.
    func update(bulkStatus: String?) {
        guard bulkStatus != self.bulkStatus else { return }
        self.bulkStatus = bulkStatus
        updateButtons()
    }

    /// A deletion of several meetings began on `targets`: the list keeps its order now. While the deletion runs, a
    /// selection its deletions empty stays empty, whatever order the refreshes see them go in; once it ended
    /// (`bulkDeletionEnded`), the next read selects the meeting after the first deleted one in that order.
    func bulkDeletionStarted(_ targets: [String]) {
        bulkSelection = BulkSelection(targets: Set(targets), order: rowIDs.compactMap { $0 })
    }

    /// The deletion of several meetings ended: the list is read again, and that read picks the selection.
    func bulkDeletionEnded() {
        guard var selection = bulkSelection else {
            refresh()
            return
        }
        selection.endedAfterRead = readsStarted
        bulkSelection = selection
        refresh()
    }

    /// Reads the catalog off the main actor, then shows it. Asked while a read runs: once more after it, so what
    /// changed meanwhile (a deletion just ended) is seen.
    func refresh() {
        guard !loading else {
            refreshAgain = true
            return
        }
        loading = true
        readsStarted += 1
        let read = readsStarted
        let root = self.root
        let (cache, catalogCache) = (peopleCache, listState.catalogCache)
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
            let foreground = Set(self?.running.keys.map { $0 } ?? [])
            let listed = await Task.detached {
                () -> ([SessionSummary], [String: [String]], Int64?, Set<String>, Set<String>, [String: PostProcessingProgress]) in
                let summaries = await SessionCatalog.checkingLanguageModels(SessionCatalog.list(root: root, cache: catalogCache))
                let store = SpeakerProfileStore()
                let names = VoiceProfileService.profileNames(store: store)
                let recognition = VoiceProfileService.recognitionAllowed(store: store)
                var people: [String: [String]] = [:]
                for summary in summaries {
                    people[summary.id] = cache.people(of: summary, profileNames: names, applyRecognition: recognition)
                }
                cache.keep(only: Set(summaries.map(\.id)))
                var stale: Set<String> = []
                for summary in summaries where MeetingSummarySchedule.isFinished(summary.state) {
                    if filesCache?.state(of: summary) == .stale { stale.insert(summary.id) }
                }
                filesCache?.keep(only: Set(summaries.map(\.id)))
                let selfName = VoiceProfileService.ownName(store: store)
                let reviewMadeUp = Set(summaries.filter {
                    reviewPending.contains($0.id) && SessionExports.filesMatchLabels(
                        session: $0.directory, profileNames: names, applyRecognition: recognition, selfName: selfName)
                }.map(\.id))
                let progress = Dictionary(uniqueKeysWithValues: summaries.filter {
                    $0.state == .processing || $0.jobInProgress != nil || foreground.contains($0.id)
                }.compactMap { summary in
                    MeetingProcessingProgress.read(session: summary.directory).map { (summary.id, $0) }
                })
                return (summaries, people, try? VolumeFreeSpace().availableBytes(at: root), stale, reviewMadeUp, progress)
            }.value
            guard let self else { return }
            self.loading = false
            self.staleFiles = listed.3
            self.listState.progress = listed.5
            for id in listed.4 where self.running[id] == nil {
                PendingExports().clear(id, ifGeneration: reviewGenerations[id] ?? 0)
            }
            self.show(listed.0, people: listed.1, freeBytes: listed.2, read: read)
            self.readAgainWhileWorking()
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    /// Shows the catalog as read: the meetings, the people each one's labels name, and the free space. `read`: the
    /// number of the read it comes from (`readsStarted`); nil for a listing given directly, taken as the latest.
    func show(_ listed: [SessionSummary], people: [String: [String]], freeBytes: Int64?, read: Int? = nil) {
        let requested = pendingSelection
        var selected = requested.map { Set([$0]) } ?? selectedIDs
        let previouslyShown = rowIDs.compactMap { $0 }
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
        // Every selected meeting is gone (deleted, here or elsewhere): the meeting after them is selected, as in the
        // Finder, so the keyboard can go on from there.
        let listedIDs = Set(sessions.map(\.id))
        if requested == nil, let bulk = bulkSelection {
            if let ended = bulk.endedAfterRead, read.map({ $0 > ended }) ?? true {
                // A read begun after the deletion of several ended: unless a meeting chosen meanwhile is still
                // listed, the meeting after the first deleted one in the order the list had when it began.
                bulkSelection = nil
                if selected.isDisjoint(with: listedIDs) {
                    let remaining = Set(shownSessions().map(\.id))
                    selected = MeetingSelection.successor(of: bulk.targets.subtracting(listedIDs),
                                                          previous: bulk.order, remaining: remaining)
                        .map { [$0] } ?? []
                }
            } else if !selected.isEmpty, selected.isDisjoint(with: listedIDs) {
                // Emptied by its deletions while it runs: chosen once it ended.
                selected = []
            }
        } else if requested == nil, !selected.isEmpty, selected.isDisjoint(with: listedIDs) {
            let remaining = Set(shownSessions().map(\.id))
            selected = MeetingSelection.successor(of: selected, previous: previouslyShown, remaining: remaining)
                .map { [$0] } ?? []
        }
        reloadRows(selecting: selected, scroll: requested != nil)
        let used = sessions.reduce(Int64(0)) { $0 + $1.bytes }
        footer.stringValue = "Meetings use \(MeetingFormat.gigabytes(used))"
            + (freeBytes.map { " · \(MeetingFormat.gigabytes($0)) free" } ?? "")
        updateButtons()
        refreshLiveHeader()
    }

    /// The meetings that match the search, in list order.
    private func shownSessions() -> [SessionSummary] {
        let query = search.stringValue
        return sessions.filter { MeetingListFormat.matches($0, people: people[$0.id] ?? [], query: query) }
    }

    /// Rebuilds the rows from `sessions` and the search, keeping the meetings `ids` selected (those the search
    /// shows). Not while a name is edited (the editor is in a row): then once the editing ends.
    private func reloadRows(selecting ids: Set<String>, scroll: Bool = false) {
        if renaming != nil {
            reloadDeferred = true
            return
        }
        let query = search.stringValue
        let shown = shownSessions()
        rows = MeetingListFormat.groups(shown, now: Date()).flatMap { group in
            [Row.group(group.title)] + group.meetings.map(Row.meeting)
        }
        table.reloadData()
        // Rows move when meetings are added or removed: keep the same meetings selected, not the same rows.
        let indexes = MeetingSelection.indexes(of: ids, rows: rowIDs)
        if table.selectedRowIndexes != indexes {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        if scroll, let first = indexes.first { table.scrollRowToVisible(first) }
        if sessions.isEmpty {
            emptyView.show(Self.noMeetings, enabled: canStartRecording)
        } else if shown.isEmpty {
            emptyView.show(.init(text: "No meetings match “\(query)”."))
        }
        emptyView.isHidden = !shown.isEmpty  // invariant 5
        startButton.isHidden = sessions.isEmpty
    }

    /// Reloads the rows' contents (badges, the live phase) with the selection kept.
    func reloadKeepingSelection() {
        reloadRows(selecting: selectedIDs)
    }

    /// The table row of meeting `id`, if the list shows it.
    func rowIndex(of id: String) -> Int? {
        rows.firstIndex { if case .meeting(let summary) = $0 { summary.id == id } else { false } }
    }

    func session(at row: Int) -> SessionSummary? {
        guard row >= 0, row < rows.count, case .meeting(let summary) = rows[row] else { return nil }
        return summary
    }

    /// The table as shown: each row's session ID, nil for a day header (`MeetingSelection`).
    private var rowIDs: [String?] {
        rows.map { if case .meeting(let summary) = $0 { summary.id } else { nil } }
    }

    /// The selected meetings, in list order.
    private var selectedSessions: [SessionSummary] { activeMeeting.map { [$0] } ?? table.selectedRowIndexes.compactMap(session(at:)) }

    /// The session IDs of the selected meetings, in list order (tests read the selection through this).
    var selectedSessionIDs: [String] { selectedSessions.map(\.id) }

    private var selectedIDs: Set<String> { Set(selectedSessionIDs) }

    /// The selected meeting when exactly one is: what the single-meeting actions use.
    var selectedSession: SessionSummary? {
        activeMeeting ?? (table.selectedRowIndexes.count == 1 ? session(at: table.selectedRow) : nil)
    }

    /// Voice is Local works on the meeting (`running`): a command, or it waits in a deletion of several.
    func isBusy(_ summary: SessionSummary) -> Bool {
        running[summary.id] != nil
    }

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

    /// Clicks, ⇧-click ranges, ⌘-clicks, ⌘A and ⇧↑/↓ select meetings only: a range over a day header selects the
    /// meetings on both sides of it.
    func tableView(_ tableView: NSTableView,
                   selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        MeetingSelection.selectable(proposed, rows: rowIDs)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard case .meeting = rows[row] else { return nil }
        return MeetingTableRowView(table: tableView)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .group: return 28
        case .meeting: return listState.twoLines ? MeetingRowView.twoLineHeight : MeetingRowView.height
        }
    }

    /// A day header spans the row (`tableColumn` nil); a meeting has a cell per `MeetingGridColumn`.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let identifier = NSUserInterfaceItemIdentifier("meetingGroup")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? MeetingGroupView
                ?? MeetingGroupView(identifier: identifier)
            cell.show(title)
            return cell
        case .meeting(let summary):
            guard let column = MeetingGridColumn(tableColumn) else { return nil }
            func cell<Cell: NSView & IdentifiedCell>(_: Cell.Type) -> Cell { column.cell(in: tableView) }
            let names = people[summary.id] ?? [], now = Date()
            switch column {
            case .name:
                let isLive = MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID)
                let phase = isLive
                    ? LiveMeetingPhase.of(sessionID: summary.id, state: meetingState, summary: summary) : nil
                let row = cell(MeetingRowView.self)
                row.show(rowContent(summary, people: names, now: now, isLive: isLive, livePhase: phase))
                row.setAccessibilityCustomActions(accessibilityActions(summary))
                return row
            case .when:
                return cell(MeetingTextCell.self).showing(MeetingListFormat.detailLine(summary, people: [], now: now))
            case .description:
                let text = descriptionLines(summary, people: names)
                return cell(MeetingTextCell.self).showing(text.first ?? "", toolTip: text.joined(separator: "\n\n"))
            case .actions:
                return cell(MeetingRowActionsView.self).showing(rowActions(summary), title: summary.displayTitle,
                                                                start: rowStart(summary, now: now),
                                                                action: actionHandler(summary.id))
            }
        }
    }

    /// The row's summary text: the generated one, while the meeting is not being recorded.
    func summaryText(_ summary: SessionSummary) -> String? {
        guard !MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID),
              let text = summary.generatedSummary?.summary, !text.isEmpty else { return nil }
        return text
    }

    /// What a command (or a deletion of several meetings), a final transcript, the summary, or the echo catch-up is
    /// doing to the meeting now.
    private func working(_ summary: SessionSummary) -> String? {
        if let progress = listState.progress[summary.id] { return MeetingProgressPresentation(progress).title + "…" }
        return running[summary.id] ?? deepStates[summary.id] ?? (summarizing == summary.id ? "Writing summary…" : nil)
            ?? echoStates[summary.id]
    }

    /// The meeting's row badges (`MeetingListFormat.badges`).
    func badges(_ summary: SessionSummary, livePhase: LiveMeetingPhase?) -> [MeetingListFormat.Badge] {
        var echoFailed = false
        if case .failed? = echoProblems[summary.id] { echoFailed = true }
        return MeetingListFormat.badges(summary, livePhase: livePhase, working: working(summary),
                                        echoNotRemoved: echoFailed)
    }

    /// The line under the list, about the selected meeting.
    var statusText: String { statusLabel.stringValue }

    func toolTip(_ summary: SessionSummary, isLive: Bool) -> String {
        var lines: [String] = []
        if summary.displayTitle != summary.name { lines.append("Named “\(summary.name)”; the title was written by "
            + "Apple Intelligence from the transcript.") }
        lines.append(Self.stateText(summary) + " · " + MeetingFormat.size(summary.bytes) + " on disk")
        if isLive {
            lines.append("Double-click or press Return to watch the live transcript.")
        } else if enabledActions(summary).contains(.rename) {
            lines.append("Double-click or press Return to open. Press ⌘R to rename.")
        }
        if let message = summary.labelMessage, summary.speakerState != .labelled { lines.append(message) }
        return lines.joined(separator: "\n")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        revealRowActions()
        announceSelection()
    }

    /// What VoiceOver says about a selection of several meetings ("5 meetings selected"); nil for one or none.
    var selectionAnnouncement: String? {
        let count = selectedSessions.count
        return count > 1 ? "\(count) meetings selected" : nil
    }

    /// VoiceOver says how many meetings are selected when there are several and the count changes.
    private func announceSelection() {
        let count = selectedSessions.count
        defer { announcedCount = count }
        guard count != announcedCount, let text = selectionAnnouncement else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
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

    /// What `MeetingActionPolicy` enables for `summary` now, the rules of the commands behind the actions. The menus
    /// show it, and every way to an action (button, menu, ⌫, Return, double-click) checks it again when used.
    func enabledActions(_ summary: SessionSummary?) -> Set<MeetingActionPolicy.Action> {
        MeetingActionPolicy.enabled(summary, inUse: summary.map(isBusy) ?? false,
                                    hasExport: summary.map(hasExport) ?? false,
                                    transcriptFiles: summary.map { SessionExports.hasTranscriptFiles(session: $0.directory) })
    }

    /// exports/transcript.md is a regular file.
    func hasExport(_ summary: SessionSummary) -> Bool {
        Self.isRegularFile(SessionPaths.export("md", in: summary.directory))
    }

    /// The selected meeting, when `action` is enabled for it; else nil, and a keyboard use beeps.
    private func selection(for action: MeetingActionPolicy.Action) -> SessionSummary? {
        guard let summary = selectedSession else {
            // Several selected: this action is for one meeting.
            if table.selectedRowIndexes.count > 1 { NSSound.beep() }
            return nil
        }
        guard enabledActions(summary).contains(action) else {
            NSSound.beep()
            updateButtons()
            return nil
        }
        return summary
    }

    /// Start Recording… follows the recorder, the selection's ··· the selection; the line under the list says what is
    /// happening to the selection, else what it is.
    func updateButtons() {
        let selected = selectedSessions
        let summary = selectedSession
        startButton.isEnabled = canStartRecording
        selectionActions.isEnabled = !selected.isEmpty
        let progress = bulkStatus.map { [$0] } ?? []
        if selected.count > 1 {
            statusLabel.stringValue = (progress + [MeetingSelection.summary(selected)]).joined(separator: " ")
        } else if let summary {
            var parts: [String] = progress
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
                parts.append("The transcript files are out of date; choose Update Transcript Files from the ··· at the top of the Meetings section.")
            }
            statusLabel.stringValue = parts.isEmpty ? MeetingSelection.summary(of: summary)
                : parts.joined(separator: " ")
        } else {
            statusLabel.stringValue = progress.joined(separator: " ")
        }
    }

    /// What several selected meetings offer: Show in Finder (all of them), and Delete Audio… and Delete Meeting… when
    /// `MeetingActionPolicy` allows them for at least one.
    private func bulkActions(_ selected: [SessionSummary]) -> Set<MeetingActionPolicy.Action> {
        var actions: Set<MeetingActionPolicy.Action> = [.showInFinder]
        for action in [MeetingActionPolicy.Action.deleteAudio, .deleteMeeting]
        where selected.contains(where: { enabledActions($0).contains(action) }) {
            actions.insert(action)
        }
        return actions
    }

    /// Delete Meeting… or Delete Audio… on several selected meetings: the plan of what runs and what is skipped.
    func bulkPlan(_ action: MeetingBulkPlan.Action) -> MeetingBulkPlan {
        let policy: MeetingActionPolicy.Action = action == .deleteMeeting ? .deleteMeeting : .deleteAudio
        return MeetingBulkPlan(action: action, selected: selectedSessions,
                               allowed: { enabledActions($0).contains(policy) }, inUse: isBusy)
    }

    /// Review needs speaker labels and no recording, labelling, or command running on the meeting.
    private func canReview(_ summary: SessionSummary) -> Bool {
        MeetingOpenPolicy.canReview(summary, inUse: running[summary.id] != nil)
    }

    /// Double-click and Return both open the meeting; Rename is an explicit advanced action.
    @objc private func openSelected() {
        listState.cancelPendingRename()
        let row = table.clickedRow
        guard session(at: row) != nil else { return }
        openSelection()
    }

    /// Open, Return, and double-click share one meeting screen.
    @objc private func openSelection() {
        guard let summary = selectedSession else {
            if table.selectedRowIndexes.count > 1 { NSSound.beep() }
            return
        }
        showLive(sessionID: summary.id, directory: summary.directory)
    }

    @objc private func recover() { act(.recover, .recover) }

    @objc private func labelSpeakers() { act(.labelSpeakers, .labelSpeakers) }

    @objc private func deleteAudio() { act(.deleteAudio, .deleteAudio) }

    /// The menu's item, and ⌫ (or ⌘⌫) in the list: refused (with a beep) whenever the item is off, for example while
    /// another process holds the meeting.
    @objc private func deleteMeeting() { act(.deleteMeeting, .deleteMeeting) }

    /// One meeting selected: the action on it. Several: Delete Meeting… and Delete Audio… on those that allow it
    /// (`performBulk`, one confirmation), an alert when none does; the other actions are for one meeting.
    private func act(_ action: Action, _ policy: MeetingActionPolicy.Action) {
        if table.selectedRowIndexes.count > 1 {
            let bulkAction: MeetingBulkPlan.Action
            switch action {
            case .deleteMeeting: bulkAction = .deleteMeeting
            case .deleteAudio: bulkAction = .deleteAudio
            case .recover, .labelSpeakers:
                NSSound.beep()
                return
            }
            let plan = bulkPlan(bulkAction)
            guard !plan.targets.isEmpty else {
                NSSound.beep()
                showSheet(plan.nothingTitle, plan.skipText ?? "")
                updateButtons()
                return
            }
            guard let performBulk else {
                NSSound.beep()
                return
            }
            performBulk(action, plan)
            updateButtons()
            return
        }
        guard let summary = selection(for: policy) else { return }
        perform(action, summary)
        updateButtons()
    }

    /// The selected meetings' folders, all of them when several are selected.
    @objc private func showInFinder() {
        let selected = selectedSessions
        guard selected.count > 1 else {
            guard let summary = selection(for: .showInFinder) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([summary.directory])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.directory))
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

    /// Rename uses the visible meeting's sheet or the list row; an empty name restores the generated title.
    func beginRename(_ summary: SessionSummary) {
        if live != nil { renameOnMeetingScreen(summary); return }
        guard renaming == nil, let index = rowIndex(of: summary.id) else { return }
        if table.selectedRowIndexes != IndexSet(integer: index) {
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
    /// independent of any recording or processing job); `renameEnded` reports.
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
            reloadKeepingSelection()
            refreshLiveHeader()
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

    static func isRegularFile(_ url: URL) -> Bool {
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
    /// The row menu keeps Open and Delete Meeting visible. Export, rename, file access, recording controls,
    /// transcription, summaries, recovery, and audio deletion live in Advanced, with their command policies.
    ///
    /// A right-click on a row of a selection of several acts on all of them (the Finder's rule,
    /// `MeetingSelection.menuTargets`): Show in Finder, Delete Audio…, Delete Meetings…. On a row outside the selection
    /// it acts on that row, which becomes the selection.
    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu, clickedRow: table.clickedRow)
    }

    /// The menu for a right-click on `clickedRow` (tests call it with the row they click).
    func fill(_ rootMenu: NSMenu, clickedRow: Int) {
        rootMenu.removeAllItems()
        let targets = MeetingSelection.menuTargets(clicked: clickedRow, selected: table.selectedRowIndexes,
                                                   rows: rowIDs)
        guard !targets.isEmpty else { return }
        if table.selectedRowIndexes != targets {
            table.selectRowIndexes(targets, byExtendingSelection: false)
        }
        guard targets.count == 1, let summary = session(at: clickedRow) else {
            fillBulk(rootMenu)
            return
        }
        fill(rootMenu, summary: summary)
    }

    func fill(_ rootMenu: NSMenu, summary: SessionSummary) {
        let enabled = enabledActions(summary)
        let open = NSMenuItem(title: "Open", action: #selector(openSelection), keyEquivalent: "")
        open.target = self
        rootMenu.addItem(open)
        let delete = NSMenuItem(title: "Delete Meeting…", action: #selector(deleteMeeting), keyEquivalent: "")
        delete.target = self
        delete.isEnabled = enabled.contains(.deleteMeeting)
        rootMenu.addItem(delete)
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Advanced")
        menu.autoenablesItems = false
        advanced.submenu = menu
        rootMenu.addItem(.separator())
        rootMenu.addItem(advanced)
        @discardableResult
        func add(_ title: String, _ action: Selector, _ isEnabled: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = isEnabled
            menu.addItem(item)
            return item
        }
        let isLive = MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID)
        let hasTranscript = hasExport(summary)
        add("View Transcript", #selector(viewTranscript), hasTranscript).representedObject = summary.id
        add("Show Transcript File", #selector(openTranscript), hasTranscript)
        add("Show in Finder", #selector(showInFinder), enabled.contains(.showInFinder))
        add("Copy Path", #selector(copyPath), true).representedObject = summary.id
        add("Save Transcript As…", #selector(saveTranscript), enabled.contains(.saveTranscript))
        add("Clean Up", #selector(cleanUp), enabled.contains(.cleanUp))
        addRecordingItems(for: summary, isLive: isLive, to: menu)

        menu.addItem(.separator())
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameSelected), keyEquivalent: "r")
        rename.keyEquivalentModifierMask = .command
        rename.target = self
        rename.isEnabled = enabled.contains(.rename)
        rename.toolTip = MeetingActionPolicy.renameRefusal(
            summary, hasExport: SessionExports.hasTranscriptFiles(session: summary.directory))
            ?? ("Gives the meeting a name of your own, which no title Apple Intelligence writes replaces. "
                + "Keyboard shortcut: ⌘R.")
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
    }

    /// The menu of a selection of several meetings: what acts on all of them.
    private func fillBulk(_ menu: NSMenu) {
        let selected = selectedSessions
        let enabled = bulkActions(selected)
        let count = selected.count
        let advanced = NSMenu(title: "Advanced")
        advanced.autoenablesItems = false
        for (title, action, policy) in [
            ("Show \(count) in Finder", #selector(showInFinder), MeetingActionPolicy.Action.showInFinder),
            ("Delete Audio of \(count) Meetings…", #selector(deleteAudio), .deleteAudio),
            ("Delete \(count) Meetings…", #selector(deleteMeeting), .deleteMeeting),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled.contains(policy)
            if policy == .deleteMeeting { menu.addItem(item) } else { advanced.addItem(item) }
        }
        let more = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        more.submenu = advanced
        menu.addItem(.separator())
        menu.addItem(more)
    }

    /// The meeting the app records: Pause or Resume Recording and Stop and Save… (Stop Recording while it starts),
    /// enabled as the menu bar's (`MeetingRecordingControls`); the app delegate checks them again when one is chosen.
    func addRecordingItems(for summary: SessionSummary, isLive: Bool, to menu: NSMenu) {
        guard isLive, onRecordingCommand != nil else { return }
        let controls = liveHeader(summary.id, summary).controls
        guard controls.sessionID == summary.id, let stop = controls.stop else { return }
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector, _ isEnabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = summary.id
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
        if let pause = controls.pause {
            add(pause.title, pause == .pause ? #selector(pauseRecording(_:)) : #selector(resumeRecording(_:)),
                controls.pauseEnabled)
        }
        add(stop.title, #selector(stopRecording(_:)), controls.stopEnabled)
    }

    @objc private func pauseRecording(_ sender: NSMenuItem) { recordingCommand(.pause, sender) }

    @objc private func resumeRecording(_ sender: NSMenuItem) { recordingCommand(.resume, sender) }

    @objc private func stopRecording(_ sender: NSMenuItem) { recordingCommand(.stop, sender) }

    private func recordingCommand(_ command: MeetingRecordingCommand, _ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRecordingCommand?(command, id)
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
