import Foundation
import HolosCore
import HolosSpeakers

/// Who an edit names as a turn's speaker: a listed speaker, or the unknown speaker.
public enum SpeakerTarget: Sendable, Equatable { case speaker(String), unknown }

/// Resolves what a user typed for a speaker, a turn, or a time against one projection (docs/meeting-design.md §5.7).
/// Every CLI edit command resolves its selectors against the projection it then passes to `SpeakerEditor` as the
/// view, so a relabel in between is refused rather than applied to a different turn.
///
/// Errors are `HolosError.invalidInput` and list the candidates. They name speakers (the user's own labels); they
/// are for the person typing the command and are never logged.
public enum SpeakerSelector {
    /// In order: exact speaker ID ("system:S2"); engine label if unique ("S2"); ordinal ("2", "Speaker 2");
    /// name (case-insensitive, unique); "unknown". Errors list the candidates.
    ///
    /// Only listed speakers (`projection.speakers`) can be named. IDs and engine labels (the part of the ID after
    /// its first ":") are compared exactly first, then ignoring case; a step that matches more than one speaker
    /// fails instead of falling through to the next step. Names are compared with `name` (never the " (auto)"
    /// suffix of `label`), ignoring case and surrounding whitespace.
    public static func speaker(_ text: String, in projection: SpeakerProjection) throws -> SpeakerTarget {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw HolosError.invalidInput("Name a speaker. \(candidates(projection.speakers))")
        }
        let speakers = projection.speakers

        // 1. Exact speaker ID, then the ID ignoring case.
        if let match = speakers.first(where: { $0.id == query }) { return .speaker(match.id) }
        if let found = try unique(speakers.filter { $0.id.caseInsensitiveCompare(query) == .orderedSame },
                                  query: query) {
            return .speaker(found)
        }

        // 2. Engine label ("S2" of "system:S2").
        let labelled = speakers.filter { engineLabel(of: $0.id) == query }
        if let found = try unique(labelled, query: query) { return .speaker(found) }
        let labelledIgnoringCase = speakers.filter {
            engineLabel(of: $0.id)?.caseInsensitiveCompare(query) == .orderedSame
        }
        if labelled.isEmpty, let found = try unique(labelledIgnoringCase, query: query) { return .speaker(found) }

        // 3. Ordinal ("3" or "Speaker 3").
        if let ordinal = ordinal(in: query),
           let found = try unique(speakers.filter { $0.ordinal == ordinal }, query: query) {
            return .speaker(found)
        }

        // 4. Name.
        let named = speakers.filter { speaker in
            speaker.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(query) == .orderedSame
        }
        if let found = try unique(named, query: query) { return .speaker(found) }

        // 5. The unknown speaker.
        if query.caseInsensitiveCompare("unknown") == .orderedSame { return .unknown }

