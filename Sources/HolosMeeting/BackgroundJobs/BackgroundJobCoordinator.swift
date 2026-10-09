import Foundation
import os

/// Runs the app's background jobs on meetings, one at a time on this Mac (docs/meeting-design.md §4.16 "App",
/// §4.17, §5.11 "Catching up in the app"): final transcripts (`DeepTranscriptionJobs`) and echo analyses
/// (`EchoCatchUpJobs`). Each kind keeps its queue and says what runs next and what an exit comes to; the coordinator
/// probes the background job lock, applies the holds, orders the kinds' picks (`BackgroundJobOrder`), takes the
/// meeting, starts the command through `BackgroundJobRunner`, stops it when a meeting starts, and retries what was
/// turned down. Summaries keep their own scheduler: they count as another job here (`Environment.otherJobRunning`),
/// and a Summarize Again their scan may start goes first (`Environment.summaryRequestScan`).
///
/// The app calls `schedule()` whenever something may let a job start (a job or command ending, a meeting saved, a
/// queue changing, and a 30 s tick, which also ends delays), and `meetingStateChanged()` on every meeting state change.
///
/// Invariants:
/// 1. At most one job of this coordinator runs (`running`), and none starts while a meeting is starting, recording or
///    saving, while another scheduler of this app runs a job, or while any process holds `DeepTranscriptionLock`.
/// 2. A job is marked running before its meeting is taken (`Environment.beginUsing`): the look that taking it
///    triggers (`MeetingController.onSessionsInUseChanged`) sees it and starts nothing else.
/// 3. A job that took its meeting lets it go exactly once (`Environment.released`), however it ends or fails to
///    start, before the other schedulers and then this one look for their next jobs, and before the kind shows its
///    end (`settled`).
/// 4. Only this coordinator's own child is signalled, at most once per run for a meeting (`preempted`); a job another
///    process runs is never signalled or adopted.
/// 5. Retries live for the launch: a kind waits `retryDelay` after a failed start or a `.retryAll` exit
///    (`retryAfter`), and a meeting after a `.retryMeeting` exit waits the delay its kind gives for that many refusals
///    in a row (`BackgroundJobKind.retryDelay(attempts:)`; a flat minute for final transcripts). A look clears every
///    deadline it finds past, so a clock set back does not bring one back; a meeting's count is forgotten when its job
///    finishes or is cancelled.
@MainActor public final class BackgroundJobCoordinator {
    /// What the coordinator reads of the app and tells it.
    public struct Environment {
        /// A meeting is starting, recording, or saving, or a recorder may still run.
        public var meetingBusy: @MainActor () -> Bool
        /// Meetings in use by another command of the app, or open (opening, saving) in Review.
        public var sessionsInUse: @MainActor () -> Set<String>
        /// Takes a meeting for a job (`MeetingController.beginUsing`); false when the app already uses it.
        public var beginUsing: @MainActor (_ sessionID: String, _ doing: String) -> Bool
        public var lockState: @MainActor () -> DeepTranscriptionLock.State
        /// Another scheduler of this app runs a job (a summary).
        public var otherJobRunning: @MainActor () -> Bool
        /// The summary scan going on may start a Summarize Again.
        public var summaryRequestScan: @MainActor () -> Bool
        /// Looks for the other schedulers' next jobs (summaries), before this coordinator looks for its own.
        public var scheduleOthers: @MainActor () -> Void
        /// A job took its meeting, before its command starts.
        public var started: @MainActor (_ kind: any BackgroundJobKind, _ sessionID: String) -> Void
        /// A job let go of its meeting (invariant 3): the app ends its use (`MeetingController.endUsing`).
        public var released: @MainActor (_ kind: any BackgroundJobKind, _ sessionID: String) -> Void
        /// What the Meetings list shows of the jobs may have changed.
        public var changed: @MainActor () -> Void
        public var now: @MainActor () -> Date

