import Foundation
import HolosCore

/// The app's queue of deep transcription passes (docs/meeting-design.md §4.16, "App"): meetings waiting for
/// `voiceislocal session deep-transcribe`, kept across launches (UserDefaults), so a pass cut short by a quit or a
/// crash runs again (from the start, with the flags it was queued with) at the next launch. No process identity is
/// saved; keys an earlier version saved (`pid`, `pidStart`, `started`, `verifyOnly`) are ignored when it is read.
/// Pure value; the app owns it on the main actor.
public struct DeepTranscriptionQueue: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var sessionID: String
        /// The session folder's path when it was queued.
        public var path: String
        public var queuedAt: Date
        /// Asked for from the meeting's menu: runs whatever the power source, and before automatic items.
        public var runNow: Bool

        public init(sessionID: String, path: String, queuedAt: Date, runNow: Bool = false) {
            self.sessionID = sessionID; self.path = path; self.queuedAt = queuedAt; self.runNow = runNow
        }
    }

    public var schemaVersion = 1
    public private(set) var items: [Item] = []

    public init(items: [Item] = []) { self.items = items }

    /// Adds `sessionID` at the end, or (already queued) keeps its place, upgraded to `runNow` when asked.
    public mutating func enqueue(sessionID: String, path: String, at date: Date, runNow: Bool = false) {
        if let index = items.firstIndex(where: { $0.sessionID == sessionID }) {
            items[index].runNow = items[index].runNow || runNow
            items[index].path = path
            return
        }
        items.append(Item(sessionID: sessionID, path: path, queuedAt: date, runNow: runNow))
    }

    public mutating func remove(_ sessionID: String) {
        items.removeAll { $0.sessionID == sessionID }
    }

    /// Drops every item not asked for from the menu (the setting was turned off), except `keeping`: the app's pass
    /// running now, whose item stays until it ends (then it is taken off).
    public mutating func removeAutomatic(keeping: String? = nil) {
        items.removeAll { !$0.runNow && $0.sessionID != keeping }
    }

    /// The one rule for automatic items while the setting is off (`enabled` false): all of them are dropped, except
    /// the one the app's own pass is running on (`running`), which goes when it ends. Applied at launch, on every
    /// scheduler tick, and when a pass ends, so none is left behind. Run Now items stay. Returns whether any was dropped.
    @discardableResult
    public mutating func dropAutomatic(enabled: Bool, running: String?) -> Bool {
        guard !enabled else { return false }
        let before = items.count
        removeAutomatic(keeping: running)
        return items.count != before
    }

    public func contains(_ sessionID: String) -> Bool { items.contains { $0.sessionID == sessionID } }

    /// The queue as saved; one that cannot be read (damaged, or a newer schema) is empty.
    public static func decode(_ data: Data?) -> DeepTranscriptionQueue {
        guard let data, let queue = try? HolosJSON.decoder().decode(DeepTranscriptionQueue.self, from: data),
              queue.schemaVersion == 1 else { return DeepTranscriptionQueue() }
        return queue
    }

    public func encoded() -> Data? { try? HolosJSON.encoder(pretty: false).encode(self) }
}

/// When the app runs the next deep transcription pass (docs/meeting-design.md §4.16, "App"). Pure.
public enum DeepTranscriptionSchedule {
    /// Where the Mac's power comes from.
    public enum Power: Sendable, Equatable {
        case ac
        case battery
        /// No battery (a desktop) or not known: treated as AC.
        case unknown
    }

    public struct Situation: Sendable, Equatable {
        /// Settings › Meetings › "Deep transcription after meetings".
        public var enabled: Bool
        public var modelInstalled: Bool
        public var power: Power
        /// A meeting is starting, recording, or saving: its post-processing goes first.
        public var meetingBusy: Bool
        /// The pass running now, if any (one at a time).
        public var running: String?
        /// Meetings another command of the app is working on (Label Speakers, a relabel, a delete…), and meetings open
        /// (or opening, or still saving) in Review, which owns their transcript and labels until it closes.
        public var inUse: Set<String>

        public init(enabled: Bool, modelInstalled: Bool, power: Power, meetingBusy: Bool = false,
                    running: String? = nil, inUse: Set<String> = []) {
            self.enabled = enabled; self.modelInstalled = modelInstalled; self.power = power
            self.meetingBusy = meetingBusy; self.running = running; self.inUse = inUse
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Start the pass on this meeting now.
        case run(String)
        /// Automatic passes wait for the power adapter.
        case waitForPower
        /// Nothing to start now.
        case idle
    }

    /// The next pass: none while one runs, a meeting is busy, or the model is missing; a meeting asked for from its
    /// menu first, whatever the power source; else the oldest queued meeting when the setting is on and the Mac is on
    /// AC power (or has no battery), `waitForPower` on battery. Meetings in use by another command wait their turn.
    public static func next(_ queue: DeepTranscriptionQueue, _ situation: Situation) -> Decision {
        guard situation.running == nil, !situation.meetingBusy, situation.modelInstalled else { return .idle }
        let ready = queue.items.filter { !situation.inUse.contains($0.sessionID) }
        if let asked = ready.first(where: \.runNow) { return .run(asked.sessionID) }
        guard situation.enabled, let first = ready.first else { return .idle }
        return situation.power == .battery ? .waitForPower : .run(first.sessionID)
    }

