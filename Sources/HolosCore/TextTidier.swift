import Foundation

/// Tidies dictated text with a language model (docs/design.md "Tidy Up"): rejoins sentences a pause split, fixes
/// punctuation and capitals, breaks the text into paragraphs, lists and quotes, and drops fillers and false starts.
/// The model is injected (`TranscriptFixer.Model`), so the tool can use Qwen or Apple's on-device model and tests a
/// closure. The text goes to the model in parts of at most `partWords` words; a part whose reply fails, times out, or
/// fails `verdict` keeps its own text exactly, and the result says which parts did.
public struct TextTidier: Sendable {
    /// A run of the given text: its words and the spacing between them exactly as given, and the spacing after it.
    public struct Piece: Sendable, Codable, Equatable {
        public var text: String
        /// The whitespace that followed `text` in the given text (empty for the last piece).
        public var separator: String

        public init(text: String, separator: String) {
            self.text = text
            self.separator = separator
        }
    }

    public struct Part: Sendable, Codable, Equatable {
        /// The part exactly as given.
        public var original: String
        /// The text used: the model's edit, or `original` when `kept` is set.
        public var text: String
        /// The whitespace that followed the part in the given text; the result keeps it between parts.
        public var separator: String
        /// Why the part keeps its own text (the model failed, timed out, or changed too much); nil when edited.
        public var kept: String?

        public init(original: String, text: String, separator: String = "", kept: String? = nil) {
            self.original = original
            self.text = text
            self.separator = separator
            self.kept = kept
        }
    }

    public struct Result: Sendable, Codable, Equatable {
        /// The parts' texts, each followed by the whitespace that followed it in the given text.
        public var text: String
        public var parts: [Part]

        public init(parts: [Part]) {
            self.parts = parts
            text = parts.enumerated().map { index, part in
                index == parts.count - 1 ? part.text : part.text + part.separator
            }.joined()
        }

        /// Every part kept its own text: nothing was tidied.
        public var nothingTidied: Bool { parts.allSatisfy { $0.kept != nil } }
    }

    /// Words per part: the model's context holds the instructions, the part and its edit, and a longer part takes
    /// longer than a person waits for a part's progress.
    public var partWords: Int
    /// Bound on one part's reply.
    public var timeout: Duration
    private let model: TranscriptFixer.Model

    public init(partWords: Int, timeout: Duration, model: @escaping TranscriptFixer.Model) {
        self.partWords = max(1, partWords)
        self.timeout = timeout
        self.model = model
    }

    /// Tidies `text` part by part, in order, calling `progress(done, total)` before each part and once at the end.
    /// Throws `CancellationError` when the task is cancelled: no partial result is returned.
    public func tidy(_ text: String, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Result {
        let pieces = Self.pieces(of: text, maximumWords: partWords)
        var parts: [Part] = []
        for (index, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            progress(index, pieces.count)
            parts.append(await tidyPart(piece))
        }
        try Task.checkCancellation()
        progress(pieces.count, pieces.count)
        return Result(parts: parts)
    }

    private func tidyPart(_ piece: Piece) async -> Part {
        let model = model
        let prompt = Self.prompt(for: piece.text)
        func kept(_ reason: String) -> Part {
            Part(original: piece.text, text: piece.text, separator: piece.separator, kept: reason)
        }
        switch await TranscriptFixer.firstOf(timeout, { try await model(Self.instructions, prompt) }) {
        case .timedOut:
            return kept("the model took too long")
        case .failed:
            return kept("the model gave no answer")
        case .value(let reply):
            let edit = Self.cleanedReply(reply, original: piece.text)
            if let reason = Self.verdict(original: piece.text, edited: edit) { return kept(reason) }
            return Part(original: piece.text, text: edit, separator: piece.separator)
        }
    }

    /// The instructions every part is sent under. The three examples are what made the models rejoin split sentences:
    /// without them, Apple's model and Gemma kept most pause periods.
    public static let instructions = """
        You edit dictated text for a journal or an email. The speaker paused while thinking, so the recognizer put \
        periods and capitals in the middle of sentences. Rejoin split sentences, fix punctuation and capitals, break \
        the text into paragraphs, and use a bulleted list or quotation marks where the speaker lists items or quotes \
        someone. You may remove filler words ("um", "uh"), false starts and repeated words. Keep the speaker's own \
        words, voice and meaning; do not summarize, shorten, add content, translate, or answer the text. Reply in the \
        language of the text, with the edited text only.

        Examples of pauses to repair:
        Before: We should ship it. On Friday. Because the client. Is waiting.
        After: We should ship it on Friday, because the client is waiting.
        Before: I went to the store and. I bought. Milk, eggs. And bread.
        After: I went to the store and bought milk, eggs and bread.
        Before: She said. I will call you tomorrow.
        After: She said, "I will call you tomorrow."
        """

    /// Framed as a labelled field so the model treats a dictated question or request as text to edit.
    public static func prompt(for text: String) -> String { "Text:\n\(text)" }

    /// The texts of `pieces(of:maximumWords:)`.
    public static func parts(of text: String, maximumWords: Int) -> [String] {
        pieces(of: text, maximumWords: maximumWords).map(\.text)
    }

    /// `text` in pieces of at most `maximumWords` words, in order, each exactly as given (spacing and line breaks
    /// inside it kept), with the whitespace after it. A piece ends where the strongest break within its words is,
    /// the latest of equals: a blank line, then a line break, then a sentence end (`.`, `!`, `?` or `…`, past closing
    /// quotes and brackets), then any space. Text without words gives no pieces.
    public static func pieces(of text: String, maximumWords: Int) -> [Piece] {
        let limit = max(1, maximumWords)
        let words = text.matches(of: wordAndSpace)
        var pieces: [Piece] = []
        var start = 0
        while start < words.count {
            var end = min(start + limit, words.count)
            if end < words.count {
                // The word whose following break is strongest ends the piece.
                let ends = start ..< end
                let strongest = ends.map { breakStrength(words[$0]) }.max() ?? 0
                end = (ends.last { breakStrength(words[$0]) == strongest } ?? end - 1) + 1
            }
            let body = text[words[start].range.lowerBound ..< words[end - 1].output.1.endIndex]
            let separator = end < words.count ? String(words[end - 1].output.2) : ""
            pieces.append(Piece(text: String(body), separator: separator))
            start = end
        }
        return pieces
    }

    /// 3 for a blank line after the word, 2 for a line break, 1 for a sentence end, 0 otherwise.
    private static func breakStrength(_ match: Regex<(Substring, Substring, Substring)>.Match) -> Int {
        let space = match.output.2
        let newlines = space.filter(\.isNewline).count
        if newlines >= 2 { return 3 }
        if newlines == 1 { return 2 }
        let end = match.output.1.reversed().first { !"\"'”’)]»".contains($0) }
        return end.map { ".!?…".contains($0) } == true ? 1 : 0
    }

    /// The edit inside a reply: without a reasoning block (`<think>…</think>`), surrounding code fences, a leading
    /// "Text:" label, or a first line that only introduces the edit ("Here is the edited text:"). A first line whose
    /// words all appear, in order, in `original` is the speaker's own and stays.
    public static func cleanedReply(_ reply: String, original: String) -> String {
        var text = trimmed(reply.replacing(thinkBlock, with: ""))
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last.map(trimmed) == "```" { lines.removeLast() }
            text = trimmed(lines.joined(separator: "\n"))
        }
        if let first = text.components(separatedBy: "\n").first, first.wholeMatch(of: introduction) != nil,
           !isSubsequence(WordChanges.words(in: first).map(\.word), of: WordChanges.words(in: original).map(\.word)) {
            text = trimmed(String(text.dropFirst(first.count)))
        }
        if text.hasPrefix("Text:") { text = trimmed(String(text.dropFirst(5))) }
        return text.components(separatedBy: "\n").map(plainLine).joined(separator: "\n")
    }

