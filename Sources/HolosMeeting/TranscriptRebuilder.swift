import Foundation
import HolosCore
import HolosStorage
import os

/// What `TranscriptRebuilder.rebuild` did.
public struct RebuildReport: Sendable, Equatable {
    public var transcriptID: String
    public var journalSegments: Int
    /// Per track: session time up to which journal words are kept.
    public var coverageEnd: [String: Double]
    /// Per track: seconds of audio transcribed again.
    public var replayedSeconds: [String: Double]
    /// True when an earlier rebuild was reused (idempotent path).
    public var reused: Bool
    /// Set when the rebuilt transcript was saved and made current, but marking the manifest `recovered` or
    /// journaling `transcriptRebuilt` then failed (for example, the disk is full). The transcript stands; the next
    /// recover rebuilds it again, because no event records this rebuild.
    public var recordingError: String?

    public init(transcriptID: String, journalSegments: Int, coverageEnd: [String: Double],
                replayedSeconds: [String: Double], reused: Bool, recordingError: String? = nil) {
        self.transcriptID = transcriptID; self.journalSegments = journalSegments; self.coverageEnd = coverageEnd
        self.replayedSeconds = replayedSeconds; self.reused = reused; self.recordingError = recordingError
    }
}

/// Rebuilds the transcript of an interrupted session from the phrases live transcription journaled
/// (`transcriptFinalized` events), and transcribes only the audio they do not cover (docs/meeting-design.md §5.6).
public enum TranscriptRebuilder {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")
    /// Audio that ends no more than this after a track's coverage is not transcribed again.
    static let uncoveredTolerance = 0.05
    /// Replay starts this long before coverage ends, so a word cut by the crash is heard whole.
    static let replayLeadIn = 2.0

