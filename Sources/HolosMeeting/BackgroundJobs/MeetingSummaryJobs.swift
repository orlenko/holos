import Foundation
import HolosCore
import HolosStorage
import os

/// Meeting titles and summaries as a `BackgroundJobKind` (docs/meeting/titles-summaries.md §4.17): `voiceislocal session
/// summarize`, one meeting at a time, as `MeetingSummarySchedule` picks it from a scan of the sessions folder. A
/// Summarize Again is asked-for work; the others are automatic, after final transcripts and echo analyses that are
/// ready at the same look. Its candidates come from a scan made off the main actor: a full look starts one when none
/// goes on (`lookForWork`), and the look made when it ends picks from it.
///
/// Invariants:
/// 1. Every change to `requests` is saved (`save`), so a Summarize Again that had to wait runs after a quit; a request
///    goes only when its run ends for good, when Cancel drops it, when its meeting is gone, or when a summary answers
///    it.
/// 2. No scan starts, and no summary is picked, before the launch is ready (`launchReady`) or while a final-transcript
///    reconciliation runs (`reconciling`); none starts while a summary runs or a meeting is busy.
/// 3. A scan's result is offered only to the look made when it ends (`onScanned`), and to the looks made during it (a
///    job that could not start looks again), and then dropped. No scan starts during those looks, even when the scan
///    found nothing to offer (a people store it could not read): the next one waits for a later look.
/// 4. A run that failed for good is not tried again for the same key (transcript and speakers' names) until the key
///    changes, the setting is turned on again, or the app starts again (`attempted`).
@MainActor public final class MeetingSummaryJobs: BackgroundJobKind {
    public typealias Outcome = SessionSummarizeCommand.Outcome

    /// What a pick depends on besides the scan.
    public struct Conditions: Sendable, Equatable {
        /// Settings › Meetings › "Title and summarize meetings with Apple Intelligence".
        public var enabled: Bool
        public var modelAvailable: Bool
        public var onBattery: Bool
        /// Meetings a final transcript is queued for, pending, or being decided about: summarized after it.
        public var finalTranscriptQueued: Set<String>

        public init(enabled: Bool, modelAvailable: Bool, onBattery: Bool, finalTranscriptQueued: Set<String> = []) {
            self.enabled = enabled; self.modelAvailable = modelAvailable; self.onBattery = onBattery
            self.finalTranscriptQueued = finalTranscriptQueued
        }
    }

    /// A scan's result: the meetings and the requested ones no folder holds, or a people store it could not read (with
    /// the reason when that is for good).
    public enum Scan: Sendable {
        case scanned([MeetingSummarySchedule.Candidate], gone: Set<String>)
        case unreadable(String?)
    }

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")
    /// What the Meetings list shows while a summary is made (`MeetingController.beginUsing`).
    public static let runningText = "Writing summary…"

    public let name = "Summary"
    public var runningText: String { Self.runningText }

    /// Summarize Again, newest last (invariant 1). Each has a random ID, which its run writes into summary.json.
    public var requests: [MeetingSummarySchedule.Request] {
        didSet { save(requests) }
    }
    /// The key each meeting was last tried with when no summary came of it (invariant 4).
    public var attempted: [String: String] = [:]
    /// The people store could not be used for good (a newer build wrote it): no summary starts until it changes.
    public private(set) var peopleStoreProblem: String?
    /// The launch's final-transcript reconciliation has queued the meetings saved while the app was closed (invariant
    /// 2).
    public var launchReady = false
    /// Final-transcript reconciliations running (invariant 2).
    public private(set) var reconciling = 0
    public private(set) var scanning = false
    /// Called when a scan ended: the coordinator looks (invariant 3).
    public var onScanned: @MainActor () -> Void = {}
    /// Called when `peopleStoreProblem` changed.
    public var onProblemChanged: @MainActor () -> Void = {}
    /// Called, before the meeting is let go of, with why a Summarize Again made no summary.
    public var onRequestFailed: @MainActor (_ sessionID: String, _ message: String) -> Void = { _, _ in }

