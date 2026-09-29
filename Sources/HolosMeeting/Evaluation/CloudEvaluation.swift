import Foundation
import HolosAudio
import HolosCore
import HolosStorage

/// Whether to go ahead with an upload (`voiceislocal eval cloud`): only an explicit yes, typed at a terminal or given
/// as `--yes`, uploads anything.
public enum ConsentGate {
    public enum Decision: Sendable, Equatable {
        case proceed
        case declined
        /// No terminal to ask at and no `--yes`.
        case noTerminal
    }

    /// `readAnswer` is called only when a terminal can answer; "y" or "yes" (any case) proceeds, anything else,
    /// including end of input, declines.
    public static func decide(assumeYes: Bool, isTerminal: Bool, readAnswer: () -> String?) -> Decision {
        if assumeYes { return .proceed }
        guard isTerminal else { return .noTerminal }
        let answer = readAnswer()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes" ? .proceed : .declined
    }
}

/// `voiceislocal eval cloud` (docs/reference-evaluation.md, "Cloud reference"): renders a session's tracks, cuts them
/// into segments, and — after consent — uploads each segment to OpenAI and saves each answer as it arrives.
public enum CloudEvaluation {
    public struct Options: Sendable, Equatable {
        public var model: String
        /// Tracks to send; nil for every track with audio.
        public var tracks: [String]?
        public var vocabulary: Bool
        public var timestamps: Bool
        /// A run to resume; nil resumes the newest unfinished run with the same settings, or starts a new one.
        public var runID: String?
        public var segmentation: CloudSegmentation.Settings

        public init(model: String = CloudModels.defaultModel, tracks: [String]? = nil, vocabulary: Bool = false,
                    timestamps: Bool = false, runID: String? = nil,
                    segmentation: CloudSegmentation.Settings = CloudSegmentation.Settings()) {
            self.model = model; self.tracks = tracks; self.vocabulary = vocabulary; self.timestamps = timestamps
            self.runID = runID; self.segmentation = segmentation
        }
    }

    /// The word list, people's names, and correction terms for `--vocabulary` (read only when it is given, and only
    /// for a new run). A source that cannot be read throws, so a run never goes out with less than was asked for.
    public struct VocabularySource: Sendable {
        public var wordList: @Sendable () throws -> [String]
        public var names: @Sendable () throws -> [String]
        public var terms: @Sendable (_ languages: [String]) throws -> [String]

        public init(wordList: @escaping @Sendable () throws -> [String],
                    names: @escaping @Sendable () throws -> [String],
                    terms: @escaping @Sendable (_ languages: [String]) throws -> [String]) {
            self.wordList = wordList; self.names = names; self.terms = terms
        }
    }

    /// A run ready to upload: its plan, and what is left to send.
    public struct Prepared: Sendable {
        public var session: URL
        public var sessionName: String
        public var record: CloudRunRecord
        public var resumed: Bool
        /// Segments (not silent) still without a saved result, per track.
        public var pending: [String: [Int]]
        /// Rendered track files in the run's work folder.
        public var renders: [String: URL]

        public var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }

        public var pendingSeconds: Double {
            record.tracks.reduce(0) { total, track in
                let wanted = Set(pending[track.track] ?? [])
                return total + track.segments.filter { wanted.contains($0.index) }
                    .reduce(0) { $0 + $1.seconds(sampleRate: track.sampleRate) }
            }
        }

        /// Requests left: one per pending segment, two with the timestamp pass.
        public var pendingRequests: Int { pendingCount * (record.timestampRequest == nil ? 1 : 2) }

        /// Estimated cost of what is left, or nil when a model's price is unknown.
        public var estimatedCost: Double? {
            guard let main = CloudModels.estimate(model: record.model, seconds: pendingSeconds) else { return nil }
            guard let timestamps = record.timestampRequest else { return main }
            return CloudModels.estimate(model: timestamps.model, seconds: pendingSeconds).map { main + $0 }
        }

