import Foundation

/// Calls `onChange` on `queue` when an entry of `folder` is added, removed, or renamed (an atomic save replaces a
/// file by renaming it into place), until the watcher is released. The app watches its corrections this way, so a
/// list changed by `voiceislocal eval apply` is loaded as it runs.
public final class FolderWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    public init?(folder: URL, queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                           eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}

public struct Correction:Codable, Sendable, Equatable, Hashable {
    public var heard: String
    public var meant: String

    public init(heard: String, meant: String) {
        self.heard = heard
        self.meant = meant
    }
}

/// Phrase replacements learned from the user's fixes. Matching is whole-word, case-insensitive,
/// and tolerant of whitespace differences inside a phrase.
public struct CorrectionList: Codable, Sendable, Equatable {
    public private(set) var entries: [Correction] = []

    public init(entries: [Correction] = []) {
        for entry in entries { add(entry) }
    }

    /// `<supportRoot>/corrections.json`, beside `words.json`: Application Support/Holos, or `HOLOS_SUPPORT_DIR` when
    /// set, so a scratch or test support folder never reads or changes the user's real corrections.
    public static var defaultURL: URL {
        HolosPaths.supportRoot.appendingPathComponent("corrections.json")
    }

    /// Words the recognizer should expect: the content words (`SpokenWords.isContent`) of the meant phrases, once
    /// each ignoring case, spelled with a capital when any meant phrase has one. "on Ubuntu", "ubuntu" and "Ubuntu
    /// machine" give "Ubuntu" and "machine": listing "on Ubuntu" or "a bunch of windows" as phrases biased the
    /// recognizer toward words the speaker says everywhere. Function words of both English and French are left out;
    /// `vocabulary(language:)` leaves out only those of the language dictated.
    public var vocabulary: [String] { vocabulary(language: nil) }

    /// `vocabulary` for dictation in `language` (a locale identifier): English dictation keeps "son", a French
    /// function word.
    public func vocabulary(language: String?) -> [String] {
        vocabulary { SpokenWords.isContent($0, language: language) }
    }

    /// `vocabulary` for a meeting in `languages` (locale identifiers, the meeting's languages): a word that carries
    /// meaning in any of them stays, so an English meeting keeps "son". No languages (the recorder's default) leaves
    /// out the function words of both English and French.
    public func vocabulary(languages: [String]) -> [String] {
        guard !languages.isEmpty else { return vocabulary(language: nil) }
        return vocabulary { word in languages.contains { SpokenWords.isContent(word, language: $0) } }
    }

    private func vocabulary(keeping isContent: (String) -> Bool) -> [String] {
        var order: [String] = []
        var spelling: [String: String] = [:]
        for entry in entries {
            for match in entry.meant.matches(of: /[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/) {
                let word = String(match.output)
                guard isContent(word) else { continue }
                let key = word.lowercased()
                if let known = spelling[key] {
                    if !known.contains(where: \.isUppercase), word.contains(where: \.isUppercase) { spelling[key] = word }
                } else {
                    order.append(key)
                    spelling[key] = word
                }
            }
        }
        return order.compactMap { spelling[$0] }
    }

    /// Adds or replaces the entry for the same heard phrase. Blank or identical pairs are ignored.
    public mutating func add(_ correction: Correction) {
        let heard = correction.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = correction.meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return }
        let key = Self.normalized(heard)
        entries.removeAll { Self.normalized($0.heard) == key }
        entries.append(Correction(heard: heard, meant: meant))
    }

    public mutating func remove(_ correction: Correction) {
        entries.removeAll { $0 == correction }
    }

    /// Reconciles rules introduced by live editing with the rules its latest edits still confirm. `managed` is every
    /// exact rule a live edit has introduced; removing those first lets the desired rules be rebuilt in edit order.
    /// A desired rule already supplied by an unrelated, pre-existing entry stays implicit. The returned rules are
    /// newly managed ones, excluding rules already recorded in `managed`, so later reconciliation can distinguish a
    /// pre-existing rule from one live editing may remove when its last dependent edit is undone.
    @discardableResult
    public mutating func reconcileLearned(_ managed: [Correction], with desired: [Correction]) -> [Correction] {
        let managed = managed.compactMap(Self.storedCorrection)
        for correction in managed { remove(correction) }
        let alreadyManaged = Set(managed)
        var introduced: [Correction] = []
        for correction in desired.compactMap(Self.storedCorrection) {
            guard apply(to: correction.heard) != correction.meant else { continue }
            add(correction)
            if !alreadyManaged.contains(correction) { introduced.append(correction) }
        }
        return introduced.filter(entries.contains)
    }

    private static func storedCorrection(_ correction: Correction) -> Correction? {
        let heard = correction.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = correction.meant.trimmingCharacters(in: .whitespacesAndNewlines)
        return !heard.isEmpty && !meant.isEmpty && heard != meant ? Correction(heard: heard, meant: meant) : nil
    }

