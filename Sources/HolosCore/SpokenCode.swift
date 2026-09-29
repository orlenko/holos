import Foundation

/// Spoken paths and commands written as code (Settings › Dictation › "Write spoken paths and commands as code"):
/// "scripts slash restart dash app dot es aytch" is written `scripts/restart-app.sh`, "slash Q C" `/qc`.
///
/// A code token is a run of characters without spaces that holds at least one symbol of `symbols` and at least one
/// letter, and whose parts are not all function words (`/the` is "slash the", a verb and an article). Its spoken
/// form is its symbols and its parts in order: each symbol said as one of its words ("slash", "dot", "dash",
/// "underscore"…, `symbolWords`) or written as the symbol itself, each part said as its words (up to three joined:
/// "transcript fixer" for `transcriptfixer`, case aside), its letters spelled ("S. H.", "es aytch", "Q C" for
/// `sh`, `qc`), or its digits said ("one" for `1`). A recognizer's all-capitals run of four letters or more may be
/// one letter off (`ZHRC` for `zshrc`); no other word may. "@" stands only between two parts.
///
/// This is the grammar both steps follow: the model proposes code spans (`SpokenCodeFormatter`), and a span is kept
/// only when its source is a spoken form of its token (`says`); without the model, `fallback` finds unambiguous runs
/// on its own.
public enum SpokenCode {
    // MARK: - Words

    /// Words that say a symbol, folded (`fold`). `strong`: a word rarely used otherwise in dictated prose ("slash",
    /// "dot", "dash", "underscore"...), which alone asks the model, holds back the end of a streamed chunk, and forms
    /// a run without the model (`fallback`); "at", "plus", "equals" or "period" count only inside a span the model
    /// proposes.
    struct SymbolWord: Sendable {
        let words: [String]
        let symbols: String
        let strong: Bool

        init(_ words: String, _ symbols: String, strong: Bool = false) {
            self.words = words.split(separator: " ").map(String.init)
            self.symbols = symbols
            self.strong = strong
        }
    }

    /// The characters a code token may hold besides letters and digits.
    public static let symbols: Set<Character> = ["/", "\\", ".", "-", "_", "~", ":", "@", "*", "=", "+", "#", "$", "|"]

    static let englishWords: [SymbolWord] = [
        .init("slash", "/", strong: true), .init("forward slash", "/", strong: true),
        .init("backslash", "\\", strong: true), .init("back slash", "\\", strong: true),
        .init("dot", ".", strong: true), .init("period", "."),
        .init("dash", "-", strong: true), .init("hyphen", "-", strong: true), .init("minus", "-"),
        .init("double dash", "--", strong: true), .init("double hyphen", "--", strong: true),
        .init("underscore", "_", strong: true), .init("under score", "_", strong: true),
        .init("tilde", "~", strong: true),
        .init("colon", ":"), .init("at", "@"), .init("star", "*"), .init("asterisk", "*"),
        .init("equals", "="), .init("equal", "="), .init("plus", "+"), .init("hash", "#"), .init("pound", "#"),
        .init("hashtag", "#"), .init("dollar", "$"), .init("pipe", "|"),
    ]

    static let frenchWords: [SymbolWord] = [
        .init("slash", "/", strong: true), .init("barre oblique", "/", strong: true),
        .init("antislash", "\\", strong: true), .init("barre oblique inversee", "\\", strong: true),
        .init("point", "."),
        .init("tiret", "-", strong: true), .init("moins", "-"), .init("double tiret", "--", strong: true),
        .init("tiret bas", "_", strong: true), .init("underscore", "_", strong: true),
        .init("tilde", "~", strong: true),
        .init("deux points", ":"), .init("arobase", "@"), .init("arobas", "@"), .init("etoile", "*"),
        .init("asterisque", "*"), .init("egal", "="), .init("egale", "="), .init("plus", "+"), .init("diese", "#"),
        .init("dollar", "$"), .init("pipe", "|"), .init("barre verticale", "|"),
    ]

    /// The symbol words of `language` (a locale identifier): English, French, or both when it is not given or is
    /// another one. Longer phrases first, so "tiret bas" is tried before "tiret".
    static func symbolWords(for language: String?) -> [SymbolWord] {
        let words: [SymbolWord] = switch language.map(DictationLanguage.languageCode) {
        case "en": englishWords
        case "fr": frenchWords
        default: englishWords + frenchWords
        }
        return words.sorted { $0.words.count > $1.words.count }
    }

