/// When Voice is Local asks whether to check for updates automatically (docs/release.md "Updates"), free of AppKit so
/// it can be tested. Nothing goes online before the answer: the app starts Sparkle at launch only when the answer is
/// yes, and otherwise only for Check for Updates….
public enum UpdateCheckConsent {
    /// Sparkle's UserDefaults key for automatic checks. Absent until the user answers the question or changes
    /// Settings › General › "Check for updates automatically".
    public static let automaticChecksKey = "SUEnableAutomaticChecks"
    /// UserDefaults key: an update-capable build of the app has launched before.
    public static let launchedBeforeKey = "updateCheckLaunchedBefore"

    public enum Launch: Equatable {
        /// The first launch: Setup and permissions come first, so the question waits for the next launch.
        case wait
        /// Ask now, once.
        case ask
        /// The user answered (or chose in Settings): checks follow that answer.
        case answered(automatic: Bool)
    }

    /// What this launch does about the question, from the saved answer (nil when none) and whether an update-capable
    /// build launched before.
    public static func launch(answer: Bool?, launchedBefore: Bool) -> Launch {
        if let answer { return .answered(automatic: answer) }
        return launchedBefore ? .ask : .wait
    }
}
