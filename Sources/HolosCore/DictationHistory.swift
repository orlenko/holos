import Foundation

/// One finished dictation that produced text, as the History section and `voiceislocal history` show it
/// (docs/design.md "Dictation history"). Stored only on this Mac, one JSON line per dictation.
public struct DictationRecord: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    /// What happened to the text.
    public enum OutcomeKind: String, Codable, Sendable, CaseIterable {
        /// Written into the focused field through Accessibility.
        case inserted
        /// Typed into the app as keystrokes (terminals, web editors).
        case typed
        /// Not written; the text waited for Copy.
        case needsCopy
        /// A write may have landed without being confirmed.
        case unverified
        /// The app or field changed before Voice is Local could write.
        case targetChanged
    }

    public struct Outcome: Codable, Sendable, Equatable {
        public var kind: OutcomeKind
        /// Why the text was not written (needsCopy, unverified, targetChanged).
        public var reason: String?
        /// Part of the text was written before the rest could not be.
        public var partial: Bool

        public init(kind: OutcomeKind, reason: String? = nil, partial: Bool = false) {
            self.kind = kind
            self.reason = reason
            self.partial = partial
        }

        /// The text went where the user was.
        public var wasWritten: Bool { (kind == .inserted || kind == .typed) && !partial }
    }

    /// What changed the text between the recognizer and the field.
    public struct Fixes: Codable, Sendable, Equatable {
        /// Filler words ("um", "euh") were removed.
        public var fillersRemoved: Bool
        /// Learned corrections applied (each replaced phrase counts once).
        public var corrections: Int
        /// Words Apple Intelligence's on-device fix changed.
        public var aiChangedWords: Int

        public init(fillersRemoved: Bool = false, corrections: Int = 0, aiChangedWords: Int = 0) {
            self.fillersRemoved = fillersRemoved
            self.corrections = corrections
            self.aiChangedWords = aiChangedWords
        }

        public var isEmpty: Bool { !fillersRemoved && corrections == 0 && aiChangedWords == 0 }
    }

    public var schemaVersion: Int
    /// The dictation's utterance ID.
    public var id: UUID
    public var date: Date
    /// The app the dictation was for (its display name); nil when it could not be told.
    public var app: String?
    /// Locale identifier ("fr-CA").
    public var language: String
    /// The text as written, or as offered for Copy when it could not be written.
    public var text: String
    /// The recognizer's text before filler removal, corrections, and Apple Intelligence's fix.
    public var heard: String
    public var fixes: Fixes
    public var outcome: Outcome
    /// Seconds from Listening to release.
    public var seconds: Double
    public var words: Int

    public init(id: UUID, date: Date, app: String?, language: String, text: String, heard: String,
                fixes: Fixes = Fixes(), outcome: Outcome, seconds: Double, words: Int? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.date = date
        self.app = app
        self.language = language
        self.text = text
        self.heard = heard
        self.fixes = fixes
        self.outcome = outcome
        self.seconds = max(0, seconds)
        self.words = words ?? Self.wordCount(text)
    }

    /// True when the text written differs from what was heard (the "Fixed" badge).
    public var wasFixed: Bool { WordDiff.normalized(text) != WordDiff.normalized(heard) }

    /// Words as a reader counts them (letters or digits, apostrophes kept inside words).
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    // MARK: - Texts

    /// "Inserted into Mail", "Typed into Terminal", "Not inserted — <reason> Use Copy."
    public var resultText: String {
        let target = app ?? "the app"
        switch outcome.kind {
        case .inserted where !outcome.partial: return "Inserted into \(target)"
        case .typed where !outcome.partial: return "Typed into \(target)"
        case .inserted, .typed, .needsCopy:
            let reason = Self.sentence(outcome.reason) ?? "The field could not be written."
            return outcome.partial
                ? "Partly written into \(target) — \(reason) Use Copy for the rest."
                : "Not inserted — \(reason) Use Copy."
        case .targetChanged:
            return outcome.partial
                ? "Partly written into \(target) — then the app or field changed. Use Copy for the rest."
                : "Not inserted — the app or field changed before Voice is Local could write. Use Copy."
        case .unverified:
            return "Unverified — check \(target) before using Copy."
        }
    }

    /// "Apple Intelligence changed 1 word · 1 correction · fillers removed", or "None".
    public var fixesText: String {
        var parts: [String] = []
        if fixes.aiChangedWords > 0 {
            parts.append("Apple Intelligence changed \(fixes.aiChangedWords) \(fixes.aiChangedWords == 1 ? "word" : "words")")
        }
        if fixes.corrections > 0 {
            parts.append("\(fixes.corrections) \(fixes.corrections == 1 ? "correction" : "corrections")")
        }
        if fixes.fillersRemoved { parts.append("fillers removed") }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    /// "42 words · 12 seconds".
    public var lengthText: String {
        let seconds = Int(self.seconds.rounded())
        return "\(words) \(words == 1 ? "word" : "words") · \(seconds) \(seconds == 1 ? "second" : "seconds")"
    }

    /// The badge a list row shows: "Not inserted", "Unverified", "Fixed", or none.
    public var badge: String? {
        switch outcome.kind {
        case .needsCopy, .targetChanged: return "Not inserted"
        case .unverified: return "Unverified"
        case .inserted, .typed:
            if outcome.partial { return "Not inserted" }
            return wasFixed ? "Fixed" : nil
        }
    }

    /// Whether the text or app contains `query` (case- and diacritic-insensitive); an empty query matches all.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return text.range(of: query, options: options) != nil
            || heard.range(of: query, options: options) != nil
            || (app?.range(of: query, options: options) != nil)
    }

    private static func sentence(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Reasons end with "use Copy Result." for the menu; History says Use Copy itself.
        for suffix in ["; use Copy Result.", " Use Copy Result.", " use Copy Result."] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text
    }
}

