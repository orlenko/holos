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

        /// `leading` and `trailing`: the whitespace before the first word and after the last of the given text.
        public init(parts: [Part], leading: String = "", trailing: String = "") {
            self.parts = parts
            text = leading + parts.enumerated().map { index, part in
                index == parts.count - 1 ? part.text : part.text + part.separator
            }.joined() + trailing
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
        let lineBreak = text.contains("\r\n") ? "\r\n" : "\n"
        var parts: [Part] = []
        for (index, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            progress(index, pieces.count)
            parts.append(await tidyPart(piece, lineBreak: lineBreak))
        }
        try Task.checkCancellation()
        progress(pieces.count, pieces.count)
        guard !pieces.isEmpty else { return Result(parts: [], leading: text) }
        return Result(parts: parts, leading: String(text.prefix { $0.isWhitespace }),
                      trailing: String(text.reversed().prefix { $0.isWhitespace }.reversed()))
    }

    /// `lineBreak`: the given text's line ending ("\r\n" or "\n"), which the edit's lines get too.
    private func tidyPart(_ piece: Piece, lineBreak: String) async -> Part {
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
            let text = lineBreak == "\n" ? edit : edit.replacingOccurrences(of: "\n", with: lineBreak)
            return Part(original: piece.text, text: text, separator: piece.separator)
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
    /// inside it kept), with the whitespace after it. A piece that does not reach the end ends at the strongest break
    /// after one of the last two thirds of its words, the latest of equals: a blank line, then a line break, then a
    /// sentence end (`.`, `!`, `?` or `…`, past closing quotes and brackets), then any space. The first third does not
    /// count, so a short first line ("Dear John,") stays with the text after it. Text without words gives no pieces.
    public static func pieces(of text: String, maximumWords: Int) -> [Piece] {
        let limit = max(1, maximumWords)
        let words = text.matches(of: wordAndSpace)
        var pieces: [Piece] = []
        var start = 0
        while start < words.count {
            var end = min(start + limit, words.count)
            if end < words.count {
                // The word whose following break is strongest ends the piece.
                let ends = (start + (end - start) / 3) ..< end
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

    /// The edit inside a reply: without a reasoning block (`<think>…</think>`), surrounding code fences, or a leading
    /// "Text:" label (the prompt's own: the reply says "text" more often than `original`). Nothing else the model wrote is taken
    /// out: a line it added ("Here is the edited text:") is left for `verdict` and for the person, who sees it marked
    /// as added. Its line breaks become `\n`, its lines lose trailing spaces, and `*` or `•` bullets become `- `.
    public static func cleanedReply(_ reply: String, original: String) -> String {
        var text = trimmed(reply.replacingOccurrences(of: "\r\n", with: "\n").replacing(thinkBlock, with: ""))
        var lines = text.components(separatedBy: "\n")
        // A fence line is three backticks and at most a language name, never text.
        if let first = lines.first, first.wholeMatch(of: fenceLine) != nil, lines.count > 1 {
            lines.removeFirst()
            if lines.last.map(trimmed) == "```" { lines.removeLast() }
            text = trimmed(lines.joined(separator: "\n"))
        }
        if text.hasPrefix("Text:"),
           WordChanges.words(in: text).count { $0.word == "text" } > WordChanges.words(in: original).count { $0.word == "text" } {
            text = trimmed(String(text.dropFirst(5)))
        }
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

    /// Nil when `edited` is an acceptable tidy-up of `original`; otherwise why not, in words for the person. It refuses
    /// only an edit that is plainly not one, and leaves the rest to the person, who sees every word the edit removed
    /// and added (`WordChanges`) before using the text: heavy tidying of rambling speech passes, and so can a dropped
    /// sentence, which shows as removed. Fillers (`FillerWords`) never count, and a removed word with another copy
    /// within four words of it that the edit keeps (a repeat) does not count towards the total. The edit fails when it
    /// leaves out more than two thirds of the other words (a summary; at least 2) or more than 16 of any 20 words in a
    /// row (a dropped passage), or adds more than a tenth of the words (at least 2) or a run of more than 3 (an answer,
    /// or a sentence of the model's own).
    public static func verdict(original: String, edited: String) -> String? {
        let before = WordChanges.words(in: original).map(\.word)
        let after = WordChanges.words(in: edited).map(\.word)
        guard !after.isEmpty else { return "the model gave no text" }
        let difference = after.difference(from: before)
        let removed = offsets(difference.removals)
        let removedSet = Set(removed)
        let counted = removed.filter { offset in
            let word = before[offset]
            if FillerWords.isFiller(word, language: nil) { return false }
            let nearby = max(0, offset - 4) ... min(before.count - 1, offset + 4)
            return !nearby.contains { $0 != offset && before[$0] == word && !removedSet.contains($0) }
        }
        let inserted = offsets(difference.insertions)
        let unfilled = removed.filter { !FillerWords.isFiller(before[$0], language: nil) }
        let others = before.count - before.count { FillerWords.isFiller($0, language: nil) }
            - (unfilled.count - counted.count)
        if counted.count > max(2, others * 2 / 3) || densest(unfilled, window: 20) > 16 {
            return "the model left out too many words"
        }
        if inserted.count > max(2, before.count / 10) || longestRun(inserted) > 3 {
            return "the model added words that were not said"
        }
        return nil
    }

    /// The most of `offsets` (increasing) that fall in any `window` consecutive positions.
    private static func densest(_ offsets: [Int], window: Int) -> Int {
        var most = 0
        var first = 0
        for (index, offset) in offsets.enumerated() {
            while offsets[first] <= offset - window { first += 1 }
            most = max(most, index - first + 1)
        }
        return most
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

    private static func trimmed(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Built on each use: `Regex` is not `Sendable`, so it cannot be a stored static.
    /// A word (any run without whitespace) and the whitespace after it.
    private static var wordAndSpace: Regex<(Substring, Substring, Substring)> { /(\S+)(\s*)/ }
    private static var bulletMarker: Regex<(Substring, Substring)> { /^([ \t]*)[*•][ \t]+/ }
    private static var fenceLine: Regex<Substring> { /```[A-Za-z]*\s*/ }
    private static var thinkBlock: Regex<Substring> { /(?s)<think>.*?<\/think>/ }
}