    /// Other entries `replace(_:with:)` would drop because they have the same heard phrase as `new`.
    public func conflicts(replacing old: Correction, with new: Correction) -> [Correction] {
        let key = Self.normalized(new.heard.trimmingCharacters(in: .whitespacesAndNewlines))
        return entries.filter { $0 != old && Self.normalized($0.heard) == key }
    }

    /// Edits `old` in place, keeping its position. Returns false, changing nothing, for a blank or identical
    /// pair. Another entry for the same heard phrase is dropped, as `add` does; an `old` that is no longer in
    /// the list (removed meanwhile) makes this an `add`.
    @discardableResult
    public mutating func replace(_ old: Correction, with new: Correction) -> Bool {
        let heard = new.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = new.meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return false }
        guard let index = entries.firstIndex(of: old) else {
            add(Correction(heard: heard, meant: meant))
            return true
        }
        let key = Self.normalized(heard)
        entries[index] = Correction(heard: heard, meant: meant)
        entries = entries.indices.filter { $0 == index || Self.normalized(entries[$0].heard) != key }
            .map { entries[$0] }
        return true
    }

    public func apply(to text: String) -> String {
        applyCounting(to: text).text
    }

    /// `apply`, and how many phrases it replaced (History's "2 corrections").
    public func applyCounting(to text: String) -> (text: String, count: Int) {
        let found = matches(in: text)
        guard !found.isEmpty else { return (text, 0) }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in found {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += match.meant
            cursor = match.range.location + match.range.length
        }
        return (output + source.substring(from: cursor), found.count)
    }

    /// One place `apply` replaces: the UTF-16 range of the heard phrase as written, and the text it becomes.
    public struct Match: Sendable, Equatable {
        /// UTF-16 range in the text searched.
        public var range: NSRange
        /// The heard phrase as the text has it.
        public var heard: String
        /// The meant phrase, with a capital the sentence gave the heard phrase carried over.
        public var meant: String
        /// The entry that matched.
        public var correction: Correction
    }

    /// Where `apply` replaces in `text`, in order and without overlaps: whole words and phrases, in any case and
    /// spacing, the longest heard phrase first. The meant phrase takes a capital the sentence gave the heard phrase
    /// ("Bundu" at a sentence start becomes "Ubuntu"), unless the saved heard phrase has one ("Mac OS" → "macOS" stays
    /// lowercase). The meeting word-fix stage applies corrections through this, as dictation does.
    public func matches(in text: String) -> [Match] {
        guard !entries.isEmpty, let pattern = matcher() else { return [] }
        let replacements = Dictionary(entries.map { (Self.normalized($0.heard), $0) },
                                      uniquingKeysWith: { _, last in last })
        let source = text as NSString
        var found: [Match] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let heard = source.substring(with: match.range)
            guard let entry = replacements[Self.normalized(heard)] else { continue }
            var meant = entry.meant
            // A capital the saved phrase lacks came from sentence position, so carry it over; a saved
            // capital ("Mac OS" → "macOS") means the lowercase replacement is deliberate.
            if let first = heard.first, first.isUppercase, entry.heard.first?.isLowercase == true,
               let head = meant.first, head.isLowercase {
                meant = head.uppercased() + meant.dropFirst()
            }
            found.append(Match(range: match.range, heard: heard, meant: meant, correction: entry))
        }
        return found
    }

    /// For text still growing while the user speaks: withholds trailing words that could become the start
    /// of a multi-word phrase once more words arrive, then applies corrections to the rest. Withholding is
    /// decided on the uncorrected text, so a shorter rule cannot consume the start of a longer one.
    public func applyWithholdingPartialMatch(to text: String) -> String {
        let words = Self.words(in: text)
        var withheld = 0
        for entry in entries {
            let heard = Self.normalized(entry.heard).split(separator: " ").map(String.init)
            guard heard.count > 1 else { continue }
            for length in stride(from: min(heard.count - 1, words.count), to: withheld, by: -1) {
                let tail = words.suffix(length).map { text[$0].lowercased() }
                if tail == Array(heard.prefix(length)) { withheld = length; break }
            }
        }
        guard withheld > 0 else { return apply(to: text) }
        let cut = words[words.count - withheld].lowerBound
        return apply(to: String(text[..<cut]).trimmingCharacters(in: .whitespaces))
    }

    /// Word-level substitutions between a transcript and the user's fixed version. Pure insertions,
    /// deletions, and rewrites longer than a few words are ignored as rewording rather than mishearing.
    /// A single misheard word that is itself a dictionary word keeps a neighbouring word as context,
    /// so "bull" → "pull" is learned as "bull request" → "pull request" rather than rewriting every "bull".
    public static func learn(original: String, corrected: String,
                             isDictionaryWord: (String) -> Bool = { _ in false }) -> [Correction] {
        learnReportingDeclined(original: original, corrected: corrected, isDictionaryWord: isDictionaryWord).learned
    }

    /// Like `learn`, and also returns single dictionary-word swaps that were not learned because no
    /// neighbouring word could anchor them, so the caller can explain why and offer to add them by hand.
    public static func learnReportingDeclined(original: String, corrected: String,
                                              isDictionaryWord: (String) -> Bool = { _ in false })
        -> (learned: [Correction], declined: [Correction]) {
        let a = tokens(in: original)
        let b = tokens(in: corrected)
        guard !a.isEmpty, !b.isEmpty, a.count <= 2_000, b.count <= 2_000 else { return ([], []) }
        let aText = a.map { String(original[$0]) }
        let bText = b.map { String(corrected[$0]) }

        // Longest common subsequence over exact tokens.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = aText[i] == bText[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var hunks: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, aText[i] == bText[j] { i += 1; j += 1; continue }
            let (startA, startB) = (i, j)
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, aText[i] == bText[j] { break }
                if j == b.count || (i < a.count && table[i + 1][j] >= table[i][j + 1]) { i += 1 } else { j += 1 }
            }
            hunks.append((startA..<i, startB..<j))
        }

        let maximumTokens = 6
        var learned: [Correction] = []
        var declined: [Correction] = []
        for (rangeA, rangeB) in hunks {
            guard !rangeA.isEmpty, !rangeB.isEmpty,
                  rangeA.count <= maximumTokens, rangeB.count <= maximumTokens,
                  rangeA.contains(where: { isWord(aText[$0]) }),
                  rangeB.contains(where: { isWord(bText[$0]) }) else { continue }
            var spanA = rangeA, spanB = rangeB
            if rangeA.count == 1, isDictionaryWord(aText[rangeA.lowerBound]) {
                // Neighbours are shared by both texts because the hunk is bounded by equal tokens.
                if spanA.upperBound < a.count, isWord(aText[spanA.upperBound]) {
                    spanA = spanA.lowerBound..<spanA.upperBound + 1
                    spanB = spanB.lowerBound..<spanB.upperBound + 1
                } else if spanA.lowerBound > 0, isWord(aText[spanA.lowerBound - 1]) {
                    spanA = spanA.lowerBound - 1..<spanA.upperBound
                    spanB = spanB.lowerBound - 1..<spanB.upperBound
                } else {
                    // No neighbouring word: a bare dictionary-word rule would rewrite unrelated text.
                    let meant = corrected[b[rangeB.lowerBound].lowerBound..<b[rangeB.upperBound - 1].upperBound]
                    declined.append(Correction(heard: aText[rangeA.lowerBound], meant: String(meant)))
                    continue
                }
            }
            let heard = String(original[a[spanA.lowerBound].lowerBound..<a[spanA.upperBound - 1].upperBound])
            let meant = String(corrected[b[spanB.lowerBound].lowerBound..<b[spanB.upperBound - 1].upperBound])
            learned.append(Correction(heard: heard, meant: meant))
        }
        return (learned, declined)
    }

    public static func load(from url: URL) throws -> CorrectionList {
        guard FileManager.default.fileExists(atPath: url.path) else { return CorrectionList() }
        return try JSONDecoder().decode(CorrectionList.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reads the list at `url`, applies `change`, and saves it when it changed, all under an exclusive lock
    /// (`flock` on "<file>.lock" beside it). Every writer of the file — the app and `voiceislocal eval apply` —
    /// changes it only through here, so one never saves over what another added in between. Returns the list as
    /// saved (or as read, when `change` left it alone) and what `change` returned. Nothing is written when the
    /// file cannot be read.
    public static func update<T>(at url: URL, _ change: (inout CorrectionList) throws -> T) throws
        -> (list: CorrectionList, result: T) {
        try withFileLock(for: url) {
            var list = try load(from: url)
            let before = list
            let result = try change(&list)
            if list != before { try list.save(to: url) }
            return (list, result)
        }
    }

    /// Runs `body` holding the exclusive lock of the corrections file at `url` (waits for another holder).
    public static func withFileLock<T>(for url: URL, _ body: () throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockPath = folder.appendingPathComponent(url.lastPathComponent + ".lock").path
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: lockPath])
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            // A volume without flock (some network shares) fails too: changing the list unlocked could lose what
            // another writer added in between.
            guard errno == EINTR else {
                throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: lockPath])
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func matcher() -> NSRegularExpression? {
        let alternatives = entries.map(\.heard)
            .sorted { $0.count > $1.count }
            .map { $0.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+") }
        let pattern = "(?<![\\p{L}\\p{N}'’])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}'’])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func words(in text: String) -> [Range<String.Index>] {
        text.ranges(of: /\S+/)
    }

    /// Words (letters, digits, apostrophes) and single punctuation marks.
    private static func tokens(in text: String) -> [Range<String.Index>] {
        text.ranges(of: /[\p{L}\p{N}'’]+|[^\s\p{L}\p{N}'’]/)
    }

    private static func isWord(_ token: String) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }
}