/// How long History keeps dictations (UserDefaults "historyRetention"; 30 days when never set).
public enum HistoryRetention: String, CaseIterable, Sendable {
    case off
    case days7 = "7"
    case days30 = "30"
    case forever

    public static let defaultsKey = "historyRetention"
    public static let standard = HistoryRetention.days30

    /// The saved choice, or 30 days.
    public static func saved(_ raw: String?) -> HistoryRetention {
        raw.flatMap(HistoryRetention.init(rawValue:)) ?? standard
    }

    public var title: String {
        switch self {
        case .off: "Off"
        case .days7: "7 days"
        case .days30: "30 days"
        case .forever: "Forever"
        }
    }

    /// New dictations are recorded.
    public var records: Bool { self != .off }

    /// Records dated before this are removed by a sweep; nil keeps everything (Forever). Off keeps what is there:
    /// turning History off offers to clear it instead.
    public func cutoff(now: Date) -> Date? {
        switch self {
        case .days7: now.addingTimeInterval(-7 * 86_400)
        case .days30: now.addingTimeInterval(-30 * 86_400)
        case .off, .forever: nil
        }
    }

    /// The footer: "Kept on this Mac for 30 days."
    public var footerText: String {
        switch self {
        case .off: "History is off; new dictations are not kept."
        case .days7: "Kept on this Mac for 7 days."
        case .days30: "Kept on this Mac for 30 days."
        case .forever: "Kept on this Mac until you delete them."
        }
    }
}

/// Day headers for the History list: "Today", "Yesterday", then "Monday, September 21".
public enum HistoryDay {
    public static func title(for date: Date, now: Date, calendar: Calendar = .current,
                             locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEMMMMd" : "EEEEMMMMdyyyy")
        return formatter.string(from: date)
    }

    /// Records grouped by day, newest day first; each group newest first.
    public static func groups(_ records: [DictationRecord], now: Date, calendar: Calendar = .current,
                              locale: Locale = .current) -> [(title: String, records: [DictationRecord])] {
        let sorted = records.enumerated().sorted { lhs, rhs in
            // Dates have one-second precision; the file order (append order) breaks ties.
            lhs.element.date != rhs.element.date ? lhs.element.date > rhs.element.date : lhs.offset > rhs.offset
        }.map(\.element)
        var groups: [(title: String, records: [DictationRecord])] = []
        var lastDay: Date?
        for record in sorted {
            let day = calendar.startOfDay(for: record.date)
            if day == lastDay {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append((title(for: record.date, now: now, calendar: calendar, locale: locale), [record]))
                lastDay = day
            }
        }
        return groups
    }
}

/// Word-level differences between the text as heard and the text as written: which heard words changed (for the
/// highlight in History) and how many words a fix changed. Words compare without case and surrounding punctuation.
public enum WordDiff {
    /// Ranges in `old` of the words that are not in `new`.
    public static func changedRanges(in old: String, comparedTo new: String) -> [Range<String.Index>] {
        let a = words(in: old)
        let b = words(in: new)
        let matchedA = lcsMatches(a.map { key(old[$0]) }, b.map { key(new[$0]) }).a
        return a.indices.filter { !matchedA.contains($0) }.map { a[$0] }
    }

    /// How many words changed between `old` and `new`: the larger of the words removed and the words added.
    public static func changedWordCount(from old: String, to new: String) -> Int {
        let a = words(in: old).map { key(old[$0]) }
        let b = words(in: new).map { key(new[$0]) }
        let matches = lcsMatches(a, b)
        return max(a.count - matches.a.count, b.count - matches.b.count)
    }

    /// Lowercased words without punctuation, for "did anything change".
    public static func normalized(_ text: String) -> [String] {
        words(in: text).map { key(text[$0]) }.filter { !$0.isEmpty }
    }

    static func words(in text: String) -> [Range<String.Index>] {
        text.ranges(of: /\S+/).filter { !key(text[$0]).isEmpty }
    }

    static func key(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// Indices of `a` and `b` in one longest common subsequence. Long texts (over 2 000 words) compare position by
    /// position instead, so a very long dictation never costs a large table.
    private static func lcsMatches(_ a: [String], _ b: [String]) -> (a: Set<Int>, b: Set<Int>) {
        guard !a.isEmpty, !b.isEmpty else { return ([], []) }
        guard a.count <= 2_000, b.count <= 2_000 else {
            let same = (0..<min(a.count, b.count)).filter { a[$0] == b[$0] }
            return (Set(same), Set(same))
        }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var matchedA = Set<Int>(), matchedB = Set<Int>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                matchedA.insert(i); matchedB.insert(j)
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (matchedA, matchedB)
    }
}