        throw HolosError.invalidInput("No speaker matches “\(query)”. \(candidates(speakers))")
    }

    /// "T12" or "T12/…" exactly; or a time ("01:12:03", "12:03.5", "723.5") → the turn containing it,
    /// requiring `track` when both tracks have one there.
    ///
    /// Details:
    /// - A turn ID is matched exactly, then ignoring case. With `track`, the turn must be on that track.
    /// - A time picks the turn with `start ≤ time < end` (or `time == end` for the turn that ends there when no turn
    ///   starts there), on `track` when given. Two turns on one track at the same time cannot happen in a run; if a
    ///   damaged run has them, the error lists both.
    /// - `track` must be "mic" or "system".
    public static func turn(_ text: String, track: String?, in projection: SpeakerProjection) throws -> String {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let track, track != "mic", track != "system" {
            throw HolosError.invalidInput("Unknown track “\(track)”: use mic or system.")
        }
        guard !query.isEmpty else {
            throw HolosError.invalidInput("Name a turn by its ID (T12) or by a time (00:12:05).")
        }

        var byID = projection.turns.filter { $0.id == query }
        if byID.isEmpty { byID = projection.turns.filter { $0.id.caseInsensitiveCompare(query) == .orderedSame } }
        if let turn = byID.first {
            guard byID.count == 1 else {
                throw HolosError.invalidInput("“\(query)” matches more than one turn: "
                                              + byID.map(\.id).joined(separator: ", ") + ". Use the exact ID.")
            }
            if let track, turn.track != track {
                throw HolosError.invalidInput("Turn \(turn.id) is on the \(turn.track) track, not \(track).")
            }
            return turn.id
        }
        guard let seconds = try? time(query) else {
            if looksLikeTurnID(query) {
                throw HolosError.invalidInput("There is no turn \(query) in the current speaker labels. "
                                              + "List them with holos speakers list --turns.")
            }
            throw HolosError.invalidInput(
                "“\(query)” is neither a turn ID (T12) nor a time (01:12:03, 12:03.5, or 723.5 seconds).")
        }

        let candidates = projection.turns.filter { track == nil || $0.track == track }
        var containing = candidates.filter { $0.start <= seconds && seconds < $0.end }
        if containing.isEmpty {
            containing = candidates.filter { $0.end == seconds && $0.start <= seconds }
        }
        let place = TimeFormat.clock(seconds) + (track.map { " on the \($0) track" } ?? "")
        switch containing.count {
        case 0:
            var message = "No turn at \(place)."
            if let nearest = nearest(to: seconds, in: candidates) {
                message += " The nearest is \(nearest.id) (\(nearest.track), \(TimeFormat.clock(nearest.start))–"
                    + "\(TimeFormat.clock(nearest.end)))."
            }
            throw HolosError.invalidInput(message)
        case 1:
            return containing[0].id
        default:
            let tracks = Set(containing.map(\.track))
            let listed = containing.map { "\($0.id) (\($0.track))" }.joined(separator: ", ")
            if track == nil, tracks.count > 1 {
                throw HolosError.invalidInput(
                    "Both tracks have a turn at \(place): \(listed). Add --track mic or --track system.")
            }
            throw HolosError.invalidInput("More than one turn is at \(place): \(listed). Name the turn by its ID.")
        }
    }

    /// Seconds on the session timeline from "h:mm:ss", "mm:ss", or seconds, each with an optional decimal fraction
    /// on the last part: "01:12:03" → 4323, "12:03.5" → 723.5, "723.5" → 723.5. Hours and a leading minutes field
    /// may have any number of digits; minutes and seconds after a colon are below 60. ASCII digits only (no sign,
    /// exponent, or spaces inside).
    public static func time(_ text: String) throws -> Double {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = HolosError.invalidInput(
            "“\(query)” is not a time: use h:mm:ss (01:12:03), mm:ss (12:03.5), or seconds (723.5).")
        let parts = query.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { throw invalid }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard let value = number(part, allowFraction: isLast) else { throw invalid }
            if index > 0, value >= 60 { throw invalid }
            total = total * 60 + value
        }
        guard total.isFinite else { throw invalid }
        return total
    }

    // MARK: - Private

    /// The one speaker in `matches`, nil when there is none; throws when there are several.
    private static func unique(_ matches: [ProjectedSpeaker], query: String) throws -> String? {
        guard let first = matches.first else { return nil }
        guard matches.count == 1 else {
            throw HolosError.invalidInput("“\(query)” matches more than one speaker: "
                                          + matches.map(describe).joined(separator: ", ") + ". Use the full ID.")
        }
        return first.id
    }

    /// The part of a speaker ID after its first ":", e.g. "S2" of "system:S2"; nil without a ":".
    private static func engineLabel(of id: String) -> String? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let label = id[id.index(after: colon)...]
        return label.isEmpty ? nil : String(label)
    }

    /// N from "N" or "Speaker N" (any case, any spaces between the two words).
    private static func ordinal(in query: String) -> Int? {
        var digits = Substring(query)
        let prefix = "speaker"
        if query.lowercased().hasPrefix(prefix) {
            digits = query.dropFirst(prefix.count).drop { $0 == " " }
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// "T12" or "T12/…" in shape: a T followed by a digit.
    private static func looksLikeTurnID(_ text: String) -> Bool {
        let characters = Array(text)
        return characters.count >= 2 && (characters[0] == "T" || characters[0] == "t")
            && characters[1].isASCII && characters[1].isNumber
    }

    /// Unsigned decimal: digits with at most one "." (fraction only when allowed), at least one digit.
    private static func number(_ text: String, allowFraction: Bool) -> Double? {
        guard !text.isEmpty, text.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }) else { return nil }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 1 || (allowFraction && pieces.count == 2),
              pieces.contains(where: { !$0.isEmpty }) else { return nil }
        return Double(text.hasPrefix(".") ? "0" + text : text)
    }

    /// The turn whose time range is closest to `seconds`.
    private static func nearest(to seconds: Double, in turns: [ProjectedTurn]) -> ProjectedTurn? {
        turns.min { distance(seconds, $0) < distance(seconds, $1) }
    }

    private static func distance(_ seconds: Double, _ turn: ProjectedTurn) -> Double {
        if seconds < turn.start { return turn.start - seconds }
        if seconds > turn.end { return seconds - turn.end }
        return 0
    }

    /// "system:S2 (Maria)", or the ID alone when the label is the ID.
    static func describe(_ speaker: ProjectedSpeaker) -> String {
        speaker.label == speaker.id ? speaker.id : "\(speaker.id) (\(speaker.label))"
    }

    /// "Speakers: 1 mic:me (Me), 2 system:S1 (Jim), or unknown."
    private static func candidates(_ speakers: [ProjectedSpeaker]) -> String {
        guard !speakers.isEmpty else { return "This meeting has no listed speakers; use unknown." }
        return "Speakers: " + speakers.map { "\($0.ordinal) \(describe($0))" }.joined(separator: ", ")
            + ", or unknown."
    }
}
