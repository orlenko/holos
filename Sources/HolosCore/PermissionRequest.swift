import Foundation

/// A privacy permission that Setup's "Open Settings" asks macOS for.
public enum PrivacyPermission: String, CaseIterable, Sendable {
    case accessibility, inputMonitoring, screenAndSystemAudio
}

/// What one "Open Settings" click does, decided without guessing whether macOS showed a prompt. A permission not
/// granted is asked for on every click: asking adds Voice is Local to the list in System Settings (again after its
/// entry was removed), and macOS shows its own prompt, which leads to the page, only the first time for an entry.
/// So the first click for a permission in this run only asks; a later click (the prompt did not come, or the user
/// wants the page) asks and opens the page. A granted permission's click just opens the page.
public struct PermissionRequest: Sendable, Equatable {
    public var asks: Bool
    public var opensSettings: Bool

    /// `clicksBefore`: earlier clicks for this permission since the app started.
    public static func forClick(granted: Bool, clicksBefore: Int) -> PermissionRequest {
        if granted { return PermissionRequest(asks: false, opensSettings: true) }
        return PermissionRequest(asks: true, opensSettings: clicksBefore > 0)
    }
}
