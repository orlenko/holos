import Foundation
import HolosCore

/// Where a job stands against the others (docs/meeting-design.md §4.17, "Work the user asked for goes before automatic
/// work"; §5.11, "Catching up in the app"): lower goes first.
public enum BackgroundJobPriority: Int, Comparable, Sendable {
    /// Asked for from a meeting's menu (Make Final Transcript Now).
    case askedFor
    /// Brings a saved meeting in step with what the app shows of it (the echo analysis of a call that misses it).
    case catchUp
    /// Made after a meeting without being asked for (a final transcript queued automatically).
    case automatic

    public static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }
}

/// The `voiceislocal` command a job runs, and its output files (`CommandRunner.start`).
public struct BackgroundJobCommand: Sendable, Equatable {
    public var arguments: [String]
    public var output: String
    public var errors: String?
    public var maxOutputBytes: Int

    public init(arguments: [String], output: String, errors: String?, maxOutputBytes: Int) {
        self.arguments = arguments; self.output = output; self.errors = errors; self.maxOutputBytes = maxOutputBytes
    }
}

/// The job a kind would start next, were nothing else going on.
public struct BackgroundJobPick: Sendable, Equatable {
    public var sessionID: String
    /// The session folder's path when it was queued.
    public var path: String
    public var priority: BackgroundJobPriority
    public var command: BackgroundJobCommand

    public init(sessionID: String, path: String, priority: BackgroundJobPriority, command: BackgroundJobCommand) {
        self.sessionID = sessionID; self.path = path; self.priority = priority; self.command = command
    }
}

/// What holds a kind's meetings back now, as `BackgroundJobCoordinator` gives it to the kind.
public struct BackgroundJobHolds: Sendable, Equatable {
    /// A meeting is starting, recording, or saving.
    public var meetingBusy: Bool
    /// Meetings another command of the app works on (`MeetingController.sessionsInUse`), and meetings open, opening
    /// or still saving in Review (`sessionsUnderReview`), which owns their transcript and labels until it closes.
    public var inUse: Set<String>
    /// The kind's meetings turned down for now (another process held them), and until when.
    public var delayedUntil: [String: Date]
    /// No job of the kind starts before this (a start that failed, or the lock refused a run).
    public var retryAfter: Date?
    /// The meeting the kind's job runs on now, if any.
    public var running: String?
    public var now: Date

    public init(meetingBusy: Bool = false, inUse: Set<String> = [], delayedUntil: [String: Date] = [:],
                retryAfter: Date? = nil, running: String? = nil, now: Date) {
        self.meetingBusy = meetingBusy; self.inUse = inUse; self.delayedUntil = delayedUntil
        self.retryAfter = retryAfter; self.running = running; self.now = now
    }

    /// The kind's jobs may start now (`retryAfter` is over).
    public var retryOver: Bool { retryAfter.map { $0 <= now } ?? true }

    /// Whether `sessionID`'s delay is over (or it has none).
    public func delayOver(_ sessionID: String) -> Bool { delayedUntil[sessionID].map { $0 <= now } ?? true }
}

/// What becomes of a job's meeting when its run ended (or did not start).
public enum BackgroundJobEnd: Sendable, Equatable {
    /// Off the kind's queue (done, failed, partial, refused, cancelled): its turned-down count is forgotten.
    case finished
    /// Stays queued as it was: stopped for a meeting, or not started.
    case stopped
    /// Turned down for this meeting (another process held it): it waits the kind's `retryDelay(attempts:)` for that
    /// many refusals in a row; the kind's other meetings go on.
    case retryMeeting
    /// Turned down for every meeting of the kind (another process held the background job lock): the kind waits
    /// `BackgroundJobCoordinator.retryDelay`.
    case retryAll
}

/// A kind of background job on meetings that `BackgroundJobCoordinator` runs: it keeps its own queue and says which
/// meeting is next, the command, and what an exit comes to. The coordinator owns everything else: the lock probe, the
/// holds, preemption, retries and the order between kinds.
@MainActor public protocol BackgroundJobKind: AnyObject {
    /// What the command prints with `--json`.
    associatedtype Outcome: Decodable & Sendable

