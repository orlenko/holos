import Foundation

/// The search field at the top of Settings (docs/design.md "Main window"): a fuzzy match of a query against each
/// setting's title, caption, and keywords, free of AppKit so it can be tested.
///
/// Each word of the query must match one of the setting's texts, ignoring case, diacritics, and width. A word
/// matches a text, best first, as the text's start ("mic" in "Microphone"), the start of one of its words ("talk" in
/// "Hold-to-talk shortcut"), inside a word ("phone" in "Microphone", three letters or more), or as letters in order
/// within one word of a title or keyword ("dctn" in "Dictation", three letters or more). A title counts three times,
/// a keyword twice, a caption once, so the setting named by the query ranks above the ones that only mention it.
public enum SettingsSearch {
    /// One searchable setting.
    public struct Entry: Sendable, Equatable {
        public var title: String
        public var caption: String
        public var keywords: [String]

        public init(title: String, caption: String = "", keywords: [String] = []) {
            self.title = title
            self.caption = caption
            self.keywords = keywords
        }
    }

    /// How one query word matches one text, weakest first.
    public enum Match: Int, Comparable, Sendable {
        case subsequence = 1, inside, wordStart, start

        public static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }

        var points: Int {
            switch self {
            case .subsequence: 20
            case .inside: 40
            case .wordStart: 80
            case .start: 100
            }
        }
    }

    /// The shortest query word that may match inside a word or as a subsequence; shorter ones only match the start
    /// of a word.
    static let minimumLooseLength = 3

    /// `text` lowercased, without diacritics, in standard width: "Théme" is "theme".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// The folded words of `text`, split at anything other than letters and digits: "Hold-to-talk" is
    /// ["hold", "to", "talk"].
    public static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// How the query word `word` matches `text`, or nil. `subsequence`: whether letters in order within one word
    /// count (titles and keywords; a caption is too long for it).
    public static func match(_ word: String, in text: String, subsequence: Bool) -> Match? {
        let word = fold(word)
        guard !word.isEmpty else { return nil }
        let textWords = words(text)
        guard let first = textWords.first else { return nil }
        if first.hasPrefix(word) { return .start }
        if textWords.contains(where: { $0.hasPrefix(word) }) { return .wordStart }
        guard word.count >= minimumLooseLength else { return nil }
        if textWords.contains(where: { $0.contains(word) }) { return .inside }
        if subsequence, textWords.contains(where: { isSubsequence(word, of: $0) }) { return .subsequence }
        return nil
    }

    /// The setting's score for `query` (higher is better), or nil when a word of the query matches none of its texts
    /// or the query has no words.
    public static func score(_ query: String, _ entry: Entry) -> Int? {
        let queryWords = words(query)
        guard !queryWords.isEmpty else { return nil }
        var total = 0
        for word in queryWords {
            var best = 0
            if let match = match(word, in: entry.title, subsequence: true) { best = max(best, match.points * 3) }
            for keyword in entry.keywords {
                if let match = match(word, in: keyword, subsequence: true) { best = max(best, match.points * 2) }
            }
            if let match = match(word, in: entry.caption, subsequence: false) { best = max(best, match.points) }
            guard best > 0 else { return nil }
            total += best
        }
        // The whole query as said at the title's start, or among its words: "speech model" for "Speech model".
        let phrase = queryWords.joined(separator: " ")
        let title = words(entry.title).joined(separator: " ")
        if queryWords.count > 1 {
            if title.hasPrefix(phrase) { total += 60 } else if title.contains(phrase) { total += 30 }
        }
        return total
    }

    /// The indices of the entries that match `query`, best first; equal scores keep the entries' order (the page's).
    /// Empty when the query has no words.
    public static func rank(_ query: String, _ entries: [Entry]) -> [Int] {
        entries.indices
            .compactMap { index in score(query, entries[index]).map { (index, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.0)
    }

    /// Whether the best match (what Return goes to) differs between two rankings: a search run again because a
    /// setting's caption changed moves the page only then.
    public static func bestMatchChanged(from previous: [Int], to current: [Int]) -> Bool {
        previous.first != current.first
    }

    /// Whether every character of `word` appears in `text` in order.
    static func isSubsequence(_ word: String, of text: String) -> Bool {
        var remaining = word[...]
        for character in text where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

/// Which chapter of Settings the sidebar marks for a scroll position (docs/design.md "Main window"), free of AppKit
/// so it can be tested. Positions are in the page's coordinates, from its top.
public enum SettingsChapterTracking {
    /// How far below the visible top a chapter's top may be and still count as reached: its heading has come up to
    /// the top of the page.
    public static let reachedMargin = 60.0

    /// The index of the chapter to mark: the last one whose top has reached the visible top. Scrolled to the end,
    /// where the last chapters can never reach the top, it is `chosen` when that chapter's top is in view (the user
    /// chose it in the sidebar, and the page went as far as it can), else the last chapter shown. Nil when no chapter
    /// is shown.
    ///
    /// - Parameters:
    ///   - offset: the visible top.
    ///   - viewport: the visible height.
    ///   - contentHeight: the page's height.
    ///   - tops: each chapter's top, nil while it is hidden (no setting in it matches the search).
    ///   - chosen: the chapter the user chose in the sidebar (or went to with Return), while `keepsChosen` holds;
    ///     never the chapter scrolling marked.
    public static func chapter(offset: Double, viewport: Double, contentHeight: Double, tops: [Double?],
                               chosen: Int?) -> Int? {
        let shown = tops.indices.compactMap { index in tops[index].map { (index, $0) } }
        guard let first = shown.first, let last = shown.last else { return nil }
        let atEnd = contentHeight > viewport && offset + viewport >= contentHeight - 1
        if atEnd {
            if let chosen, tops.indices.contains(chosen), keepsChosen(top: tops[chosen], offset: offset,
                                                                      viewport: viewport) {
                return chosen
            }
            return last.0
        }
        return shown.last(where: { $0.1 <= offset + reachedMargin })?.0 ?? first.0
    }

    /// What the sidebar marks when Settings comes on screen as it was left (⌘, or Settings…): the chapter it shows
    /// (`current`), or nil for the Settings row at the page's top and while a search is open (a filtered page's top
    /// is not the page's, and its cards are only the ones that match).
    public static func markOnShow(searching: Bool, atTop: Bool, current: Int) -> Int? {
        searching || atTop ? nil : current
    }

    /// What the sidebar marks as the user scrolls: the chapter at the top (`chapter`), or nil for the Settings row
    /// while a search is open.
    public static func markWhileScrolling(searching: Bool, chapter: Int) -> Int? {
        searching ? nil : chapter
    }

    /// Whether a chapter the user chose still counts as chosen: its card's top (nil while hidden) is in view. Scrolling
    /// it out of view, either way, ends the choice.
    public static func keepsChosen(top: Double?, offset: Double, viewport: Double) -> Bool {
        guard let top else { return false }
        return top >= offset - 1 && top < offset + viewport
    }

    /// The scroll position that brings a chapter's top to the visible top, `margin` below it, as far as the page
    /// scrolls.
    public static func offset(toShow top: Double, viewport: Double, contentHeight: Double, margin: Double) -> Double {
        max(0, min(top - margin, contentHeight - viewport))
    }
}