    /// Requires an inactive archive and the caller's lease. Replays without the writer lock; takes it only for
    /// the final save through `SessionArchive.openForMaintenance(at:lease:)`. `vocabulary` nil reads vocabulary.json.
    ///
    /// Details:
    /// - Refuses (`unavailable`) while a recorder holds the writer lock, and (`invalidInput`) a manifest still marked
    ///   `recording` or `processing`: `SessionArchive.recover` must mark it interrupted first. A dead recorder's
    ///   status.json is marked exited.
    /// - Idempotent: when the last `transcriptRebuilt` event comes after the last `archiveRecovered` event (by
    ///   sequence) and names the current transcript, it is returned with `reused: true` and nothing changes, unless
    ///   `force`, or unless this call may transcribe audio and that rebuild could not (it ran without `transcribe`,
    ///   recorded as `transcribed: false`, while the audio still exists). The current transcript counts only once its
    ///   revision was read and holds its own ID (`SessionFiles.readableCurrentTranscriptID`): a truncated, damaged, or
    ///   mislabelled revision is rebuilt.
    /// - Refuses (`unavailable`), even with `force`, a current pointer or revision, or a vocabulary.json the replay
    ///   would use, written by a newer Holos (schema rule 3, §1.6).
    /// - Journal words are kept per track up to `TranscriptCoverage.coverageEnd` (the last phrase's end, capped at the
    ///   earliest `transcriptionBehind`). With `transcribe`, the audio after it is replayed from 2 s earlier with the
    ///   session vocabulary and joined at word level (`TranscriptCoverage.merge`); without it, or once Delete Audio
    ///   removed the audio, every journal phrase is kept and nothing is replayed.
    /// - Replay calls have the stop path's time limits. A replay that fails or times out publishes nothing and throws
    ///   `HolosError.incomplete`; a cancelled one throws `CancellationError`.
    /// - The new revision becomes current (`saveTranscript(_:writeLegacyExports: false)`), the manifest status becomes
    ///   `recovered`, and `transcriptRebuilt {transcriptID, journalSegments, replayedSeconds}` is journaled (with
    ///   `transcribed`, and `coverageEnd.<track>` and `replayedSeconds.<track>` for each track). Once the new revision
    ///   is current, a failure to set the status or journal the event does not throw: it is returned as
    ///   `recordingError`.
    /// - `progress` reports 0...1 over the audio to replay.
    public static func rebuild(session: URL, lease: ProcessingLease, force: Bool = false, transcribe: Bool = true,
                               vocabulary: [String]? = nil, makeSpeech: LiveSpeechFactory? = nil,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> RebuildReport {
        // The lease stays locked, even across a concurrent `release()`, until the rebuild ends.
        try await lease.withUse(for: session) {
            try await rebuildUnderLease(session: session, lease: lease, force: force, transcribe: transcribe,
                                        vocabulary: vocabulary, makeSpeech: makeSpeech, progress: progress)
        }
    }

    private static func rebuildUnderLease(session: URL, lease: ProcessingLease, force: Bool, transcribe: Bool,
                                          vocabulary: [String]?, makeSpeech: LiveSpeechFactory?,
                                          progress: @escaping @Sendable (Double) -> Void) async throws -> RebuildReport {
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording. Stop it before rebuilding its transcript.")
        }
        do { try RecorderChannel.markDeadRecorderExited(session: session) } catch {
            log.error("Session \(logID(session), privacy: .public): cannot check the recorder status before a rebuild: \(error.localizedDescription, privacy: .private)")
        }
        let manifest = try SessionArchive.readManifest(at: session)
        guard manifest.status != ArchiveStatus.recording, manifest.status != ArchiveStatus.processing else {
            throw HolosError.invalidInput(
                "This meeting's archive was interrupted and is not recovered yet; run holos session recover first.")
        }
        let events = try SessionArchive.readEvents(at: session).events
        // Whether audio may be transcribed: asked for, and not deleted.
        let mayTranscribe = transcribe && !SessionFiles.audioDeleted(session: session)
        // The current revision is read, not only found: a damaged, truncated, or mislabelled one is not reused but
        // replaced. A pointer or revision from a newer Holos is refused (`unavailable`) before anything changes,
        // even with `force`, so the save never replaces it.
        let currentID = try SessionFiles.readableCurrentTranscriptID(session: session)
        if !force, let reused = reusedReport(events, currentTranscriptID: currentID,
                                             needsTranscription: mayTranscribe) {
            log.notice("Session \(manifest.id, privacy: .public): transcript already rebuilt; reused")
            return reused
        }

        // Journal phrases and coverage, per track.
        let journal = JournalTranscript(events)
        var tracks = Set(journal.segments.keys).union(journal.behindFrom.keys).union(manifest.chunks.map(\.track))
        tracks.formUnion(sourceTracks(manifest.source))
        var coverage: [String: Double] = [:]
        for track in tracks {
            coverage[track] = TranscriptCoverage.coverageEnd(live: journal.segments[track] ?? [],
                                                             behindFrom: journal.behindFrom[track])
        }

        // The audio live transcription did not cover.
        var plans: [ReplayPlan] = []
        if mayTranscribe {
            for track in tracks.sorted() {
                let chunks = manifest.chunks.filter { $0.track == track }
                let covered = coverage[track] ?? 0
                guard let end = chunks.map(\.end).max(), end - covered > uncoveredTolerance else { continue }
                let from = max(0, covered - replayLeadIn)
                // Time that overlapping chunks both hold is fed once (`TrackReplayer`), so it is counted once.
                plans.append(ReplayPlan(track: track, from: from, seconds: manifest.audioSeconds(track: track, from: from)))
            }
        }
        let strings = plans.isEmpty ? [] : try (vocabulary ?? sessionVocabulary(session))
        let total = plans.reduce(0.0) { $0 + $1.seconds }
        var done = 0.0
        var replayed: [String: [TranscriptSegment]] = [:]
        progress(0)
        for plan in plans {
            try Task.checkCancellation()
            do {
                replayed[plan.track] = try await TrackReplayer.replay(
                    directory: session, track: plan.track, locale: manifest.locale, backend: manifest.backend,
                    contextualStrings: strings, from: plan.from, makeSpeech: makeSpeech, timeouts: .standard)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let what = plan.track == "system" ? "system audio" : plan.track == "mic" ? "microphone audio" : plan.track
                throw HolosError.incomplete("Could not transcribe the saved \(what) that live transcription missed: "
                    + "\(error.localizedDescription) The transcript was not changed; try again, or use --no-transcribe "
                    + "to rebuild it from the saved phrases only.")
            }
            done += plan.seconds
            progress(total > 0 ? min(1, done / total) : 1)
        }
        progress(1)

        // Journal words before coverage, replayed words from it on.
        var segments: [TranscriptSegment] = []
        for track in tracks.sorted() {
            let live = journal.segments[track] ?? []
            if let replay = replayed[track] {
                segments += TranscriptCoverage.merge(live: live, replayed: replay, coverageEnd: coverage[track] ?? 0)
            } else {
                segments += live
            }
        }
        segments = uniqueIDs(ordered(segments))
        try Task.checkCancellation()

        var replayedSeconds: [String: Double] = [:]
        for track in tracks { replayedSeconds[track] = 0 }
        for plan in plans { replayedSeconds[plan.track] = plan.seconds }
        let transcript = Transcript(source: session.path, locale: manifest.locale, backend: manifest.backend,
                                    segments: segments)
        var details = ["transcriptID": transcript.id, "journalSegments": String(journal.count),
                       "replayedSeconds": String(total), "transcribed": String(mayTranscribe)]
        for track in tracks {
            details["coverageEnd.\(track)"] = String(coverage[track] ?? 0)
            details["replayedSeconds.\(track)"] = String(replayedSeconds[track] ?? 0)
        }
        // The only moment the writer lock is held: the save.
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        try await archive.saveTranscript(transcript, writeLegacyExports: false)
        // The rebuilt transcript is current from here on, so a later failure is reported with it, not thrown.
        // Status before the event: a rebuild whose event is missing is simply done again next time.
        var recordingError: String?
        do {
            try await archive.setStatus(ArchiveStatus.recovered)
            try await archive.recordEvent(kind: MeetingEventKind.transcriptRebuilt, details: details)
            try await archive.finish(status: ArchiveStatus.recovered)
        } catch {
            // An unfinished archive lets go of the writer lock when it is released, as this function returns.
            recordingError = error.localizedDescription
            log.error("Session \(manifest.id, privacy: .public): transcript rebuilt, but recording the rebuild failed: \(error.localizedDescription, privacy: .private)")
        }
        log.notice("Session \(manifest.id, privacy: .public): transcript rebuilt from \(journal.count, privacy: .public) journal segments, \(total, privacy: .public) s replayed")
        return RebuildReport(transcriptID: transcript.id, journalSegments: journal.count, coverageEnd: coverage,
                             replayedSeconds: replayedSeconds, reused: false, recordingError: recordingError)
    }

