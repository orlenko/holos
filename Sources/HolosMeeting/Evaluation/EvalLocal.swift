import CryptoKit
import Foundation
import HolosAudio
import HolosCore
import HolosSpeakers
import HolosStorage

/// eval/local/<id>/run.json: a candidate local transcription of the whole meeting (`voiceislocal eval local`).
public struct LocalRunRecord: Codable, Sendable, Equatable {
    public struct Track: Codable, Sendable, Equatable {
        public var track: String
        /// `EvalStore.audioFingerprint`: a resumed run transcribes the same audio only if it is unchanged.
        public var audioFingerprint: String
        /// SHA-256 of the track's chunk files' bytes, in order: the chunk list could stay while a file's contents
        /// change, and a resumed run never joins transcriptions of different audio.
        public var contentSHA256: String?
        public var seconds: Double
    }

    public var schemaVersion = 1
    public var id: String
    public var sessionID: String
    public var createdAt: Date
    /// Each is a transcription of every track; several are merged as the post-processing languages stage merges them.
    public var languages: [String]
    public var backend: SpeechBackend
    /// The recognizer's contextual strings, exactly as they were given (empty with --no-vocabulary).
    public var vocabulary: [String]
    /// "current": the word list, people's names, and correction words when the run started; "none".
    public var vocabularySource: String
    /// Recognition as the languages stage makes it: final results only (`AppleSpeechSession.make(accurate: true)`).
    public var accurate = true
    /// Text steps applied after recognition, in order (currently `wordFixes`, unless `--no-word-fixes`).
    public var textSteps: [String] = []
    public var tracks: [Track]
    /// Set once every track is transcribed in every language and transcript.json is written.
    public var completedAt: Date?
    public var transcriptID: String?
    /// The deep transcription model that transcribed it ("whisper:<model>", `--backend whisper`); nil for Apple's
    /// speech recognition. With it, `vocabulary` is the prompt's candidates and `prompt` what the model was given.
    public var engine: String? = nil
    /// The prompt the deep transcription model was given on every chunk (`DeepTranscriptionPrompt`).
    public var prompt: String? = nil
    /// The recorded transcript the deep transcription guards compared every track with (a revision kept in the
    /// session): a resumed run uses it again, so all of its tracks are guarded alike. `noReference` for a run begun
    /// without a transcript, which stays unguarded by recorded words when resumed.
    public var referenceTranscriptID: String? = nil

    /// `referenceTranscriptID` of a Whisper run begun with no transcript to guard against.
    public static let noReference = ""

    public var seconds: Double { tracks.reduce(0) { $0 + $1.seconds } }
    public var partCount: Int { languages.count * tracks.count }

    /// The schema of a run transcribed by the deep transcription model; its `backend` is written as "whisper", which a
    /// version of Voice is Local from before it cannot read, so it never resumes such a run with Apple's recognizer.
    static let whisperSchemaVersion = 2
    static let whisperBackend = "whisper"

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, sessionID, createdAt, languages, backend, vocabulary, vocabularySource, accurate,
             textSteps, tracks, completedAt, transcriptID, engine, prompt, referenceTranscriptID, meetingBackend
    }

    init(id: String, sessionID: String, createdAt: Date, languages: [String], backend: SpeechBackend,
         vocabulary: [String], vocabularySource: String, textSteps: [String], tracks: [Track],
         engine: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.createdAt = createdAt; self.languages = languages
        self.backend = backend; self.vocabulary = vocabulary; self.vocabularySource = vocabularySource
        self.textSteps = textSteps; self.tracks = tracks; self.engine = engine
        if engine != nil { schemaVersion = Self.whisperSchemaVersion }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.whisperSchemaVersion else {
            throw HolosError.unavailable("This local run was made by a newer version of Voice is Local.")
        }
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        languages = try container.decode([String].self, forKey: .languages)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        let backendName = try container.decode(String.self, forKey: .backend)
        if backendName == Self.whisperBackend {
            guard engine != nil else {
                throw DecodingError.dataCorruptedError(forKey: .engine, in: container,
                                                       debugDescription: "A Whisper run names no engine.")
            }
            // The meeting's own backend, kept beside it so a resumed run matches the session's.
            backend = try container.decodeIfPresent(SpeechBackend.self, forKey: .meetingBackend) ?? .speech
        } else {
            guard let known = SpeechBackend(rawValue: backendName) else {
                throw DecodingError.dataCorruptedError(forKey: .backend, in: container,
                                                       debugDescription: "Unknown backend \(backendName).")
            }
            backend = known
        }
        vocabulary = try container.decode([String].self, forKey: .vocabulary)
        vocabularySource = try container.decode(String.self, forKey: .vocabularySource)
        accurate = try container.decodeIfPresent(Bool.self, forKey: .accurate) ?? true
        textSteps = try container.decodeIfPresent([String].self, forKey: .textSteps) ?? []
        tracks = try container.decode([Track].self, forKey: .tracks)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        transcriptID = try container.decodeIfPresent(String.self, forKey: .transcriptID)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        referenceTranscriptID = try container.decodeIfPresent(String.self, forKey: .referenceTranscriptID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(languages, forKey: .languages)
        try container.encode(engine == nil ? backend.rawValue : Self.whisperBackend, forKey: .backend)
        if engine != nil { try container.encode(backend, forKey: .meetingBackend) }
        try container.encode(vocabulary, forKey: .vocabulary)
        try container.encode(vocabularySource, forKey: .vocabularySource)
        try container.encode(accurate, forKey: .accurate)
        try container.encode(textSteps, forKey: .textSteps)
        try container.encode(tracks, forKey: .tracks)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(transcriptID, forKey: .transcriptID)
        try container.encodeIfPresent(engine, forKey: .engine)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(referenceTranscriptID, forKey: .referenceTranscriptID)
    }
}

