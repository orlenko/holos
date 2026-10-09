import Foundation

/// Settings › Meetings › "Capture the screen during meetings (slides, shared screens) to improve transcripts"
/// (docs/meeting/screen-context.md §4.15): the start panel's "Capture screen" begins checked when it is on.
public enum MeetingScreenPreference {
    public static let key = "meetingScreenCapture"
    /// Before the whole display was captured, this key offered a choice of window by default.
    public static let legacyKey = "meetingScreenCaptureDefault"

    /// Off for a new install, since it needs Screen Recording permission; on for someone who had the window offer
    /// on; afterwards what Settings last saved.
    public static func enabled(in defaults: UserDefaults) -> Bool {
        if let value = defaults.object(forKey: key) as? Bool { return value }
        return defaults.object(forKey: legacyKey) as? Bool ?? false
    }

    public static func set(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }
}