    // MARK: - Idempotence

    /// The report of the last rebuild, when it came after the last recovery and its transcript is still current, and
    /// (with `needsTranscription`) it was allowed to transcribe audio too.
    static func reusedReport(_ events: [ArchiveEvent], currentTranscriptID: String?,
                             needsTranscription: Bool) -> RebuildReport? {
        guard let rebuilt = events.last(where: { $0.kind == MeetingEventKind.transcriptRebuilt }),
              let transcriptID = rebuilt.details["transcriptID"],
              let current = currentTranscriptID, current == transcriptID,
              !needsTranscription || rebuilt.details["transcribed"] != "false" else { return nil }
        let recovered = events.last(where: { $0.kind == MeetingEventKind.archiveRecovered })?.sequence ?? 0
        guard rebuilt.sequence > recovered else { return nil }
        var coverage: [String: Double] = [:]
        var replayed: [String: Double] = [:]
        for (key, value) in rebuilt.details {
            guard let number = Double(value), number.isFinite else { continue }
            if key.hasPrefix("coverageEnd.") { coverage[String(key.dropFirst("coverageEnd.".count))] = number }
            if key.hasPrefix("replayedSeconds.") { replayed[String(key.dropFirst("replayedSeconds.".count))] = number }
        }
        return RebuildReport(transcriptID: transcriptID,
                             journalSegments: rebuilt.details["journalSegments"].flatMap { Int($0) } ?? 0,
                             coverageEnd: coverage, replayedSeconds: replayed, reused: true)
    }

    // MARK: - Helpers

    private struct ReplayPlan {
        var track: String
        var from: Double
        var seconds: Double
    }