/// eval/local/<id>/parts/<language>-<track>.json: one track transcribed in one language, saved as soon as it is done.
public struct LocalRunPart: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var language: String
    public var track: String
    public var segments: [TranscriptSegment]
    public var finishedAt: Date
}

extension EvalPaths {
    public static func localRoot(_ session: URL) -> URL { root(session).appendingPathComponent("local", isDirectory: true) }
    public static func localRun(_ id: String, in session: URL) -> URL {
        localRoot(session).appendingPathComponent(id, isDirectory: true)
    }
    public static func localRecord(_ id: String, in session: URL) -> URL {
        localRun(id, in: session).appendingPathComponent("run.json")
    }
    public static func localPart(_ id: String, language: String, track: String, in session: URL) -> URL {
        localRun(id, in: session).appendingPathComponent("parts", isDirectory: true)
            .appendingPathComponent("\(language)-\(track).json")
    }
    public static func localTranscript(_ id: String, in session: URL) -> URL {
        localRun(id, in: session).appendingPathComponent("transcript.json")
    }
    /// A comparison of a local candidate with a cloud run: next to the cloud run's comparison of the current transcript.
    public static func compare(_ run: String, local: String?, in session: URL) -> URL {
        guard let local else { return compare(run, in: session) }
        return compare(run, in: session).appendingPathComponent(local, isDirectory: true)
    }
}

/// `voiceislocal eval local` (docs/reference-evaluation.md, "Local candidates"): transcribes all of a session's saved
/// audio again, per track, with the languages stage's recognition and today's vocabulary, into eval/local/<id>/. The
/// meeting's transcript, speaker labels, exports, and vocabulary.json are never changed.
public enum EvalLocal {
    public static let idPrefix = "local-"

    public struct Options: Sendable {
        /// One language instead of the meeting's (meeting.json's list, else the recording's locale).
        public var language: String?
        /// Resume this unfinished run (default: the newest unfinished one with the same settings).
        public var runID: String?
        /// Resuming `runID` with the vocabulary it saved: today's word list and corrections are not needed (nor read).
        public var savedVocabulary: Bool
        /// Apply the meeting word-fix stage to the assembled candidate.
        public var wordFixes: Bool
        /// What transcribes the audio.
        public var backend: Backend

        public init(language: String? = nil, runID: String? = nil, savedVocabulary: Bool = false,
                    wordFixes: Bool = true, backend: Backend = .apple) {
            self.language = language; self.runID = runID; self.savedVocabulary = savedVocabulary
            self.wordFixes = wordFixes; self.backend = backend
        }
    }

    /// What transcribes a local candidate.
    public enum Backend: String, Sendable, CaseIterable {
        /// Apple's speech recognition, as the languages stage runs it.
        case apple
        /// The deep transcription pass's local Whisper model (docs/meeting-design.md §4.16), with its prompt and guards.
        case whisper
    }

