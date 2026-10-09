import Foundation
import HolosAudio
import HolosCore
import HolosMeeting
import HolosStorage
import HolosTestSupport
import Synchronization

// The HolosMeetingTests helpers these tests used before they moved here (SessionFixtures.swift and Fakes.swift there):
// finished sessions with audio, and scripted speech. What HolosTestSupport has is taken from it.

/// A value shared between a test and the closures or tasks it hands to the code under test.
final class SharedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    var value: Value { mutex.withLock { $0 } }

    func set(_ newValue: Value) { mutex.withLock { $0 = newValue } }

    @discardableResult
    func update<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

enum SessionFixtures {
    static let date = TranscriptFixtures.date

    /// A segment on `track` whose words are laid out one every `wordSeconds` from `start`, each lasting 80 % of
    /// that, with UTF-16 offsets into the space-joined text.
    static func segment(_ words: [String], track: String?, start: Double, wordSeconds: Double = 0.5,
                        id: String = UUID().uuidString) -> TranscriptSegment {
        TranscriptFixtures.segment(words, id: id, track: track, start: start, every: wordSeconds,
                                   lasting: wordSeconds * 0.8)
    }

    static func transcript(_ segments: [TranscriptSegment], id: String = UUID().uuidString) -> Transcript {
        TranscriptFixtures.transcript(segments, id: id)
    }