    /// Whether a meeting is finished as `voiceislocal session deep-transcribe` requires it: saved, recovered, or saved
    /// as audio only; not recording, processing, interrupted (Recover first), damaged, or with its audio deleted.
    public static func isFinished(_ state: SessionState, audioDeleted: Bool) -> Bool {
        !audioDeleted && [.complete, .transcriptionIncomplete, .recovered, .audioOnly].contains(state)
    }

    /// Whether a command's error output says it could not start for another process: one holding the meeting's
    /// processing lease (another command on it), or another pass holding `DeepTranscriptionLock` (one started in
    /// Terminal a moment before). The meeting then stays queued and is tried again later.
    public static func isBusyElsewhere(_ errorOutput: String) -> Bool {
        errorOutput.contains("processing this session") || errorOutput.contains(DeepTranscriptionLock.busyMessage)
    }

    /// A meeting the app finds at launch, for `reconcile`.
    public struct Candidate: Sendable, Equatable {
        public var sessionID: String
        public var path: String
        public var createdAt: Date
        /// `isFinished`.
        public var finished: Bool
        /// The most languages named by meeting.json or the current transcript.
        public var languages: Int
        /// A deep transcription was journaled for it (`deepTranscribed`).
        public var hasDeepTranscript: Bool

        public init(sessionID: String, path: String, createdAt: Date, finished: Bool, languages: Int,
                    hasDeepTranscript: Bool) {
            self.sessionID = sessionID; self.path = path; self.createdAt = createdAt; self.finished = finished
            self.languages = languages; self.hasDeepTranscript = hasDeepTranscript
        }
    }

    /// Meetings that finished while the app was closed (the recorder saves and post-processes them on its own): the
    /// finished ones in one language, started after the setting was turned on (`enabledSince`), with no deep
    /// transcript, not considered before (`considered`: queued once already, whatever came of it) and not queued, in
    /// the order given (oldest first is the caller's).
    public static func reconcile(_ candidates: [Candidate], enabledSince: Date?, considered: Set<String>,
                                 queue: DeepTranscriptionQueue) -> [Candidate] {
        guard let enabledSince else { return [] }
        return candidates.filter { candidate in
            candidate.finished && candidate.languages <= 1 && !candidate.hasDeepTranscript
                && candidate.createdAt >= enabledSince && !considered.contains(candidate.sessionID)
                && !queue.contains(candidate.sessionID)
        }
    }

    /// Whether `item`'s command gets `--force`: a Run Now request (made again, over edited labels), also when it runs
    /// again after a pass the app did not see end. Without `--force` a run finds a transcript the model already made
    /// and keeps it; with it, a Run Now whose pass did finish before a quit is made a second time (a known cost).
    public static func forces(_ item: DeepTranscriptionQueue.Item) -> Bool {
        item.runNow
    }

    /// Whether a meeting that just finished saving is queued: the setting is on, the model installed, and the meeting
    /// is in one language (several are not supported yet), and the user did not act on it while its languages were
    /// read (`queued` now, or `considered`: asked for, maybe cancelled since).
    public static func queuesAfterMeeting(enabled: Bool, modelInstalled: Bool, languages: Int, queued: Bool = false,
                                          considered: Bool = false) -> Bool {
        enabled && modelInstalled && languages <= 1 && !queued && !considered
    }

    /// Whether a meeting's menu offers Make Final Transcript Now: not while the app's pass runs on it, nor when it is
    /// already asked for; a meeting queued automatically is upgraded by it (`enqueue` with `runNow`).
    public static func offersRunNow(sessionID: String, queue: DeepTranscriptionQueue, running: String?) -> Bool {
        running != sessionID && queue.items.first(where: { $0.sessionID == sessionID })?.runNow != true
    }

    /// Why a Make Final Transcript Now pass did not finish (exit `code`), for the app's alert: the messages of the
    /// stages its record (`--json` output) says failed, and of the deep transcription stage when it was skipped; else
    /// the command's last error line that is not progress; else how it ended.
    public static func failureText(code: Int32, record: PostProcessingRecord?, errors: String) -> String {
        let stages = (record?.stages ?? []).filter { stage in
            stage.result == .failed || (stage.result == .skipped && stage.stage == .deepTranscription)
        }.compactMap { $0.message?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !stages.isEmpty { return stages.joined(separator: "\n") }
        let lines = errors.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix("%") && !$0.hasSuffix("…") }
        if let last = lines.last {
            return last.hasPrefix("Error: ") ? String(last.dropFirst("Error: ".count)) : last
        }
        return code > 128 ? "The command stopped unexpectedly (signal \(code - 128))."
            : "The command ended with code \(code)."
    }

    /// What the Meetings list's State column says of a queued or running meeting; nil for the others. While another
    /// process's pass holds `DeepTranscriptionLock` (`otherPassRunning`), queued meetings wait for it.
    public static func stateText(sessionID: String, queue: DeepTranscriptionQueue, running: String?,
                                 power: Power, otherPassRunning: Bool = false) -> String? {
        if running == sessionID { return "Final transcript in progress…" }
        guard let item = queue.items.first(where: { $0.sessionID == sessionID }) else { return nil }
        if otherPassRunning, running == nil { return "Waiting for another final transcript to finish" }
        if !item.runNow, power == .battery { return "Final transcript waits for power" }
        return "Final transcript queued"
    }
}