    /// English letter names, and whether the name is also a common word ("see", "are", "you"), which only a model's
    /// span may read as a letter.
    static let letterNames: [String: (letter: Character, common: Bool)] = [
        "bee": ("b", true), "be": ("b", true), "cee": ("c", false), "see": ("c", true), "sea": ("c", true),
        "dee": ("d", false), "ef": ("f", false), "eff": ("f", false), "gee": ("g", false), "aitch": ("h", false),
        "aych": ("h", false), "aytch": ("h", false), "haitch": ("h", false), "eye": ("i", true), "jay": ("j", false),
        "kay": ("k", false), "el": ("l", false), "ell": ("l", false), "em": ("m", false), "en": ("n", false),
        "oh": ("o", true), "pee": ("p", false), "pea": ("p", true), "cue": ("q", false), "queue": ("q", true),
        "ar": ("r", false), "are": ("r", true), "es": ("s", false), "ess": ("s", false), "tee": ("t", false),
        "tea": ("t", true), "you": ("u", true), "vee": ("v", false), "ex": ("x", false), "why": ("y", true),
        "wye": ("y", false), "zed": ("z", false), "zee": ("z", false),
    ]

    static func letterName(_ word: String, language: String?) -> (letter: Character, common: Bool)? {
        language.map(DictationLanguage.languageCode) == "fr" ? nil : letterNames[word]
    }

