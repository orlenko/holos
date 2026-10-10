import Foundation
import os

/// Runs the app's background jobs on meetings, one at a time on this Mac (docs/meeting/deep-transcription.md §4.16 "App",
/// docs/meeting/titles-summaries.md §4.17, docs/meeting/online-calls-echo.md §5.11 "Catching up in the app"): final transcripts (`DeepTranscriptionJobs`), echo analyses
/// (`EchoCatchUpJobs`) and summaries (`MeetingSummaryJobs`). Each kind keeps its queue and says what runs next and what
/// an exit comes to; the coordinator probes the background job lock, applies the holds, orders the kinds' picks
/// (`BackgroundJobOrder`), takes the meeting, starts the command through `BackgroundJobRunner`, stops it when a meeting
/// starts, and retries what was turned down.
///
/// `MeetingController`'s automatic relabel is not one of its jobs: it runs beside them (it takes no background job
/// lock, waits for none of them, and is never stopped for a meeting, since it starts only while none goes on), and
/// meets them only through `MeetingController.sessionsInUse`.
///
/// The app calls `schedule()` whenever something may let a job start (a job or command ending, a meeting saved, a
/// queue changing, and a 30 s tick, which also ends delays), and `meetingStateChanged()` on every meeting state change.
///
/// Invariants:
/// 1. At most one job of this coordinator runs (`running`), and none starts while a meeting is starting, recording or
///    saving, or while any process holds `DeepTranscriptionLock`.
/// 2. A job is marked running before its meeting is taken (`Environment.beginUsing`): the look that taking it
///    triggers (`MeetingController.onSessionsInUseChanged`) sees it and starts nothing else.
/// 3. A job that took its meeting lets it go exactly once (`Environment.released`), however it ends or fails to
///    start, before the next jobs are looked for, and before the kind shows its end (`settled`).
/// 4. Only this coordinator's own child is signalled, at most once per run for a meeting (`preempted`); a job another
///    process runs is never signalled or adopted.
/// 5. Retries live for the launch: a kind waits `retryDelay` after a failed start or a `.retryAll` exit
///    (`retryAfter`), and a meeting after a `.retryMeeting` exit waits the delay its kind gives for that many refusals
///    in a row (`BackgroundJobKind.retryDelay(attempts:)`; a flat minute for final transcripts, 1, 2, 4… up to 30 minutes for
///    echo analyses). A look clears every
///    deadline it finds past, so a clock set back does not bring one back; a meeting's count is forgotten when its job
///    finishes or is cancelled.
/// 6. A job of a kind with a `reviewHold` holds its meeting's review from the moment it is marked running until it is
///    let go of (`reviewHold(on:)`), and that hold goes with its release, however the job ends or fails to start.
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
        /// A job let go of its meeting (invariant 3): the app ends its use (`MeetingController.endUsing`).
        /// With the job's review hold (invariant 6), if it had one: the app's review of the meeting takes it back.
        public var released: @MainActor (_ kind: any BackgroundJobKind, _ sessionID: String,
                                         _ hold: ReviewMaintenance.Hold?) -> Void
        /// What the Meetings list shows of the jobs may have changed.
        public var changed: @MainActor () -> Void
        public var now: @MainActor () -> Date

        public init(meetingBusy: @escaping @MainActor () -> Bool,
                    sessionsInUse: @escaping @MainActor () -> Set<String>,
                    beginUsing: @escaping @MainActor (String, String) -> Bool,
                    lockState: @escaping @MainActor () -> DeepTranscriptionLock.State = { DeepTranscriptionLock.state() },
                    released: @escaping @MainActor (any BackgroundJobKind, String, ReviewMaintenance.Hold?) -> Void,
                    changed: @escaping @MainActor () -> Void = {},
                    now: @escaping @MainActor () -> Date = { Date() }) {
            self.meetingBusy = meetingBusy; self.sessionsInUse = sessionsInUse; self.beginUsing = beginUsing
            self.lockState = lockState
            self.released = released; self.changed = changed; self.now = now
        }
    }

    private struct Running {
        let kind: any BackgroundJobKind
        let sessionID: String
        /// The review hold of the run (invariant 6), for a kind that has one.
        let hold: ReviewMaintenance.Hold?
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

    /// The review hold of the job running on `sessionID` (invariant 6): a review that opens on it meanwhile is
    /// read-only until the job lets the meeting go.
    public func reviewHold(on sessionID: String) -> ReviewMaintenance.Hold? {
        guard let running, running.sessionID == sessionID else { return nil }
        return running.hold
    }

    // MARK: - Scheduling

    /// Starts the next job when one may start (invariant 1), in `BackgroundJobOrder`'s order. A full look first lets
    /// the kinds look for work (a summary scan), also while a job runs; `catchUpOnly`: only a catch-up job may start,
    /// and no kind looks for work (a catch-up queue just found).
    public func schedule(catchUpOnly: Bool = false) {
        for kind in kinds { kind.willLook(running: runningSession(of: kind)) }
        let now = environment.now()
        // Also while a job runs, so a clock set back before it ends brings no wait back (invariant 5).
        expireRetries(now: now)
        let busy = environment.meetingBusy()
        if !catchUpOnly {
            let inUse = environment.sessionsInUse()
            for kind in kinds { kind.lookForWork(holds(for: kind, busy: busy, inUse: inUse, now: now)) }
        }
        guard running == nil else {
            environment.changed()
            return
        }
        lock = environment.lockState()
        let inUse = environment.sessionsInUse()
        let askedFor = kinds.contains { $0.askedForWaiting(holds(for: $0, busy: busy, inUse: inUse, now: now)) }
        let found = picks(busy: busy, inUse: inUse, askedFor: askedFor, now: now)
            .filter { !catchUpOnly || $0.pick.priority == .catchUp }
        let situation = BackgroundJobOrder.Situation(
            blocked: busy || lock != .free, askedForWaiting: askedFor,
            askedForFinding: kinds.contains(where: \.askedForFinding),
            catchUpPending: kinds.contains(where: \.finding))
        guard let index = BackgroundJobOrder.next(found.map(\.pick.priority), situation) else {
            environment.changed()
            return
        }
        start(found[index].kind, found[index].pick)
    }

    /// Every meeting state change: while a meeting is starting, recording, or saving, this coordinator's running
    /// command is stopped (SIGTERM; invariant 4); the kind keeps it queued when the signal ended it.
    public func meetingStateChanged() {
        guard environment.meetingBusy(), let job = running else { return }
        preempt(job.kind, because: "for a meeting")
    }

    /// `kind`'s running command is stopped as for a meeting (SIGTERM; invariant 4): a summary when a final-transcript
    /// reconciliation starts, which may queue a final transcript of its meeting.
    public func preempt(_ kind: any BackgroundJobKind, because reason: String = "for a reconciliation") {
        guard let job = running, job.kind === kind, !job.preempted, job.handle?.terminate() == true else { return }
        running?.preempted = true
        Self.log.notice("\(job.kind.name, privacy: .public) of \(job.sessionID, privacy: .public) stopped \(reason, privacy: .public)")
        environment.changed()
    }

    /// The user cancelled `kind`'s run on `sessionID` without taking it off the kind's work (Cancel Summarize: the
    /// request goes, nothing else): its command is stopped (SIGTERM).
    public func stop(_ kind: any BackgroundJobKind, _ sessionID: String) {
        guard let job = running, job.kind === kind, job.sessionID == sessionID else { return }
        job.handle?.terminate()
    }

    /// `kind`'s meeting `sessionID` may start again at once (Summarize Again).
    public func clearDelay(_ kind: any BackgroundJobKind, _ sessionID: String) {
        retries[ObjectIdentifier(kind)]?.delays[sessionID] = nil
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
    private func picks(busy: Bool, inUse: Set<String>, askedFor: Bool, now: Date)
        -> [(kind: any BackgroundJobKind, pick: BackgroundJobPick)] {
        kinds.compactMap { kind in
            var holds = holds(for: kind, busy: busy, inUse: inUse, now: now)
            holds.askedForWaiting = askedFor
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
        // Invariants 2 and 6.
        running = Running(kind: kind, sessionID: sessionID, hold: kind.reviewHold.map(ReviewMaintenance.Hold.init))
        guard environment.beginUsing(sessionID, kind.runningText) else {
            running = nil
            delay(kind, sessionID)
            environment.changed()
            return
        }
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
            // A transient process limit: the job stays queued and the kind (or the meeting) waits a minute.
            Self.log.error("Cannot start \(kind.name.lowercased(), privacy: .public): \(error.localizedDescription, privacy: .private)")
            finish(kind, sessionID, kind.startFailed(sessionID))
        }
    }

    private func exited<Kind: BackgroundJobKind>(_ kind: Kind, _ sessionID: String,
                                                 _ result: CommandResult<Kind.Outcome>) {
        let preempted = running.map { $0.kind === kind && $0.sessionID == sessionID && $0.preempted } ?? false
        Self.log.notice("\(kind.name, privacy: .public) of \(sessionID, privacy: .public) ended with \(result.code, privacy: .public)")
        finish(kind, sessionID, kind.ended(sessionID, result: result, preempted: preempted))
    }

    /// The job on `sessionID` ended (or did not start) as `end`: its retries follow, the meeting is let go of, and the
    /// next jobs are looked for, a summary scan first (invariant 3).
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
        case .wait(let seconds):
            let attempts = retries[ObjectIdentifier(kind)]?.delays[sessionID]?.attempts ?? 0
            retries[ObjectIdentifier(kind), default: Retries()].delays[sessionID] =
                (attempts, environment.now().addingTimeInterval(seconds))
        }
        let hold = running?.hold
        running = nil
        environment.released(kind, sessionID, hold)
        environment.changed()
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