    /// A finished (`complete`) session in `root`: `audioSeconds` of a quiet 16 kHz mono tone (`tone` radians per
    /// sample) per track (written by `AudioChunkWriter`), meeting.json when `mode` is given, and `transcript` saved as
    /// current (with the legacy speaker-less exports only when `legacyExports`).
    static func makeSession(in root: URL, name: String = "Fixture meeting", source: AudioSource = .microphone,
                            audioSeconds: [String: Double] = ["mic": 20], mode: MeetingMode? = nil,
                            othersInRoom: Bool = false, expectedSpeakers: Int? = nil, transcript: Transcript?,
                            legacyExports: Bool = false, tone: Double = 0.05) async throws -> URL {
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
            let samples = (0..<count).map { Float(sin(Double($0) * tone)) * 0.01 }
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

    static func files(in folder: URL) -> [String: Data] { FileInspection.files(in: folder) }

    static func exists(_ url: URL) -> Bool { FileInspection.exists(url) }

    static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - Speech

/// What one fake speech session does.
struct FakeSpeechScript: Sendable {
    /// Returned by `finish()`, with times relative to the session's first frame. Each segment is also
    /// reported as a final update once the audio fed to the session reaches its end; the rest at `finish()`.
    var segments: [TranscriptSegment]
    /// The factory throws this instead of creating the session.
    var makeError: HolosError?
    /// `append` throws this…
    var appendError: HolosError?
    /// …once this many seconds of audio were fed (nil: from the first frame).
    var appendErrorAfter: Double?
    /// `finish()` waits this long first.
    var finishDelay: Duration?
    /// `finish()` does not return until `cancel()`; it then throws `CancellationError`.
    var finishHangs: Bool
    /// `finish()` throws this, without reporting the segments not yet reported.
    var finishError: HolosError?
    /// Reported as volatile updates once the audio fed reaches their end, before any final update of that frame.
    var volatile: [TranscriptSegment]

    init(segments: [TranscriptSegment] = [], makeError: HolosError? = nil, appendError: HolosError? = nil,
         finishDelay: Duration? = nil, finishHangs: Bool = false, appendErrorAfter: Double? = nil,
         finishError: HolosError? = nil, volatile: [TranscriptSegment] = []) {
        self.segments = segments; self.makeError = makeError; self.appendError = appendError
        self.finishDelay = finishDelay; self.finishHangs = finishHangs
        self.appendErrorAfter = appendErrorAfter; self.finishError = finishError
        self.volatile = volatile
    }
}

/// A scripted `LiveSpeechSession` that records what it was given.
actor FakeSpeech: LiveSpeechSession {
    nonisolated let locale: String
    nonisolated let backend: SpeechBackend
    nonisolated let contextualStrings: [String]
    private let script: FakeSpeechScript
    private let onUpdate: @Sendable (TranscriptUpdate) -> Void
    /// Start times of the frames fed, in order.
    private(set) var frameStarts: [Double] = []
    /// Seconds of audio fed.
    private(set) var fedSeconds = 0.0
    private(set) var finishCalls = 0
    private(set) var cancelled = false
    private var firstStart: Double?
    private var reported: Set<Int> = []
    private var reportedVolatile: Set<Int> = []

    init(locale: String, backend: SpeechBackend, contextualStrings: [String], script: FakeSpeechScript,
         onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) {
        self.locale = locale; self.backend = backend; self.contextualStrings = contextualStrings
        self.script = script; self.onUpdate = onUpdate
    }

    func append(_ frame: PCMFrame) async throws {
        if cancelled { throw CancellationError() }
        if let error = script.appendError, fedSeconds >= (script.appendErrorAfter ?? 0) - 1e-9 { throw error }
        frameStarts.append(frame.startTime)
        fedSeconds += frame.duration
        let base = firstStart ?? frame.startTime
        firstStart = base
        report(through: frame.startTime + frame.duration - base)
    }

    func finish() async throws -> [TranscriptSegment] {
        finishCalls += 1
        if let delay = script.finishDelay { try await Task.sleep(for: delay) }
        if script.finishHangs {
            while !cancelled { try await Task.sleep(for: .milliseconds(5)) }
        }
        if cancelled { throw CancellationError() }
        if let error = script.finishError { throw error }
        report(through: .infinity)
        return script.segments
    }

    func cancel() async { cancelled = true }

    private func report(through end: Double) {
        for (index, segment) in script.volatile.enumerated()
        where !reportedVolatile.contains(index) && segment.end <= end + 1e-9 {
            reportedVolatile.insert(index)
            onUpdate(TranscriptUpdate(segment: segment, isFinal: false))
        }
        for (index, segment) in script.segments.enumerated() where !reported.contains(index) && segment.end <= end + 1e-9 {
            reported.insert(index)
            onUpdate(TranscriptUpdate(segment: segment, isFinal: true))
        }
    }
}

/// A `LiveSpeechFactory` whose n-th call uses `scripts[n]` (an empty script past the end). It records every
/// call, including calls that throw.
final class FakeSpeechFactory: Sendable {
    struct Call: Sendable, Equatable {
        var locale: String
        var backend: SpeechBackend
        var contextualStrings: [String]
    }

    private struct State {
        var calls: [Call] = []
        var sessions: [FakeSpeech] = []
    }

    private let scripts: [FakeSpeechScript]
    private let state = Mutex(State())

    init(_ scripts: [FakeSpeechScript] = []) { self.scripts = scripts }

    var factory: LiveSpeechFactory {
        { locale, backend, contextualStrings, onUpdate in
            try self.make(locale: locale, backend: backend, contextualStrings: contextualStrings, onUpdate: onUpdate)
        }
    }

    var calls: [Call] { state.withLock { $0.calls } }

    /// Sessions created, in order (calls that threw created none).
    var sessions: [FakeSpeech] { state.withLock { $0.sessions } }

    private func make(locale: String, backend: SpeechBackend, contextualStrings: [String],
                      onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) throws -> FakeSpeech {
        let script = state.withLock { state -> FakeSpeechScript in
            let index = state.calls.count
            state.calls.append(Call(locale: locale, backend: backend, contextualStrings: contextualStrings))
            return index < scripts.count ? scripts[index] : FakeSpeechScript()
        }
        if let error = script.makeError { throw error }
        let session = FakeSpeech(locale: locale, backend: backend, contextualStrings: contextualStrings,
                                 script: script, onUpdate: onUpdate)
        state.withLock { $0.sessions.append(session) }
        return session
    }
}