    /// How logs name a job of this kind ("Deep transcription").
    var name: String { get }
    /// What the Meetings list shows while the job runs (`MeetingController.beginUsing`).
    var runningText: String { get }
    /// The queue is still being found (a scan goes on): automatic work waits for it as for a ready catch-up job.
    var finding: Bool { get }
    /// Called before every look, whatever comes of it, with the kind's meeting running now.
    func willLook(running: String?)
    /// The job this kind starts next were nothing else going on (`holds` applied), or nil. It may tidy the queue on
    /// the way (a meeting whose folder is gone).
    func next(_ holds: BackgroundJobHolds) -> BackgroundJobPick?
    /// Work of this kind the user asked for is waiting, whether or not it can start yet: catch-up work waits for it.
    func askedForWaiting(_ holds: BackgroundJobHolds) -> Bool
    /// A check run off the main actor once the meeting is taken and before the command starts (false: nothing to
    /// do); nil when the command starts at once.
    func preparation(for pick: BackgroundJobPick) -> (@Sendable () -> Bool)?
    /// The check found nothing to do.
    func nothingToDo(_ sessionID: String) -> BackgroundJobEnd
    /// The command exited; `preempted`: the coordinator signalled it because a meeting started.
    func ended(_ sessionID: String, result: CommandResult<Outcome>, preempted: Bool) -> BackgroundJobEnd
    /// How long a meeting turned down `attempts` times in a row waits.
    func retryDelay(attempts: Int) -> TimeInterval
    /// After an end was applied, the meeting let go of and the next jobs looked for: what the end shows the user.
    func settled(_ sessionID: String)
}

extension BackgroundJobKind {
    public var finding: Bool { false }
    public func willLook(running: String?) {}
    public func askedForWaiting(_ holds: BackgroundJobHolds) -> Bool { false }
    public func preparation(for pick: BackgroundJobPick) -> (@Sendable () -> Bool)? { nil }
    public func nothingToDo(_ sessionID: String) -> BackgroundJobEnd { .finished }
    public func settled(_ sessionID: String) {}
}

/// Which job goes next among the ones the kinds would start (docs/meeting-design.md §4.17, §5.11). Pure.
public enum BackgroundJobOrder {
    public struct Situation: Sendable, Equatable {
        /// A meeting is starting, recording, or saving; or another background job runs (a summary of this app, or any
        /// process holding `DeepTranscriptionLock`): nothing starts.
        public var blocked: Bool
        /// Work the user asked for is waiting, ready or not (a Make Final Transcript Now whose languages are being
        /// read): catch-up work waits for it.
        public var askedForWaiting: Bool
        /// The summary scan going on may start a Summarize Again: catch-up and automatic work wait for its end.
        public var summaryRequestScan: Bool
        /// A catch-up queue is not known yet (its scan goes on): automatic work waits for it.
        public var catchUpPending: Bool

        public init(blocked: Bool = false, askedForWaiting: Bool = false, summaryRequestScan: Bool = false,
                    catchUpPending: Bool = false) {
            self.blocked = blocked; self.askedForWaiting = askedForWaiting
            self.summaryRequestScan = summaryRequestScan; self.catchUpPending = catchUpPending
        }
    }

    /// The index of the job that starts now among `priorities` (one per job a kind would start), or nil when none
    /// does: none while `blocked`; else the first of the highest priority, unless it waits. Asked-for work never
    /// waits; catch-up work waits for asked-for work and a summary scan that may start a Summarize Again; automatic
    /// work waits for that scan and for a catch-up queue not known yet. A ready catch-up job goes before automatic
    /// work, so automatic work also waits while one waits.
    public static func next(_ priorities: [BackgroundJobPriority], _ situation: Situation) -> Int? {
        guard !situation.blocked,
              let first = priorities.indices.min(by: { priorities[$0] < priorities[$1] }) else { return nil }
        switch priorities[first] {
        case .askedFor:
            return first
        case .catchUp:
            return situation.askedForWaiting || situation.summaryRequestScan ? nil : first
        case .automatic:
            return situation.summaryRequestScan || situation.catchUpPending ? nil : first
        }
    }
}

/// Starts a job's command (`CommandRunner`, or a fake in tests).
@MainActor public protocol BackgroundJobRunner {
    /// Starts `command` and returns its handle; `completion` gets its result on the main actor once it exits. Throws
    /// when it cannot start.
    func startJob<Outcome: Decodable & Sendable>(
        _ command: BackgroundJobCommand, as type: Outcome.Type,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws -> any BackgroundJobHandle
}

/// A running job's command, to stop it (`CommandHandle`).
public protocol BackgroundJobHandle: AnyObject {
    /// Sends the command SIGTERM; whether a signal was sent now (false once it has been reaped).
    @discardableResult func terminate() -> Bool
}

extension CommandHandle: BackgroundJobHandle {}

extension CommandRunner: BackgroundJobRunner {
    public func startJob<Outcome: Decodable & Sendable>(
        _ command: BackgroundJobCommand, as type: Outcome.Type,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws -> any BackgroundJobHandle {
        try start(command.arguments, output: command.output, errors: command.errors,
                  maxOutputBytes: command.maxOutputBytes, as: type, completion: completion)
    }
}
