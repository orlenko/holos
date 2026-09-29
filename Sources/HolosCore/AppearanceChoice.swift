/// Settings › General › Appearance: every Voice is Local window follows macOS, or stays light or dark whatever macOS
/// uses (docs/design.md "Main window").
public enum AppearanceChoice: String, CaseIterable, Sendable {
    case system, light, dark

    /// UserDefaults key; the value is the raw value, and anything else (or nothing) means `system`.
    public static let key = "appearance"

    public init(saved: String?) {
        self = saved.flatMap(Self.init(rawValue:)) ?? .system
    }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