        /// What will be sent, for the consent question.
        public var summaryLines: [String] {
            var lines: [String] = []
            lines.append("Session: \(sessionName)")
            lines.append((resumed ? "Resuming run " : "New run ") + record.id)
            for track in record.tracks {
                let pendingSegments = Set(pending[track.track] ?? [])
                let seconds = track.segments.filter { pendingSegments.contains($0.index) }
                    .reduce(0) { $0 + $1.seconds(sampleRate: track.sampleRate) }
                let silent = track.segments.filter(\.silent).count
                lines.append("  \(track.track): \(Self.minutes(seconds)) min in \(pendingSegments.count) of "
                    + "\(track.segments.count) segments" + (silent > 0 ? " (\(silent) silent, not sent)" : ""))
            }
            lines.append("Model: \(record.model)" + (record.timestampRequest.map { ", plus \($0.model) for word timestamps" } ?? ""))
            lines.append("Languages: " + (record.request.languages.isEmpty ? "detected by the model"
                : record.request.languages.joined(separator: ", ")))
            if record.vocabulary {
                lines.append("Vocabulary: \(record.request.keywords.count) keywords"
                    + (record.request.prompt == nil ? "" : " and a prompt")
                    + " (word list, people's names, and correction words)")
            }
            lines.append("To upload: \(Self.minutes(pendingSeconds)) min of audio in \(pendingRequests) "
                + (pendingRequests == 1 ? "request" : "requests"))
            if let cost = estimatedCost {
                lines.append(String(format: "Estimated cost: US$%.3f", locale: Locale(identifier: "en_US_POSIX"), cost)
                    + " at OpenAI's list price")
            } else {
                lines.append("Estimated cost: unknown (no list price recorded for this model)")
            }
            return lines
        }