        public init(meetingBusy: @escaping @MainActor () -> Bool,
                    sessionsInUse: @escaping @MainActor () -> Set<String>,
                    beginUsing: @escaping @MainActor (String, String) -> Bool,
                    lockState: @escaping @MainActor () -> DeepTranscriptionLock.State = { DeepTranscriptionLock.state() },
                    otherJobRunning: @escaping @MainActor () -> Bool = { false },
                    summaryRequestScan: @escaping @MainActor () -> Bool = { false },
                    scheduleOthers: @escaping @MainActor () -> Void = {},
                    started: @escaping @MainActor (any BackgroundJobKind, String) -> Void = { _, _ in },
                    released: @escaping @MainActor (any BackgroundJobKind, String) -> Void,
                    changed: @escaping @MainActor () -> Void = {},
                    now: @escaping @MainActor () -> Date = { Date() }) {
            self.meetingBusy = meetingBusy; self.sessionsInUse = sessionsInUse; self.beginUsing = beginUsing
            self.lockState = lockState; self.otherJobRunning = otherJobRunning
            self.summaryRequestScan = summaryRequestScan; self.scheduleOthers = scheduleOthers
            self.started = started; self.released = released; self.changed = changed; self.now = now
        }
    }

    private struct Running {
        let kind: any BackgroundJobKind
        let sessionID: String
        /// Nil until the command started (a kind's `preparation` runs first).
        var handle: (any BackgroundJobHandle)?
        /// Signalled because a meeting started (invariant 4).
        var preempted = false
    }

    /// A kind's retries (invariant 5).
    private struct Retries {
        var retryAfter: Date?
        /// Refusals in a row, and until when the meeting waits (nil once a look found it past).
        var delays: [String: (attempts: Int, until: Date?)] = [:]
    }

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")
    /// How long a kind waits after its command could not start or the lock refused it.
    public static let retryDelay: TimeInterval = 60

    /// In the order their picks are weighed when two have the same priority.
    public let kinds: [any BackgroundJobKind]
    private let runner: any BackgroundJobRunner
    private let environment: Environment
    private var running: Running?
    private var retries: [ObjectIdentifier: Retries] = [:]
    /// The background job lock as last probed while no job of this coordinator ran.
    public private(set) var lock: DeepTranscriptionLock.State = .free
    /// A look held a job back while the summary scan that may start a Summarize Again went on: `summaryScanEnded`
    /// looks again.
    public private(set) var waitsForSummaryScan = false

    public init(runner: any BackgroundJobRunner, kinds: [any BackgroundJobKind], environment: Environment) {
        self.runner = runner
        self.kinds = kinds
        self.environment = environment
    }

    // MARK: - State

    /// A job of this coordinator runs (or is being started).
    public var isRunning: Bool { running != nil }

    /// The meeting `kind`'s job runs on now, if any.
    public func runningSession(of kind: any BackgroundJobKind) -> String? {
        guard let running, running.kind === kind else { return nil }
        return running.sessionID
    }

    /// Whether automatic work of another scheduler (a summary) waits for catch-up work: a catch-up queue is not known
    /// yet, or, with no job of this coordinator running, a catch-up job could start were nothing else going on.
    public func catchUpReady() -> Bool {
        if kinds.contains(where: \.finding) { return true }
        guard running == nil else { return false }
        return picks(busy: environment.meetingBusy(), inUse: environment.sessionsInUse(), now: environment.now())
            .contains { $0.pick.priority == .catchUp }
    }

    /// Whether work the user asked for of one of the kinds waits (ready or not): automatic summaries wait for it.
    public func askedForWorkWaiting() -> Bool {
        let now = environment.now()
        let inUse = environment.sessionsInUse()
        let busy = environment.meetingBusy()
        return kinds.contains { $0.askedForWaiting(holds(for: $0, busy: busy, inUse: inUse, now: now)) }
    }

    // MARK: - Scheduling

