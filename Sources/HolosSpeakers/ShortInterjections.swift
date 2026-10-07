import Foundation
import HolosCore

/// What the Review list and the exports do with a short turn of the unknown speaker (`ShortInterjections`).
public enum ShortInterjection: Sendable, Equatable {
    /// Shown with the speaker of the neighbouring turn it continues (`speakerID`).
    case attached(speakerID: String)
    /// Left out: a standalone filler or backchannel ("um", "Yeah.").
    case hidden
}

/// Short turns of the unknown speaker, as the Review list and the exports show them (docs/meeting-design.md §5.10,
/// "Short interjections"). Presentation only: nothing is stored, the run and the edit journal keep these turns as they
/// are, and voice learning, voice matching and every edit read the projection's own `turns`. Pure and deterministic.
///
/// Only a shown turn of the unknown speaker (`speakerID` nil) of at most `maxWords` words is a candidate: at most
/// `maxWords` words in its text split at spaces, and at most `maxRecognizerWords` words the recognizer timed (a
/// language written without spaces, such as Chinese, is held to that count), and never one
/// the user worked on: assigned (named by an applied `reassignTurns` edit, "Unknown" included, so choosing Unknown for
/// an attached turn keeps it unknown; or `reassigned`), split (`modified`), or with a word edited in Review. Its neighbours
/// are the turns just before and after it on its own track. In order:
/// 1. **Hidden** when every word is a filler or backchannel of the meeting's languages (`isFillerOnly`). Fillers are
///    never attached: a stretched "umm" heard as "an" says nothing in anyone's sentence.
/// 2. **Attached** to the previous turn when that turn has a speaker, does not end a sentence (its text does not end
///    in `.`, `!`, `?` or `…`), and this one starts at most `gapSeconds` after it ends: "… but they" + "agreed to it.
///    Yeah." reads as one sentence of the previous speaker.
/// 3. **Attached** when the turns just before and after it have the same speaker and both gaps are at most
///    `gapSeconds`: a few words inside one person's speech.
/// 4. Otherwise shown as it is.
public enum ShortInterjections {
    /// Turns of more words than this are never touched.
    public static let maxWords = 4
    /// Turns the recognizer timed more words for than this are never touched either, whatever their text's spaces
    /// say (it may time punctuation or a hyphenated word apart, hence the margin).
    public static let maxRecognizerWords = 2 * maxWords
    /// The most silence between a short turn and the turn it joins.
    public static let gapSeconds = 1.5

    // Not `FillerWords` (dictation's hesitation sounds, which leaves out "mm" because it is a unit inside a
    // sentence): here a word stands alone as a whole turn, and backchannels ("yeah", "okay") count too.

    /// Fillers and backchannels in every language: sounds rather than words.
    static let anyLanguage = ["mm", "hmm", "mhm", "mm-hmm", "ok", "okay"]
    /// Fillers and backchannels by language (the language code before "-" or "_").
    static let byLanguage: [String: [String]] = [
        "en": ["um", "umm", "uh", "uh-huh", "yeah", "yes", "right"],
        "fr": ["euh", "ouais", "oui", "d'accord"],
    ]
    /// Fillers only when they are the turn's one word: an article on its own is a stretched "umm".
    static let aloneByLanguage: [String: [String]] = ["en": ["a", "an"]]

    /// Turn ID → what to do with it, for the candidates of `turns` (in the projection's order). `transcript` holds the
    /// turns' words; its languages (`languages`, else `locale`) choose the fillers. `assigned`: the turns the user gave
    /// a speaker (or Unknown) by an edit in effect; they are never candidates.
    public static func classify(_ turns: [ProjectedTurn], transcript: Transcript,
                                assigned: Set<String> = []) -> [String: ShortInterjection] {
        var words = TurnWords(transcript)
        let fillers = Fillers(languages: transcript.languages ?? [transcript.locale])
        var edited: Set<WordRef>?
        // Previous and next turn on the same track.
        var previous: [Int?] = Array(repeating: nil, count: turns.count)
        var next: [Int?] = Array(repeating: nil, count: turns.count)
        var lastOnTrack: [String: Int] = [:]
        for (index, turn) in turns.enumerated() {
            if let last = lastOnTrack[turn.track] {
                previous[index] = last
                next[last] = index
            }
            lastOnTrack[turn.track] = index
        }

        var result: [String: ShortInterjection] = [:]
        for (index, turn) in turns.enumerated() where turn.speakerID == nil && !turn.reassigned && !turn.modified
            && !assigned.contains(turn.id) {
            // Both counts (the recognizer's, which is cheap, first).
            guard turn.spans.reduce(0, { $0 + max(0, $1.end - $1.first) }) <= maxRecognizerWords else { continue }
            let tokens = Self.tokens(words.text(of: turn.spans))
            guard !tokens.isEmpty, tokens.count <= maxWords else { continue }
            let editedWords = edited ?? EchoFilter.reviewEditedWords(in: transcript)
            edited = editedWords
            if !editedWords.isEmpty, turn.spans.contains(where: { span in
                (max(0, span.first)..<max(max(0, span.first), span.end)).contains {
                    editedWords.contains(WordRef(segmentID: span.segmentID, word: $0))
                }
            }) { continue }

            if fillers.isFillerOnly(tokens) {
                result[turn.id] = .hidden
                continue
            }
            let before = previous[index].map { turns[$0] }
            let after = next[index].map { turns[$0] }
            if let before, let speakerID = before.speakerID, Self.gap(before, turn) <= gapSeconds,
               !Self.endsSentence(words.text(of: before.spans.suffix(1))) {
                result[turn.id] = .attached(speakerID: speakerID)
            } else if let before, let after, let speakerID = before.speakerID, after.speakerID == speakerID,
                      Self.gap(before, turn) <= gapSeconds, Self.gap(turn, after) <= gapSeconds {
                result[turn.id] = .attached(speakerID: speakerID)
            }
        }
        return result
    }

