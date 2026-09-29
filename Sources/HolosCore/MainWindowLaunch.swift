/// Whether the main window opens when Voice is Local starts, and on which section (docs/design.md "Main window"),
/// free of AppKit so it can be tested. The Setup Assistant, and Settings while dictation is off, take precedence
/// (`SetupAssistantLaunch`); this decides the other launches.
public enum MainWindowLaunch {
    /// UserDefaults key: Settings › General › "Open the Voice is Local window when it starts"; absent means on.
    public static let openAtLaunchKey = "openWindowAtLaunch"
    /// UserDefaults key: the section the window last showed (Settings excepted), by its stable name, for the next
    /// launch.
    public static let lastSectionKey = "mainWindowLastSection"
    /// The section a launch opens when none was saved, or the saved one is unknown to this build.
    public static let defaultSection = "history"
    /// The section a launch opens while a meeting records.
    public static let meetingsSection = "meetings"

    /// Whether the window opens at launch; the setting is on until the user turns it off.
    public static func opensWindow(saved: Bool?) -> Bool { saved ?? true }

    /// The section a launch opens: Meetings while a meeting records (the app reattached to it), else the one the
    /// window last showed when this build knows it, else History.
    public static func section(lastUsed: String?, known: Set<String>, meetingRecording: Bool) -> String {
        if meetingRecording, known.contains(meetingsSection) { return meetingsSection }
        if let lastUsed, known.contains(lastUsed) { return lastUsed }
        return defaultSection
    }
}
