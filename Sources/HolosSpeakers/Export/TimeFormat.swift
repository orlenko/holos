import Foundation

/// Session-time layouts used by the exports (docs/meeting-design.md §4.11). Inputs are seconds on the session
/// timeline. A non-finite or negative value shows as zero and values are capped at 99,999 hours, so formatting never
/// traps on corrupt data.
public enum TimeFormat {
    /// `HH:MM:SS`, the Markdown timestamp: "00:12:03", "01:02:03". Whole seconds, rounded down.
    public static func clock(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds, rule: .down)
        return pad(total / 3_600) + ":" + pad(total / 60 % 60) + ":" + pad(total % 60)
    }

    /// `mm:ss` below one hour ("01:05") and `h:mm:ss` from one hour ("1:02:05"): the header time of the text
    /// export, which the Otter parser and the evaluator's header regex read. Whole seconds, rounded down.
    public static func compact(_ seconds: Double) -> String {
        layout(wholeSeconds(seconds, rule: .down))
    }

    /// A length of time in the `compact` layout, rounded to the nearest second: "41:12", "2:58:12".
    public static func duration(_ seconds: Double) -> String {
        layout(wholeSeconds(seconds, rule: .toNearestOrAwayFromZero))
    }

    /// 99,999 hours.
    static let maximumSeconds = 359_996_400

    static func wholeSeconds(_ seconds: Double, rule: FloatingPointRoundingRule) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let rounded = seconds.rounded(rule)
        return rounded >= Double(maximumSeconds) ? maximumSeconds : Int(rounded)
    }

    private static func layout(_ total: Int) -> String {
        let minutesAndSeconds = pad(total / 60 % 60) + ":" + pad(total % 60)
        return total < 3_600 ? minutesAndSeconds : "\(total / 3_600):" + minutesAndSeconds
    }

    /// At least two digits.
    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
