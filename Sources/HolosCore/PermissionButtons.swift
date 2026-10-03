import Foundation

/// The buttons of an Accessibility, Input Monitoring, or Screen & System Audio Recording row, each doing exactly one
/// thing. macOS cannot tell an app whether its one-time prompt will appear, so no button both asks and opens System
/// Settings: one click never shows the prompt and the page together.
public struct PermissionButtons: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Calls macOS's request API, which adds Voice is Local to the list (again after its entry was removed) and
        /// shows macOS's prompt if it still will.
        case ask
        /// Opens the permission's page in System Settings.
        case openSettings
    }

    public struct Button: Equatable, Sendable {
        public var title: String
        public var step: Step
    }

    public var primary: Button
    /// Shown as a link under the primary button.
    public var secondary: Button?

    /// Not granted: Allow… asks, System Settings… opens the page. Granted: Open Settings opens the page.
    public static func forPermission(granted: Bool) -> PermissionButtons {
        granted
            ? PermissionButtons(primary: Button(title: "Open Settings", step: .openSettings), secondary: nil)
            : PermissionButtons(primary: Button(title: "Allow…", step: .ask),
                                secondary: Button(title: "System Settings…", step: .openSettings))
    }
}
