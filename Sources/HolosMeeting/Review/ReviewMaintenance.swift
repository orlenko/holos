import Foundation

/// What a review window of a meeting does while a maintenance command works on that meeting
/// (docs/meeting-design.md §5.10, "Reviews and maintenance"). One rule for every command:
///
/// - A meeting with a review open or still opening is in use: the automatic relabel leaves it alone
///   (`sessionsInUse`), as it does a meeting a Meetings command runs for.
/// - When a command starts, a review still opening is waited for first. Delete Meeting then closes the review (its
///   changes saved) before the meeting moves; a review that finishes opening while the deletion runs is closed
///   before it is shown. Every other command that changes what the review reads (Recover, Label Speakers, Delete
///   Audio, the automatic relabel) makes the review read-only with a banner: its queued changes are saved and the
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
    }

    public enum Response: Sendable, Equatable {
        /// The review goes on as before.
        case unaffected
        /// Read-only with `banner` until the command ends, then reread from disk.
        case readOnly(banner: String)
        /// Closed (its changes saved) before the command starts.
        case close
    }

    /// `ReviewSession.pause` key of commands the app runs from Meetings or the interrupted-recording prompt.
    public static let commandKey = "command"
    /// `ReviewSession.pause` key of the automatic relabel.
    public static let automaticKey = "automatic"

    public static func response(to command: Command) -> Response {
        switch command {
        case .deleteMeeting: .close
        case .cleanUp: .unaffected
        case .recover: .readOnly(banner: "Holos is recovering this meeting.")
        case .labelSpeakers, .automaticRelabel: .readOnly(banner: "Holos is labelling this meeting's speakers.")
        case .deleteAudio: .readOnly(banner: "Holos is deleting this meeting's audio.")
        }
    }

    /// `ReviewSession.pause` key of `command`.
    public static func pauseKey(_ command: Command) -> String {
        command == .automaticRelabel ? automaticKey : commandKey
    }

    /// Meetings the automatic relabel leaves alone: those a command runs for, and those with a review open, opening,
    /// or still saving after it closed.
    public static func sessionsInUse(commands: some Sequence<String>, reviews: some Sequence<String>) -> Set<String> {
        Set(commands).union(reviews)
    }
}

/// Meetings whose transcript files (`exports/`) are older than their saved speaker labels because rewriting them
/// failed when a review window closed (docs/meeting-design.md §5.10). Kept in UserDefaults, which a full disk does not
/// stop, so Meetings can say so and the meeting's next review rewrites them. Holds session IDs only.
public struct PendingExports {
    public static let key = "meeting.exportsPending"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var sessionIDs: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    public func contains(_ sessionID: String) -> Bool { sessionIDs.contains(sessionID) }

    public func mark(_ sessionID: String) {
        var ids = sessionIDs
        guard ids.insert(sessionID).inserted else { return }
        defaults.set(ids.sorted(), forKey: Self.key)
    }

    public func clear(_ sessionID: String) {
        var ids = sessionIDs
        guard ids.remove(sessionID) != nil else { return }
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(ids.sorted(), forKey: Self.key)
        }
    }
}
