import Foundation

/// What the user chose about deleting meetings' audio, kept in UserDefaults, free of AppKit so it can be tested:
/// whether Delete Audio on one meeting asks first, and whether the audio of old meetings is deleted on its own
/// (Settings › Meetings).
///
/// Invariants:
/// 1. A missing or unreadable value reads as its default: asking first, the cleanup off, `defaultCleanupDays`.
/// 2. The days read and written are always within `cleanupDayRange`.
/// 3. Every change to the cleanup posts `cleanupChanged`.
public struct MeetingAudioPreferences {
    /// UserDefaults key: Delete Audio on one meeting asks first. Absent means yes; "Don't ask again" in the
    /// confirmation sets it to false, and Settings › Meetings turns it back on.
    public static let confirmDeletionKey = "confirmMeetingAudioDeletion"
    /// UserDefaults key: the audio of meetings older than `cleanupDaysKey` days is deleted on its own. Absent means no.
    public static let cleanupKey = "meetingAudioCleanup"
    /// UserDefaults key: after how many days; absent means `defaultCleanupDays`.
    public static let cleanupDaysKey = "meetingAudioCleanupDays"
    public static let defaultCleanupDays = 7
    public static let cleanupDayRange = 1...365
    /// Posted when the cleanup is turned on or off or its days change, so the app looks for audio to delete.
    public static let cleanupChanged = Notification.Name("MeetingAudioCleanupChanged")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var confirmsDeletion: Bool {
        get { defaults.object(forKey: Self.confirmDeletionKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.confirmDeletionKey) }
    }

    public var cleansUp: Bool {
        get { defaults.object(forKey: Self.cleanupKey) as? Bool ?? false }
        nonmutating set {
            defaults.set(newValue, forKey: Self.cleanupKey)
            NotificationCenter.default.post(name: Self.cleanupChanged, object: nil)
        }
    }

    /// Kept within `cleanupDayRange` both ways.
    public var cleanupDays: Int {
        get { Self.clamped(defaults.object(forKey: Self.cleanupDaysKey) as? Int ?? Self.defaultCleanupDays) }
        nonmutating set {
            defaults.set(Self.clamped(newValue), forKey: Self.cleanupDaysKey)
            NotificationCenter.default.post(name: Self.cleanupChanged, object: nil)
        }
    }

    /// After how many days old meetings lose their audio, or nil while the cleanup is off.
    public var cleanupAfterDays: Int? { cleansUp ? cleanupDays : nil }

    private static func clamped(_ days: Int) -> Int {
        min(cleanupDayRange.upperBound, max(cleanupDayRange.lowerBound, days))
    }
}
