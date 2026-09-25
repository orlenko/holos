import Darwin
import Foundation
import HolosAudio
import HolosCore
import HolosStorage
import os

/// How often `MeetingController` looks at the recorder (docs/meeting-design.md §5.8); tests shorten them.
struct MeetingControllerTuning: Sendable {
    /// The followed session's status and liveness are read this often.
    var poll: Duration = .seconds(1)
    /// While idle, the sessions folder is searched for a live meeting this often.
    var rescan: Duration = .seconds(3)
    /// While idle, the automatic relabel runs this often.
    var relabel: Duration = .seconds(30)
    /// A state-changing request waits this long for the previous one's acknowledgement.
    var ackTimeout: Duration = .seconds(3)
}

/// The app's side of a meeting, without AppKit (docs/meeting-design.md §5.8): starts the recorder, follows its
/// `status.json`, sends control requests, finds meetings started elsewhere, pauses dictation through its effects,
/// cleans up the vocabulary hand-off file, and relabels meetings whose labelling was interrupted.
///
/// Effects the app acts on (`announce`, `setDictationPaused`, `finished`, `offerNaming`, `clearNamingOffer`) go to
/// `onEffect`; `launch`, `send`, and `terminateChild` are carried out here. `onChange` follows every state change,
/// including each new status of the followed meeting.
@MainActor public final class MeetingController {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")
    /// Files older than this in the temporary folder are left over from a crash (§4.12).
    static let staleVocabularyAge: TimeInterval = 3_600
    static let vocabularyPrefix = "holos-vocabulary-"
    static let maxVocabularyEntries = 1_000
    static let maxVocabularyLength = 100
    /// UserDefaults key: attempts of the automatic relabel per session ID.
    static let relabelAttemptsKey = "meeting.relabelAttempts"
    /// UserDefaults key: recorder children launched by this app, or by an earlier run of it, whose exit was not seen,
    /// per session ID: [pid, start time in microseconds since 1970].
    static let launchedRecordersKey = "meeting.launchedRecorders"
    /// What the automatic relabel is doing, as `sessionsInUse` shows it.
    public static let relabelDoing = "Labelling speakers automatically…"
    /// UserDefaults key: naming offers the user opened, per session ID: the run they were for.
    static let dismissedOffersKey = "meeting.namingOffersDismissed"

    /// A meeting offered for naming: its labels are those of run `runID`.
    public struct NamingOffer: Sendable, Equatable {
        public var sessionID: String
        public var name: String
        public var runID: String
    }

    public private(set) var reducer = MeetingReducer()
    public var state: MeetingState { reducer.state }
    /// The followed meeting's last status.
    public var status: RecorderStatus? {
        switch reducer.state {
        case .active(_, let status): status
        case .finishing(_, let status): status ?? lastStatus
        case .starting, .failed: lastStatus
        case .idle: nil
        }
    }
    /// True while dictation must stay paused (§4.12).
    public var dictationShouldPause: Bool { reducer.dictationShouldPause }
    /// True while an automatic relabel runs.
    public private(set) var relabelling = false
    /// The meeting the automatic relabel is labelling, while it runs.
    public private(set) var relabellingSessionID: String?
    /// The meetings the app is working on, by session ID: what it is doing ("Recovering…"). Every operation of the
    /// app that takes a meeting's processing lease, or reads the meeting for the user, holds its entry while it runs
    /// (`beginUsing`, `endUsing`): the automatic relabel, Recover (Meetings window and the interrupted prompt), Label
    /// Speakers, Delete Audio, Delete Meeting, Clean Up, and Save Transcript As…. The automatic relabel skips these
    /// meetings and every Meetings action refuses them, so two of them never contend for one lease (the loser fails,
    /// and a relabel would use up an attempt).
    public private(set) var sessionsInUse: [String: String] = [:]
    /// Called after `sessionsInUse` changed.
    public var onSessionsInUseChanged: @MainActor () -> Void = {}
    /// The "Name Speakers — <name>…" offer, derived from saved state (`NamingOfferPolicy`) by `refreshNamingOffer`.
    /// Each change is reported once, as `offerNaming` or `clearNamingOffer`.
    public private(set) var namingOffer: NamingOffer?
    /// Meetings with a review window open, opening, or still saving after it closed (PR9). The automatic relabel
    /// skips them too (`ReviewMaintenance.sessionsInUse`), but Meetings commands do not: a command makes the review
    /// read-only (or closes it) instead (`ReviewMaintenance.response`).
    public var sessionsUnderReview: @MainActor () -> Set<String> = { [] }
    /// Called with the meeting's ID and true when the automatic relabel starts on it, and false when it ends, so an
    /// open review of the meeting can follow `ReviewMaintenance`.
    public var onAutoRelabel: (@MainActor (_ sessionID: String, _ running: Bool) -> Void)?

