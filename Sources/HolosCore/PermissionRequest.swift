import Foundation

/// A privacy permission that Setup's "Open Settings" asks macOS for.
public enum PrivacyPermission: String, CaseIterable, Sendable {
    case accessibility, inputMonitoring, screenAndSystemAudio
}

/// What one "Open Settings" click does for a permission that is not granted yet. macOS shows its own prompt (with
/// its own "Open System Settings" button) only the first time an app asks; asking is also what adds the app to the
/// list in System Settings. So the first click only asks, and later clicks only open System Settings: never both,
/// which showed the system prompt on top of an already open System Settings page.
public enum PermissionRequest: Equatable, Sendable {
    /// Ask macOS (its prompt leads to the right System Settings page).
    case askSystem
    /// Open the permission's System Settings page.
    case openSettings

    public static func next(for permission: PrivacyPermission, asked: Set<String>) -> PermissionRequest {
        asked.contains(permission.rawValue) ? .openSettings : .askSystem
    }

    /// The permissions already asked for, as saved in `defaults`.
    public static let defaultsKey = "privacyPermissionsAsked"

    public static func asked(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public static func recordAsked(_ permission: PrivacyPermission, in defaults: UserDefaults) {
        var asked = asked(in: defaults)
        asked.insert(permission.rawValue)
        defaults.set(asked.sorted(), forKey: defaultsKey)
    }
}