    /// The sessions folder scanned; no scan starts without it.
    public var root: URL?
    /// What a pick depends on besides the scan, read at each pick.
    public var conditions: @MainActor () -> Conditions = {
        Conditions(enabled: false, modelAvailable: false, onBattery: false)
    }
    private let save: @MainActor ([MeetingSummarySchedule.Request]) -> Void
    private let scanner: @Sendable (_ root: URL, _ requested: [String]) -> Scan
    /// The result of the scan that just ended, during the look it makes (invariant 3).
    private var found: (candidates: [MeetingSummarySchedule.Candidate], gone: Set<String>)?
    /// The look a scan's end makes is going on (invariant 3).
    private var scanEnding = false
    /// The key of each meeting picked, for a failure.
    private var keys: [String: String] = [:]

    public init(requests: [MeetingSummarySchedule.Request],
                save: @escaping @MainActor ([MeetingSummarySchedule.Request]) -> Void,
                scanner: @escaping @Sendable (_ root: URL, _ requested: [String]) -> Scan = MeetingSummaryJobs.scan) {
        self.requests = requests
        self.save = save
        self.scanner = scanner
    }

    /// The meetings asked for, oldest first.
    public var requested: [String] { requests.map(\.sessionID) }

    public func removeRequest(_ sessionID: String) {
        requests.removeAll { $0.sessionID == sessionID }
    }

    /// A final-transcript reconciliation started or ended (invariant 2).
    public func reconcileStarted() { reconciling += 1 }

    public func reconcileEnded() {
        reconciling = max(0, reconciling - 1)
        launchReady = true
    }

    /// A Summarize Again may be found by the scan going on: catch-up and automatic work wait for its end.
    public var askedForFinding: Bool { scanning && !requests.isEmpty }

    /// Starts a scan when none goes on and a summary could follow (invariant 2).
    public func lookForWork(_ holds: BackgroundJobHolds) {
        guard let root, !scanning, !scanEnding, found == nil, holds.running == nil, launchReady, reconciling == 0,
              !holds.meetingBusy else { return }
        scanning = true
        let requested = requested
        let scanner = scanner
        Task { [weak self] in
            let scan = await Task.detached { scanner(root, requested) }.value
            self?.scanEnded(scan)
        }
    }

    private func scanEnded(_ scan: Scan) {
        scanning = false
        switch scan {
        case .unreadable(let problem):
            // Transient (nil): looked at again at the next scan. For good: said once.
            if let problem, problem != peopleStoreProblem {
                peopleStoreProblem = problem
                onProblemChanged()
            }
        case .scanned(let candidates, let gone):
            if peopleStoreProblem != nil {
                peopleStoreProblem = nil
                onProblemChanged()
            }
            if launchReady, reconciling == 0 {
                // A request for a meeting that is gone is dropped, and so is one a summary made since already answers
                // (a command that finished while the app was closed).
                let satisfied = MeetingSummarySchedule.satisfied(requests, by: candidates)
                requests.removeAll { gone.contains($0.sessionID) || satisfied.contains($0.sessionID) }
            }
            found = (candidates, gone)
        }
        scanEnding = true
        onScanned()
        scanEnding = false
        found = nil
    }

