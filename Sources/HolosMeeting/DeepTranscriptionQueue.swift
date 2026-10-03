import Foundation
import HolosCore

/// The app's queue of deep transcription passes (docs/meeting-design.md §4.16, "App"): meetings waiting for
/// `voiceislocal session deep-transcribe`, kept across launches (UserDefaults), so a pass cut short by a quit or a
/// crash runs again (from the start) at the next launch. Pure value; the app owns it on the main actor.
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

    /// Drops every item not asked for from the menu (the setting was turned off).
    public mutating func removeAutomatic() {
        items.removeAll { !$0.runNow }
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
        /// Meetings another command of the app is working on (Label Speakers, a relabel, a delete…).
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

    /// Whether a meeting that just finished saving is queued: the setting is on, the model installed, and the meeting
    /// is in one language (several are not supported yet).
    public static func queuesAfterMeeting(enabled: Bool, modelInstalled: Bool, languages: Int) -> Bool {
        enabled && modelInstalled && languages <= 1
    }

    /// What the Meetings list's State column says of a queued or running meeting; nil for the others.
    public static func stateText(sessionID: String, queue: DeepTranscriptionQueue, running: String?,
                                 power: Power) -> String? {
        if running == sessionID { return "Final transcript in progress…" }
        guard let item = queue.items.first(where: { $0.sessionID == sessionID }) else { return nil }
        if !item.runNow, power == .battery { return "Final transcript waits for power" }
        return "Final transcript queued"
    }
}