    /// The language a `--backend whisper` run without `--language` transcribes in: the current transcript's (the one
    /// a deep transcript or word fixes were made from), as `DeepTranscriptionStage` chooses it; nil without a current
    /// transcript. Throws for a meeting whose meeting.json lists several languages, or a transcript merged from
    /// several, which the pass does not transcribe.
    static func whisperLanguages(session: URL, manifest: SessionManifest) throws -> [String]? {
        let meeting = try SessionFiles.meetingInfo(session: session, manifest: manifest)
        if DictationLanguage.meetingLanguages(meeting.languages ?? []).count > 1 {
            throw HolosError.invalidInput(severalLanguages)
        }
        guard let current = try SessionFiles.currentTranscript(session: session) else { return nil }
        let events = try SessionArchive.readEvents(at: session).events
        let base = DeepTranscriptionStage.recordedBase(of: current, events: events, session: session).unfixed
        if DictationLanguage.meetingLanguages(base.languages ?? []).count > 1 {
            throw HolosError.invalidInput(severalLanguages)
        }
        return [DictationLanguage.identifier(base.locale)]
    }

    /// Why a `--backend whisper` run without `--language` refuses a meeting in several languages (meeting.json's, or
    /// the current transcript's merge), as the deep transcription pass does.
    static let severalLanguages = "This meeting is in several languages; deep transcription handles meetings in one "
        + "language for now. Pass --language with one of them to evaluate it in that language."

    /// The prompt candidates of a `--backend whisper` run, as the deep transcription pass orders them: the meeting's
    /// vocabulary.json first, then the rest of `wordList`, then `names`.
    public static func whisperVocabulary(session: URL, wordList: [String], names: [String]) throws -> [String] {
        DeepTranscriptionPrompt.candidates(vocabulary: try TranscriptRebuilder.sessionVocabulary(session),
                                           wordList: wordList, names: names)
    }

    /// "local-<UTC yyyyMMdd'T'HHmmss'Z'>".
    public static func newRunID(at date: Date = Date()) -> String {
        idPrefix + String(EvalStore.newRunID(model: "x", at: date).dropFirst(2))
    }