    /// The meeting `MeetingSummarySchedule.next` picks from the scan that just ended; a request goes first and is
    /// asked-for work. An automatic summary waits while a Make Final Transcript Now waits.
    public func next(_ holds: BackgroundJobHolds) -> BackgroundJobPick? {
        guard let found, launchReady, reconciling == 0 else { return nil }
        let conditions = conditions()
        let situation = MeetingSummarySchedule.Situation(
            enabled: conditions.enabled, modelAvailable: conditions.modelAvailable, meetingBusy: holds.meetingBusy,
            deepPassRunning: false, running: nil, inUse: holds.inUse, attempted: attempted,
            delayedUntil: holds.delayedUntil.filter { !holds.delayOver($0.key) }, requested: requested,
            onBattery: conditions.onBattery, finalTranscriptQueued: conditions.finalTranscriptQueued,
            askedForPassWaiting: holds.askedForWaiting, now: holds.now)
        guard case .run(let sessionID, let path, let force) = MeetingSummarySchedule.next(found.candidates, situation)
        else { return nil }
        keys[sessionID] = found.candidates.first { $0.sessionID == sessionID }?.key
        // Run for a Summarize Again: its ID goes into summary.json, so the request is known answered.
        let answers = requests.last { $0.sessionID == sessionID }.map { ["--answers-request", $0.id] } ?? []
        let arguments = ["session", "summarize", path, "--json"] + (force ? ["--force"] : []) + answers
        return BackgroundJobPick(sessionID: sessionID, path: path,
                                 priority: requested.contains(sessionID) ? .askedFor : .automatic,
                                 command: BackgroundJobCommand(arguments: arguments, output: "summary",
                                                               errors: "summary-err", maxOutputBytes: 4 << 20))
    }

    /// A result the command reports decides: a summary it saved counts even when a meeting started at the very end.
    /// Without one, a run stopped for a meeting is tried again. Tried again in a minute (a request stays): stopped,
    /// held by another command or job, or the transcript changed. Done for good otherwise: written (its files
    /// rewritten later, without the model, when they were not), up to date, failed, or unavailable.
    public func ended(_ sessionID: String, result: CommandResult<SessionSummarizeCommand.Outcome>,
                      preempted: Bool) -> BackgroundJobEnd {
        let code = result.code
        let status = result.outcome?.status
        Self.log.notice("Summary of \(sessionID, privacy: .public): \(status?.rawValue ?? "no result", privacy: .public)")
        if status.map(\.retriesLater) ?? preempted { return .retryMeeting }
        let requested = requested.contains(sessionID)
        removeRequest(sessionID)
        var end = BackgroundJobEnd.finished
        if status == .written { attempted[sessionID] = nil }
        if status == .written, code != 0 {
            end = .wait(300)
        } else if code != 0, let key = keys[sessionID] {
            attempted[sessionID] = key
        }
        if requested, code != 0, status != .written {
            onRequestFailed(sessionID, result.outcome?.message ?? "The summary command stopped (code \(code)).")
        }
        return end
    }

    /// One that cannot start waits a minute; the other meetings go on.
    public func startFailed(_ sessionID: String) -> BackgroundJobEnd { .retryMeeting }

    /// A meeting turned down (another process held it, or the app used it) waits a minute each time.
    public func retryDelay(attempts: Int) -> TimeInterval { 60 }
}

extension MeetingSummaryJobs {
    /// The scan the app makes: people's names and Remember voices once (a people store that cannot be read stops the
    /// scan; one a newer build wrote stops summaries until it changes), the meetings under `root`, and the requested
    /// meetings no folder holds, whatever the folder's name (one whose manifest cannot be read now keeps its request).
    public nonisolated static func scan(root: URL, requested: [String]) -> Scan {
        let voice: SessionSummarizeCommand.VoiceInputs
        do {
            voice = try SessionSummarizeCommand.VoiceInputs.read()
        } catch {
            let terminal = SessionSummarizeCommand.peopleStoreStatus(error) == .failed
            return .unreadable(terminal ? "the people store: \(error.localizedDescription)" : nil)
        }
        let candidates = MeetingSummarySchedule.scan(root: root, profileNames: voice.names,
                                                     recognition: voice.recognition, selfName: voice.selfName)
        let listed = Set(candidates.map(\.sessionID))
        let gone = Set(requested.filter { !listed.contains($0) && SessionCatalog.hasSession($0, in: root) == false })
        return .scanned(candidates, gone: gone)
    }
}
