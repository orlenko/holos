import Foundation

/// The language dictation listens for: a locale identifier Apple's speech transcriber supports, chosen in Setup.
public enum DictationLanguage {
    /// Until the user picks another one.
    public static let standard = "en-CA"

    /// "fr-CA" for "fr_CA", the form Holos saves and hands to the recognizer.
    public static func identifier(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "-")
    }

    /// "fr" for "fr-CA", "fr_FR", or "fr".
    public static func languageCode(of identifier: String) -> String {
        String(identifier.prefix { $0.isLetter }).lowercased()
    }

    /// "French (Canada)" in the user's own language; the identifier when macOS has no name for it.
    public static func name(of identifier: String, in display: Locale = .current) -> String {
        display.localizedString(forIdentifier: self.identifier(identifier)) ?? identifier
    }

    /// The identifiers for a picker, without duplicates: English variants first, then French, then the rest, each
    /// group sorted by name.
    public static func ordered(_ identifiers: [String], in display: Locale = .current) -> [String] {
        Set(identifiers.map(identifier)).sorted {
            (group($0), name(of: $0, in: display), $0) < (group($1), name(of: $1, in: display), $1)
        }
    }

    /// `ordered`, split into its English, French and other groups, leaving out empty ones; a picker puts a separator
    /// between them.
    public static func groups(_ identifiers: [String], in display: Locale = .current) -> [[String]] {
        let sorted = ordered(identifiers, in: display)
        return (0...2).map { rank in sorted.filter { group($0) == rank } }.filter { !$0.isEmpty }
    }

    private static func group(_ identifier: String) -> Int {
        switch languageCode(of: identifier) {
        case "en": 0
        case "fr": 1
        default: 2
        }
    }
}