    /// The session ID for log lines: the manifest's ID, or "unknown" when the manifest cannot be read. IDs are
    /// public in logs; folder names are user paths (a folder may have been renamed), so they are never used here.
    static func logID(_ session: URL) -> String {
        (try? SessionArchive.readManifest(at: session))?.id ?? "unknown"
    }

    /// The tracks a session of `source` records.
    private static func sourceTracks(_ source: AudioSource) -> [String] {
        switch source {
        case .microphone: ["mic"]
        case .system: ["system"]
        case .microphoneAndSystem: ["mic", "system"]
        }
    }

    /// vocabulary.json's strings; none when it is missing, cannot be read, or is damaged. One written by a newer
    /// Holos is refused (`unavailable`, schema rule 3, §1.6), never read as having no strings.
    static func sessionVocabulary(_ session: URL) throws -> [String] {
        let data: Data
        do {
            guard let read = try AtomicFile.readIfPresent(SessionPaths.vocabulary(session), maxBytes: 1 << 20) else {
                return []
            }
            data = read
        } catch {
            log.error("vocabulary.json ignored: \(error.localizedDescription, privacy: .private)")
            return []
        }
        try SessionFiles.checkVersion(data, current: 1, name: "vocabulary.json")
        do {
            let vocabulary = try HolosJSON.decoder().decode(MeetingVocabulary.self, from: data)
            guard vocabulary.schemaVersion >= 1 else { throw HolosError.invalidInput("Unsupported schema version.") }
            return vocabulary.strings
        } catch {
            log.error("vocabulary.json ignored: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    /// By start time, then track; otherwise in the given order.
    private static func ordered(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if a.start != b.start { return a.start < b.start }
            if (a.track ?? "") != (b.track ?? "") { return (a.track ?? "") < (b.track ?? "") }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// Gives every segment after the first with an ID already used a new one, so runs can name segments by ID.
    private static func uniqueIDs(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var seen = Set<String>()
        return segments.map { segment in
            var unique = segment
            while !seen.insert(unique.id).inserted { unique.id = UUID().uuidString }
            return unique
        }
    }
}

/// The phrases live transcription journaled, per track (docs/meeting-design.md §4.6 `LiveTrack`).
struct JournalTranscript {
    /// `transcriptFinalized` events in journal order, exact duplicates `(track, start, end, text)` dropped. Events with
    /// `words` keep their timed words and `segmentID`; older events give untimed segments.
    var segments: [String: [TranscriptSegment]] = [:]
    /// The earliest `transcriptionBehind.from` per track.
    var behindFrom: [String: Double] = [:]
    /// Segments kept, over all tracks.
    var count = 0

    init(_ events: [ArchiveEvent]) {
        struct Key: Hashable {
            var track: String
            var start: Double
            var end: Double
            var text: String
        }
        var seen = Set<Key>()
        var ids = Set<String>()
        let decoder = HolosJSON.decoder()
        for event in events {
            let details = event.details
            switch event.kind {
            case MeetingEventKind.transcriptFinalized:
                guard let track = details["track"], !track.isEmpty,
                      let start = Self.number(details["start"]), start.isFinite,
                      let end = Self.number(details["end"]), end.isFinite, end >= start else { continue }
                let text = details["text"] ?? ""
                guard seen.insert(Key(track: track, start: start, end: end, text: text)).inserted else { continue }
                var words: [TimedWord] = []
                if let encoded = details["words"],
                   let decoded = try? decoder.decode([TimedWord].self, from: Data(encoded.utf8)) {
                    words = decoded
                }
                var id = details["segmentID"].flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
                while !ids.insert(id).inserted { id = UUID().uuidString }
                segments[track, default: []].append(TranscriptSegment(id: id, start: start, end: end, text: text,
                                                                      words: words, track: track))
                count += 1
            case MeetingEventKind.transcriptionBehind:
                guard let track = details["track"], !track.isEmpty,
                      let from = Self.number(details["from"]), from.isFinite else { continue }
                behindFrom[track] = min(behindFrom[track] ?? from, from)
            default:
                continue
            }
        }
    }

    /// A number written with `String(Double)`.
    private static func number(_ text: String?) -> Double? {
        text.flatMap { Double($0) }
    }
}
