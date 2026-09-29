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
        /// Terms marked on the review page, once each ignoring case.
        public var terms: [String]
        /// For the terms: heard → meant pairs from the reviewed passages whose final text contains a term (what the
        /// local recognizer wrote there, up to `maxTermSoundalikeWords` words). The correction list holds only
        /// pairs, so a term is added to it through these.
        public var termPairs: [Correction]
        /// Terms no reviewed passage gives a soundalike for.
        public var termsWithoutSoundalike: [String]
    }

    public static let maxTermSoundalikeWords = 6

    public static let maxCorrectionWords = 3

    /// Builds the gold transcript and the proposals. The decisions must belong to this session and run and to the
    /// compare report's transcript revision, and the current transcript must still be that revision (the passage
    /// positions refer to it). A decision for a passage the report does not have is refused.
    public static func build(session: URL, report: CompareReport, decisions: ReviewDecisions, now: Date = Date(),
                             isDictionaryWord: (String) -> Bool = { _ in false }) throws -> Result {
        guard decisions.sessionID == report.sessionID else {
            throw HolosError.invalidInput("These decisions belong to another session.")
        }
        guard decisions.run == report.run else {
            throw HolosError.invalidInput("These decisions are for run \(decisions.run), not \(report.run).")
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
        let decided = decisions.decisions.compactMap { decision in passages[decision.id].map { ($0, decision) } }

        var tracks: [GoldTranscript.Track] = []
        for trackReport in report.tracks {
            let track = trackReport.track
            let local = EvalCompare.localTokens(transcript, track: track, parameters: parameters,
                                                untrackedOwner: report.tracks.first?.track)
            let replacements = decided.filter { $0.0.track == track }
                .sorted { ($0.0.localFirst, $0.0.localEnd) < ($1.0.localFirst, $1.0.localEnd) }
            tracks.append(goldTrack(track: track, local: local, replacements: replacements))
        }
        var corrections: [Correction] = []
        for (passage, decision) in decided {
            for pair in correctionPairs(passage: passage, final: decision.text, isDictionaryWord: isDictionaryWord)
            where !corrections.contains(where: { $0.heard.lowercased() == pair.heard.lowercased() }) {
                corrections.append(pair)
            }
        }
        var terms: [String] = []
        for term in decisions.terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !terms.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { continue }
            terms.append(trimmed)
        }
        var termPairs: [Correction] = []
        var withoutSoundalike: [String] = []
        for term in terms {
            var found = false
            for (passage, decision) in decided
            where containsWords(decision.text, term) && !containsWords(passage.local, term) && !passage.local.isEmpty {
                // Learned as the corrections are (context, a lone dictionary word kept with a neighbour), without
                // their three-word limit; nothing is proposed when learning declines.
                let original = [passage.before, passage.local, passage.after].filter { !$0.isEmpty }
                    .joined(separator: " ")
                let corrected = [passage.before, decision.text, passage.after].filter { !$0.isEmpty }
                    .joined(separator: " ")
                let pairs = CorrectionList.learn(original: original, corrected: corrected,
                                                 isDictionaryWord: isDictionaryWord)
                    .filter { containsWords($0.meant, term) }
                for pair in pairs where EvalText.tokens(pair.heard).count <= maxTermSoundalikeWords {
                    found = true
                    if !termPairs.contains(where: { $0.heard.lowercased() == pair.heard.lowercased() }) {
                        termPairs.append(pair)
                    }
                }
            }
            if !found { withoutSoundalike.append(term) }
        }
        let gold = GoldTranscript(sessionID: report.sessionID, run: report.run, transcriptID: report.transcriptID,
                                  createdAt: now, reviewedPassages: decided.count, tracks: tracks)
        return Result(gold: gold, corrections: corrections, terms: terms, termPairs: termPairs,
                      termsWithoutSoundalike: withoutSoundalike)
    }

    /// Whether the words of `phrase` appear in order, as whole words, in `text` (compared by key).
    static func containsWords(_ text: String, _ phrase: String) -> Bool {
        let words = EvalText.tokens(text).map(EvalText.key)
        let wanted = EvalText.tokens(phrase).map(EvalText.key)
        guard !wanted.isEmpty, words.count >= wanted.count else { return false }
        for start in 0...(words.count - wanted.count) where Array(words[start..<start + wanted.count]) == wanted {
            return true
        }
        return false
    }

    /// The local words of a track (echo left out) with each reviewed passage's words replaced by its final text. The
    /// words keep the spacing they had in the transcript (none between the characters of a script written without
    /// spaces), and so does a reviewed passage with the words around it.
    static func goldTrack(track: String, local: [EvalToken],
                          replacements: [(EvalPassage, ReviewDecisions.Decision)]) -> GoldTranscript.Track {
        var pieces: [GoldTranscript.Piece] = []
        var spaced: [Bool] = []
        var run: [EvalToken] = []
        func flushRun() {
            let kept = run.filter { !$0.echo }
            run.removeAll()
            guard let first = kept.first, let last = kept.last else { return }
            pieces.append(GoldTranscript.Piece(start: first.start ?? 0, end: last.end ?? last.start ?? 0,
                                               text: EvalText.join(kept), passage: nil))
            spaced.append(first.spaceBefore)
        }
        var position = 0
        for (passage, decision) in replacements {
            let first = min(max(passage.localFirst, position), local.count)
            let end = min(max(passage.localEnd, first), local.count)
            run += local[position..<first]
            flushRun()
            let text = decision.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty {
                pieces.append(GoldTranscript.Piece(start: passage.start, end: passage.end, text: text,
                                                   passage: passage.id))
                spaced.append(first < local.count ? local[first].spaceBefore : true)
            }
            position = end
        }
        run += local[min(position, local.count)...]
        flushRun()
        return GoldTranscript.Track(track: track, text: EvalText.join(pieces.map(\.text), spaceBefore: spaced),
                                    pieces: pieces)
    }

    /// Word-level substitutions between the passage's local text and its final text, with the passage's context
    /// around both so a lone dictionary word is learned with a neighbour (`CorrectionList.learn`). Only pairs of at
    /// most `maxCorrectionWords` words on each side whose words differ in more than case or punctuation.
    static func correctionPairs(passage: EvalPassage, final: String,
                                isDictionaryWord: (String) -> Bool) -> [Correction] {
        guard !passage.local.isEmpty, !final.trimmingCharacters(in: .whitespaces).isEmpty,
              EvalText.tokens(passage.local).map(EvalText.key) != EvalText.tokens(final).map(EvalText.key) else {
            return []
        }
        let original = [passage.before, passage.local, passage.after].filter { !$0.isEmpty }.joined(separator: " ")
        let corrected = [passage.before, final, passage.after].filter { !$0.isEmpty }.joined(separator: " ")
        return CorrectionList.learn(original: original, corrected: corrected, isDictionaryWord: isDictionaryWord)
            .filter { pair in
                let heard = EvalText.tokens(pair.heard)
                let meant = EvalText.tokens(pair.meant)
                return !heard.isEmpty && !meant.isEmpty && heard.count <= maxCorrectionWords
                    && meant.count <= maxCorrectionWords && heard.map(EvalText.key) != meant.map(EvalText.key)
            }
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
}
