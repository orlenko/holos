import Foundation
import HolosCore
import HolosStorage

/// decisions.json, as the review page exports it.
public struct ReviewDecisions: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable {
        case local, cloud, edited
    }

    public struct Decision: Codable, Sendable, Equatable {
        public var id: String
        public var choice: Choice
        public var text: String

        public init(id: String, choice: Choice, text: String) { self.id = id; self.choice = choice; self.text = text }
    }

    public var schemaVersion: Int
    public var sessionID: String
    public var run: String
    public var transcriptID: String
    public var exportedAt: String?
    public var decisions: [Decision]
    public var terms: [String]

    public init(schemaVersion: Int = 1, sessionID: String, run: String, transcriptID: String, exportedAt: String? = nil,
                decisions: [Decision], terms: [String] = []) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.run = run
        self.transcriptID = transcriptID; self.exportedAt = exportedAt; self.decisions = decisions; self.terms = terms
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionID, run, transcriptID, exportedAt, decisions, terms
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        run = try c.decode(String.self, forKey: .run)
        transcriptID = try c.decode(String.self, forKey: .transcriptID)
        exportedAt = try c.decodeIfPresent(String.self, forKey: .exportedAt)
        decisions = try c.decode([Decision].self, forKey: .decisions)
        terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
    }

    /// Parses and checks a decisions file: schema version 1, known choices, each passage once.
    public static func parse(_ data: Data) throws -> ReviewDecisions {
        let decoded: ReviewDecisions
        do {
            decoded = try JSONDecoder().decode(ReviewDecisions.self, from: data)
        } catch {
            throw HolosError.invalidInput("This is not a decisions file exported by the review page.")
        }
        guard decoded.schemaVersion == 1 else {
            throw HolosError.invalidInput("The decisions file has schema version \(decoded.schemaVersion); this build reads 1.")
        }
        var seen = Set<String>()
        for decision in decoded.decisions where !seen.insert(decision.id).inserted {
            throw HolosError.invalidInput("The decisions file lists passage \(decision.id) twice.")
        }
        return decoded
    }
}

/// eval/gold/<run>.json: the reference transcript made from the review.
public struct GoldTranscript: Codable, Sendable, Equatable {
    public struct Piece: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String
        /// The passage this piece replaced, when it was reviewed.
        public var passage: String?
    }

    public struct Track: Codable, Sendable, Equatable {
        public var track: String
        public var text: String
        public var pieces: [Piece]
    }

    public var schemaVersion = 1
    public var sessionID: String
    public var run: String
    public var transcriptID: String
    public var createdAt: Date
    public var reviewedPassages: Int
    public var tracks: [Track]
}

/// `voiceislocal eval apply` (docs/reference-evaluation.md, "Cloud reference").
public enum EvalApply {
    public struct Result: Sendable, Equatable {
        public var gold: GoldTranscript
        /// Heard (local) → meant (reviewed) pairs of at most `maxCorrectionWords` words each side.
        public var corrections: [Correction]
        /// Terms marked on the review page (whitespace collapsed), once each ignoring case and spacing, for the word
        /// list.
        public var terms: [String]
        /// Local real words a reviewed passage replaced by a term (one of `knownTerms`, the word list's, or a marked
        /// term): "often heard as" words of that term (`heard` the local words, `meant` the term as listed), not
        /// corrections, since the same words are often meant as they are ("cloud" for "Claude"). A pair whose local
        /// side has a word that is not a real word stays a correction.
        public var heardAs: [Correction] = []
        /// Decisions on formatting-only passages, left out of the gold and the proposals.
        public var ignoredFormatting = 0
    }

    public static let maxCorrectionWords = 3