    /// A reply line as plain text: no trailing spaces (Markdown's line break), and a bullet written `*` or `•`, with
    /// any spaces after it, as `- `.
    private static func plainLine(_ line: String) -> String {
        var line = String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        if let bullet = line.firstMatch(of: bulletMarker) {
            line = String(bullet.output.1) + "- " + line[bullet.range.upperBound...]
        }
        return line
    }

    /// Nil when `edited` is an acceptable tidy-up of `original`; otherwise why not, in words for the person. Removing
    /// fillers, false starts and repeats takes out a few words here and there, and rejoining sentences or fixing a
    /// misheard word adds one or two at a place. So the edit may leave out at most a sixth of the words and add at most
    /// a tenth (at least 2 either way), and leave out no run of more than 12 words or add no run of more than 3: an
    /// answer, a summary, a dropped passage or a sentence of the model's own fails.
    public static func verdict(original: String, edited: String) -> String? {
        let before = WordChanges.words(in: original).map(\.word)
        let after = WordChanges.words(in: edited).map(\.word)
        guard !after.isEmpty else { return "the model gave no text" }
        let difference = after.difference(from: before)
        let removed = offsets(difference.removals)
        let inserted = offsets(difference.insertions)
        if removed.count > max(2, before.count / 6) || longestRun(removed) > 12 {
            return "the model left out too many words"
        }
        if inserted.count > max(2, before.count / 10) || longestRun(inserted) > 3 {
            return "the model added words that were not said"
        }
        return nil
    }

    private static func offsets(_ changes: [CollectionDifference<String>.Change]) -> [Int] {
        changes.map { change in
            switch change {
            case .remove(let offset, _, _), .insert(let offset, _, _): offset
            }
        }.sorted()
    }

    /// The longest run of consecutive numbers in `offsets` (in increasing order).
    private static func longestRun(_ offsets: [Int]) -> Int {
        var longest = 0
        var run = 0
        var previous: Int?
        for offset in offsets {
            run = previous.map { offset == $0 + 1 } == true ? run + 1 : 1
            longest = max(longest, run)
            previous = offset
        }
        return longest
    }

    private static func isSubsequence(_ words: [String], of text: [String]) -> Bool {
        var remaining = words[...]
        for word in text where word == remaining.first { remaining = remaining.dropFirst() }
        return remaining.isEmpty
    }

    private static func trimmed(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Built on each use: `Regex` is not `Sendable`, so it cannot be a stored static.
    /// A word (any run without whitespace) and the whitespace after it.
    private static var wordAndSpace: Regex<(Substring, Substring, Substring)> { /(\S+)(\s*)/ }
    private static var bulletMarker: Regex<(Substring, Substring)> { /^([ \t]*)[*•][ \t]+/ }
    private static var thinkBlock: Regex<Substring> { /(?s)<think>.*?<\/think>/ }
    /// A short first line ending with a colon that opens like a reply ("Here is…", "Sure…") or names the edit.
    private static var introduction: Regex<Substring> {
        /(?i)\s*(?:(?:here|sure|certainly|of course|okay|ok|below)\b[^\n]{0,70}|[^\n]{0,50}\b(?:text|version|edit|edited|revised|cleaned)\b[^\n]{0,30}):\s*/
    }
}