    public static func isLocalRunID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Local run IDs, oldest first.
    public static func runIDs(in session: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: EvalPaths.localRoot(session).path)) ?? []
        return names.filter { SessionArchive.validToken($0) && isLocalRunID($0) }.sorted()
    }

    /// eval/local/<id>/run.json; a record that names another run, a language or track that is not a plain token, or
    /// another session is refused.
    public static func record(_ id: String, in session: URL, sessionID: String? = nil) throws -> LocalRunRecord? {
        try EvalStore.checkRunID(id)
        guard isLocalRunID(id) else { throw HolosError.invalidInput("\(id) is not a local run ID (local-…).") }
        guard let record = try EvalStore.read(LocalRunRecord.self, from: EvalPaths.localRecord(id, in: session))
        else { return nil }
        guard record.id == id, record.tracks.allSatisfy({ SessionArchive.validToken($0.track) }),
              !record.languages.isEmpty, record.languages.allSatisfy(SessionArchive.validToken) else {
            throw HolosError.invalidInput("eval/local/\(id)/run.json does not describe run \(id).")
        }
        let owner = try sessionID ?? SessionArchive.readManifest(at: session).id
        guard record.sessionID == owner else { throw HolosError.invalidInput("Run \(id) belongs to another session.") }
        return record
    }

    /// The finished run `spec` names ("latest", or an ID).
    public static func resolve(_ spec: String, in session: URL) throws -> LocalRunRecord {
        if spec == "latest" {
            for id in runIDs(in: session).reversed() {
                if let record = try? record(id, in: session), record.completedAt != nil { return record }
            }
            throw HolosError.invalidInput("This session has no finished local run yet; run voiceislocal eval local "
                + "first.")
        }
        guard let record = try record(spec, in: session) else {
            throw HolosError.invalidInput("There is no local run \(spec) in this session (see voiceislocal eval list).")
        }
        guard record.completedAt != nil else {
            throw HolosError.incomplete("Local run \(spec) has not finished; run voiceislocal eval local again to "
                + "resume it.")
        }
        return record
    }

    /// The candidate transcript of a finished run.
    public static func transcript(of record: LocalRunRecord, in session: URL) throws -> Transcript {
        guard let transcript = try EvalStore.read(Transcript.self, from: EvalPaths.localTranscript(record.id, in: session)),
              transcript.id == record.transcriptID else {
            throw HolosError.invalidInput("eval/local/\(record.id)/transcript.json is missing or damaged; delete "
                + "the run and make it again.")
        }
        return transcript
    }

    static func part(_ record: LocalRunRecord, language: String, track: String, in session: URL) -> LocalRunPart? {
        guard let part = try? EvalStore.read(LocalRunPart.self, from: EvalPaths.localPart(
            record.id, language: language, track: track, in: session)),
              part.language == language, part.track == track else { return nil }
        return part
    }

    /// How many of a run's (language, track) transcriptions are saved.
    public static func savedParts(_ record: LocalRunRecord, in session: URL) -> Int {
        record.languages.reduce(0) { count, language in
            count + record.tracks.filter { part(record, language: language, track: $0.track, in: session) != nil }.count
        }
    }

    /// The languages a run transcribes: `language`, else meeting.json's, else the recording's locale.
    public static func languages(session: URL, language: String?) throws -> [String] {
        let manifest = try SessionArchive.readManifest(at: session)
        let chosen = language.map { [$0] } ?? CloudEvaluation.meetingLanguages(session: session, manifest: manifest)
        var seen = Set<String>()
        let languages = chosen.map(DictationLanguage.identifier).filter { seen.insert($0).inserted }
        for language in languages where !SessionArchive.validToken(language) {
            throw HolosError.invalidInput("\(language) is not a language identifier (like en-CA).")
        }
        return languages
    }

    /// Transcribes every track of the session in each language (`languages`), with `vocabulary` (nil: none) as
    /// contextual strings, and saves the candidate. Resumes the newest unfinished run with the same languages,
    /// vocabulary, and audio (or `options.runID`): a (language, track) transcription already saved is not made again.
    /// Refuses a session that is recording or whose audio was deleted, and a language whose speech model is not
    /// installed. The caller holds the session's processing lease. Cancellation keeps what is saved.
    public static func run(session: URL, options: Options, vocabulary: [String]?,
                           dependencies: LanguageDetectionDependencies = .live, now: Date = Date(),
                           wordFixes: WordFixDependencies = .none,
                           deepTranscription: DeepTranscriptionDependencies = .none,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> LocalRunRecord {
        guard try !SessionArchive.isActive(at: session) else {
            throw HolosError.unavailable("This session is still recording; stop it first.")
        }
        let manifest = try SessionArchive.readManifest(at: session)
        // A recording that stopped without finishing (a crash) may have saved audio its manifest does not list yet:
        // recover it first, so every saved chunk is included.
        guard ![ArchiveStatus.recording, ArchiveStatus.interrupted].contains(manifest.status) else {
            throw HolosError.unavailable("This session was not finished properly; run voiceislocal session recover "
                + "\(manifest.id) first, so all of its saved audio is included.")
        }
        guard try !AudioDeletedRecord.isDeleted(session: session, sessionID: manifest.id) else {
            throw HolosError.invalidInput("This session's audio was deleted; there is nothing to transcribe.")
        }
        let trackNames = CloudEvaluation.orderedTracks(Set(manifest.chunks.map(\.track)))
        guard !trackNames.isEmpty else { throw HolosError.invalidInput("This session has no saved audio.") }
        progress("Checking the saved audio…")
        let tracks = try trackNames.map { track in
            LocalRunRecord.Track(track: track, audioFingerprint: EvalStore.audioFingerprint(manifest: manifest,
                                                                                            track: track),
                                 contentSHA256: try contentDigest(session: session, manifest: manifest, track: track),
                                 seconds: manifest.audioSeconds(track: track))
        }
        // A run resumed by name keeps the languages it began with, whatever the meeting's are now.
        let resumed = try options.runID.map { id in
            guard let found = try Self.record(id, in: session, sessionID: manifest.id) else {
                throw HolosError.invalidInput("There is no local run \(id) in this session (see voiceislocal eval list).")
            }
            return found
        }
        // Whisper transcribes in the current transcript's language, as the deep transcription pass does.
        let languages: [String]
        if let resumed, options.language == nil {
            languages = resumed.languages
        } else {
            languages = try (options.backend == .whisper && options.language == nil
                ? whisperLanguages(session: session, manifest: manifest) : nil)
                ?? Self.languages(session: session, language: options.language)
        }
        let engine = options.backend == .whisper ? deepTranscription.engine : nil
        if engine != nil, resumed == nil, languages.count > 1 {
            throw HolosError.invalidInput("Deep transcription handles one language; pass --language with one of "
                + languages.joined(separator: ", ") + ".")
        }
        // A language asked for by name is kept to: one Whisper has no token for is refused, never detected under its
        // name.
        if engine != nil, let asked = options.language, DeepTranscriptionModel.whisperLanguage(asked) == nil {
            throw HolosError.invalidInput("Whisper does not transcribe \(asked); choose another language, or leave out "
                + "--language to use the meeting's.")
        }
        let strings = vocabulary ?? []
        let source = vocabulary == nil ? "none" : "current"
        let textSteps = options.wordFixes ? [PostProcessingStage.wordFixes.rawValue] : []

        var record: LocalRunRecord
        var isNew = false
        if let found = resumed {
            let id = found.id
            guard found.completedAt == nil else {
                throw HolosError.invalidInput("Local run \(id) is complete; there is nothing to resume.")
            }
            guard found.tracks == tracks else {
                throw HolosError.invalidInput("The audio changed since local run \(id) started; start a new run.")
            }
            guard found.languages == languages || options.language == nil,
                  found.vocabularySource == source || (options.savedVocabulary && found.vocabularySource != "none"),
                  found.textSteps == textSteps, found.engine == engine
            else {
                throw HolosError.invalidInput("Local run \(id) was started with other options ("
                    + found.languages.joined(separator: ",")
                    + (found.vocabularySource == "none" ? ", --no-vocabulary" : "")
                    + (found.textSteps.contains(PostProcessingStage.wordFixes.rawValue) ? "" : ", --no-word-fixes")
                    + (found.engine == nil ? "" : ", --backend whisper")
                    + "); resume it with the same.")
            }
            // A resumed run keeps the vocabulary it started with, so its tracks are all heard alike.
            record = found
        } else if let found = latestResumable(session: session, sessionID: manifest.id, languages: languages,
                                              backend: manifest.backend, vocabulary: strings, source: source,
                                              textSteps: textSteps, tracks: tracks, engine: engine) {
            record = found
        } else {
            record = LocalRunRecord(id: newRunID(at: now), sessionID: manifest.id, createdAt: now,
                                    languages: languages, backend: manifest.backend, vocabulary: strings,
                                    vocabularySource: source, textSteps: textSteps, tracks: tracks, engine: engine)
            if FileManager.default.fileExists(atPath: EvalPaths.localRun(record.id, in: session).path) {
                throw HolosError.unavailable("Local run \(record.id) already exists; try again in a second.")
            }
            isNew = true
        }

        // A language whose transcription recognized no words on any track, where the current transcript has some (or
        // where there is none), failed rather than heard silence, as the languages stage treats it: nothing is saved
        // for it, so the same command tries again. One silent track, or a language heard on only some tracks, is fine.
        let current = try? SessionFiles.currentTranscript(session: session)
        let expectsWords = current.map { LanguageStage.hasWords($0.segments) } ?? true
        var parts: [String: [String: LocalRunPart]] = [:]
        var missing: [(language: String, track: LocalRunRecord.Track)] = []
        for language in record.languages {
            var saved: [String: LocalRunPart] = [:]
            for track in record.tracks {
                saved[track.track] = part(record, language: language, track: track.track, in: session)
            }
            // Parts saved with no words while none were expected (the transcript had none then), where some are now:
            // the language is transcribed again, or it would fail on every resume.
            if expectsWords, !saved.isEmpty, !saved.values.contains(where: { LanguageStage.hasWords($0.segments) }) {
                for track in saved.keys {
                    try? FileManager.default.removeItem(at: EvalPaths.localPart(record.id, language: language,
                                                                                track: track, in: session))
                }
                saved = [:]
            }
            for track in record.tracks {
                if let part = saved[track.track] {
                    parts[language, default: [:]][track.track] = part
                } else {
                    missing.append((language, track))
                }
            }
        }
        // The deep transcription model, when it transcribes: installed, loaded, and its prompt made (once per run).
        var whisper: (transcriber: any DeepTranscriber, reference: Transcript?)?
        if record.engine != nil, !missing.isEmpty {
            guard deepTranscription.modelStatus() == .installed else {
                throw HolosError.unavailable(DeepTranscriptionModel.missingModelMessage)
            }
            progress("Loading the deep transcription model…")
            let transcriber = try await deepTranscription.makeTranscriber()
            if record.prompt == nil {
                let built = try await DeepTranscriptionPrompt.build(
                    meetingName: record.vocabularySource == "none" ? nil : manifest.name, candidates: record.vocabulary,
                    tokenCount: { try await transcriber.promptTokenCount($0) })
                record.prompt = built.text
                progress("Prompt: \(built.terms.count) of \(record.vocabulary.count) vocabulary terms, "
                    + "\(built.tokens) tokens.")
                if !isNew { try EvalStore.write(record, to: EvalPaths.localRecord(record.id, in: session)) }
            }
            // The guards' reference: the one this run began with when it is resumed, so every track is guarded alike.
            let reference: Transcript?
            if record.referenceTranscriptID == LocalRunRecord.noReference {
                reference = nil
            } else if let id = record.referenceTranscriptID {
                do {
                    reference = try SessionFiles.transcript(id: id, session: session)
                } catch {
                    throw HolosError.incomplete("The transcript local run \(record.id) was checked against cannot be "
                        + "read (\(error.localizedDescription)); start a new run.")
                }
            } else {
                // Only a session with no current transcript runs unguarded: one that cannot be read is an error.
                let readable: Transcript?
                let events: [ArchiveEvent]
                do {
                    readable = try SessionFiles.currentTranscript(session: session)
                    events = try SessionArchive.readEvents(at: session).events
                } catch {
                    throw HolosError.incomplete("The meeting's transcript cannot be read (\(error.localizedDescription)"
                        + "), so the run could not be checked against it.")
                }
                reference = readable.flatMap {
                    DeepTranscriptionStage.recordedBase(of: $0, events: events, session: session).reference
                }
                if record.referenceTranscriptID == nil {
                    record.referenceTranscriptID = reference?.id ?? LocalRunRecord.noReference
                    if !isNew { try EvalStore.write(record, to: EvalPaths.localRecord(record.id, in: session)) }
                }
            }
            whisper = (transcriber, reference)
        }
        // Every language still to transcribe must have its speech model, before anything is saved.
        for language in Set(missing.map(\.language)).sorted() where record.engine == nil {
            try Task.checkCancellation()
            let check = dependencies.modelStatus
            let backend = record.backend
            var status = "unsupported"
            // The asset inventory is a platform call, waited for within the stop path's limit as the stage does.
            if let limit = dependencies.timeouts?.speechFinishBase {
                switch await awaitWithTimeout(limit, { await check(language, backend) }) {
                case .finished(.success(let value)): status = value
                case .finished(.failure): status = "unsupported"
                case .cancelled: throw CancellationError()
                case .timedOut:
                    throw HolosError.unavailable("The speech model for \(LanguageStage.name(language)) did not "
                        + "answer in time; try again.")
                }
            } else {
                status = await check(language, backend)
            }
            guard status == "installed" else {
                let state = status == "unsupported" ? "is not supported on this Mac"
                    : status == "downloading" ? "is still downloading" : "is not installed"
                throw HolosError.unavailable("The speech model for \(LanguageStage.name(language)) \(state); "
                    + "install it with voiceislocal setup --locale \(language), then run this again.")
            }
        }
        if isNew { try EvalStore.write(record, to: EvalPaths.localRecord(record.id, in: session)) }
        progress("Local run \(record.id): \(record.partCount - missing.count) of \(record.partCount) track "
            + "transcriptions saved; \(record.vocabulary.count) vocabulary strings.")
        // Parts with no words wait until their language is known to have words somewhere (a saved part, or one
        // transcribed now), and are saved as soon as it is: a later track that fails does not lose them.
        var silent: [LocalRunPart] = []
        func save(_ part: LocalRunPart) throws {
            try EvalStore.write(part, to: EvalPaths.localPart(record.id, language: part.language, track: part.track,
                                                             in: session))
        }
        func hasWords(_ language: String) -> Bool {
            (parts[language] ?? [:]).values.contains { LanguageStage.hasWords($0.segments) }
        }
        for (language, track) in missing {
            try Task.checkCancellation()
            let label = "the \(track.track) track in \(LanguageStage.name(language))"
            progress("Transcribing \(label) (\(Int(track.seconds.rounded())) s of audio)…")
            let segments: [TranscriptSegment]
            if let whisper {
                segments = try await transcribeDeep(session: session, manifest: manifest, track: track,
                                                    language: language, record: record,
                                                    transcriber: whisper.transcriber, reference: whisper.reference,
                                                    freeSpace: freeSpace, note: progress) { percent in
                    progress("  \(label): \(percent) %")
                }
            } else {
                segments = try await transcribe(session: session, track: track, language: language, record: record,
                                                dependencies: dependencies) { percent in
                    progress("  \(label): \(percent) %")
                }
            }
            try Task.checkCancellation()
            let part = LocalRunPart(language: language, track: track.track, segments: segments, finishedAt: Date())
            parts[language, default: [:]][track.track] = part
            guard !expectsWords || hasWords(language) else {
                silent.append(part)
                continue
            }
            try save(part)
            for waiting in silent where waiting.language == language { try save(waiting) }
            silent.removeAll { $0.language == language }
        }
        // What still waits belongs to a language that heard nothing: it is not saved.
        let failed = expectsWords ? record.languages.filter { !hasWords($0) } : []
        if !failed.isEmpty {
            let names = LanguageStage.names(failed)
            throw HolosError.unavailable("No words were recognized in \(names) on any track"
                + (current == nil ? "" : ", although the meeting's transcript has some")
                + "; nothing was saved for it. Run the same command again to try again.")
        }

        var transcript = try assemble(record: record, parts: parts, session: session, manifest: manifest,
                                      scorer: dependencies.makeScorer())
        if record.textSteps.contains(PostProcessingStage.wordFixes.rawValue) {
            transcript = try await applyingWordFixes(to: transcript, title: manifest.name,
                                                     dependencies: wordFixes, progress: progress)
        }
        try Task.checkCancellation()
        try EvalStore.write(transcript, to: EvalPaths.localTranscript(record.id, in: session))
        record.transcriptID = transcript.id
        record.completedAt = now
        try EvalStore.write(record, to: EvalPaths.localRecord(record.id, in: session))
        return record
    }

    /// SHA-256 of a track's chunk files, in the manifest's time order, read in pieces.
    static func contentDigest(session: URL, manifest: SessionManifest, track: String) throws -> String {
        var hasher = SHA256()
        let chunks = manifest.chunks.filter { $0.track == track }
            .sorted { ($0.start, $0.relativePath) < ($1.start, $1.relativePath) }
        for chunk in chunks {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: session.appendingPathComponent(chunk.relativePath))
            defer { try? handle.close() }
            hasher.update(data: Data(chunk.relativePath.utf8))
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The newest unfinished run with these settings.
    private static func latestResumable(session: URL, sessionID: String, languages: [String], backend: SpeechBackend,
                                        vocabulary: [String], source: String, textSteps: [String],
                                        tracks: [LocalRunRecord.Track], engine: String?) -> LocalRunRecord? {
        for id in runIDs(in: session).reversed() {
            guard let record = try? record(id, in: session, sessionID: sessionID), record.completedAt == nil else {
                continue
            }
            if record.languages == languages, record.backend == backend, record.vocabulary == vocabulary,
               record.vocabularySource == source, record.textSteps == textSteps, record.tracks == tracks,
               record.engine == engine {
                return record
            }
        }
        return nil
    }

    /// Applies stage 1d without publishing to the meeting. With no configured fixes, or no matching words, the
    /// recognized candidate is kept exactly as assembled; the run still records that the step was checked.
    private static func applyingWordFixes(to transcript: Transcript, title: String,
                                          dependencies: WordFixDependencies,
                                          progress: @escaping @Sendable (String) -> Void) async throws -> Transcript {
        let corrections: CorrectionList
        let terms: CorrectionList
        do {
            corrections = try dependencies.corrections()
            terms = CorrectionList(entries: try dependencies.wordList().heardAsPairs)
        } catch {
            throw HolosError.invalidInput("Could not read the meeting word fixes (pass --no-word-fixes to skip them): "
                + error.localizedDescription)
        }
        guard !corrections.entries.isEmpty || !terms.entries.isEmpty else { return transcript }
        progress("Fixing misheard words in the local candidate…")
        let computed = try await WordFixStage.fix(transcript, title: title, corrections: corrections, terms: terms,
                                                  dependencies: dependencies)
        for note in computed.notes { progress("Note: \(note)") }
        return computed.counts.total == 0 ? transcript : computed.transcript
    }

    /// One track in one language, from the saved audio, as the languages stage transcribes it (`TrackReplayer`,
    /// the stop path's time limits); `progress` gets whole tens of percent.
    private static func transcribe(session: URL, track: LocalRunRecord.Track, language: String,
                                   record: LocalRunRecord, dependencies: LanguageDetectionDependencies,
                                   progress: @escaping @Sendable (Int) -> Void) async throws -> [TranscriptSegment] {
        let total = max(track.seconds, 1e-9)
        let fed = LockedValue((seconds: 0.0, step: 0))
        let base = dependencies.makeSpeech
        let counting: LiveSpeechFactory = { locale, backend, contextualStrings, onUpdate in
            let speech = try await base(locale, backend, contextualStrings, onUpdate)
            return CountingSpeechSession(base: speech) { duration in
                let step = fed.withLock { value -> Int? in
                    value.seconds += duration
                    let step = Int(min(1, value.seconds / total) * 10)
                    guard step > value.step, step < 10 else { return nil }
                    value.step = step
                    return step
                }
                if let step { progress(step * 10) }
            }
        }
        do {
            return try await TrackReplayer.replay(directory: session, track: track.track, locale: language,
                                                  backend: record.backend, contextualStrings: record.vocabulary,
                                                  makeSpeech: counting, timeouts: dependencies.timeouts)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw HolosError.incomplete("Could not transcribe the \(track.track) track in "
                + "\(LanguageStage.name(language)): \(error.localizedDescription) What is saved is kept; run the "
                + "same command again to resume.")
        }
    }

    /// One track transcribed by the deep transcription model as the deep transcription pass does it (rendered next to
    /// the run and deleted, in pieces, with the run's prompt, the guards against `reference`); `progress` gets whole
    /// tens of percent and `note` what the guards left out.
    private static func transcribeDeep(session: URL, manifest: SessionManifest, track: LocalRunRecord.Track,
                                       language: String, record: LocalRunRecord, transcriber: any DeepTranscriber,
                                       reference: Transcript?, freeSpace: any FreeSpaceProvider,
                                       note: @escaping @Sendable (String) -> Void,
                                       progress: @escaping @Sendable (Int) -> Void) async throws -> [TranscriptSegment] {
        let total = max(1e-9, TrackRenderer.renderedSeconds(manifest: manifest, track: track.track))
        // The whole track is rendered before it is transcribed: refused, as the pass refuses it, when the render would
        // not fit with the headroom kept free. Unmeasurable: tried (a render that runs out of space fails).
        if let free = try? freeSpace.availableBytes(at: EvalPaths.localRun(record.id, in: session)),
           !SpeakerAnalysis.renderAllowed(freeBytes: free, renderSeconds: total) {
            throw HolosError.unavailable(DeepTranscriptionStage.noDiskSpace)
        }
        let step = LockedValue(0)
        do {
            let heard = try await DeepTranscriptionStage.transcribeTrack(
                track.track, session: session, manifest: manifest,
                renderTo: EvalPaths.localRun(record.id, in: session).appendingPathComponent("deep-\(track.track)-16k.caf"),
                transcriber: transcriber, language: DeepTranscriptionModel.whisperLanguage(language),
                prompt: record.prompt ?? "", reference: reference) { seconds in
                    let next = step.withLock { value -> Int? in
                        let reached = Int(min(1, seconds / total) * 10)
                        guard reached > value, reached < 10 else { return nil }
                        value = reached
                        return reached
                    }
                    if let next { progress(next * 10) }
                }
            let built = DeepTranscriptionStage.segments(heard, reference: reference)
            if !built.lost.isEmpty {
                throw HolosError.incomplete(DeepTranscriptionStage.lostMessage(built.lost))
            }
            note("  \(track.track): \(built.segments.count) passages; left out \(built.guards.droppedSilent) over "
                + "silence and \(built.guards.droppedRepeats) repeats.")
            return built.segments
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw HolosError.incomplete("Could not transcribe the \(track.track) track with the deep transcription "
                + "model: \(error.localizedDescription) What is saved is kept; run the same command again to resume.")
        }
    }

    /// The candidate transcript: one language's tracks in time order, or several languages merged as the languages
    /// stage merges them (`LanguageMerge`, with microphone echo of a call found in each language's transcription).
    static func assemble(record: LocalRunRecord, parts: [String: [String: LocalRunPart]], session: URL,
                         manifest: SessionManifest, scorer: LanguageMerge.Scorer) throws -> Transcript {
        func segments(_ language: String) -> [TranscriptSegment] {
            record.tracks.flatMap { parts[language]?[$0.track]?.segments ?? [] }
                .sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        }
        guard record.languages.count > 1, let primary = record.languages.first else {
            return Transcript(source: session.path, locale: record.languages[0], backend: record.backend,
                              segments: segments(record.languages[0]), engine: record.engine)
        }
        let echo: AlignmentParameters? = {
            guard let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest) else { return nil }
            let parameters = SpeakerAnalysis.alignmentParameters(meeting: meeting)
            return parameters.echoWindowSeconds == nil ? nil : parameters
        }()
        let candidates = record.languages.map { language in
            let heard = segments(language)
            let spans = echo.map { parameters in
                EchoFilter.echoSpans(transcript: Transcript(source: session.path, locale: language,
                                                            backend: record.backend, segments: heard),
                                     parameters: parameters)
            } ?? []
            return LanguageMerge.Candidate(language: language, segments: heard, echo: spans)
        }
        let merged = LanguageMerge.merge(candidates, scorer: scorer)
        return Transcript(source: session.path, locale: primary, backend: record.backend, segments: merged.segments,
                          languages: record.languages)
    }
}
