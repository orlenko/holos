import CryptoKit
import Foundation
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
        public var contentSHA256: String
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
    /// Text steps applied after recognition, in order. A meeting applies none today (corrections, filler removal,
    /// and spoken-code formatting are dictation steps), so neither does a candidate.
    public var textSteps: [String] = []
    public var tracks: [Track]
    /// Set once every track is transcribed in every language and transcript.json is written.
    public var completedAt: Date?
    public var transcriptID: String?

    public var seconds: Double { tracks.reduce(0) { $0 + $1.seconds } }
    public var partCount: Int { languages.count * tracks.count }
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

        public init(language: String? = nil, runID: String? = nil) { self.language = language; self.runID = runID }
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
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> LocalRunRecord {
        guard try !SessionArchive.isActive(at: session) else {
            throw HolosError.unavailable("This session is still recording; stop it first.")
        }
        let manifest = try SessionArchive.readManifest(at: session)
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
        let languages = try Self.languages(session: session, language: options.language)
        let strings = vocabulary ?? []
        let source = vocabulary == nil ? "none" : "current"

        var record: LocalRunRecord
        var isNew = false
        if let id = options.runID {
            guard let found = try Self.record(id, in: session, sessionID: manifest.id) else {
                throw HolosError.invalidInput("There is no local run \(id) in this session (see voiceislocal eval list).")
            }
            guard found.completedAt == nil else {
                throw HolosError.invalidInput("Local run \(id) is complete; there is nothing to resume.")
            }
            guard found.tracks == tracks else {
                throw HolosError.invalidInput("The audio changed since local run \(id) started; start a new run.")
            }
            guard found.languages == languages || options.language == nil,
                  found.vocabularySource == source else {
                throw HolosError.invalidInput("Local run \(id) was started with other options ("
                    + found.languages.joined(separator: ",")
                    + (found.vocabularySource == "none" ? ", --no-vocabulary" : "") + "); resume it with the same.")
            }
            // A resumed run keeps the vocabulary it started with, so its tracks are all heard alike.
            record = found
        } else if let found = latestResumable(session: session, sessionID: manifest.id, languages: languages,
                                              backend: manifest.backend, vocabulary: strings, source: source,
                                              tracks: tracks) {
            record = found
        } else {
            record = LocalRunRecord(id: newRunID(at: now), sessionID: manifest.id, createdAt: now,
                                    languages: languages, backend: manifest.backend, vocabulary: strings,
                                    vocabularySource: source, tracks: tracks)
            if FileManager.default.fileExists(atPath: EvalPaths.localRun(record.id, in: session).path) {
                throw HolosError.unavailable("Local run \(record.id) already exists; try again in a second.")
            }
            isNew = true
        }

        var parts: [String: [String: LocalRunPart]] = [:]
        var missing: [(language: String, track: LocalRunRecord.Track)] = []
        for language in record.languages {
            for track in record.tracks {
                if let saved = part(record, language: language, track: track.track, in: session) {
                    parts[language, default: [:]][track.track] = saved
                } else {
                    missing.append((language, track))
                }
            }
        }
        // Every language still to transcribe must have its speech model, before anything is saved.
        for language in Set(missing.map(\.language)).sorted() {
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
        for (language, track) in missing {
            try Task.checkCancellation()
            let label = "the \(track.track) track in \(LanguageStage.name(language))"
            progress("Transcribing \(label) (\(Int(track.seconds.rounded())) s of audio)…")
            let segments = try await transcribe(session: session, track: track, language: language, record: record,
                                                dependencies: dependencies) { percent in
                progress("  \(label): \(percent) %")
            }
            try Task.checkCancellation()
            let saved = LocalRunPart(language: language, track: track.track, segments: segments, finishedAt: Date())
            try EvalStore.write(saved, to: EvalPaths.localPart(record.id, language: language, track: track.track,
                                                              in: session))
            parts[language, default: [:]][track.track] = saved
        }

        let transcript = try assemble(record: record, parts: parts, session: session, manifest: manifest,
                                      scorer: dependencies.makeScorer())
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
                                        vocabulary: [String], source: String,
                                        tracks: [LocalRunRecord.Track]) -> LocalRunRecord? {
        for id in runIDs(in: session).reversed() {
            guard let record = try? record(id, in: session, sessionID: sessionID), record.completedAt == nil else {
                continue
            }
            if record.languages == languages, record.backend == backend, record.vocabulary == vocabulary,
               record.vocabularySource == source, record.tracks == tracks {
                return record
            }
        }
        return nil
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
                              segments: segments(record.languages[0]))
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
