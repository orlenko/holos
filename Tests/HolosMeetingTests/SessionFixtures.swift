import Foundation
import HolosAudio
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage

// Finished sessions for post-processing, export, and speaker-editing tests. Only the first-merged PR of each wave
// edits this file (docs/meeting-design.md §1.8; PR7b in wave 2); other PRs add prefixed helpers in their own files.

enum SessionFixtures {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Transcripts

    /// A segment on `track` whose words are laid out one every `wordSeconds` from `start`, each lasting 80 % of
    /// that, with UTF-16 offsets into the space-joined text.
    static func segment(_ words: [String], track: String?, start: Double, wordSeconds: Double = 0.5,
                        id: String = UUID().uuidString) -> TranscriptSegment {
        var text = ""
        var timed: [TimedWord] = []
        for (index, word) in words.enumerated() {
            if !text.isEmpty { text += " " }
            let offset = text.utf16.count
            text += word
            let wordStart = start + Double(index) * wordSeconds
            timed.append(TimedWord(text: word, start: wordStart, end: wordStart + wordSeconds * 0.8,
                                   utf16Offset: offset, utf16Length: word.utf16.count))
        }
        return TranscriptSegment(id: id, start: start, end: start + Double(words.count) * wordSeconds, text: text,
                                 words: timed, track: track)
    }

    /// One segment per turn of `FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds:, duration:)` on
    /// `track`: `wordsPerTurn` words starting 0.5 s into the turn, spelled "<track>t<turn>w<word>".
    static func alternatingSegments(track: String, turnSeconds: Double = 5, duration: Double = 20,
                                    wordsPerTurn: Int = 6) -> [TranscriptSegment] {
        let turns = Int((duration / turnSeconds).rounded(.down))
        let spacing = min(0.5, (turnSeconds - 1) / Double(max(1, wordsPerTurn)))
        return (0..<turns).map { turn in
            segment((0..<wordsPerTurn).map { "\(track)t\(turn + 1)w\($0 + 1)" }, track: track,
                    start: Double(turn) * turnSeconds + 0.5, wordSeconds: spacing)
        }
    }

    /// The diarizer output matching `alternatingSegments`.
    static func alternatingOutput(turnSeconds: Double = 5, duration: Double = 20) -> DiarizerOutput {
        FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds: turnSeconds, duration: duration)
    }

    static func transcript(_ segments: [TranscriptSegment], id: String = UUID().uuidString) -> Transcript {
        let ordered = segments.sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        return Transcript(id: id, createdAt: date, source: "fixture", locale: "en-CA", backend: .speech,
                          segments: ordered)
    }

    // MARK: - Sessions

    /// A finished (`complete`) session in `root`: `audioSeconds` of quiet 16 kHz mono audio per track (written by
    /// `AudioChunkWriter`), meeting.json when `mode` is given, and `transcript` saved as current (with the legacy
    /// speaker-less exports only when `legacyExports`).
    static func makeSession(in root: URL, name: String = "Fixture meeting", source: AudioSource = .microphone,
                            audioSeconds: [String: Double] = ["mic": 20], mode: MeetingMode? = nil,
                            othersInRoom: Bool = false, expectedSpeakers: Int? = nil, transcript: Transcript?,
                            legacyExports: Bool = false) async throws -> URL {
        let archive = try SessionArchive.create(root: root, name: name, source: source, locale: "en-CA",
                                                backend: .speech)
        if let mode {
            try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: mode, othersInRoom: othersInRoom,
                                                 expectedSpeakers: expectedSpeakers, createdAt: date),
                                     to: SessionPaths.meetingInfo(archive.directory))
        }
        let writer = AudioChunkWriter(archive: archive)
        for (track, seconds) in audioSeconds.sorted(by: { $0.key < $1.key }) {
            let count = Int(seconds * 16_000)
            let samples = (0..<count).map { Float(sin(Double($0) * 0.05)) * 0.01 }
            let frame = try PCMFrame(samples: samples, sampleRate: 16_000, channels: 1, startTime: 0)
            try await writer.append(CapturedAudio(track: track, frame: frame))
        }
        try await writer.finish()
        if let transcript { try await archive.saveTranscript(transcript, writeLegacyExports: legacyExports) }
        try await archive.finish(status: ArchiveStatus.complete)
        return archive.directory
    }

    /// Saves `transcript` as the session's new current revision, as a rebuild does (maintenance open under a lease).
    static func saveTranscript(_ transcript: Transcript, in session: URL) async throws {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        try await archive.saveTranscript(transcript, writeLegacyExports: false)
        try await archive.finish(status: ArchiveStatus.complete)
    }

    /// The head-run builder: builds a run of `transcript` from per-track outputs (session times) with
    /// `SpeakerRunBuilder` and publishes it as the head under the speaker lock, as stage 6 does. Tracks in `outputs`
    /// are diarized unless `policies` says otherwise.
    @discardableResult
    static func writeHeadRun(session: URL, transcript: Transcript, outputs: [String: DiarizerOutput],
                             policies: [String: TrackPolicy] = [:]) throws -> DiarizationRun {
        let manifest = try SessionArchive.readManifest(at: session)
        let tracks = Set(outputs.keys).union(policies.keys).sorted()
        let built = SpeakerRunBuilder.build(
            sessionID: manifest.id, transcript: transcript,
            tracks: tracks.map { track in
                SpeakerRunBuilder.TrackInput(track: track, policy: policies[track] ?? .diarized, output: outputs[track])
            },
            engine: .fake)
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.writeRun(built.run, session: session)
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: built.run.id), session: session)
        }
        return built.run
    }

    /// Appends `actions` for the head run as one editor batch: each carries its fingerprint on the current view.
    static func appendEdits(_ actions: [SpeakerEditAction], session: URL, source: String = "cli") throws {
        try SessionArchive.withSpeakerLock(at: session) {
            let snapshot = try SpeakerSessionSnapshot.load(session: session)
            guard let run = snapshot.run, var view = snapshot.projection else {
                throw HolosError.invalidInput("The fixture session has no usable head run.")
            }
            let batchID = UUID().uuidString
            var edits: [SpeakerEdit] = []
            for action in actions {
                let id = UUID().uuidString
                edits.append(SpeakerEdit(id: id, baseRunID: run.id, source: source, action: action,
                                         expected: view.fingerprint(for: action), batchID: batchID))
                view = view.applying(action, editID: id)
            }
            try SessionSpeakerStore.appendEdits(edits, session: session)
        }
    }

    // MARK: - Inspecting

    /// Every regular file under `folder` by relative path, with its bytes, for "nothing changed" checks.
    static func files(in folder: URL) -> [String: Data] {
        let prefix = folder.standardizedFileURL.path + "/"
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
        }
        return result
    }

    /// The permission bits of `url`.
    static func mode(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