    public let root: URL
    private let launcher: any RecorderLauncher
    private let maintenance: MaintenanceLauncher?
    private let freeSpace: any FreeSpaceProvider
    private let findInputDevices: @Sendable () -> InputDevices
    private let vocabulary: @MainActor () -> [String]
    private let modelsInstalled: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let onChange: @MainActor (MeetingState) -> Void
    private let onEffect: @MainActor (MeetingEffect) -> Void

    /// Test seams.
    var tuning = MeetingControllerTuning()
    /// Where the vocabulary hand-off files are written ($TMPDIR).
    var vocabularyDirectory = FileManager.default.temporaryDirectory
    /// Where relabel attempts are kept: UserDefaults "meeting.relabelAttempts" (tests keep them in memory).
    var loadRelabelAttempts: @MainActor () -> [String: Int] = {
        (UserDefaults.standard.dictionary(forKey: MeetingController.relabelAttemptsKey) ?? [:])
            .compactMapValues { $0 as? Int }
    }
    var saveRelabelAttempts: @MainActor ([String: Int]) -> Void = {
        UserDefaults.standard.set($0, forKey: MeetingController.relabelAttemptsKey)
    }
    /// Where launched recorders are kept: UserDefaults "meeting.launchedRecorders" (tests keep them in memory).
    var loadLaunchedRecorders: @MainActor () -> [String: [Int]] = {
        (UserDefaults.standard.dictionary(forKey: MeetingController.launchedRecordersKey) ?? [:])
            .compactMapValues { $0 as? [Int] }
    }
    var saveLaunchedRecorders: @MainActor ([String: [Int]]) -> Void = {
        UserDefaults.standard.set($0, forKey: MeetingController.launchedRecordersKey)
    }
    /// Where dismissed naming offers are kept: UserDefaults "meeting.namingOffersDismissed" (tests keep them in memory).
    var loadDismissedOffers: @MainActor () -> [String: String] = {
        (UserDefaults.standard.dictionary(forKey: MeetingController.dismissedOffersKey) ?? [:])
            .compactMapValues { $0 as? String }
    }
    var saveDismissedOffers: @MainActor ([String: String]) -> Void = {
        UserDefaults.standard.set($0, forKey: MeetingController.dismissedOffersKey)
    }

    private var lastStatus: RecorderStatus?
    /// Recorders this controller launched whose end the launcher has not reported yet. A start the menu gave up on
    /// (the 2-minute timeout) can still have its recorder at a permission prompt, before it created its session
    /// folder and before it acts on SIGTERM: no new recorder is launched while one of these still runs. A child's pid
    /// and start time are also saved (`saveLaunchedRecorders`), so an app quit or relaunched meanwhile still waits for
    /// it (`launchedRecordersStillRun`).
    private var unexitedRecorders: Set<String> = []
    private var vocabularyFiles: [String: URL] = [:]
    private var loop: Task<Void, Never>?
    private let clock = ContinuousClock()
    private var lastRescan: ContinuousClock.Instant?
    private var lastRelabel: ContinuousClock.Instant?
    /// Control requests waiting for the previous request's acknowledgement.
    private var pendingSends: [(command: ControlCommand, label: String?, sessionID: String)] = []
    private var awaitingAck: Task<Void, Never>?
    /// Counts `refreshNamingOffer` calls and dismissals: a listing read before the latest one is dropped.
    private var offerGeneration = 0

