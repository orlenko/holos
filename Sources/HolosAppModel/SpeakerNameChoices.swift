import Foundation

/// What Name Speaker… offers while a meeting records (docs/design.md "Live transcript").
public enum SpeakerNameChoices {
    /// The names given in this meeting first, then the people in People, each once (letter case ignored), in that
    /// order.
    public static func choices(inMeeting: [String], known: [String]) -> [String] {
        var seen = Set<String>()
        return (inMeeting + known).compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}
