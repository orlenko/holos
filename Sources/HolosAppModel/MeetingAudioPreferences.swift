import Foundation

/// What the user chose about deleting a meeting's audio, kept in UserDefaults, free of AppKit so it can be tested.
public struct MeetingAudioPreferences {
    /// UserDefaults key: Delete Audio on one meeting asks first. Absent means yes; "Don't ask again" in the
    /// confirmation sets it to false.
    public static let confirmDeletionKey = "confirmMeetingAudioDeletion"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var confirmsDeletion: Bool {
        get { defaults.object(forKey: Self.confirmDeletionKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.confirmDeletionKey) }
    }
}
