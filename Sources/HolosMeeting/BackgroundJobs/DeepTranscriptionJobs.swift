import Foundation
import HolosCore

/// Final transcripts after meetings as a `BackgroundJobKind` (docs/meeting-design.md §4.16, "App"): the app's saved
/// queue of `voiceislocal session deep-transcribe` passes, what runs next (`DeepTranscriptionSchedule`), and what a
/// pass's exit comes to (`DeepTranscriptionSchedule.passEnded`). Make Final Transcript Now passes are asked-for work;
/// the others are automatic.
///
/// Invariants:
/// 1. Every change to `queue` is saved (`save`), so a pass cut short by a quit or crash runs again at the next launch.
/// 2. With the setting off, every look drops the automatic items except the one running (`willLook`).
/// 3. A pass that ran is reported once (`onEnded`), after the coordinator let its meeting go and looked for the next
///    jobs; one that never started is not.
@MainActor public final class DeepTranscriptionJobs: BackgroundJobKind {
    public typealias Outcome = PostProcessingRecord

    /// What a look depends on besides the queue.
    public struct Conditions: Sendable, Equatable {
        /// Settings › Meetings › "Deep transcription after meetings".
        public var enabled: Bool
        public var modelInstalled: Bool
        public var power: DeepTranscriptionSchedule.Power

        public init(enabled: Bool, modelInstalled: Bool, power: DeepTranscriptionSchedule.Power) {
            self.enabled = enabled; self.modelInstalled = modelInstalled; self.power = power
        }
    }

    /// How the app's pass on a meeting ended, for the app's alerts.
    public struct PassReport: Sendable {
        public var sessionID: String
        /// The queue item it ran; nil when the user cancelled it meanwhile (Cancel takes it off the queue first).
        public var item: DeepTranscriptionQueue.Item?
        public var end: DeepTranscriptionSchedule.PassEnd
        public var result: CommandResult<PostProcessingRecord>
    }

    /// What the Meetings list shows while the pass runs (`MeetingController.beginUsing`).
    public static let runningText = "Final transcript in progress…"

    public let name = "Deep transcription"
    public var runningText: String { Self.runningText }

    /// Saved on every change (invariant 1).
    public var queue: DeepTranscriptionQueue {
        didSet { save(queue) }
    }
    /// Gets each pass that ran (invariant 3).
    public var onEnded: @MainActor (PassReport) -> Void = { _ in }

    private let conditions: @MainActor () -> Conditions
    private let save: @MainActor (DeepTranscriptionQueue) -> Void
    private let exists: @MainActor (String) -> Bool
    private var reports: [String: PassReport] = [:]

    /// `exists` says whether a queued meeting's folder is still there (deleted from Meetings while queued).
    public init(queue: DeepTranscriptionQueue, save: @escaping @MainActor (DeepTranscriptionQueue) -> Void,
                conditions: @escaping @MainActor () -> Conditions,
                exists: @escaping @MainActor (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.queue = queue
        self.save = save
        self.conditions = conditions
        self.exists = exists
    }

    public func willLook(running: String?) {
        queue.dropAutomatic(enabled: conditions().enabled, running: running)  // Invariant 2.
    }

    /// The next pass (`DeepTranscriptionSchedule.nextPresent`): a Make Final Transcript Now first, whatever the power
    /// source; else the oldest queued meeting when the setting is on and the Mac is on AC power. A meeting picked whose
    /// folder is gone is taken off the queue and the next one picked.
    public func next(_ holds: BackgroundJobHolds) -> BackgroundJobPick? {
        let conditions = conditions()
        let situation = DeepTranscriptionSchedule.Situation(
            enabled: conditions.enabled, modelInstalled: conditions.modelInstalled, power: conditions.power,
            meetingBusy: holds.meetingBusy, running: holds.running, inUse: holds.inUse,
            delayed: Set(holds.delayedUntil.keys.filter { !holds.delayOver($0) }))
        var picked = queue
        let decision = DeepTranscriptionSchedule.nextPresent(&picked, situation, exists: exists)
        if picked != queue { queue = picked }
        guard case .run(let sessionID) = decision,
              let item = queue.items.first(where: { $0.sessionID == sessionID }) else { return nil }
        // Asked for from the meeting's menu: made again even when made before, and over edited labels.
        let arguments = ["session", "deep-transcribe", item.path, "--json"]
            + (DeepTranscriptionSchedule.forces(item) ? ["--force"] : [])
        return BackgroundJobPick(sessionID: sessionID, path: item.path, priority: item.runNow ? .askedFor : .automatic,
                                 command: BackgroundJobCommand(arguments: arguments, output: "deep", errors: "deep-err",
                                                               maxOutputBytes: 16 << 20))
    }

    /// A Make Final Transcript Now pass is queued (or its languages are being read) and could start but for the other
    /// jobs: the model is installed, no failed start holds the kind back, and its meeting is not in use or delayed.
    /// The setting and the power source do not hold it back.
    public func askedForWaiting(_ holds: BackgroundJobHolds) -> Bool {
        guard conditions().modelInstalled, holds.retryOver else { return false }
        // One whose languages are still being read (`pending`) is about to join the queue.
        if queue.pending.contains(where: \.runNow) { return true }
        return queue.items.contains { item in
            item.runNow && !holds.inUse.contains(item.sessionID) && holds.delayOver(item.sessionID)
        }
    }

    /// Stopped for a meeting: stays queued and runs again from the start. Another command held the meeting: only it
    /// waits. Another pass held the lock: every pass waits. Otherwise (done, refused, partial, failed, cancelled) off
    /// the queue; only a pass the app did not see end (a quit, a crash) stays queued.
    public func ended(_ sessionID: String, result: CommandResult<PostProcessingRecord>,
                      preempted: Bool) -> BackgroundJobEnd {
        let item = queue.items.first { $0.sessionID == sessionID }
        let end = DeepTranscriptionSchedule.passEnded(code: result.code, preempted: preempted, errors: result.errors)
        reports[sessionID] = PassReport(sessionID: sessionID, item: item, end: end, result: result)
        switch end {
        case .keepPreempted:
            return .stopped
        case .retryLater(let global):
            return global ? .retryAll : .retryMeeting
        case .done:
            queue.remove(sessionID)
            return .finished
        }
    }

    /// A meeting turned down because another command held it waits a minute each time.
    public func retryDelay(attempts: Int) -> TimeInterval { 60 }

    public func settled(_ sessionID: String) {
        guard let report = reports.removeValue(forKey: sessionID) else { return }
        onEnded(report)
    }
}