    /// Digit words, folded. "one", "un" and "une" are left out of runs found without the model (`fallback`).
    static let digitWords: [String: Character] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "un": "1", "une": "1", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5",
        "sept": "7", "huit": "8", "neuf": "9",
    ]

    /// Lowercased, without diacritics.
    static func fold<S: StringProtocol>(_ text: S) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    /// Whether `text` has a strong symbol word (`SymbolWord.strong`): only then is the model asked.
    public static func mayContainCode(_ text: String, language: String? = nil) -> Bool {
        let strong = Set(symbolWords(for: language).filter(\.strong).flatMap(\.words))
        return text.matches(of: /[\p{L}]+/).contains { strong.contains(fold($0.output)) }
    }

    /// Localized names of the terminals `KeystrokeTarget` types into, for Run Again, which knows a dictation's app
    /// only by name: a code token typed into a terminal is never wrapped in backticks.
    public static let terminalAppNames: Set<String> = [
        "terminal", "iterm", "iterm2", "ghostty", "wezterm", "kitty", "alacritty", "warp",
    ]

    public static func isTerminal(appName: String?) -> Bool {
        appName.map { terminalAppNames.contains($0.lowercased()) } ?? false
    }

    // MARK: - Speaking a token

    enum Element: Equatable {
        case symbol(Character)
        /// Letters and digits, folded.
        case part(String)
    }

    /// `token` as symbols and parts; nil when it has a space, a backtick, or a character that is neither a letter, a
    /// digit nor one of `symbols`.
    static func elements(of token: String) -> [Element]? {
        var result: [Element] = []
        var part = ""
        for character in token {
            if character.isLetter || character.isNumber {
                part.append(character)
            } else if symbols.contains(character) {
                if !part.isEmpty { result.append(.part(fold(part))); part = "" }
                result.append(.symbol(character))
            } else {
                return nil
            }
        }
        if !part.isEmpty { result.append(.part(fold(part))) }
        return result
    }

    /// One way to say `token`: each symbol as its first English word ("slash", "dot"), each part as written, or with
    /// `spelling`, letter by letter in capitals ("S H"). `says(token, verbalize(token))` holds for every token.
    public static func verbalize(_ token: String, spelling: Bool = false) -> String {
        guard let elements = elements(of: token) else { return token }
        return elements.map { element -> String in
            switch element {
            case .symbol(let symbol):
                englishWords.first { $0.symbols == String(symbol) }?.words.joined(separator: " ") ?? String(symbol)
            case .part(let part):
                spelling ? part.uppercased().map(String.init).joined(separator: " ") : part
            }
        }.joined(separator: " ")
    }

    /// A spoken word, symbol or other character of a span's source.
    struct Piece {
        enum Kind: Equatable { case word, symbol(Character), other }

        var kind: Kind
        /// A word folded; empty otherwise.
        var folded: String
        /// A word as written.
        var raw: Substring
        /// A "." straight after a one-letter word ("S."): the mark of a spelled letter, or a dot.
        var afterLetter = false
    }

    static func pieces(of text: Substring) -> [Piece] {
        var result: [Piece] = []
        var index = text.startIndex
        var spaced = true
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                spaced = true
                index = text.index(after: index)
                continue
            }
            if character.isLetter || character.isNumber {
                var end = index
                while end < text.endIndex, text[end].isLetter || text[end].isNumber { end = text.index(after: end) }
                result.append(Piece(kind: .word, folded: fold(text[index..<end]), raw: text[index..<end]))
                index = end
            } else {
                let afterLetter = !spaced && character == "." && result.last?.kind == .word
                    && result.last?.raw.count == 1 && result.last?.raw.first?.isLetter == true
                result.append(Piece(kind: symbols.contains(character) ? .symbol(character) : .other, folded: "",
                                    raw: text[index...index], afterLetter: afterLetter))
                index = text.index(after: index)
            }
            spaced = false
        }
        return result
    }

    /// Most words joined into one part ("transcript fixer" for `transcriptfixer`).
    static let maximumJoinedWords = 3

    /// Whether `source`, what the speaker said, is a spoken form of `token` (see `SpokenCode`): every symbol said as
    /// its word or written as itself, in order, and every part said as its words, letters or digits. Nothing else
    /// may be in `source`: no word, mark or symbol the token does not have.
    public static func says(_ token: String, _ source: Substring, language: String? = nil) -> Bool {
        guard token.count <= 200, let elements = elements(of: token) else { return false }
        let pieces = pieces(of: source)
        guard pieces.count <= 120 else { return false }
        return Matcher(elements: elements, pieces: pieces, language: language).match(0, 0)
    }

    /// The search behind `says`, remembering the states that failed.
    final class Matcher {
        let elements: [Element]
        let pieces: [Piece]
        let language: String?
        let words: [SymbolWord]
        private var failed = Set<[Int]>()

        init(elements: [Element], pieces: [Piece], language: String?) {
            self.elements = elements
            self.pieces = pieces
            self.language = language
            words = SpokenCode.symbolWords(for: language)
        }

        /// Whether elements from `element` on are said by pieces from `piece` on, to the end.
        func match(_ element: Int, _ piece: Int) -> Bool {
            guard element < elements.count else { return piece == pieces.count }
            let key = [element, piece, -1, 0]
            if failed.contains(key) { return false }
            let found: Bool
            switch elements[element] {
            case .symbol(let symbol): found = matchSymbol(symbol, element, piece)
            case .part(let part): found = matchPart(Array(part), element, piece, 0, 0)
            }
            if !found { failed.insert(key) }
            return found
        }

        /// The words from `piece` on, when they are `phrase`.
        private func says(_ phrase: [String], at piece: Int) -> Bool {
            guard piece + phrase.count <= pieces.count else { return false }
            return phrase.indices.allSatisfy { pieces[piece + $0].kind == .word && pieces[piece + $0].folded == phrase[$0] }
        }

        private func matchSymbol(_ symbol: Character, _ element: Int, _ piece: Int) -> Bool {
            if piece < pieces.count, pieces[piece].kind == .symbol(symbol), match(element + 1, piece + 1) {
                return true
            }
            for word in words where word.symbols.first == symbol && says(word.words, at: piece) {
                // "double dash" says two symbols.
                let count = word.symbols.count
                guard element + count <= elements.count,
                      (0..<count).allSatisfy({ elements[element + $0] == .symbol(symbol) }) else { continue }
                if match(element + count, piece + word.words.count) { return true }
            }
            return false
        }

        /// Whether `part` from `offset` on, and the elements after it, are said by pieces from `piece` on;
        /// `joined` counts the words of more than one letter the part has taken so far.
        private func matchPart(_ part: [Character], _ element: Int, _ piece: Int, _ offset: Int,
                               _ joined: Int) -> Bool {
            let key = [element, piece, offset, joined]
            if failed.contains(key) { return false }
            var found = false
            defer { if !found { failed.insert(key) } }
            if offset == part.count {
                // The mark of a spelled letter may close the part ("S. H." for `sh`).
                if piece < pieces.count, pieces[piece].afterLetter,
                   matchPart(part, element, piece + 1, offset, joined) {
                    found = true
                    return true
                }
                found = match(element + 1, piece)
                return found
            }
            guard piece < pieces.count else { return false }
            let current = pieces[piece]
            if current.afterLetter, offset > 0, matchPart(part, element, piece + 1, offset, joined) {
                found = true
                return true
            }
            guard current.kind == .word else { return false }
            let word = Array(current.folded)
            // The word as it is.
            if word.count > 1 ? joined < maximumJoinedWords : true,
               part[offset...].starts(with: word),
               matchPart(part, element, piece + 1, offset + word.count, joined + (word.count > 1 ? 1 : 0)) {
                found = true
                return true
            }
            // A letter's name or a digit's word.
            let spoken = SpokenCode.letterName(current.folded, language: language)?.letter
                ?? SpokenCode.digitWords[current.folded]
            if let spoken, part[offset] == spoken, matchPart(part, element, piece + 1, offset + 1, joined) {
                found = true
                return true
            }
            // "double you" for "w".
            if current.folded == "double", piece + 1 < pieces.count, ["you", "u"].contains(pieces[piece + 1].folded),
               part[offset] == "w", matchPart(part, element, piece + 2, offset + 1, joined) {
                found = true
                return true
            }
            // A recognizer's all-capitals run for the whole part, one letter off ("ZHRC" for `zshrc`).
            if offset == 0, word.count >= 4, current.raw.allSatisfy({ $0.isUppercase }),
               SpokenWords.editDistance(word, part) <= 1, match(element + 1, piece + 1) {
                found = true
                return true
            }
            return false
        }
    }

    /// Why a token said by `source` is still not code: nil when it is. It needs a symbol and a letter, a symbol word
    /// in `source` (a span with none only wraps what was already written: "e.g." is not `e.g.`), parts that are
    /// not all function words of `language` (`/the`), and "@" only between two parts.
    static func isCode(_ token: String, source: Substring, language: String?) -> Bool {
        guard let elements = elements(of: token), elements.contains(where: { if case .symbol = $0 { true } else { false } }),
              token.contains(where: \.isLetter) else { return false }
        let parts = elements.compactMap { element -> String? in if case .part(let part) = element { part } else { nil } }
        let stop = SpokenWords.stopWords(for: language).union(shortFunctionWords)
        guard !parts.allSatisfy({ stop.contains($0) }) else { return false }
        for (index, element) in elements.enumerated() where element == .symbol("@") {
            guard index > 0, index + 1 < elements.count, case .part = elements[index - 1],
                  case .part = elements[index + 1] else { return false }
        }
        let symbolFirstWords = Set(symbolWords(for: language).compactMap(\.words.first))
        return pieces(of: source).contains { $0.kind == .word && symbolFirstWords.contains($0.folded) }
    }

    /// Function words of fewer than three letters, which `SpokenWords.stopWords` leaves out.
    static let shortFunctionWords: Set<String> = [
        "a", "an", "i", "in", "on", "to", "of", "is", "it", "at", "as", "or", "if", "so", "be", "by", "he", "me",
        "we", "my", "up", "do", "us", "le", "la", "de", "du", "un", "et", "en", "au", "il", "je", "tu", "ce", "se",
    ]

    /// Whether `token` may replace `source`: said by it (`says`) and code (`isCode`).
    public static func accepts(_ token: String, for source: Substring, language: String? = nil) -> Bool {
        isCode(token, source: source, language: language) && says(token, source, language: language)
    }

    // MARK: - A model's reply

    /// One code span: the text of the chunk it replaces, and the token written there.
    public struct Span: Sendable, Equatable {
        public var range: Range<String.Index>
        public var token: String
    }

    /// A span the model proposed, and whether it passed (`accepts` and the frozen words).
    struct Proposal {
        var span: Span
        var accepted: Bool
    }

    /// Most code spans read from one reply.
    static let maximumSpans = 20
    /// Longest source a span may replace, in characters.
    static let maximumSource = 300

    /// The spans of `reply`, the model's copy of `original` with code tokens between backticks, each with the text of
    /// `original` it replaces. Nil when the reply is anything else: the text outside the backticks must be
    /// `original`'s, character for character but for the length of runs of spaces; each span replaces a stretch of
    /// `original` that starts and ends with a non-space. Of several ways to read the spans, the one with the most
    /// spans passing `accepted` wins.
    static func proposals(original: String, reply: String,
                          accepted: (Range<String.Index>, String) -> Bool) -> [Proposal]? {
        let parts = reply.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count % 2 == 1, parts.count / 2 <= maximumSpans else { return nil }
        let texts = stride(from: 0, to: parts.count, by: 2).map { parts[$0] }
        let codes = stride(from: 1, to: parts.count, by: 2).map { String(parts[$0]) }
        guard let start = consume(texts[0], in: original, from: original.startIndex) else { return nil }
        if codes.isEmpty { return start == original.endIndex ? [] : nil }
        struct Key: Hashable { let span: Int; let at: String.Index }
        var memo: [Key: (score: Int, proposals: [Proposal])?] = [:]
        func search(_ span: Int, _ at: String.Index) -> (score: Int, proposals: [Proposal])? {
            if let known = memo[Key(span: span, at: at)] { return known }
            var best: (score: Int, proposals: [Proposal])?
            let limit = original.index(at, offsetBy: maximumSource, limitedBy: original.endIndex) ?? original.endIndex
            var end = at
            while end < limit {
                end = original.index(after: end)
                let source = original[at..<end]
                guard let first = source.first, let last = source.last, !first.isWhitespace, !last.isWhitespace,
                      !source.contains(where: \.isNewline) else { continue }
                guard let next = consume(texts[span + 1], in: original, from: end) else { continue }
                let rest: (score: Int, proposals: [Proposal])?
                if span + 1 == codes.count {
                    rest = next == original.endIndex ? (0, []) : nil
                } else {
                    rest = search(span + 1, next)
                }
                guard let rest else { continue }
                let ok = accepted(at..<end, codes[span])
                let score = rest.score + (ok ? 1 : 0)
                if best.map({ score > $0.score }) ?? true {
                    best = (score, [Proposal(span: Span(range: at..<end, token: codes[span]), accepted: ok)]
                        + rest.proposals)
                }
            }
            memo[Key(span: span, at: at)] = best
            return best
        }
        return search(0, start)?.proposals
    }

    /// Where `text` ends when it is found in `original` at `start`, a run of spaces matching any run of spaces; nil
    /// when it is not there.
    static func consume(_ text: Substring, in original: String, from start: String.Index) -> String.Index? {
        var i = text.startIndex, j = start
        while i < text.endIndex {
            if text[i].isWhitespace {
                guard j < original.endIndex, original[j].isWhitespace else { return nil }
                while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
                while j < original.endIndex, original[j].isWhitespace { j = original.index(after: j) }
            } else {
                guard j < original.endIndex, original[j] == text[i] else { return nil }
                i = text.index(after: i)
                j = original.index(after: j)
            }
        }
        return j
    }

    /// `original` with each span's text replaced by its token, between backticks when `backticks`.
    public static func render(_ original: String, spans: [Span], backticks: Bool) -> String {
        var result = ""
        var cursor = original.startIndex
        for span in spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where span.range.lowerBound >= cursor {
            result += original[cursor..<span.range.lowerBound]
            result += backticks ? "`\(span.token)`" : span.token
            cursor = span.range.upperBound
        }
        return result + original[cursor...]
    }

    // MARK: - Without the model

    /// A word of dictated text, as runs found without the model see it.
    struct Item {
        enum Kind {
            /// A symbol word, and whether it is strong (`SymbolWord.strong`).
            case symbol(String)
            /// Letters and digits, or a word already written with symbols between them ("restart-app").
            case word(String)
            /// Spelled letters ("Q C", "S. H.", "es aytch"), as the letters.
            case letters(String)
            /// Anything else: quotes, brackets, other marks.
            case other
        }

        var kind: Kind
        var range: Range<String.Index>
        /// Clause punctuation (",", ";", ":", "!", "?", a sentence's ".") ends a run after this item.
        var endsClause = false
        /// The item starts a sentence: the text's start, or after ".", "!" or "?".
        var startsSentence = false

        var isPart: Bool {
            switch kind {
            case .word, .letters: true
            case .symbol, .other: false
            }
        }
    }

    /// The items of `text` in `region`, for runs found without the model: symbol words that are strong
    /// (`SymbolWord.strong`), words, spelled letters, and other things.
    static func items(in text: String, region: Range<String.Index>, language: String?) -> [Item] {
        struct Raw {
            var core: Range<String.Index>
            var endsClause: Bool
            var closesSentence: Bool
            var other: Bool
        }
        let region = text[region]
        var raws: [Raw] = []
        let matches = Array(region.matches(of: /\S+/))
        for (position, match) in matches.enumerated() {
            var core = match.range
            var endsClause = false, closesSentence = false
            // A run of capitals with dots ("S.", "S.H.") keeps its dots: they spell letters. The last one's dot also
            // ends the sentence at the end of the text, or before a capitalized word that is not a spelled letter.
            let word = text[core]
            var spelled = word.wholeMatch(of: /(?:\p{Lu}\.)+/) != nil
            if spelled {
                if position + 1 < matches.count {
                    let next = text[matches[position + 1].range]
                    if next.first?.isUppercase == true, next.wholeMatch(of: /\p{Lu}\.?/) == nil { spelled = false }
                } else if match.range.upperBound == text.endIndex {
                    spelled = false
                }
            }
            if !spelled {
                while core.lowerBound < core.upperBound {
                    let last = text[text.index(before: core.upperBound)]
                    guard ",;:!?.…".contains(last) else { break }
                    endsClause = true
                    if ".!?…".contains(last) { closesSentence = true }
                    core = core.lowerBound..<text.index(before: core.upperBound)
                }
            }
            let body = text[core]
            let other = body.isEmpty || !(body.first!.isLetter || body.first!.isNumber)
                || !(body.last!.isLetter || body.last!.isNumber || body.last == ".")
                || body.contains { !($0.isLetter || $0.isNumber || symbols.contains($0)) }
            raws.append(Raw(core: core, endsClause: endsClause, closesSentence: closesSentence, other: other))
        }
        let strong = symbolWords(for: language).filter(\.strong)
        var items: [Item] = []
        var index = 0
        var sentenceStart = region.startIndex == text.startIndex
            || text[..<region.startIndex].last(where: { !$0.isWhitespace }).map { ".!?…".contains($0) } ?? true
        while index < raws.count {
            let raw = raws[index]
            defer { sentenceStart = raw.closesSentence }
            if raw.other {
                items.append(Item(kind: .other, range: raw.core, endsClause: true, startsSentence: sentenceStart))
                index += 1
                continue
            }
            // A symbol word, of one word or more (none but the last may end a clause).
            var matched: (SymbolWord, Int)?
            for word in strong where index + word.words.count <= raws.count {
                let span = raws[index..<(index + word.words.count)]
                guard span.dropLast().allSatisfy({ !$0.endsClause && !$0.other }), !span.last!.other,
                      zip(span, word.words).allSatisfy({ fold(text[$0.core]) == $1 }) else { continue }
                matched = (word, word.words.count)
                break
            }
            if let (word, count) = matched {
                let last = raws[index + count - 1]
                items.append(Item(kind: .symbol(word.symbols), range: raw.core.lowerBound..<last.core.upperBound,
                                  endsClause: last.endsClause, startsSentence: sentenceStart))
                index += count
                sentenceStart = last.closesSentence
                continue
            }
            items.append(Item(kind: .word(String(text[raw.core])), range: raw.core, endsClause: raw.endsClause,
                              startsSentence: sentenceStart))
            index += 1
        }
        return mergingLetters(items, in: text, language: language)
    }

    /// `items` with each run of spelled letters made one item: capitals alone or with dots ("Q C", "S. H.",
    /// "S.H."), and letter names that are not common words ("es aytch"), two letters or more; a capital alone
    /// counts too, but for "I" and "A".
    static func mergingLetters(_ items: [Item], in text: String, language: String?) -> [Item] {
        func letters(of item: Item) -> String? {
            guard case .word(let word) = item.kind else { return nil }
            if word.wholeMatch(of: /(?:\p{Lu}\.?)+/) != nil, word.filter(\.isLetter).count == 1 || word.contains(".") {
                return word.filter(\.isLetter).lowercased()
            }
            if word.count == 1, word.first!.isUppercase { return word.lowercased() }
            if let name = letterName(fold(word), language: language), !name.common { return String(name.letter) }
            return nil
        }
        var result: [Item] = []
        var index = 0
        while index < items.count {
            var end = index
            var spelled = ""
            var named = 0
            while end < items.count, let letters = letters(of: items[end]) {
                spelled += letters
                if case .word(let word) = items[end].kind, !word.first!.isUppercase { named += 1 }
                end += 1
                if items[end - 1].endsClause { break }
            }
            let count = end - index
            let alone = count == 1 && named == 0 && !["i", "a"].contains(spelled)
            if count >= 2 || alone {
                var item = items[index]
                item.kind = .letters(spelled)
                item.range = items[index].range.lowerBound..<items[end - 1].range.upperBound
                item.endsClause = items[end - 1].endsClause
                result.append(item)
                index = end
            } else {
                result.append(items[index])
                index += 1
            }
        }
        return result
    }

    /// Symbol words that start a token whatever word comes before them: "dot slash", "dot dot slash", "tilde" and
    /// "dash dash" (`./x`, `../x`, `~/x`, `--x`).
    static func isLeader(_ symbols: String) -> Bool {
        symbols.hasPrefix("./") || symbols.hasPrefix("../") || symbols.hasPrefix("~") || symbols.hasPrefix("--")
    }

    /// The token `run` spells, symbols joined to parts: spelled letters in lower case unless another part is a word
    /// in capitals (`HOLOS_AIFIX`), a word as recognized but for a capital a sentence gave it, and a digit's word as
    /// the digit; nil when a part is another number word ("ten").
    static func token(of run: ArraySlice<Item>, in text: String, language: String?,
                      digitWords allowed: [String: Character]) -> String? {
        let capitals = run.contains { item in
            if case .word(let word) = item.kind { word.count > 1 && word.allSatisfy { !$0.isLetter || $0.isUppercase } }
            else { false }
        }
        var token = ""
        for item in run {
            switch item.kind {
            case .symbol(let symbols): token += symbols
            case .letters(let letters): token += capitals ? letters.uppercased() : letters
            case .word(let word):
                let folded = fold(word)
                if let digit = allowed[folded] {
                    token.append(digit)
                } else if SpokenWords.meaning(of: folded, language: language).number != nil,
                          !word.contains(where: \.isNumber) {
                    return nil
                } else if item.startsSentence, word.first!.isUppercase, word.dropFirst().allSatisfy(\.isLowercase) {
                    token += word.lowercased()
                } else {
                    token += word
                }
            case .other: return nil
            }
        }
        return token
    }

    /// Digit words a run found without the model reads as digits: not "one", "un" or "une", which say other things
    /// far more often.
    static let fallbackDigits = digitWords.filter { !["one", "un", "une"].contains($0.key) }

    /// Whether `word` is a function word of `language`, or has fewer than three letters (`SpokenWords.isContent`).
    static func isFunctionWord(_ item: Item, language: String?) -> Bool {
        guard case .word(let word) = item.kind else { return false }
        return !SpokenWords.isContent(fold(word), language: language)
    }

    static func isStopWord(_ item: Item, language: String?) -> Bool {
        guard case .word(let word) = item.kind else { return false }
        let folded = fold(word)
        return SpokenWords.stopWords(for: language).contains(folded) || shortFunctionWords.contains(folded)
    }

    /// The code spans of `text` found without the model: only runs that can be read one way. A run is words
    /// (one word or spelled letters each) joined by strong symbol words (`SymbolWord.strong`: "slash", "dot",
    /// "dash", "underscore", "tilde", "backslash"...), within one clause, ending with a word; its symbols give at least
    /// two characters (`scripts/restart-app.sh`, `.local/bin`, `--no-parallel`, `./x`), and it has a letter. The
    /// word before the first symbol belongs to the token when that symbol is "dash" or "underscore"
    /// (`restart-app`); it does not when the symbols start with "dot slash", "tilde" or "dash dash" (`./x`, `~/x`,
    /// `--x`), nor when it is a function word ("in slash tmp" is "in `/tmp`"); with a single "slash", "dot" or
    /// "backslash" after any other word ("adds dot local slash bin": `adds.local/bin` or "adds `.local/bin`"?), the
    /// run is left as said. A run next to another one ("source slash holos core slash app": a part may be "holos
    /// core"), a run that ends with a function word ("dot the"), or one with a number word other than a digit's is
    /// left as said too. "at", "plus", "equals", "colon" and "period" never form a run on their own.
    public static func fallback(_ text: String, language: String? = nil) -> [Span] {
        let items = items(in: text, region: text.startIndex..<text.endIndex, language: language)
        // Runs: stretches of items alternating words and symbol words, within one clause.
        var runs: [Range<Int>] = []
        var start = 0
        for index in items.indices {
            let item = items[index]
            let previous = index > start ? items[index - 1] : nil
            if case .other = item.kind {
                if start < index { runs.append(start..<index) }
                start = index + 1
                continue
            }
            if let previous, previous.isPart, item.isPart {
                runs.append(start..<index)
                start = index
            }
            if item.endsClause {
                runs.append(start..<(index + 1))
                start = index + 1
            }
        }
        if start < items.count { runs.append(start..<items.count) }
        func hasSymbol(_ run: Range<Int>) -> Bool {
            items[run].contains { if case .symbol = $0.kind { true } else { false } }
        }
        var spans: [Span] = []
        for (number, run) in runs.enumerated() where hasSymbol(run) {
            // Next to another run with symbols, a word of either may belong to the other's part.
            if number > 0, runs[number - 1].upperBound == run.lowerBound, hasSymbol(runs[number - 1]),
               !items[runs[number - 1].upperBound - 1].endsClause { continue }
            if number + 1 < runs.count, runs[number + 1].lowerBound == run.upperBound, hasSymbol(runs[number + 1]),
               !items[run.upperBound - 1].endsClause { continue }
            var lower = run.lowerBound, upper = run.upperBound
            // A run ends with a word; a symbol word the run ends with (a clause's end) stays a word.
            while upper > lower, !items[upper - 1].isPart { upper -= 1 }
            guard upper > lower else { continue }
            if items[lower].isPart, lower + 1 < upper, case .symbol = items[lower + 1].kind {
                let leading = items[(lower + 1)...].prefix { if case .symbol = $0.kind { true } else { false } }
                    .map { item -> String in if case .symbol(let s) = item.kind { s } else { "" } }.joined()
                if isLeader(leading) || isFunctionWord(items[lower], language: language) {
                    lower += 1
                } else if !(leading.hasPrefix("-") || leading.hasPrefix("_")) {
                    continue
                }
            }
            let slice = items[lower..<upper]
            let symbolCount = slice.reduce(0) { count, item in
                if case .symbol(let s) = item.kind { count + s.count } else { count }
            }
            guard symbolCount >= 2, let first = slice.first(where: \.isPart), let last = slice.last,
                  !isStopWord(first, language: language), !isStopWord(last, language: language),
                  let token = token(of: slice, in: text, language: language, digitWords: fallbackDigits)
            else { continue }
            let range = slice.first!.range.lowerBound..<last.range.upperBound
            guard accepts(token, for: text[range], language: language) else { continue }
            spans.append(Span(range: range, token: token))
        }
        return spans
    }

    /// The token for `range` of `text`, a span the model proposed but whose token was refused, read as a run found
    /// without the model would be (`fallback`) with the span's own edges: its words and symbol words alternate, it
    /// starts and ends with a word that is not a function word or with a symbol word, and it has one symbol at least.
    /// Nil when the span is anything else ("the dash", "holos core slash app").
    static func repair(_ range: Range<String.Index>, in text: String, language: String?) -> String? {
        let items = items(in: text, region: range, language: language)
        guard let first = items.first, let last = items.last, first.range.lowerBound == range.lowerBound,
              last.range.upperBound == range.upperBound, last.isPart else { return nil }
        for (index, item) in items.enumerated() {
            if case .other = item.kind { return nil }
            if item.endsClause { return nil }
            if index > 0, items[index - 1].isPart, item.isPart { return nil }
        }
        guard items.contains(where: { if case .symbol = $0.kind { true } else { false } }),
              let firstPart = items.first(where: \.isPart),
              !isStopWord(firstPart, language: language), !isStopWord(last, language: language),
              let token = token(of: items[...], in: text, language: language, digitWords: fallbackDigits),
              accepts(token, for: text[range], language: language) else { return nil }
        return token
    }

    // MARK: - Streaming

    /// For text still growing while the user speaks: withholds a trailing run that more words may continue (a strong
    /// symbol word among the last four words, and any strong symbol word within four words before that one), from its
    /// first symbol word and the content word before it (`SpokenWords.isContent`), so a token is formatted whole:
    /// "run scripts slash restart" waits for "dash app dot S H". A trailing word that may start a symbol phrase
    /// ("double", "forward", "back", "barre", "tiret") is held back too, and without a symbol word, a last content
    /// word, which one may still follow. Nothing is held back once the text ends a clause (",", ".", "?"...). The
    /// words before what is withheld are never held back again, so what was handed on stays a prefix.
    public static func withholdingTrailingRun(_ text: String, language: String? = nil) -> String {
        let words = text.ranges(of: /\S+/)
        guard !words.isEmpty else { return text }
        let strong = symbolWords(for: language).filter(\.strong)
        let single = Set(strong.filter { $0.words.count == 1 }.map { $0.words[0] })
        let starts = Set(strong.filter { $0.words.count > 1 }.map { $0.words[0] })
        func isSymbol(_ index: Int) -> Bool {
            let word = text[words[index]]
            return single.contains(fold(word.trimmingCharacters(in: CharacterSet(charactersIn: ",;:!?.…"))))
        }
        func endsClause(_ index: Int) -> Bool {
            let word = text[words[index]]
            guard let last = word.last, ",;:!?.…".contains(last) else { return false }
            return word.wholeMatch(of: /(?:\p{Lu}\.)+/) == nil
        }
        let last = words.count - 1
        // A run that ended with its clause is complete.
        if endsClause(last) { return text }
        // The last strong symbol word among the last four words, with no clause's end after it; else a last word
        // that may start a symbol phrase.
        var found: Int?
        for index in stride(from: last, through: max(0, last - 3), by: -1) {
            if index < last, endsClause(index) { break }
            if isSymbol(index) { found = index; break }
        }
        if found == nil, starts.contains(fold(text[words[last]])) { found = last }
        // A content word may be a token's first part ("scripts" before "slash restart").
        func mayStartToken(_ index: Int) -> Bool {
            !endsClause(index) && !isSymbol(index) && SpokenWords.isContent(fold(text[words[index]]), language: language)
        }
        guard var cut = found else {
            // No symbol word yet: a last content word may still be followed by one.
            return mayStartToken(last) ? String(text[..<words[last].lowerBound]).trimmingCharacters(in: .whitespaces)
                                       : text
        }
        // Earlier symbol words chained to it, at most three words apart, within the clause.
        var probe = cut - 1
        var between = 0
        while probe >= 0, between <= 3, !endsClause(probe) {
            if isSymbol(probe) {
                cut = probe
                between = 0
            } else {
                between += 1
            }
            probe -= 1
        }
        if cut > 0, mayStartToken(cut - 1) { cut -= 1 }
        return String(text[..<words[cut].lowerBound]).trimmingCharacters(in: .whitespaces)
    }
}
