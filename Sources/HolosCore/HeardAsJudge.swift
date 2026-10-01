import Foundation

/// Asks Apple's on-device model whether a word-list term was meant where one of its "often heard as" words was
/// written (docs/design.md "Word list" and "Meeting word fixes"): "cloud" in "I asked cloud to refactor the parser" is
/// "Claude", in "we moved the backups to the cloud" it stays. The model is shown the passage around the place, marked,
/// and (for a meeting) its title, and asked which of the two the speaker said; only a reply that is exactly the term
/// (ignoring case, the spaces and marks around it) replaces that place, by the term and nothing else. Any other reply
/// (the word itself, another word, a sentence) keeps the place as written, and so does a model that fails or does not
/// answer in time. A fresh session per question, so places never steer each other. Dictation's fix (`TranscriptFixer`)
/// and the meeting word-fix stage both ask this way.
public enum HeardAsJudge {
    /// One place to decide.
    public struct Question: Sendable, Equatable {
        /// The meeting's title (`SessionManifest.name`); nil for dictation.
        public var title: String?
        /// The passage before the place.
        public var before: String
        /// The words as written there ("cloud").
        public var heard: String
        public var after: String
        /// The term as it would be written there ("Claude").
        public var term: String

        public init(title: String?, before: String, heard: String, after: String, term: String) {
            self.title = title; self.before = before; self.heard = heard; self.after = after; self.term = term
        }
    }

    /// Characters of context kept before and after the place.
    public static let contextBefore = 300
    public static let contextAfter = 200
    /// A meeting segment of fewer words than this gets the end of the segment before it and the start of the one after.
    public static let shortSegmentWords = 8
    /// Characters of a neighbouring segment kept for a short segment.
    public static let neighbourCharacters = 120

    /// Measured on invented sentences with Apple's on-device model (greedy): asked to choose between the word and the
    /// term, it never put the term where it was not meant (13 of 15 single sentences right; 7 of 10 sentences of an
    /// invented meeting, the term found in 3 of the 6 places where it was meant); asked yes or no, it answered no
    /// every time. Given the neighbouring sentences too (that meeting's topics alternate), it found the term in 2 of 6
    /// and once put it where it was not, so a meeting's neighbouring segments come only with a segment too short to say
    /// much on its own. Dictation's rewrite, told the pairs as candidates, put "Claude" in 2 of 3 sentences about the
    /// cloud, which is why dictation asks this way too.
    static let instructions = """
        You check a transcript made by speech recognition, which sometimes writes a name, product or jargon term \
        the speakers use as a common word that sounds alike. A passage has one place marked [[like this]]. Two words \
        could stand there: the word as recognized, and the term. Choose the one the speaker most likely said, from \
        the meaning of the passage and the meeting's title when there is one. Reply with only that word.
        """

    static func prompt(_ question: Question) -> String {
        let passage = [question.before, "[[\(question.heard)]]", question.after]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let title = question.title.map { "Meeting title: \($0)\n" } ?? ""
        return title + """
            Passage: \(passage)
            At [[\(question.heard)]], did the speaker say "\(question.heard)" or "\(question.term)"?
            """
    }

    /// Whether `reply` chose the term: exactly the term, ignoring case, whitespace, quotes and closing marks around it.
    static func choosesTerm(_ reply: String, term: String) -> Bool {
        let trimming = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let answer = reply.trimmingCharacters(in: trimming).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let wanted = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !answer.isEmpty && answer.compare(wanted, options: [.caseInsensitive]) == .orderedSame
    }

    public enum Answer: Sendable, Equatable {
        /// The model chose the term.
        case term
        /// The model chose the word as written, or replied anything else.
        case keep
        case timedOut
        /// The model failed, or the asking task was cancelled.
        case failed
    }

    /// Asks `model`, within `timeout`. A cancelled task gets `.failed` at once; the caller checks for cancellation.
    public static func ask(_ question: Question, model: @escaping TranscriptFixer.Model,
                           timeout: Duration) async -> Answer {
        let instructions = Self.instructions
        let prompt = Self.prompt(question)
        switch await TranscriptFixer.firstOf(timeout, { try await model(instructions, prompt) }) {
        case .value(let reply): return choosesTerm(reply, term: question.term) ? .term : .keep
        case .timedOut: return .timedOut
        case .failed: return .failed
        }
    }

    /// The context of a place at `range` (UTF-16) of `text`, a segment's or a chunk's text: the text before and after
    /// it, and, for a text of fewer than `shortSegmentWords` words, the end of `previous` and the start of `next` (a
    /// meeting's segments before and after it in time, `neighbourCharacters` each); cut at a word boundary to
    /// `contextBefore` and `contextAfter` characters.
    public static func context(of range: Range<Int>, in text: String, previous: String? = nil, next: String? = nil)
        -> (before: String, after: String) {
        let utf16 = Array(text.utf16)
        let own = String(decoding: utf16[0..<range.lowerBound], as: UTF16.self)
        let rest = String(decoding: utf16[range.upperBound...], as: UTF16.self)
        let short = text.split(whereSeparator: \.isWhitespace).count < shortSegmentWords
        let earlier = short ? previous.map { suffix($0, neighbourCharacters) } : nil
        let later = short ? next.map { prefix($0, neighbourCharacters) } : nil
        let before = [earlier, own].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let after = [rest, later].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (suffix(before, contextBefore), prefix(after, contextAfter))
    }

    /// The last `count` characters of `text`, starting at a word.
    static func suffix(_ text: String, _ count: Int) -> String {
        guard text.count > count else { return text }
        let cut = String(text.suffix(count))
        guard let space = cut.firstIndex(where: \.isWhitespace) else { return cut }
        return String(cut[space...]).trimmingCharacters(in: .whitespaces)
    }

    /// The first `count` characters of `text`, ending at a word.
    static func prefix(_ text: String, _ count: Int) -> String {
        guard text.count > count else { return text }
        let cut = String(text.prefix(count))
        guard let space = cut.lastIndex(where: \.isWhitespace) else { return cut }
        return String(cut[..<space]).trimmingCharacters(in: .whitespaces)
    }
}