    /// Starts the next job when one may start (invariant 1), in `BackgroundJobOrder`'s order. `catchUpOnly`: only a
    /// catch-up job may start (a catch-up queue just found, before summaries are looked for).
    public func schedule(catchUpOnly: Bool = false) {
        for kind in kinds { kind.willLook(running: runningSession(of: kind)) }
        let now = environment.now()
        // Also while a job runs, so a clock set back before it ends brings no wait back (invariant 5).
        expireRetries(now: now)
        guard running == nil else {
            environment.changed()
            return
        }
        lock = environment.lockState()
        let busy = environment.meetingBusy()
        let inUse = environment.sessionsInUse()
        let found = picks(busy: busy, inUse: inUse, now: now).filter { !catchUpOnly || $0.pick.priority == .catchUp }
        let situation = BackgroundJobOrder.Situation(
            blocked: busy || lock != .free || environment.otherJobRunning(),
            askedForWaiting: kinds.contains { $0.askedForWaiting(holds(for: $0, busy: busy, inUse: inUse, now: now)) },
            summaryRequestScan: environment.summaryRequestScan(),
            catchUpPending: kinds.contains(where: \.finding))
        guard let index = BackgroundJobOrder.next(found.map(\.pick.priority), situation) else {
            if situation.summaryRequestScan, !found.isEmpty { waitsForSummaryScan = true }
            environment.changed()
            return
        }
        start(found[index].kind, found[index].pick)
    }

    /// The summary scan ended: a job held back for it is looked at again (it starts unless the scan started a
    /// summary).
    public func summaryScanEnded() {
        guard waitsForSummaryScan else { return }
        waitsForSummaryScan = false
        schedule()
    }

    /// Every meeting state change: while a meeting is starting, recording, or saving, this coordinator's running
    /// command is stopped (SIGTERM; invariant 4); the kind keeps it queued when the signal ended it.
    public func meetingStateChanged() {
        guard environment.meetingBusy(), let job = running, !job.preempted, job.handle?.terminate() == true else {
            return
        }
        running?.preempted = true
        Self.log.notice("\(job.kind.name, privacy: .public) of \(job.sessionID, privacy: .public) stopped for a meeting")
        environment.changed()
    }

    /// The user cancelled `kind`'s job on `sessionID`: its command is stopped (SIGTERM), it is no longer counted as
    /// stopped for a meeting, and its delay is forgotten. The kind takes it off its queue.
    public func cancel(_ kind: any BackgroundJobKind, _ sessionID: String) {
        if let job = running, job.kind === kind, job.sessionID == sessionID {
            job.handle?.terminate()
            running?.preempted = false
        }
        retries[ObjectIdentifier(kind)]?.delays[sessionID] = nil
    }

    /// `kind` may start again at once (a Make Final Transcript Now accepted after a failed start).
    public func clearRetry(_ kind: any BackgroundJobKind) {
        retries[ObjectIdentifier(kind)]?.retryAfter = nil
    }

    // MARK: - Running a job

    /// What each kind would start next were nothing else going on; a kind waiting after a failed start has none.
    private func picks(busy: Bool, inUse: Set<String>, now: Date)
        -> [(kind: any BackgroundJobKind, pick: BackgroundJobPick)] {
        kinds.compactMap { kind in
            let holds = holds(for: kind, busy: busy, inUse: inUse, now: now)
            guard holds.retryOver, let pick = kind.next(holds) else { return nil }
            return (kind, pick)
        }
    }

    private func holds(for kind: any BackgroundJobKind, busy: Bool, inUse: Set<String>, now: Date)
        -> BackgroundJobHolds {
        let kindRetries = retries[ObjectIdentifier(kind)] ?? Retries()
        return BackgroundJobHolds(meetingBusy: busy, inUse: inUse, delayedUntil: kindRetries.delays.compactMapValues(\.until),
                                  retryAfter: kindRetries.retryAfter, running: runningSession(of: kind), now: now)
    }

