import Foundation
import HolosCore
import HolosStorage
import os

/// The echo catch-up as a `BackgroundJobKind` (docs/meeting-design.md §5.11, "Catching up in the app"): calls that miss
/// their echo analysis, as the app's scan finds them (`EchoCatchUpSchedule.scan`), get `voiceislocal session
/// echo-analyze`, newest first. Catch-up work: after asked-for work, before automatic final transcripts and summaries.
/// Nothing is saved: a run a quit cut short leaves the analysis missing, so the next launch's scan finds it again.
///
/// Invariants:
/// 1. A meeting whose run ended in this launch (done, failed or partial) is not run again before the next launch
///    (`failed`), even when a scan finds it again.
/// 2. Until the first scan of the launch ends, and while a scan goes on, `finding` is true: automatic work waits.
@MainActor public final class EchoCatchUpJobs: BackgroundJobKind {
    public typealias Outcome = SessionEchoAnalyzeCommand.Outcome

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    public let name = "Echo analysis"
    public var runningText: String { EchoCatchUpSchedule.runningText }
    /// A review that opens while a run goes on is read-only, and rereads the meeting when it ends, so its labels and
    /// playback follow the new mask.
    public var reviewHold: ReviewMaintenance.Command? { .echoAnalysis }

    /// The meetings found needing the analysis, newest first; each leaves it when its run ends.
    public var queue: [EchoCatchUpSchedule.Candidate] = []
    /// A scan of the sessions folder goes on.
    public var scanning = false
    /// The first scan of this launch ended (invariant 2).
    public var scanned = false
    /// A scan was asked for while one ran: it runs again once that one ends.
    public var scanAgain = false
    /// How the runs that did not finish in this launch ended (failed: not tried again until the next launch; partial:
    /// the analysis was saved, something after it was not), for the Meetings list.
    public private(set) var problems: [String: EchoCatchUpSchedule.RunEnd] = [:]
    /// Meetings whose run ended in this launch, however it ended (invariant 1).
    public private(set) var ended: Set<String> = []

    private let needsAnalysis: @Sendable (URL) -> Bool

    /// `needsAnalysis` is read again off the main actor just before a run starts: a relabel, Recover or a run in
    /// Terminal may have made the analysis since the scan.
    public init(needsAnalysis: @escaping @Sendable (URL) -> Bool = {
        EchoCatchUpSchedule.needsAnalysis(session: $0, profiles: SpeakerProfileStore())
    }) {
        self.needsAnalysis = needsAnalysis
    }

    /// Meetings not tried again before the next launch: every run that ended in this launch.
    public var failed: Set<String> {
        ended.union(problems.compactMap { id, end in
            switch end {
            case .failed, .partial: return id
            default: return nil
            }
        })
    }

    public var finding: Bool { scanning || !scanned }

    /// The first ready meeting of the queue: not running, not in use or under review, not ended in this launch, and
    /// not turned down for now.
    public func next(_ holds: BackgroundJobHolds) -> BackgroundJobPick? {
        let situation = EchoCatchUpSchedule.Situation(running: holds.running, inUse: holds.inUse, failed: failed,
                                                      delayedUntil: holds.delayedUntil, now: holds.now)
        guard let first = EchoCatchUpSchedule.ready(queue, situation).first else { return nil }
        return BackgroundJobPick(
            sessionID: first.sessionID, path: first.path, priority: .catchUp,
            command: BackgroundJobCommand(arguments: ["session", "echo-analyze", first.path, "--json"], output: "echo",
                                          errors: "echo-err", maxOutputBytes: 1 << 20))
    }

    public func preparation(for pick: BackgroundJobPick) -> (@Sendable () -> Bool)? {
        let needsAnalysis = needsAnalysis
        let session = URL(fileURLWithPath: pick.path)
        return { needsAnalysis(session) }
    }

    /// Made since the scan, or deleted: off the queue; a result from earlier in this launch (a partial run) stays in
    /// the list.
    public func nothingToDo(_ sessionID: String) -> BackgroundJobEnd {
        runEnded(sessionID, .done, keepsProblem: true)
    }

    public func ended(_ sessionID: String, result: CommandResult<SessionEchoAnalyzeCommand.Outcome>,
                      preempted: Bool) -> BackgroundJobEnd {
        runEnded(sessionID, EchoCatchUpSchedule.runEnded(code: result.code, preempted: preempted,
                                                         summary: result.outcome?.summary, errors: result.errors))
    }

    /// Another process held the meeting or the background job lock (or it records again): longer each time in a row.
    public func retryDelay(attempts: Int) -> TimeInterval { EchoCatchUpSchedule.retryDelay(attempts: attempts) }

    private func runEnded(_ sessionID: String, _ end: EchoCatchUpSchedule.RunEnd,
                          keepsProblem: Bool = false) -> BackgroundJobEnd {
        switch end {
        case .retryLater:
            return .retryMeeting
        case .stopped:
            return .stopped
        case .done, .failed, .partial:
            queue.removeAll { $0.sessionID == sessionID }
            ended.insert(sessionID)
            // Failed: the list says why. Partial: the list says what was not brought in step.
            if !keepsProblem { problems[sessionID] = end == .done ? nil : end }
            if case .failed = end {
                Self.log.error("Echo analysis of \(sessionID, privacy: .public) failed; tried again at the next launch")
            }
            return .finished
        }
    }
}