    /// Seconds from the end of `first` to the start of `second` (negative when they overlap); infinite when either time
    /// is not a number.
    static func gap(_ first: ProjectedTurn, _ second: ProjectedTurn) -> Double {
        let gap = second.start - first.end
        return gap.isFinite ? gap : .infinity
    }

    /// The text ends a sentence: its last character other than spaces, quotes and closing brackets is `.`, `!`, `?`,
    /// `…` (or a full-width stop). An empty text ends nothing.
    static func endsSentence(_ text: String) -> Bool {
        let closing = CharacterSet(charactersIn: "\"'’”»)]}").union(.whitespacesAndNewlines)
        guard let last = text.unicodeScalars.reversed().first(where: { !closing.contains($0) }) else { return false }
        return ".!?…。！？".unicodeScalars.contains(last)
    }

    /// The words of a text as compared with the lists: split at spaces, lowercased, curly apostrophes made straight,
    /// and punctuation trimmed from both ends ("Yeah." → "yeah", "Mm-hmm," → "mm-hmm"). Pieces with no letter or
    /// digit ("—") are dropped.
    static func tokens(_ text: String) -> [String] {
        let edges = CharacterSet.alphanumerics.inverted
        return text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            let word = piece.lowercased().replacingOccurrences(of: "’", with: "'")
                .trimmingCharacters(in: edges)
            return word.isEmpty ? nil : word
        }
    }

    /// The fillers of some languages, compared with letters held longer folded ("ummm" is "um", "hmmm" is "hmm").
    struct Fillers {
        let words: Set<String>
        let alone: Set<String>

        init(languages: [String]) {
            let codes = Set(languages.map { language in
                String(language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            })
            words = Set((ShortInterjections.anyLanguage + codes.flatMap { ShortInterjections.byLanguage[$0] ?? [] })
                .map(Self.folded))
            alone = Set(codes.flatMap { ShortInterjections.aloneByLanguage[$0] ?? [] })
        }

        /// Every token is a filler; an article only as the one token.
        func isFillerOnly(_ tokens: [String]) -> Bool {
            guard !tokens.isEmpty else { return false }
            if tokens.count == 1, alone.contains(tokens[0]) { return true }
            return tokens.allSatisfy { words.contains(Self.folded($0)) }
        }

        /// Runs of one letter as one letter ("ummm" → "um", "hmm" → "hm"), applied to the lists and the words alike.
        static func folded(_ word: String) -> String {
            var result = ""
            for character in word where character != result.last { result.append(character) }
            return result
        }
    }

    /// Turn text by span, building each segment's text and words only when a turn of it is read.
    struct TurnWords {
        private let segments: [String: TranscriptSegment]
        private var built: [String: TranscriptText.Segment] = [:]

        init(_ transcript: Transcript) {
            var segments: [String: TranscriptSegment] = [:]
            for segment in transcript.segments where segments[segment.id] == nil { segments[segment.id] = segment }
            self.segments = segments
        }

        /// The spans' text as the exports write it (`TranscriptExporter.text`).
        mutating func text<Spans: Sequence<WordSpan>>(of spans: Spans) -> String {
            var pieces: [String] = []
            for span in spans {
                guard let segment = segment(span.segmentID) else { continue }
                let piece = segment.text(first: span.first, end: span.end)
                if !piece.isEmpty { pieces.append(piece) }
            }
            return pieces.joined(separator: " ")
        }

        private mutating func segment(_ id: String) -> TranscriptText.Segment? {
            if let segment = built[id] { return segment }
            guard let source = segments[id] else { return nil }
            let segment = TranscriptText.Segment(source)
            built[id] = segment
            return segment
        }
    }
}