    /// Builds the gold transcript and the proposals. The decisions must belong to this session and run and to the
    /// compare report's transcript revision, and the current transcript must still be that revision (the passage
    /// positions refer to it). A decision for a passage the report does not have is refused. `knownTerms` are the word
    /// list's terms, which with the marked terms decide which pairs are "often heard as" words (`Result.heardAs`).
    public static func build(session: URL, report: CompareReport, decisions: ReviewDecisions, now: Date = Date(),
                             knownTerms: [String] = [],
                             isDictionaryWord: (String) -> Bool = { _ in false }) throws -> Result {
        guard decisions.sessionID == report.sessionID else {
            throw HolosError.invalidInput("These decisions belong to another session.")
        }
        guard decisions.run == report.run else {
            throw HolosError.invalidInput("These decisions are for run \(decisions.run), not \(report.run).")
        }
        guard report.isOfCurrentTranscript else {
            throw HolosError.invalidInput("This comparison is of a local candidate; review and apply work on the "
                + "comparison of the current transcript.")
        }
        guard decisions.transcriptID == report.transcriptID else {
            throw HolosError.invalidInput("These decisions were made on another comparison of this run (transcript "
                + "\(decisions.transcriptID)); review the current one.")
        }
        guard let transcript = try SessionFiles.currentTranscript(session: session),
              transcript.id == report.transcriptID else {
            throw HolosError.invalidInput("The session's transcript changed since the comparison; run voiceislocal "
                + "eval compare and review again.")
        }
        let passages = Dictionary(report.passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for decision in decisions.decisions where passages[decision.id] == nil {
            throw HolosError.invalidInput("The comparison has no passage \(decision.id).")
        }
        let manifest = try SessionArchive.readManifest(at: session)
        let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest)
        let parameters = meeting.map(SpeakerAnalysis.alignmentParameters(meeting:)) ?? .v1
        // Formatting-only passages (the same words under the normalized comparison) are ignored, even when decided.
        let decided = decisions.decisions.compactMap { decision in passages[decision.id].map { ($0, decision) } }
            .filter { !$0.0.formattingOnly }
        let ignored = decisions.decisions.count - decided.count

        var tracks: [GoldTranscript.Track] = []
        for trackReport in report.tracks {
            let track = trackReport.track
            let local = EvalCompare.localTokens(transcript, track: track, parameters: parameters,
                                                untrackedOwner: report.tracks.first?.track)
            let replacements = decided.filter { $0.0.track == track }
                .sorted { ($0.0.localFirst, $0.0.localEnd) < ($1.0.localFirst, $1.0.localEnd) }
            tracks.append(goldTrack(track: track, local: local, replacements: replacements))
        }
        var terms: [String] = []
        var seenTerms = Set<String>()
        for raw in decisions.terms {
            guard let term = WordList.cleaned(raw), seenTerms.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        // The terms a pair may be "often heard as" words of: the word list's, then the marked ones.
        let spelled = termIndex(knownTerms + terms)
        var corrections: [Correction] = []
        var heardAs: [Correction] = []
        for (passage, decision) in decided {
            let pairs = proposals(passage: passage, final: decision.text, isDictionaryWord: isDictionaryWord)
            for pair in pairs.corrections {
                if let term = heardAsTerm(pair, terms: spelled, isDictionaryWord: isDictionaryWord) {
                    if !heardAs.contains(where: { termKey($0.heard) == termKey(term.heard) && $0.meant == term.meant }) {
                        heardAs.append(term)
                    }
                } else if !corrections.contains(where: { $0.heard.lowercased() == pair.heard.lowercased() }) {
                    corrections.append(pair)
                }
            }
            // A lone real word replaced by a term has no neighbour to learn a correction with, but is a heard-as word.
            for pair in pairs.declined {
                guard let term = heardAsTerm(pair, terms: spelled, isDictionaryWord: isDictionaryWord),
                      !heardAs.contains(where: { termKey($0.heard) == termKey(term.heard) && $0.meant == term.meant })
                else { continue }
                heardAs.append(term)
            }
        }
        let gold = GoldTranscript(sessionID: report.sessionID, run: report.run, transcriptID: report.transcriptID,
                                  createdAt: now, reviewedPassages: decided.count, tracks: tracks)
        return Result(gold: gold, corrections: corrections, terms: terms, heardAs: heardAs,
                      ignoredFormatting: ignored)
    }

    /// What two spellings of a term share: its words lowercased, without the marks around them.
    static func termKey(_ text: String) -> String {
        words(of: text).joined(separator: " ")
    }

    /// The words of `text`, lowercased, without the marks around each.
    static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map {
            $0.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        }.filter { !$0.isEmpty }
    }

    /// Listed terms by how a reviewed text may write them: exactly (any case, whitespace collapsed), else without the
    /// quotes, brackets and sentence marks around them. A term's own marks stay part of it, so "C#", "C++" and ".NET"
    /// are three terms, not "c", "c" and "net". The first spelling of each key is kept.
    struct TermIndex: Sendable {
        var exact: [String: String] = [:]
        var loose: [String: String] = [:]

        /// The listed spelling of the term `text` writes; nil when it is none.
        func term(_ text: String) -> String? {
            exact[EvalApply.exactKey(text)] ?? loose[EvalApply.looseKey(text)]
        }
    }

    static func termIndex(_ terms: [String]) -> TermIndex {
        var index = TermIndex()
        for term in terms {
            guard let cleaned = WordList.cleaned(term) else { continue }
            if index.exact[exactKey(cleaned)] == nil { index.exact[exactKey(cleaned)] = cleaned }
            let loose = looseKey(cleaned)
            if !loose.isEmpty, index.loose[loose] == nil { index.loose[loose] = cleaned }
        }
        return index
    }