        static func minutes(_ seconds: Double) -> String {
            String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds / 60)
        }
    }

    /// Plans the run: resumes one (`options.runID`, or the newest unfinished run with the same model, tracks,
    /// vocabulary, and timestamp settings) or plans a new one, and renders its tracks into the run's work folder (a
    /// resumed run's every track, whose segment digests must match the plan's). Uploads nothing and, for a new run, saves nothing but the renders.
    /// The caller holds the session's processing lease.
    public static func prepare(session: URL, options: Options, vocabulary: VocabularySource,
                               now: Date = Date(),
                               progress: @Sendable (String) -> Void = { _ in }) throws -> Prepared {
        guard CloudModels.isValidName(options.model) else {
            throw HolosError.invalidInput("\(options.model) is not a model name (letters, digits, \"-\" and \"_\").")
        }
        guard try !SessionArchive.isActive(at: session) else {
            throw HolosError.unavailable("This session is still recording; stop it first.")
        }
        let manifest = try SessionArchive.readManifest(at: session)
        guard try !AudioDeletedRecord.isDeleted(session: session, sessionID: manifest.id) else {
            throw HolosError.invalidInput("This session's audio was deleted; there is nothing to send.")
        }
        let available = orderedTracks(Set(manifest.chunks.map(\.track)))
        let tracks = try options.tracks.map { wanted in
            for track in wanted where !available.contains(track) {
                throw HolosError.invalidInput("This session has no \(track) track (it has: "
                    + available.joined(separator: ", ") + ").")
            }
            return orderedTracks(Set(wanted))
        } ?? available
        guard !tracks.isEmpty else { throw HolosError.invalidInput("This session has no saved audio.") }

        var record: CloudRunRecord
        var resumed = false
        if let id = try options.runID.map({ try resumable(id: $0, session: session) })
            ?? latestResumable(session: session, options: options, tracks: tracks) {
            record = id
            resumed = true
            // An explicit --run must not send anything its options did not ask for.
            let recordTracks = record.tracks.map(\.track)
            if record.model != options.model || (options.tracks != nil && recordTracks != tracks)
                || record.vocabulary != options.vocabulary || (record.timestampRequest != nil) != options.timestamps {
                throw HolosError.invalidInput("Run \(record.id) was started with --model \(record.model) --tracks "
                    + recordTracks.joined(separator: ",") + (record.vocabulary ? " --vocabulary" : "")
                    + (record.timestampRequest != nil ? " --timestamps" : "")
                    + "; resume it with the same options.")
            }
            for track in record.tracks
            where EvalStore.audioFingerprint(manifest: manifest, track: track.track) != track.audioFingerprint {
                throw HolosError.invalidInput("The \(track.track) audio changed since run \(record.id) started; "
                    + "start a new run (delete this one with voiceislocal eval delete).")
            }
        } else {
            let languages = meetingLanguages(session: session, manifest: manifest)
            let request = requestFields(model: options.model, languages: languages, vocabulary: options.vocabulary
                ? CloudVocabulary.build(languages: languages, wordList: try vocabulary.wordList(),
                                        names: try vocabulary.names(), terms: try vocabulary.terms(languages)) : nil)
            let timestampRequest = options.timestamps
                ? CloudRequestFields(model: CloudModels.timestampModel, responseFormat: "verbose_json",
                                     languages: request.languages, prompt: request.prompt,
                                     timestampGranularities: ["word"]) : nil
            record = CloudRunRecord(id: EvalStore.newRunID(model: options.model, at: now), sessionID: manifest.id,
                                    createdAt: now, request: request, timestampRequest: timestampRequest,
                                    vocabulary: options.vocabulary, maxSegmentSeconds: options.segmentation.maxSeconds,
                                    tracks: [])
            if FileManager.default.fileExists(atPath: EvalPaths.cloudRun(record.id, in: session).path) {
                throw HolosError.unavailable("Run \(record.id) already exists; try again in a second.")
            }
        }

        var renders: [String: URL] = [:]
        var pending: [String: [Int]] = [:]
        let work = EvalPaths.work(record.id, in: session)
        var plans: [CloudTrackPlan] = []
        for track in resumed ? record.tracks.map(\.track) : tracks {
            try Task.checkCancellation()
            let existing = record.tracks.first { $0.track == track }
            let missing = existing.map { plan in
                plan.segments.filter { !$0.silent && !isSaved(record, track: track, index: $0.index, session: session) }
                    .map(\.index)
            }
            // A resumed track is rendered and checked even when every answer is in: its answers are kept only for
            // the audio they answered.
            progress("Preparing the \(track) audio…")
            let url = work.appendingPathComponent("\(track).caf")
            let rendered = try EvalAudio.render(session: session, manifest: manifest, track: track, to: url)
            renders[track] = url
            if let existing {
                // The saved answers are kept only for the very audio they answered: the same shape, and the same
                // samples in every segment (a chunk replaced by other audio of the same length changes a digest).
                let digests = try EvalAudio.segmentDigests(
                    of: url, ranges: existing.segments.map { ($0.startFrame, $0.endFrame) })
                guard rendered.frameCount == existing.frameCount,
                      rendered.timeMap.map(EvalSpan.init) == existing.timeMap,
                      existing.segments.map(\.audioSHA256) == digests.map(Optional.some) else {
                    throw HolosError.invalidInput("The \(track) audio renders differently than when run \(record.id) "
                        + "started; start a new run (delete this one with voiceislocal eval delete).")
                }
                plans.append(existing)
                pending[track] = missing
            } else {
                let rms = try EvalAudio.rms(of: url, windowSeconds: options.segmentation.windowSeconds)
                var segments = CloudSegmentation.plan(frameCount: rendered.frameCount, sampleRate: rendered.sampleRate,
                                                      rms: rms, settings: options.segmentation)
                let digests = try EvalAudio.segmentDigests(of: url, ranges: segments.map { ($0.startFrame, $0.endFrame) })
                for index in segments.indices { segments[index].audioSHA256 = digests[index] }
                let plan = CloudTrackPlan(track: track, sampleRate: rendered.sampleRate,
                                          frameCount: rendered.frameCount, timeMap: rendered.timeMap.map(EvalSpan.init),
                                          audioFingerprint: EvalStore.audioFingerprint(manifest: manifest, track: track),
                                          segments: segments)
                plans.append(plan)
                pending[track] = segments.filter { !$0.silent }.map(\.index)
            }
        }
        record.tracks = plans
        return Prepared(session: session, sessionName: manifest.name, record: record, resumed: resumed,
                        pending: pending, renders: renders)
    }

    /// Removes a prepared run's renders without uploading (the user declined). A new run leaves nothing behind.
    public static func discard(_ prepared: Prepared) {
        _ = try? AtomicFile.removeTree(["derived", "eval-cloud"], in: prepared.session)
    }

    /// Removes the work folders runs left behind when their process ended (a second Ctrl-C). Called under the
    /// processing lease, when no run can be uploading.
    public static func removeStaleWork(session: URL) {
        _ = try? AtomicFile.removeTree(["derived", "eval-cloud"], in: session)
    }

    /// What `upload` did.
    public struct Outcome: Sendable, Equatable {
        public var uploaded: Int
        public var complete: Bool
    }

    /// Saves the run's plan, then sends each pending segment and saves its answer as soon as it arrives (the raw body,
    /// then the parsed result, whose presence marks the segment done), removing each segment's audio file after
    /// its upload. Once every segment is in, stitches each track into `<track>.json` and marks the run complete.
    /// The work folder is removed at the end, also on failure or cancellation; saved answers stay, so running the
    /// command again resumes. The caller holds the session's processing lease.
    public static func upload(_ prepared: Prepared, client: CloudTranscriptionClient, now: @Sendable () -> Date = Date.init,
                              progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        let session = prepared.session
        var record = prepared.record
        let work = EvalPaths.work(record.id, in: session)
        defer { _ = try? AtomicFile.removeTree(["derived", "eval-cloud"], in: session) }
        try EvalStore.write(record, to: EvalPaths.runRecord(record.id, in: session))
        let total = prepared.pendingCount
        var uploaded = 0
        for track in record.tracks {
            guard let indices = prepared.pending[track.track], !indices.isEmpty else { continue }
            guard let render = prepared.renders[track.track] else {
                throw HolosError.incomplete("The \(track.track) audio was not prepared.")
            }
            for index in indices {
                try Task.checkCancellation()
                guard let segment = track.segments.first(where: { $0.index == index }) else { continue }
                let name = "\(track.track)-\(String(format: "%03d", index)).m4a"
                let file = work.appendingPathComponent(name)
                try EvalAudio.writeM4A(from: render, startFrame: segment.startFrame, endFrame: segment.endFrame,
                                       to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let audio = try AtomicFile.readIfPresent(file, maxBytes: EvalAudio.maxUploadBytes) else {
                    throw HolosError.io("The \(track.track) segment \(index) was not written.")
                }
                progress("Uploading \(track.track) segment \(index + 1) of \(track.segments.count) "
                    + "(\(uploaded + 1) of \(total))…")
                let passes: [(CloudRequestFields, Bool)] = [(record.request, false)]
                    + (record.timestampRequest.map { [($0, true)] } ?? [])
                for (fields, timestamps) in passes {
                    let resultURL = EvalPaths.segmentResult(record.id, track: track.track, index: index,
                                                            timestamps: timestamps, in: session)
                    if FileManager.default.fileExists(atPath: resultURL.path) { continue }
                    let answer = try await client.transcribe(fields: fields, audio: audio, fileName: name) {
                        attempt, wait, reason in
                        progress("Attempt \(attempt) failed (\(reason)); retrying in \(wait.components.seconds) s…")
                    }
                    try EvalStore.writeData(answer.raw, to: EvalPaths.rawResponse(
                        record.id, track: track.track, index: index, timestamps: timestamps, in: session))
                    try EvalStore.write(CloudSegmentRecord(track: track.track, index: index, model: fields.model,
                                                           result: answer.result, attempts: answer.attempts,
                                                           receivedAt: now()), to: resultURL)
                }
                uploaded += 1
            }
        }
        try Task.checkCancellation()
        for track in record.tracks {
            try EvalStore.write(try stitch(record, track: track, session: session),
                                to: EvalPaths.trackResult(record.id, track: track.track, in: session))
        }
        record.completedAt = now()
        try EvalStore.write(record, to: EvalPaths.runRecord(record.id, in: session))
        return Outcome(uploaded: uploaded, complete: true)
    }

    /// The stitched track from the saved segment results.
    static func stitch(_ record: CloudRunRecord, track: CloudTrackPlan, session: URL) throws -> CloudTrackResult {
        var texts: [(text: String, overlapSeconds: Double)] = []
        var timed: [[CloudTranscriptionResult.Word]?] = []
        for segment in track.segments {
            if segment.silent {
                texts.append(("", 0))
                timed.append(nil)
                continue
            }
            guard let saved = try EvalStore.segment(record.id, track: track.track, index: segment.index, in: session)
            else { throw HolosError.incomplete("The \(track.track) segment \(segment.index) has no saved result.") }
            texts.append((saved.result.text, segment.overlapSeconds))
            if record.timestampRequest != nil,
               let words = try EvalStore.segment(record.id, track: track.track, index: segment.index, timestamps: true,
                                                 in: session)?.result.words {
                let offset = track.renderStart(segment)
                timed.append(words.filter { $0.start >= segment.overlapSeconds - 0.05 }.map { word in
                    CloudTranscriptionResult.Word(
                        word: word.word, start: EvalTimeMap.sessionTime(offset + word.start, map: track.timeMap),
                        end: EvalTimeMap.sessionTime(offset + word.end, map: track.timeMap))
                })
            } else {
                timed.append(nil)
            }
        }
        let words = CloudSegmentation.stitchPieces(texts)
        let segments = track.segments.enumerated().map { position, segment in
            CloudTrackResult.Segment(index: segment.index, sessionStart: track.sessionStart(segment),
                                     sessionEnd: track.sessionEnd(segment), renderStart: track.renderStart(segment),
                                     renderEnd: track.renderEnd(segment), overlapSeconds: segment.overlapSeconds,
                                     silent: segment.silent, text: texts[position].text,
                                     words: words[position].map(\.text), timedWords: timed[position])
        }
        let all = words.flatMap { segment in segment.enumerated().map { $0.offset == 0 ? true : $0.element.spaceBefore } }
        return CloudTrackResult(run: record.id, track: track.track, model: record.model, segments: segments,
                                text: EvalText.join(words.flatMap { $0.map(\.text) }, spaceBefore: all))
    }

    /// The request fields for `model`: the meeting's languages, and the vocabulary when there is one.
    static func requestFields(model: String, languages: [String], vocabulary: CloudVocabulary.Built?)
        -> CloudRequestFields {
        CloudRequestFields(model: model, responseFormat: "json", languages: CloudVocabulary.languageCodes(languages),
                           prompt: vocabulary?.prompt, keywords: vocabulary?.keywords ?? [],
                           chunkingStrategy: CloudModels.needsChunking(model) ? "auto" : nil)
    }

    /// The meeting's languages: meeting.json's list, else the recording's locale.
    static func meetingLanguages(session: URL, manifest: SessionManifest) -> [String] {
        if let languages = (try? SessionFiles.meetingInfo(session: session, manifest: manifest))?.languages,
           !languages.isEmpty {
            return languages
        }
        return [manifest.locale]
    }

    /// Microphone first, then system, then any other track by name.
    static func orderedTracks(_ tracks: Set<String>) -> [String] {
        tracks.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    private static func rank(_ track: String) -> Int {
        switch track {
        case "mic": 0
        case "system": 1
        default: 2
        }
    }

    static func isSaved(_ record: CloudRunRecord, track: String, index: Int, session: URL) -> Bool {
        let main = EvalPaths.segmentResult(record.id, track: track, index: index, in: session)
        guard FileManager.default.fileExists(atPath: main.path) else { return false }
        guard record.timestampRequest != nil else { return true }
        let timestamps = EvalPaths.segmentResult(record.id, track: track, index: index, timestamps: true, in: session)
        return FileManager.default.fileExists(atPath: timestamps.path)
    }

    private static func resumable(id: String, session: URL) throws -> CloudRunRecord {
        guard let record = try EvalStore.runRecord(id, in: session) else {
            throw HolosError.invalidInput("There is no evaluation run \(id) in this session (see voiceislocal eval list).")
        }
        guard record.completedAt == nil else {
            throw HolosError.invalidInput("Run \(id) is complete; there is nothing to resume.")
        }
        return record
    }

    /// The newest unfinished run with these settings.
    private static func latestResumable(session: URL, options: Options, tracks: [String]) -> CloudRunRecord? {
        for id in EvalStore.runIDs(in: session).reversed() {
            guard let record = try? EvalStore.runRecord(id, in: session), record.completedAt == nil else { continue }
            if record.model == options.model, record.tracks.map(\.track) == tracks,
               record.vocabulary == options.vocabulary, (record.timestampRequest != nil) == options.timestamps {
                return record
            }
        }
        return nil
    }
}
