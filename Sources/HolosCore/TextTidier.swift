import Foundation

/// Tidies dictated text with a language model (docs/design.md "Tidy Up"): rejoins sentences a pause split, fixes
/// punctuation and capitals, breaks the text into paragraphs, lists and quotes, and drops fillers and false starts.
/// The model is injected (`TranscriptFixer.Model`), so the tool can use Qwen or Apple's on-device model and tests a
/// closure. The text goes to the model in parts of at most `partWords` words; a part whose reply fails, times out, or
/// fails `verdict` keeps its own text, and the result says which parts did.
public struct TextTidier: Sendable {
    public struct Part: Sendable, Codable, Equatable {
        /// The part as given.
        public var original: String
        /// The text used: the model's edit, or `original` when `kept` is set.
        public var text: String
        /// Why the part keeps its own text (the model failed, timed out, or changed too much); nil when edited.
        public var kept: String?

        public init(original: String, text: String, kept: String? = nil) {
            self.original = original
            self.text = text
            self.kept = kept
        }
    }

    public struct Result: Sendable, Codable, Equatable {
        /// The parts' texts, a blank line between parts.
        public var text: String
        public var parts: [Part]

        public init(parts: [Part]) {
            self.parts = parts
            text = parts.map(\.text).joined(separator: "\n\n")
        }
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
        let pieces = Self.parts(of: text, maximumWords: partWords)
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

    private func tidyPart(_ piece: String) async -> Part {
        let model = model
        let prompt = Self.prompt(for: piece)
        switch await TranscriptFixer.firstOf(timeout, { try await model(Self.instructions, prompt) }) {
        case .timedOut:
            return Part(original: piece, text: piece, kept: "the model took too long")
        case .failed:
            return Part(original: piece, text: piece, kept: "the model gave no answer")
        case .value(let reply):
            let edit = Self.cleanedReply(reply, original: piece)
            if let reason = Self.verdict(original: piece, edited: edit) {
                return Part(original: piece, text: piece, kept: reason)
            }
            return Part(original: piece, text: edit)
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

    /// `text` in parts of at most `maximumWords` words, in order: whole paragraphs (split at blank lines) while they
    /// fit, a longer paragraph at sentence ends, and a longer sentence at word boundaries. Parts are trimmed and never
    /// empty; text without words gives no parts.
    public static func parts(of text: String, maximumWords: Int) -> [String] {
        let limit = max(1, maximumWords)
        let paragraphs = text.split(separator: blankLine).map(trimmed).filter { !$0.isEmpty }
        var parts: [String] = []
        var current: [String] = []
        var currentWords = 0
        func flush() {
            if !current.isEmpty { parts.append(current.joined(separator: "\n\n")) }
            current = []
            currentWords = 0
        }
        for paragraph in paragraphs.flatMap({ pieces(of: $0, limit: limit) }) {
            let count = wordCount(paragraph)
            if currentWords + count > limit { flush() }
            current.append(paragraph)
            currentWords += count
        }
        flush()
        return parts.filter { wordCount($0) > 0 }
    }

    /// A paragraph that fits, or its sentences (and over-long sentences' word runs) grouped up to `limit` words.
    private static func pieces(of paragraph: String, limit: Int) -> [String] {
        guard wordCount(paragraph) > limit else { return [paragraph] }
        let sentences = Self.sentences(of: paragraph)
            .flatMap { sentence -> [String] in
                guard wordCount(sentence) > limit else { return [sentence] }
                let words = sentence.split(whereSeparator: \.isWhitespace)
                return stride(from: 0, to: words.count, by: limit).map {
                    words[$0 ..< min($0 + limit, words.count)].joined(separator: " ")
                }
            }
        var pieces: [String] = []
        var current: [String] = []
        var currentWords = 0
        for sentence in sentences {
            let count = wordCount(sentence)
            if currentWords + count > limit, !current.isEmpty {
                pieces.append(current.joined(separator: " "))
                current = []
                currentWords = 0
            }
            current.append(sentence)
            currentWords += count
        }
        if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
        return pieces
    }

    /// The edit inside a reply: without a reasoning block (`<think>…</think>`), surrounding code fences, a leading
    /// "Text:" label, or a first line that only introduces the edit ("Here is the edited text:"). A first line whose
    /// words open `original` is the speaker's own and stays.
    public static func cleanedReply(_ reply: String, original: String) -> String {
        var text = reply.replacing(thinkBlock, with: "")
        text = trimmed(text)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last.map(trimmed) == "```" { lines.removeLast() }
            text = trimmed(lines.joined(separator: "\n"))
        }
        if let first = text.components(separatedBy: "\n").first, first.wholeMatch(of: introduction) != nil {
            let said = WordChanges.words(in: original).prefix(WordChanges.words(in: first).count).map(\.word)
            if said != WordChanges.words(in: first).map(\.word) { text = trimmed(String(text.dropFirst(first.count))) }
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
    /// fillers, false starts and repeats takes words out, and rejoining sentences rarely adds any, so the edit may
    /// leave out at most a quarter of the words and add at most a fifth (a few words more for a short part).
    public static func verdict(original: String, edited: String) -> String? {
        let before = WordChanges.words(in: original).map(\.word)
        let after = WordChanges.words(in: edited).map(\.word)
        guard !after.isEmpty else { return "the model gave no text" }
        let difference = after.difference(from: before)
        let removed = difference.removals.count
        let inserted = difference.insertions.count
        if removed > max(3, before.count / 4) { return "the model left out too many words" }
        if inserted > max(3, before.count / 5) { return "the model added words that were not said" }
        return nil
    }

    /// `paragraph`'s sentences: runs of words ending with a word whose last character, past closing quotes and
    /// brackets, is `.`, `!`, `?` or `…`.
    static func sentences(of paragraph: String) -> [String] {
        var sentences: [String] = []
        var current: [Substring] = []
        for word in paragraph.split(whereSeparator: \.isWhitespace) {
            current.append(word)
            let end = word.reversed().first { !"\"'”’)]»".contains($0) }
            if let end, ".!?…".contains(end) {
                sentences.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { sentences.append(current.joined(separator: " ")) }
        return sentences
    }

    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    private static func trimmed(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Built on each use: `Regex` is not `Sendable`, so it cannot be a stored static.
    private static var blankLine: Regex<Substring> { /\n[ \t]*\n/ }
    private static var bulletMarker: Regex<(Substring, Substring)> { /^([ \t]*)[*•][ \t]+/ }
    private static var thinkBlock: Regex<Substring> { /(?s)<think>.*?<\/think>/ }
    private static var introduction: Regex<Substring> {
        /(?i)\s*(?:here(?:'s| is)|sure|certainly)?[^\n]{0,40}\b(?:text|version)\b[^\n]{0,20}:\s*/
    }
}