    public init(root: URL = HolosPaths.sessions, launcher: any RecorderLauncher, maintenance: MaintenanceLauncher?,
                freeSpace: any FreeSpaceProvider, findInputDevices: @escaping @Sendable () -> InputDevices,
                vocabulary: @escaping @MainActor () -> [String], modelsInstalled: @escaping @MainActor () -> Bool,
                now: @escaping @MainActor () -> Date = Date.init,
                onChange: @escaping @MainActor (MeetingState) -> Void,
                onEffect: @escaping @MainActor (MeetingEffect) -> Void) {
        self.root = root; self.launcher = launcher; self.maintenance = maintenance; self.freeSpace = freeSpace
        self.findInputDevices = findInputDevices; self.vocabulary = vocabulary; self.modelsInstalled = modelsInstalled
        self.now = now; self.onChange = onChange; self.onEffect = onEffect
    }

    // MARK: - Public API

    /// Finds a live meeting (§4.1), then polls its status every second; while idle, rescans every 3 s and runs
    /// the automatic relabel every 30 s. Derives the naming offer, which covers meetings labelled while Holos was not
    /// running.
    public func attachOnLaunch() {
        sweepStaleVocabularyFiles()
        // Forgets the saved recorders of an earlier run that have ended.
        _ = launchedRecordersStillRun()
        rescan()
        lastRescan = clock.now
        refreshNamingOffer()
        runAutoRelabel()
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.tuning.poll else { return }
                try? await Task.sleep(for: interval)
                self?.step()
            }
        }
    }

    /// Stops polling (tests; the app polls until it quits).
    func stopMonitoring() {
        loop?.cancel()
        loop = nil
        awaitingAck?.cancel()
        awaitingAck = nil
    }

    /// Disk and microphone checks, writes the vocabulary file (0600), then launches. Throws with the start
    /// panel's error text.
    public func start(_ settings: MeetingStartSettings) throws {
        switch state {
        case .idle, .failed(nil, _): break
        case .failed(let failedID?, _):
            // A start that timed out may still have a recorder behind it (it was only slow); it is followed again as
            // soon as its status is fresh, and a second recorder must not take the microphone meanwhile.
            let liveness = sessionLiveness(failedID, at: now())
            if liveness == .capturing || liveness == .processing {
                throw HolosError.unavailable(MeetingReducer.stillSaving)
            }
        case .finishing: throw HolosError.unavailable(MeetingReducer.stillSaving)
        case .starting where reducer.stoppedWhileStarting: throw HolosError.unavailable(MeetingReducer.stillStopping)
        case .starting, .active: throw HolosError.unavailable(MeetingReducer.alreadyRecording)
        }
        // A recorder this app launched and then stopped following (a timed-out start, even after its failure was
        // dismissed) has not exited: it may be waiting at a permission prompt without a session folder, so its
        // liveness says nothing. It would record alongside a new one once the prompt is answered. One an earlier run of
        // the app launched (the app quit from the failure, or crashed) is found by its saved pid and start time.
        if !unexitedRecorders.isEmpty || launchedRecordersStillRun() {
            throw HolosError.unavailable(MeetingReducer.stillStopping)
        }
        // A meeting started in a terminal since the last rescan (every 3 s) is followed instead: a second recorder
        // must not take the microphone.
        rescan()
        switch state {
        case .idle, .failed: break
        case .finishing: throw HolosError.unavailable(MeetingReducer.stillSaving)
        case .starting, .active: throw HolosError.unavailable(MeetingReducer.alreadyRecording)
        }
        let settings = settings.normalized(now: now())
        try Self.checkStart(settings, freeSpace: freeSpace, root: root, devices: findInputDevices())
        let sessionID = UUID().uuidString
        let file = try writeVocabularyFile(sessionID: sessionID, strings: vocabulary())
        let effects = reducer.reduce(.startRequested(settings, sessionID: sessionID, at: now()))
        lastStatus = nil
        var launchError: (any Error)?
        for effect in effects {
            if case .launch(let launchSettings, let id) = effect {
                do {
                    launcher.onExit = { [weak self] code, tail in
                        self?.recorderExited(sessionID: id, code: code, logTail: tail)
                    }
                    let pid = try launcher.launch(launchSettings, sessionID: id, root: root, vocabularyFile: file)
                    unexitedRecorders.insert(id)
                    if let pid { saveLaunchedRecorder(sessionID: id, pid: pid) }
                    _ = reducer.reduce(.launched(pid: pid, at: now()))
                } catch {
                    launchError = error
                    break
                }
            } else {
                perform(effect)
            }
        }
        if let launchError {
            removeVocabularyFile(sessionID: sessionID)
            Self.log.error("Session \(sessionID, privacy: .public): the recorder could not start (\(ProcessSpawner.logCategory(launchError), privacy: .public)): \(launchError.localizedDescription, privacy: .private)")
            dispatch(.launchFailed(message: launchError.localizedDescription), forceChange: true)
            throw launchError
        }
        Self.log.notice("Session \(sessionID, privacy: .public): starting (\(settings.source.rawValue, privacy: .public))")
        onChange(state)
    }

    public func confirmStop() { dispatch(.stopConfirmed) }

    public func pause() { dispatch(.pauseRequested) }

    public func resume() { dispatch(.resumeRequested) }

    public func addMarker(label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        dispatch(.markerRequested(label: trimmed?.isEmpty == false ? trimmed : nil))
    }

    public func reviewOpened(sessionID: String) { dispatch(.reviewOpened(sessionID: sessionID)) }

    /// Clears a failure shown in the menu.
    public func dismissFailure() { dispatch(.dismissFailure) }

    /// Interrupted sessions not yet prompted about (SessionCatalog). The catalog walks every session, so it is listed
    /// off the main actor (§1.3).
    public func interruptedSessions(excluding prompted: Set<String>) async -> [SessionSummary] {
        let root = self.root
        let at = now()
        let listed = await Task.detached { SessionCatalog.list(root: root, now: at) }.value
        return listed.filter { $0.state == .interrupted && !prompted.contains($0.id) }
    }

    /// The session folder of `sessionID` under the root.
    public func sessionURL(_ sessionID: String) -> URL {
        root.appendingPathComponent("\(sessionID).holos", isDirectory: true)
    }

    // MARK: - Start checks

    /// Refuses a start the recorder would refuse: too little disk (`DiskPolicy.startCheck`), or in person without the
    /// built-in microphone. A free space that cannot be measured does not block the start (the recorder checks again).
    static func checkStart(_ settings: MeetingStartSettings, freeSpace: any FreeSpaceProvider, root: URL,
                           devices: InputDevices) throws {
        if let free = try? freeSpace.availableBytes(at: root),
           case .refuse(let message) = DiskPolicy.startCheck(freeBytes: free, source: settings.source) {
            throw HolosError.unavailable(message)
        }
        if settings.source == .microphone, devices.builtIn == nil {
            throw HolosError.unavailable(BuiltInMicrophone.unavailableMessage)
        }
    }

    // MARK: - Polling

    /// One pass of the loop: the followed session's status, and while idle the rescan and the relabel.
    func step() {
        let instant = clock.now
        if state.sessionID != nil { poll() }
        switch state {
        case .idle, .failed:
            if lastRescan.map({ $0.duration(to: instant) >= tuning.rescan }) ?? true {
                lastRescan = instant
                rescan()
            }
        case .starting, .active, .finishing:
            break
        }
        if case .idle = state, lastRelabel.map({ $0.duration(to: instant) >= tuning.relabel }) ?? true {
            runAutoRelabel()
        }
    }

    /// Reads the followed session's status and liveness and feeds them to the reducer, then a tick.
    func poll() {
        guard let sessionID = state.sessionID else { return }
        let session = sessionURL(sessionID)
        let at = now()
        let status = (try? RecorderChannel.readStatus(session: session)).flatMap { $0.sessionID == sessionID ? $0 : nil }
        let liveness = sessionLiveness(sessionID, at: at)
        let changed = status != nil && status != lastStatus
        if let status {
            // The recorder copied the vocabulary into the session before its first status (§4.12).
            removeVocabularyFile(sessionID: sessionID)
            lastStatus = status
        }
        // A new status (the recorder rewrites it every second) is news even when the state keeps its case: the menu
        // shows its clock and progress.
        dispatch(.statusRead(status, liveness: liveness, at: at), forceChange: changed)
        dispatch(.tick(at: at))
    }

    /// `RecorderChannel.liveness`, or `dead` when the session folder does not exist (yet): liveness counts a lock it
    /// cannot read as held, which a missing folder must not look like.
    private func sessionLiveness(_ sessionID: String, at: Date) -> RecorderLiveness {
        let session = sessionURL(sessionID)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .dead
        }
        return RecorderChannel.liveness(session: session, now: at)
    }

    /// Looks for a live meeting under the root (§4.1 "Reattach"): a `status.json` modified in the last 10 s, fresh,
    /// liveness capturing or processing, and phase `isMeetingActive`, `transcribing`, or `postprocessing`. A recording
    /// meeting wins over one being saved.
    func rescan() {
        switch state {
        case .idle, .failed: break
        case .starting, .active, .finishing: return
        }
        let at = now()
        guard let found = Self.findLiveMeeting(root: root, now: at) else { return }
        Self.log.notice("Session \(found.sessionID, privacy: .public): following a live meeting (\(found.phase.rawValue, privacy: .public))")
        lastStatus = found
        dispatch(.reattached(sessionID: found.sessionID, status: found), forceChange: true)
    }

    /// The live meeting under `root`, if any (see `rescan`). Among several, a recording one (phase `isMeetingActive`)
    /// before one being labelled, then the first by folder name; never chosen by a date.
    static func findLiveMeeting(root: URL, now: Date) -> RecorderStatus? {
        var labelling: RecorderStatus?
        for session in SessionCatalog.sessionFolders(in: root) {
            var info = stat()
            guard lstat(SessionPaths.status(session).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                continue
            }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) < MeetingReducer.freshSeconds else { continue }
            // A recorder still transcribing after a stop is followed too, so the menu shows it saving and a second
            // meeting cannot start meanwhile.
            guard let status = try? RecorderChannel.readStatus(session: session),
                  status.phase.isMeetingActive || status.phase == .transcribing || status.phase == .postprocessing,
                  session.deletingPathExtension().lastPathComponent == status.sessionID else { continue }
            let liveness = RecorderChannel.liveness(session: session, now: now)
            guard MeetingReducer.isFresh(status, liveness: liveness, at: now) else { continue }
            if status.phase.isMeetingActive { return status }
            if labelling == nil { labelling = status }
        }
        return labelling
    }

    // MARK: - Reducer

    private func dispatch(_ event: MeetingEvent, forceChange: Bool = false) {
        let before = reducer.state
        for effect in reducer.reduce(event) { perform(effect) }
        if forceChange || reducer.state != before { onChange(reducer.state) }
    }

    private func perform(_ effect: MeetingEffect) {
        switch effect {
        case .launch:
            // Only `startRequested` asks for a launch, and `start` carries it out.
            break
        case .send(let command, let label, let sessionID):
            pendingSends.append((command, label, sessionID))
            if awaitingAck == nil { sendNext() }
        case .terminateChild(let sessionID):
            launcher.terminate(sessionID: sessionID)
        case .finished(let sessionID, let summary, let ready):
            Self.log.notice("Session \(sessionID, privacy: .public): finished")
            guard ready else {
                onEffect(effect)
                refreshNamingOffer()
                return
            }
            finishOnceLabelsChecked(sessionID: sessionID, summary: summary)
        case .offerNaming:
            // The reducer's offer for a meeting that just ended: the offer is derived from saved state instead
            // (`refreshNamingOffer`, run once the finish is reported), whatever path labelled the meeting.
            break
        case .clearNamingOffer(let sessionID):
            dismissNamingOffer(sessionID: sessionID)
        case .announce, .setDictationPaused:
            onEffect(effect)
        }
    }

    /// Reports a meeting whose post-processing succeeded, with `speakersReady` from its saved labels (post-processing
    /// can succeed without labels, when the speaker models are not installed, and saved labels can be damaged), then
    /// derives the naming offer again.
    private func finishOnceLabelsChecked(sessionID: String, summary: String) {
        let session = sessionURL(sessionID)
        Task { [weak self] in
            let ready = await Self.speakerLabelsReadyOffMain(session: session)
            guard let self else { return }
            self.onEffect(.finished(sessionID: sessionID, summary: summary, speakersReady: ready))
            self.refreshNamingOffer()
        }
    }

    /// A maintenance command the app ran for the meeting in `session` (Recover, Label Speakers) ended with `code`.
    /// Returns whether it ran to its end (0, or 3 with a warning) and left labels that check out
    /// (`speakerLabelsReady`), for the app's result alert. The naming offer is derived again when the command's use of
    /// the meeting ends (`endUsing`).
    public func labellingCommandEnded(session: URL, code: Int32) async -> Bool {
        guard Self.ranToTheEnd(code) else { return false }
        return await Self.speakerLabelsReadyOffMain(session: session)
    }

    /// `holos session diarize|recover` ended with its labels saved, perhaps with a warning (exit code 3: partial).
    static func ranToTheEnd(_ code: Int32) -> Bool { code == 0 || code == 3 }

    // MARK: - Naming offer

    /// Derives the naming offer from saved state (`NamingOfferPolicy`): lists the sessions off the main actor, then
    /// reports a change as `offerNaming` or `clearNamingOffer`. Runs on launch, when a followed recording finishes,
    /// and when any use of a meeting ends (`endUsing`: a Meetings command, the interrupted prompt's Recover, Clean Up,
    /// Save Transcript As…, the automatic relabel), so the offer survives quits and relaunches and does not depend on
    /// which path labelled the meeting. A listing that a later refresh or a dismissal overtook is dropped.
    public func refreshNamingOffer() {
        offerGeneration += 1
        let generation = offerGeneration
        let root = self.root
        let at = now()
        Task { [weak self] in
            let listed = await Task.detached { SessionCatalog.list(root: root, now: at) }.value
            guard let self, generation == self.offerGeneration else { return }
            let dismissed = self.loadDismissedOffers()
            let kept = NamingOfferPolicy.pruned(dismissed, listed: listed)
            if kept != dismissed { self.saveDismissedOffers(kept) }
            let offer = NamingOfferPolicy.offer(listed, dismissed: kept, now: at).flatMap { summary in
                summary.runID.map { NamingOffer(sessionID: summary.id, name: summary.name, runID: $0) }
            }
            self.setNamingOffer(offer)
        }
    }

    /// The user opened the offer of `sessionID` (Name Speakers): it is dismissed for its labels, also across relaunches.
    private func dismissNamingOffer(sessionID: String) {
        guard let offer = namingOffer, offer.sessionID == sessionID else { return }
        var dismissed = loadDismissedOffers()
        dismissed[sessionID] = offer.runID
        saveDismissedOffers(dismissed)
        // A listing read before the dismissal would bring the offer back.
        offerGeneration += 1
        setNamingOffer(nil)
    }

    /// The one place the offer changes and is reported.
    private func setNamingOffer(_ offer: NamingOffer?) {
        guard offer != namingOffer else { return }
        let previous = namingOffer
        namingOffer = offer
        if let offer {
            onEffect(.offerNaming(sessionID: offer.sessionID, name: offer.name))
        } else if let previous {
            onEffect(.clearNamingOffer(sessionID: previous.sessionID))
        }
    }

    // MARK: - Meetings in use

    /// Registers the app's use of `sessionID` for `doing` ("Recovering…"); false, with nothing registered, while the
    /// app already uses it (`sessionsInUse`).
    public func beginUsing(_ sessionID: String, for doing: String) -> Bool {
        guard sessionsInUse[sessionID] == nil else { return false }
        sessionsInUse[sessionID] = doing
        onSessionsInUseChanged()
        return true
    }

    /// Ends the app's use of `sessionID`, then derives the naming offer again: the use may have labelled, deleted, or
    /// changed the meeting.
    public func endUsing(_ sessionID: String) {
        guard sessionsInUse.removeValue(forKey: sessionID) != nil else { return }
        onSessionsInUseChanged()
        refreshNamingOffer()
    }

    /// `speakerLabelsReady` off the main actor: it loads the session's speaker snapshot (§1.3).
    private nonisolated static func speakerLabelsReadyOffMain(session: URL) async -> Bool {
        await Task.detached { speakerLabelsReady(session: session) }.value
    }

    /// The session's saved speaker labels are usable (`SavedSpeakerState.labelsReady`, the validation the catalog,
    /// recovery, and the exports share): the head's run, its transcript, and every span load. Reads files; call it off
    /// the main actor.
    public nonisolated static func speakerLabelsReady(session: URL) -> Bool {
        SavedSpeakerState.read(session: session).labelsReady
    }

    /// Publishes the next queued request, after the previous one was acknowledged (or 3 s passed).
    private func sendNext() {
        guard !pendingSends.isEmpty else {
            awaitingAck = nil
            return
        }
        let next = pendingSends.removeFirst()
        let session = sessionURL(next.sessionID)
        do {
            let request = try RecorderChannel.send(next.command, label: next.label, session: session,
                                                   sessionID: next.sessionID, sender: "app")
            Self.log.notice("Session \(next.sessionID, privacy: .public): sent \(next.command.rawValue, privacy: .public)")
            let timeout = tuning.ackTimeout
            awaitingAck = Task { [weak self] in
                _ = await RecorderChannel.waitForAck(request, session: session, timeout: timeout)
                guard !Task.isCancelled, let self else { return }
                self.awaitingAck = nil
                self.sendNext()
            }
        } catch {
            sendFailed(next.command, sessionID: next.sessionID, error: error)
            sendNext()
        }
    }

    private func sendFailed(_ command: ControlCommand, sessionID: String, error: any Error) {
        let message = error.localizedDescription
        Self.log.error("Session \(sessionID, privacy: .public): cannot send \(command.rawValue, privacy: .public) (\(ProcessSpawner.logCategory(error), privacy: .public)): \(message, privacy: .private)")
        if command == .stop {
            // The recorder is already on its way out: nothing to do.
            if [RecorderChannel.exitedMessage, RecorderChannel.exitingMessage].contains(message) { return }
            // A recorder this app started stops gracefully on SIGTERM too. One it only found (a terminal or an earlier
            // app) gets no signal, so the controls must work again: Stop can be tried once more.
            if launcher.terminate(sessionID: sessionID) { return }
            reducer.stopWasNotDelivered()
        }
        onEffect(.announce("Could not ask the recorder to \(command.rawValue): \(message)"))
    }

    // MARK: - Recorder exit

    private func recorderExited(sessionID: String, code: Int32, logTail: String?) {
        unexitedRecorders.remove(sessionID)
        var launched = loadLaunchedRecorders()
        if launched.removeValue(forKey: sessionID) != nil { saveLaunchedRecorders(launched) }
        removeVocabularyFile(sessionID: sessionID)
        guard state.sessionID == sessionID else { return }
        // A recorder that wrote `exited` first is finished from its status, not from the exit.
        poll()
        guard state.sessionID == sessionID else { return }
        dispatch(.childExited(code: code, logTail: logTail, at: now()))
    }

    /// Saves the pid and start time of a recorder child just launched, until its exit is seen.
    private func saveLaunchedRecorder(sessionID: String, pid: Int32) {
        // A child already gone has no start time; its exit is reported by the launcher.
        guard let started = ProcessSpawner.startTime(of: pid) else { return }
        var launched = loadLaunchedRecorders()
        launched[sessionID] = [Int(pid), Int(started)]
        saveLaunchedRecorders(launched)
    }

    /// True while a saved launched recorder still runs: one of this run whose exit was not reported, or one whose
    /// pid still names a process with the saved start time (a reused pid names a later one). Saved recorders that
    /// ended are forgotten.
    private func launchedRecordersStillRun() -> Bool {
        let saved = loadLaunchedRecorders()
        let running = saved.filter { sessionID, identity in
            if unexitedRecorders.contains(sessionID) { return true }
            guard identity.count == 2, let pid = Int32(exactly: identity[0]),
                  let started = UInt64(exactly: identity[1]) else { return false }
            return ProcessSpawner.startTime(of: pid) == started
        }
        if running.count != saved.count { saveLaunchedRecorders(running) }
        return !running.isEmpty
    }

    // MARK: - Vocabulary hand-off (§4.12)

    /// Writes `$TMPDIR/holos-vocabulary-<id>.json` (0600, created exclusively) with at most 1,000 entries of at most
    /// 100 characters; nil when there is nothing to write.
    func writeVocabularyFile(sessionID: String, strings: [String]) throws -> URL? {
        let entries = Array(strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= Self.maxVocabularyLength }
            .prefix(Self.maxVocabularyEntries))
        guard !entries.isEmpty else { return nil }
        let url = vocabularyDirectory.appendingPathComponent("\(Self.vocabularyPrefix)\(sessionID).json",
                                                             isDirectory: false)
        try AtomicFile.create(HolosJSON.encoder().encode(MeetingVocabulary(strings: entries)), at: url,
                              permissions: 0o600)
        vocabularyFiles[sessionID] = url
        return url
    }

    /// Deletes the session's vocabulary file if it is still there (a regular file; never a link or a folder).
    func removeVocabularyFile(sessionID: String) {
        guard let url = vocabularyFiles.removeValue(forKey: sessionID) else { return }
        ProcessSpawner.removeRegularFile(url)
    }

    /// Removes `holos-vocabulary-*.json` files older than an hour: left by an app that crashed before cleaning up.
    func sweepStaleVocabularyFiles() {
        ProcessSpawner.removeStaleFiles(in: vocabularyDirectory, prefix: Self.vocabularyPrefix, suffix: ".json",
                                        olderThan: now().addingTimeInterval(-Self.staleVocabularyAge))
    }

    // MARK: - Automatic relabel

    /// Picks at most one meeting whose labelling was interrupted (`AutoRelabelPolicy`) and runs
    /// `holos session diarize <path> --json` for it; attempts are counted in UserDefaults. Runs on launch and every
    /// 30 s while idle; the app also calls it as soon as it learns the speaker models are installed.
    public func runAutoRelabel() {
        lastRelabel = clock.now
        guard let maintenance, !relabelling, case .idle = state, modelsInstalled() else { return }
        relabelling = true
        let root = self.root
        let at = now()
        Task { [weak self] in
            let listed = await Task.detached { SessionCatalog.list(root: root, now: at) }.value
            guard let self else { return }
            let active: Bool = if case .idle = self.state { false } else { true }
            // A meeting the app uses right now (`sessionsInUse`) is left alone: two commands would contend for its
            // processing lease, and the loser would fail (and here, use up an attempt). So is a meeting under review
            // (`sessionsUnderReview`): the user is editing its labels.
            let inUse = ReviewMaintenance.sessionsInUse(commands: self.sessionsInUse.keys,
                                                        reviews: self.sessionsUnderReview())
            let summaries = listed.filter { !inUse.contains($0.id) }
            var attempts = self.loadRelabelAttempts()
            guard let pick = AutoRelabelPolicy.candidates(summaries, attempts: attempts,
                                                          modelsInstalled: self.modelsInstalled(),
                                                          meetingActive: active, now: self.now()).first else {
                self.relabelling = false
                return
            }
            // Forget meetings too old to be picked again.
            let recent = Set(listed.filter { at.timeIntervalSince($0.createdAt) <= AutoRelabelPolicy.maxAge }.map(\.id))
            attempts = attempts.filter { recent.contains($0.key) }
            // An attempt counts only once its command started: a launch failure (a spawn error, the bundled tool
            // missing for a moment) labelled nothing and must not use up one of `AutoRelabelPolicy.maxAttempts`. The
            // count is saved before this main-actor task yields, so the command's exit never runs ahead of it.
            defer { self.saveRelabelAttempts(attempts) }
            // Registered before the command starts, on the main actor, so no Meetings action can take the meeting
            // between the check above and the spawn.
            guard self.beginUsing(pick.id, for: Self.relabelDoing) else {
                self.relabelling = false
                return
            }
            do {
                try maintenance.run(["session", "diarize", pick.directory.path, "--json"]) { [weak self] code in
                    Self.log.notice("Session \(pick.id, privacy: .public): automatic relabel ended with \(code, privacy: .public)")
                    self?.relabelling = false
                    self?.relabellingSessionID = nil
                    // An open review of the meeting rereads it and is editable again.
                    self?.onAutoRelabel?(pick.id, false)
                    // Labelled in the background: the naming offer is derived again as the use ends.
                    self?.endUsing(pick.id)
                }
                attempts[pick.id, default: 0] += 1
                self.relabellingSessionID = pick.id
                self.onAutoRelabel?(pick.id, true)
                Self.log.notice("Session \(pick.id, privacy: .public): relabelling automatically (attempt \(attempts[pick.id] ?? 0, privacy: .public))")
            } catch {
                Self.log.error("Session \(pick.id, privacy: .public): automatic relabel could not start (\(ProcessSpawner.logCategory(error), privacy: .public)): \(error.localizedDescription, privacy: .private)")
                self.relabelling = false
                self.endUsing(pick.id)
            }
        }
    }

    // MARK: - Maintenance helpers for the app

    /// Deletes leftover speaker-labelling renders (`derived/`) under the processing lease, so a running labelling is
    /// never touched (it holds the lease). Throws `unavailable` while another Holos process works on the session.
    public nonisolated static func cleanUpDerived(session: URL) throws {
        let lease = try SessionArchive.acquireProcessingLease(at: session, retry: .zero)
        defer { lease.release() }
        _ = try AtomicFile.removeTree(["derived"], in: session)
    }
}
