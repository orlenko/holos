import Foundation

/// What a review window of a meeting does while a maintenance command works on that meeting
/// (docs/meeting/review-window.md §5.10, "Reviews and maintenance"). One rule for every command:
///
/// - A meeting with a review open or still opening is in use: the automatic relabel leaves it alone
///   (`sessionsInUse`), as it does a meeting a Meetings command runs for.
/// - When a command starts, a review still opening is waited for first. Delete Meeting then closes the review (its
///   changes saved) before the meeting moves; a review that finishes opening while the deletion runs is closed
///   before it is shown. Every other command that changes what the review reads (Recover, Label Speakers, Delete
///   Audio, the automatic relabel, the app's echo catch-up) makes the review read-only with a banner: its queued changes are saved and the
///   transcript files written before the command starts, playback stops, and the audio composition is dropped.
///   `ReviewSession.pause` and the window do this; a review that finishes opening while the command runs opens
///   read-only.
/// - When the command ends, however it ends, the review rereads the transcript, the speaker labels, and the people,
///   rebuilds playback from the manifest as it now is (or turns it off when the audio is gone), and is editable
///   again (`ReviewSession.resume`).
/// - Clean Up removes only `derived/` speaker-labelling renders, which the review never reads: it does not affect it.
public enum ReviewMaintenance {
    public enum Command: Sendable, Equatable, CaseIterable {
        case recover, labelSpeakers, deleteAudio, deleteMeeting, automaticRelabel, cleanUp
        /// The app's catch-up run of `voiceislocal session echo-analyze` (§5.11): it starts only on a meeting no review
        /// holds, so it affects a review opened while it runs.
        case echoAnalysis
    }

    public enum Response: Sendable, Equatable {
        /// The review goes on as before.
        case unaffected
        /// Read-only with `banner` until the command ends, then reread from disk.
        case readOnly(banner: String)
        /// Closed (its changes saved) before the command starts.
        case close
    }

    /// One run of a maintenance command holding a review read-only (`ReviewSession.pause` and `resume`). Every run
    /// gets its own, even of the same command: a command started while the previous one's `resume` still rereads
    /// the meeting keeps the review read-only until it ends.
    public struct Hold: Hashable, Sendable {
        public let command: Command
        private let id = UUID()

        public init(_ command: Command) {
            self.command = command
        }
    }

    public static func response(to command: Command) -> Response {
        switch command {
        case .deleteMeeting: .close
        case .cleanUp: .unaffected
        case .recover: .readOnly(banner: "Voice is Local is recovering this meeting.")
        case .labelSpeakers, .automaticRelabel: .readOnly(banner: "Voice is Local is labelling this meeting's speakers.")
        case .deleteAudio: .readOnly(banner: "Voice is Local is deleting this meeting's audio.")
        case .echoAnalysis: .readOnly(banner: "Voice is Local is removing the call's echo from this meeting.")
        }
    }

    /// Meetings the automatic relabel leaves alone: those a command runs for, and those with a review open, opening,
    /// or still saving after it closed.
    public static func sessionsInUse(commands: some Sequence<String>, reviews: some Sequence<String>) -> Set<String> {
        Set(commands).union(reviews)
    }
}

/// Voice sample syncs a review could not finish (docs/meeting/review-window.md §5.10, "Voice learning off the edit queue"):
/// one failed while its window was closing (nobody saw it), or the app quit before it ran. The meeting's next review
/// says so in its footer and runs it again. Kept in UserDefaults like `PendingExports`: session IDs, the IDs of the
/// people whose voices were asked for with the store's forget epoch then (so a forget since still wins), and why it
/// failed. No voice data.
public struct PendingVoiceSamples {
    public static let key = "meeting.voiceSamplesPending"

    public struct Entry: Codable, Sendable, Equatable {
        /// Profile ID → the store's `forgetEpoch` when the voice was asked for. Empty: only bringing this meeting's
        /// samples in step with its labels was owed.
        public var enroll: [String: Int]
        /// Why it failed; nil when it was stopped (the app quit).
        public var problem: String?

        public init(enroll: [String: Int], problem: String?) {
            self.enroll = enroll; self.problem = problem
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var entries: [String: Entry] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    public func entry(_ sessionID: String) -> Entry? { entries[sessionID] }

    public func mark(_ sessionID: String, _ entry: Entry) {
        var all = entries
        guard all[sessionID] != entry else { return }
        all[sessionID] = entry
        store(all)
    }

    public func clear(_ sessionID: String) {
        var all = entries
        guard all.removeValue(forKey: sessionID) != nil else { return }
        store(all)
    }

    private func store(_ all: [String: Entry]) {
        guard !all.isEmpty, let data = try? JSONEncoder().encode(all) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}

/// Meetings whose transcript files (`exports/`) are older than their saved speaker labels because rewriting them
/// failed when a review window closed (docs/meeting/review-window.md §5.10). Kept in UserDefaults, which a full disk does not
/// stop, so Meetings can say so and the meeting's next review rewrites them. Holds session IDs only.
public struct PendingExports {
    public static let key = "meeting.exportsPending"
    private let defaults: UserDefaults
    private let key = PendingExports.key

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var sessionIDs: Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }

    public func contains(_ sessionID: String) -> Bool { sessionIDs.contains(sessionID) }

    /// How many times each meeting was marked, so a check that began before a newer mark does not clear it.
    static let generationsKey = "meeting.exportsPendingGeneration"

    private var generations: [String: Int] {
        (defaults.dictionary(forKey: Self.generationsKey) as? [String: Int]) ?? [:]
    }

    /// The meeting's mark count now: it only grows (0 if never marked).
    public func generation(_ sessionID: String) -> Int { generations[sessionID] ?? 0 }

    public func mark(_ sessionID: String) {
        var counts = generations
        counts[sessionID, default: 0] += 1
        defaults.set(counts, forKey: Self.generationsKey)
        var ids = sessionIDs
        guard ids.insert(sessionID).inserted else { return }
        defaults.set(ids.sorted(), forKey: key)
    }

    /// Removes the mark; its count stays, so a later mark gets a higher one than any read before.
    public func clear(_ sessionID: String) {
        var ids = sessionIDs
        guard ids.remove(sessionID) != nil else { return }
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(ids.sorted(), forKey: key)
        }
    }

    /// Clears the mark only when it was not set again since `generation` was read (a check that started earlier
    /// cannot clear a newer failure).
    public func clear(_ sessionID: String, ifGeneration generation: Int) {
        guard self.generation(sessionID) == generation else { return }
        clear(sessionID)
    }
}
