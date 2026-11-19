import Foundation
import HolosCore

/// What the Tidy Up section shows of an edit (docs/design.md "Tidy Up"): the tidied text with the words the model
/// added marked, and the words it removed struck through in place, so a dropped sentence is plain to see before the
/// text is copied. Copy takes `text` alone, without the removed words.
public struct TidyReview: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Text the edit kept (punctuation, capitals and line breaks may differ; they are never marked).
        case kept
        /// Words the model added.
        case added
        /// Words the model removed, shown where they were; not part of `text`.
        case removed
    }

    public struct Segment: Sendable, Equatable {
        public var text: String
        public var kind: Kind
        public init(_ text: String, _ kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// The tidied text, as Copy takes it.
    public let text: String
    /// `text` with the removed words between, in order: joining the segments that are not `.removed` gives `text`.
    public let segments: [Segment]
    /// How many words were removed and how many places got words added.
    public let removedWords: Int
    public let addedPlaces: Int

    /// `changes` are `WordChanges.between(original, text)`: UTF-16 places in `text`. A change outside `text` (from a
    /// different text) is left out rather than trusted.
    public init(text: String, changes: [WordChanges.Change]) {
        self.text = text
        let utf16 = text.utf16
        var segments: [Segment] = []
        var cursor = 0
        func append(_ piece: String, _ kind: Kind) {
            guard !piece.isEmpty else { return }
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1].text += piece
            } else {
                segments.append(Segment(piece, kind))
            }
        }
        func slice(_ range: Range<Int>) -> String {
            let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
            let end = utf16.index(start, offsetBy: range.count)
            return String(utf16[start ..< end]) ?? ""
        }
        var removedWords = 0
        var addedPlaces = 0
        let sorted = changes.sorted(by: { $0.location < $1.location })
        for (index, change) in sorted.enumerated()
        where change.location >= cursor && change.location <= utf16.count && change.length >= 0
            && change.length <= utf16.count - change.location {
            // Words removed at a sentence's end show after its punctuation: "the bank. ~~They said…~~ Then".
            var place = change.location
            if change.length == 0 {
                let limit = index + 1 < sorted.count ? min(sorted[index + 1].location, utf16.count) : utf16.count
                func character(at offset: Int) -> Character? { slice(offset ..< offset + 1).first }
                var moved = place
                while moved < limit, let next = character(at: moved), next.isPunctuation { moved += 1 }
                // Only past a sentence's end: punctuation inside "3.5", "e-mail" or before "Hello" keeps it in place.
                let ended = moved == utf16.count || character(at: moved)?.isWhitespace == true
                if moved > place, ended {
                    while moved < limit, let next = character(at: moved), next == " " { moved += 1 }
                    place = moved
                }
            }
            append(slice(cursor ..< place), .kept)
            if !change.removed.isEmpty {
                // Spaced from the words around it, so "went out" + removed "and then" reads "went out and then".
                let before = segments.last.map { $0.text.last?.isWhitespace == false } ?? false
                let next = place < utf16.count ? slice(place ..< place + 1) : ""
                let after = next.first.map { !$0.isWhitespace && !$0.isPunctuation } ?? false
                append((before ? " " : "") + change.removed + (after ? " " : ""), .removed)
                removedWords += WordChanges.words(in: change.removed).count
            }
            if change.length > 0 {
                append(slice(change.location ..< change.location + change.length), .added)
                addedPlaces += 1
            }
            cursor = place + change.length
        }
        append(slice(cursor ..< utf16.count), .kept)
        self.segments = segments
        self.removedWords = removedWords
        self.addedPlaces = addedPlaces
    }

    /// The edit as VoiceOver reads it, which does not speak strikethrough or colour: "We went out and then
    /// (removed: We) came back home." Added words are read as "(added: to)".
    public var spokenText: String {
        segments.map { segment in
            switch segment.kind {
            case .kept: segment.text
            case .added: "(added: \(segment.text))"
            case .removed: " (removed: \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))) "
            }
        }.joined()
    }

    /// "4 words removed (struck through), 2 places with words added (marked)." or the no-change line.
    public var summary: String {
        guard removedWords > 0 || addedPlaces > 0 else { return "No words changed; only punctuation, capitals and lines." }
        var parts: [String] = []
        if removedWords > 0 { parts.append("\(removedWords) \(removedWords == 1 ? "word" : "words") removed (struck through)") }
        if addedPlaces > 0 {
            parts.append("\(addedPlaces) \(addedPlaces == 1 ? "place" : "places") with words added (underlined)")
        }
        return parts.joined(separator: ", ") + ". Check them before you copy."
    }
}