    static func exactKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Quotes and brackets around a term, and the sentence marks after it.
    private static let leadingWrappers: Set<Character> = ["\"", "'", "“", "‘", "«", "(", "[", "{"]
    private static let trailingWrappers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}", ".", ",", ";", ":",
                                                           "!", "?", "…"]

    static func looseKey(_ text: String) -> String {
        var key = Substring(exactKey(text))
        while let first = key.first, leadingWrappers.contains(first) { key = key.dropFirst() }
        while let last = key.last, trailingWrappers.contains(last) { key = key.dropLast() }
        return String(key)
    }

    /// The "often heard as" pair `pair` stands for. The longest run of the meant side's words that is a listed term
    /// (`terms`) is found first; the words around it must be the same on both sides (a correction's neighbour, "asked
    /// cloud" → "asked Claude"), and the heard words between them are the term's heard-as words, when every one of them
    /// is a real word. Heard as the local words, meant as the term is spelled in the list. Nil otherwise: a correction.
    static func heardAsTerm(_ pair: Correction, terms: TermIndex,
                            isDictionaryWord: (String) -> Bool) -> Correction? {
        let heardWords = pair.heard.split(whereSeparator: \.isWhitespace).map(String.init)
        let meantWords = pair.meant.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !heardWords.isEmpty, !meantWords.isEmpty else { return nil }
        for length in stride(from: meantWords.count, through: 1, by: -1) {
            for start in 0...(meantWords.count - length) {
                guard let term = terms.term(meantWords[start..<(start + length)].joined(separator: " ")) else {
                    continue
                }
                let after = meantWords.count - start - length
                guard start + after < heardWords.count,
                      zip(heardWords.prefix(start), meantWords.prefix(start)).allSatisfy({ termKey($0) == termKey($1) }),
                      zip(heardWords.suffix(after), meantWords.suffix(after)).allSatisfy({ termKey($0) == termKey($1) })
                else { continue }
                let heard = heardWords[start..<(heardWords.count - after)].joined(separator: " ")
                    .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                let local = words(of: heard)
                guard !heard.isEmpty, exactKey(heard) != exactKey(term), !local.isEmpty,
                      local.allSatisfy(isDictionaryWord) else { return nil }
                return Correction(heard: heard, meant: term)
            }
        }
        return nil
    }

    /// How a gold piece joins the one before it.
    enum Joint: Equatable {
        /// As the transcript had it (a space or not).
        case original(Bool)
        /// By the characters that meet: a space unless both are of a script written without spaces.
        case byCharacters
    }

    /// The local words of a track (echo left out) with each reviewed passage's words replaced by its final text. The
    /// words keep the spacing they had in the transcript (none between the characters of a script written without
    /// spaces). Where a reviewed passage meets the words around it, the transcript's spacing is kept when the text
    /// there is of the same kind (spaced or unspaced script) as the words it replaced; otherwise, and around an
    /// insertion or a deletion, the characters that meet decide ("hello" and "world" get a space, "你好" and "界"
    /// none).
    static func goldTrack(track: String, local: [EvalToken],
                          replacements: [(EvalPassage, ReviewDecisions.Decision)]) -> GoldTranscript.Track {
        var pieces: [GoldTranscript.Piece] = []
        var joints: [Joint] = []
        var run: [EvalToken] = []
        var spliced: Joint?  // how the next piece joins the reviewed passage (or the deletion) before it
        func flushRun() {
            let kept = run.filter { !$0.echo }
            run.removeAll()
            guard let first = kept.first, let last = kept.last else { return }
            pieces.append(GoldTranscript.Piece(start: first.start ?? 0, end: last.end ?? last.start ?? 0,
                                               text: EvalText.join(kept), passage: nil))
            joints.append(spliced ?? .original(first.spaceBefore))
            spliced = nil
        }
        func sameKind(_ a: Character?, _ b: Character?) -> Bool {
            guard let a, let b else { return false }
            return EvalText.isUnspacedScript(a) == EvalText.isUnspacedScript(b)
        }
        var position = 0
        for (passage, decision) in replacements {
            let first = min(max(passage.localFirst, position), local.count)
            let end = min(max(passage.localEnd, first), local.count)
            run += local[position..<first]
            flushRun()
            let text = decision.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if text.isEmpty {
                spliced = .byCharacters
            } else {
                pieces.append(GoldTranscript.Piece(start: passage.start, end: passage.end, text: text,
                                                   passage: passage.id))
                let replaced = first < end
                joints.append(replaced && sameKind(text.first, local[first].text.first)
                              ? .original(local[first].spaceBefore) : .byCharacters)
                spliced = replaced && end < local.count && sameKind(text.last, local[end - 1].text.last)
                    ? .original(local[end].spaceBefore) : .byCharacters
            }
            position = end
        }
        run += local[min(position, local.count)...]
        flushRun()
        var text = ""
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                switch joints[index] {
                case .original(let space):
                    if space { text += " " }
                case .byCharacters:
                    let before = text.last, after = piece.text.first
                    if !(before.map(EvalText.isUnspacedScript) == true && after.map(EvalText.isUnspacedScript) == true) {
                        text += " "
                    }
                }
            }
            text += piece.text
        }
        return GoldTranscript.Track(track: track, text: text, pieces: pieces)
    }

    /// Word-level substitutions between the passage's local text and its final text, with the passage's context
    /// around both so a lone dictionary word is learned with a neighbour (`CorrectionList.learn`). Only pairs of at
    /// most `maxCorrectionWords` words on each side whose words differ in more than case or punctuation.
    static func correctionPairs(passage: EvalPassage, final: String,
                                isDictionaryWord: (String) -> Bool) -> [Correction] {
        proposals(passage: passage, final: final, isDictionaryWord: isDictionaryWord).corrections
    }

    /// `correctionPairs`, and the lone dictionary words `CorrectionList.learnReportingDeclined` declined (no neighbour
    /// to learn them with), which may still be "often heard as" words of a term.
    static func proposals(passage: EvalPassage, final: String,
                          isDictionaryWord: (String) -> Bool) -> (corrections: [Correction], declined: [Correction]) {
        guard !passage.local.isEmpty, !final.trimmingCharacters(in: .whitespaces).isEmpty,
              EvalText.tokens(passage.local).map(EvalText.key) != EvalText.tokens(final).map(EvalText.key) else {
            return ([], [])
        }
        let original = [passage.before, passage.local, passage.after].filter { !$0.isEmpty }.joined(separator: " ")
        let corrected = [passage.before, final, passage.after].filter { !$0.isEmpty }.joined(separator: " ")
        let learned = CorrectionList.learnReportingDeclined(original: original, corrected: corrected,
                                                            isDictionaryWord: isDictionaryWord)
        func fits(_ pair: Correction) -> Bool {
            let heard = EvalText.tokens(pair.heard)
            let meant = EvalText.tokens(pair.meant)
            return !heard.isEmpty && !meant.isEmpty && heard.count <= maxCorrectionWords
                && meant.count <= maxCorrectionWords && heard.map(EvalText.key) != meant.map(EvalText.key)
        }
        return (learned.learned.filter(fits), learned.declined.filter(fits))
    }

    /// Adds each pair's heard words (`Result.heardAs`) to its term's "often heard as" words in `store` (the app's
    /// words.json), under the list's lock. A term the list does not have is skipped (the caller adds marked terms
    /// first). The report says what each term is heard as now, and which terms were missing.
    public static func addToHeardAs(_ pairs: [Correction], store: WordListStore) throws -> WordListCommand.Report {
        let (_, changes, _) = try store.update { list -> [(String, WordList.HeardAsChange?)] in
            var grouped: [(term: String, phrases: [String])] = []
            for pair in pairs {
                if let index = grouped.firstIndex(where: { $0.term == pair.meant }) {
                    grouped[index].phrases.append(pair.heard)
                } else {
                    grouped.append((pair.meant, [pair.heard]))
                }
            }
            return grouped.map { ($0.term, list.addHeardAs($0.phrases, to: $0.term)) }
        }
        var report = WordListCommand.Report()
        for (term, change) in changes {
            guard let change else {
                report.errors.append("Not in the word list, so its often-heard-as words were not added: \(term)")
                report.exitCode = 1
                continue
            }
            WordListCommand.add(change, to: &report)
        }
        return report
    }

    /// Adds `corrections` to the correction list at `url` (the app's corrections.json) as the app adds one: an entry
    /// for the same heard phrase is replaced. The whole read, change, and save holds the list's lock
    /// (`CorrectionList.update`), which the app takes too, so neither another apply nor the app loses an entry.
    /// Returns the pairs that changed the list; the file is written only then.
    public static func addToCorrections(_ corrections: [Correction], at url: URL) throws -> [Correction] {
        try CorrectionList.update(at: url) { list in
            var added: [Correction] = []
            for pair in corrections {
                let before = list.entries
                list.add(pair)
                if list.entries != before { added.append(pair) }
            }
            return added
        }.result
    }

    /// Adds `terms` (the marked terms) to the word list in `store` (the app's words.json) as `voiceislocal words add`
    /// does, marked as coming from a review (`WordListSource.review`); a term the list has already, in any case, is
    /// left as it is. The read, change, and save hold the list's lock (`WordListStore.update`), which the app takes
    /// too. The report says what was added, what was listed already, and what did not fit.
    public static func addToWordList(_ terms: [String], store: WordListStore,
                                     at date: Date = Date()) throws -> WordListCommand.Report {
        try WordListCommand.add(terms, store: store, source: .review, at: date)
    }
}
