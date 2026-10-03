import Foundation

/// A privacy permission that Setup's "Open Settings" asks macOS for.
public enum PrivacyPermission: String, CaseIterable, Sendable {
    case accessibility, inputMonitoring, screenAndSystemAudio
}

/// What one "Open Settings" click does. A permission not granted yet is asked for first: asking is what adds Voice
/// is Local to the list in System Settings (again, after its entry was removed), and macOS then shows its own prompt,
/// whose "Open System Settings" button leads to the page. macOS shows that prompt only once per entry, so when Voice
/// is Local is still the active app a moment after asking, no prompt came and the page is opened directly. One
/// click never shows both the prompt and the page.
public enum PermissionRequest {
    /// How long after asking a prompt has to take the focus.
    public static let promptWait: Duration = .milliseconds(800)

    /// Whether to ask macOS first.
    public static func asks(granted: Bool) -> Bool { !granted }

    /// Whether to open the System Settings page: always for a granted permission (to change it), and after asking
    /// only when no system prompt took the focus.
    public static func opensSettings(granted: Bool, stillActiveAfterAsking: Bool) -> Bool {
        granted || stillActiveAfterAsking
    }
}