    private func start(_ kind: any BackgroundJobKind, _ pick: BackgroundJobPick) {
        let sessionID = pick.sessionID
        running = Running(kind: kind, sessionID: sessionID)  // Invariant 2.
        guard environment.beginUsing(sessionID, kind.runningText) else {
            running = nil
            delay(kind, sessionID)
            environment.changed()
            return
        }
        environment.started(kind, sessionID)
        environment.changed()
        guard let check = kind.preparation(for: pick) else {
            launch(kind, pick)
            return
        }
        Task { [weak self] in
            let needed = await Task.detached { check() }.value
            guard let self else { return }
            if !needed {
                self.finish(kind, sessionID, kind.nothingToDo(sessionID))
            } else if self.environment.meetingBusy() {
                // A meeting started while the check ran: it has the Mac to itself; the job stays queued.
                self.finish(kind, sessionID, .stopped)
            } else {
                self.launch(kind, pick)
            }
        }
    }

    private func launch<Kind: BackgroundJobKind>(_ kind: Kind, _ pick: BackgroundJobPick) {
        let sessionID = pick.sessionID
        do {
            let handle = try runner.startJob(pick.command, as: Kind.Outcome.self) { [weak self] result in
                self?.exited(kind, sessionID, result)
            }
            running?.handle = handle
            Self.log.notice("\(kind.name, privacy: .public) of \(sessionID, privacy: .public) started")
        } catch {
            // A transient process limit: the job stays queued and the kind waits a minute.
            retries[ObjectIdentifier(kind), default: Retries()].retryAfter =
                environment.now().addingTimeInterval(Self.retryDelay)
            Self.log.error("Cannot start \(kind.name.lowercased(), privacy: .public): \(error.localizedDescription, privacy: .private)")
            finish(kind, sessionID, .stopped)
        }
    }

    private func exited<Kind: BackgroundJobKind>(_ kind: Kind, _ sessionID: String,
                                                 _ result: CommandResult<Kind.Outcome>) {
        let preempted = running.map { $0.kind === kind && $0.sessionID == sessionID && $0.preempted } ?? false
        Self.log.notice("\(kind.name, privacy: .public) of \(sessionID, privacy: .public) ended with \(result.code, privacy: .public)")
        finish(kind, sessionID, kind.ended(sessionID, result: result, preempted: preempted))
    }

    /// The job on `sessionID` ended (or did not start) as `end`: its retries follow, the meeting is let go of, and the
    /// other schedulers and then this one look for their next jobs (invariant 3).
    private func finish(_ kind: any BackgroundJobKind, _ sessionID: String, _ end: BackgroundJobEnd) {
        switch end {
        case .finished:
            retries[ObjectIdentifier(kind)]?.delays[sessionID] = nil
        case .stopped:
            break
        case .retryMeeting:
            delay(kind, sessionID)
        case .retryAll:
            retries[ObjectIdentifier(kind), default: Retries()].retryAfter =
                environment.now().addingTimeInterval(Self.retryDelay)
        }
        running = nil
        environment.released(kind, sessionID)
        environment.changed()
        environment.scheduleOthers()
        schedule()
        kind.settled(sessionID)
    }

    /// Clears the deadlines that are past (invariant 5); the refusal counts stay.
    private func expireRetries(now: Date) {
        for (key, kindRetries) in retries {
            var expired = kindRetries
            if let retryAfter = expired.retryAfter, retryAfter <= now { expired.retryAfter = nil }
            for (sessionID, delay) in expired.delays {
                if let until = delay.until, until <= now { expired.delays[sessionID]?.until = nil }
            }
            retries[key] = expired
        }
    }

    /// `sessionID` was turned down once more in a row: it waits the kind's delay for that many attempts.
    private func delay(_ kind: any BackgroundJobKind, _ sessionID: String) {
        var kindRetries = retries[ObjectIdentifier(kind)] ?? Retries()
        let attempts = (kindRetries.delays[sessionID]?.attempts ?? 0) + 1
        kindRetries.delays[sessionID] = (attempts, environment.now().addingTimeInterval(kind.retryDelay(attempts: attempts)))
        retries[ObjectIdentifier(kind)] = kindRetries
    }
}
