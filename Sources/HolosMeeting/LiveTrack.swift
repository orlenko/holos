import Foundation
import HolosAudio
import HolosCore
import os
import Synchronization

/// Where live transcription records journal events: the archive's `recordEvent` outside tests.
typealias LiveEventSink = @Sendable (_ kind: String, _ details: [String: String]) async throws -> Void

/// What live transcription of one track produced by the end of a recording.
struct LiveTrackResult: Sendable, Equatable {
    /// Finalized segments on the session timeline, with `track` set, ordered by start.
    var segments: [TranscriptSegment]
    /// Session time from which live transcription is incomplete (the earliest `transcriptionBehind.from`); nil when
    /// it covered the whole recording, so the stop path replays nothing.
    var behindFrom: Double?
}

/// Live transcription of one track while it records (docs/meeting-design.md §4.6).
///
/// Frames and epoch boundaries wait in a queue bounded by duration (30 s of audio); a speech task feeds them to one
/// `LiveSpeechSession` at a time. Every session sees frame times that start at 0, and its results get the session
/// time of its first frame added back (§2.3). A new session starts with every capture epoch (made by
/// `prepareSession` for that epoch before its capture starts, so frames never wait for it) and at every gap over 1 s. A
/// session is finished in the background, with a timeout of 30 s + 0.05 × the seconds it was fed, while the next one
/// is fed; the segments of one that fails or hangs are the ones it already finalized.
///
/// When the queue overflows, a session cannot be created, or speech fails, the track falls behind: that session
/// time is recorded as `transcriptionBehind {track, from}`, live speech stops for the rest of the recording, and
/// every segment already finalized is kept; the stop path transcribes the rest from disk. Each finalized segment is
/// journaled as `transcriptFinalized` with `segmentID` and `words`, through a queue of 4,096 segments; segments that
/// do not fit are recorded as `transcriptionBehind` once the queue drains, so recovery knows where the journal has a
/// hole.
final class LiveTrack: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")
    static let queueSeconds = 30.0
    static let journalCapacity = 4_096
    /// A gap longer than this inside an epoch starts a new speech session.
    static let sessionGapSeconds = 1.0

    let track: String
    private let locale: String
    private let backend: SpeechBackend
    private let contextualStrings: [String]
    private let makeSpeech: LiveSpeechFactory
    private let events: LiveEventSink
    private let reporter: any RecordingReporter
    private let showPhrases: Bool
    private let timeouts: StopTimeouts
    private let input: WorkQueue<LiveInput>
    private let journal: WorkQueue<JournalItem>
    private let state = Mutex(State())
    private let tasks = Mutex(Tasks())
    /// Set by `finish()`: every session finish, including those already running, ends by it.
    private let stopDeadline = SharedDeadline()

    enum LiveInput: Sendable {
        /// A frame of capture epoch `epoch`.
        case frame(PCMFrame, epoch: Int)
        case boundary
    }

    private enum JournalItem: Sendable {
        case finalized(TranscriptSegment)
        case behind(from: Double, reason: String)
    }

    private struct SessionRecord {
        /// The speech session until it is finished or cancelled; then nil, so a long recording with many sessions
        /// (one per epoch and per gap over 1 s) keeps only their segments, not their analyzers.
        var session: (any LiveSpeechSession)?
        /// Session time of its first frame; results are shifted by it.
        var base: Double?
        var fed = 0.0
        /// Final updates so far, on the session timeline (cleared once `result` replaces them).
        var finals: [TranscriptSegment] = []
        /// What `finish()` returned, on the session timeline; nil until it returns.
        var result: [TranscriptSegment]?
    }

    private struct State {
        var sessions: [Int: SessionRecord] = [:]
        var nextSerial = 0
        /// Sessions made for epochs whose frames have not reached speech yet, by epoch.
        var prepared: [Int: Int] = [:]
        /// Epochs that pushed frames while their prepared session was still waiting: those frames take it. Only
        /// epochs in `prepared` are kept.
        var pushedEpochs: Set<Int> = []
        /// The session the speech task feeds.
        var current: Int?
        var behindFrom: Double?
        /// End of the last frame fed to speech.
        var lastFedEnd: Double?
        /// The earliest segment the journal queue dropped, recorded once the queue drains.
        var journalDroppedFrom: Double?
        var lastFinalized: Double?
        var lastPhrase: String?
        var cancelled = false
    }

    private struct Tasks {
        var speech: Task<Void, Never>?
        var journal: Task<Void, Never>?
        /// Sessions being finished, by serial; each task removes itself when done.
        var finishing: [Int: Task<Void, Never>] = [:]
    }

    init(track: String, locale: String, backend: SpeechBackend, contextualStrings: [String],
         makeSpeech: @escaping LiveSpeechFactory, events: @escaping LiveEventSink, reporter: any RecordingReporter,
         showPhrases: Bool = true, timeouts: StopTimeouts = .standard, queueSeconds: Double = LiveTrack.queueSeconds,
         journalCapacity: Int = LiveTrack.journalCapacity) {
        self.track = track; self.locale = locale; self.backend = backend
        self.contextualStrings = contextualStrings; self.makeSpeech = makeSpeech; self.events = events
        self.reporter = reporter; self.showPhrases = showPhrases; self.timeouts = timeouts
        input = WorkQueue(capacity: queueSeconds) { item in
            if case .frame(let frame, _) = item { return frame.duration }
            return 0
        }
        journal = WorkQueue(capacity: Double(max(1, journalCapacity))) { item in
            if case .finalized = item { return 1 }
            return 0
        }
        let speech = Task { [weak self] () -> Void in await self?.runSpeech() }
        let journalTask = Task { [weak self] () -> Void in await self?.runJournal() }
        tasks.withLock {
            $0.speech = speech
            $0.journal = journalTask
        }
    }

    // MARK: - Recorder side

    /// Makes the speech session for capture epoch `epoch`, unless one is ready or the track is behind. Runs in the
    /// caller's task, before the epoch's capture starts. A session made for an earlier epoch that never delivered a
    /// frame is used instead of a new one. Throws only `CancellationError` (a session made meanwhile is cancelled); a
    /// failed creation records `transcriptionBehind {track, from: epochStart}`.
    func prepareSession(epoch: Int, epochStart: Double) async throws {
        let needed = state.withLock { state -> Bool in
            guard !state.cancelled, state.behindFrom == nil, state.prepared[epoch] == nil else { return false }
            if let unused = state.prepared.keys.filter({ $0 < epoch && !state.pushedEpochs.contains($0) }).min() {
                state.prepared[epoch] = state.prepared.removeValue(forKey: unused)
                return false
            }
            return true
        }
        guard needed else { return }
        do {
            let serial = try await makeSession()
            if Task.isCancelled {
                await discardSession(serial)
                throw CancellationError()
            }
            let unused = state.withLock { state -> Int? in
                guard state.prepared[epoch] == nil, !state.cancelled else { return serial }
                state.prepared[epoch] = serial
                return nil
            }
            if let unused { await discardSession(unused) }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if epoch == 0 {
                reporter.message("Live \(track) transcription unavailable: \(Self.clause(error)). Recording will continue and transcription will be retried after stop.")
            } else {
                reporter.message("Live \(track) transcription could not restart: \(Self.clause(error)). The rest is transcribed from the saved audio after stop.")
            }
            fallBehind(from: epochStart, reason: "sessionUnavailable")
        }
    }

    /// Never blocks. A full queue makes the track fall behind from this frame's start.
    func push(_ frame: PCMFrame, epoch: Int) {
        state.withLock { state in
            if state.prepared[epoch] != nil { state.pushedEpochs.insert(epoch) }
        }
        guard !input.push(.frame(frame, epoch: epoch)), !input.isClosed else { return }
        let behind = state.withLock { $0.behindFrom != nil || $0.cancelled }
        if !behind {
            reporter.message("Transcription is behind on \(track); recording continues and saved audio will be processed after stop.")
            fallBehind(from: frame.startTime, reason: "queueFull")
        }
    }

    /// The current capture epoch ended: the next frame goes to a new speech session.
    func boundary() { input.push(.boundary, force: true) }

    /// Live, or behind once live speech stopped.
    var transcription: TranscriptionState {
        state.withLock { $0.behindFrom == nil ? .live : .behind }
    }

    var lastFinalizedSeconds: Double? { state.withLock { $0.lastFinalized } }

    var lastPhrase: String? { state.withLock { $0.lastPhrase } }

    /// Stops taking frames, lets queued ones reach speech, and finishes every session (each within its timeout).
    /// Cancelling the calling task cancels every session and returns what was finalized.
    func finish() async -> LiveTrackResult {
        input.close()
        let (speech, fed) = (tasks.withLock { $0.speech }, currentFed())
        // One budget for the whole finish (§4.6): draining the queue and finishing the sessions that are still open.
        let limit = timeouts.speechFinish(audioSeconds: fed + input.load)
        // Also cuts short the finishes of sessions that ended before the stop and are still running.
        stopDeadline.set(ContinuousClock.now.advanced(by: limit))
        await withTaskCancellationHandler {
            if let speech {
                if case .timedOut = await awaitWithTimeout(limit, { await speech.value }) {
                    Self.log.error("Live \(self.track, privacy: .public) transcription did not drain in time; cancelled")
                    speech.cancel()
                    let from = state.withLock { state in
                        state.lastFedEnd ?? state.current.flatMap { state.sessions[$0]?.base } ?? 0
                    }
                    fallBehind(from: from, reason: "speechTimedOut")
                    // Taken, so the speech task never finishes it a second time if its `append` ever returns.
                    if let current = takeCurrent() { finishLater(current) }
                }
            }
            await waitForFinishing()
        } onCancel: {
            self.cancelEverything()
        }
        let unused = state.withLock { state -> [Int] in
            defer { state.prepared.removeAll(); state.pushedEpochs.removeAll() }
            return Array(state.prepared.values)
        }
        for serial in unused { await discardSession(serial) }
        journal.close()
        if let journalTask = tasks.withLock({ $0.journal }) { await journalTask.value }
        return result()
    }

    /// Stops everything at once: every session is cancelled and nothing more is transcribed. A speech task stuck in a
    /// framework call that ignores cancellation is waited for at most `speechFinishBase`.
    func cancel() async {
        input.close(discardingQueued: true)
        cancelEverything()
        if let speech = tasks.withLock({ $0.speech }) {
            _ = await awaitWithTimeout(timeouts.speechFinishBase, cancellable: false) { await speech.value }
        }
        await waitForFinishing()
        journal.close()
        await tasks.withLock { $0.journal }?.value
    }

    // MARK: - Speech task

    private func runSpeech() async {
        var expected: Double?
        var currentEpoch: Int?
        feeding: while let item = await input.next() {
            if state.withLock({ $0.behindFrom != nil || $0.cancelled }) { break }
            switch item {
            case .boundary:
                if let current = takeCurrent() { finishLater(current) }
                expected = nil
            case .frame(var frame, let epoch):
                if epoch != currentEpoch {
                    // A new epoch is not sample-continuous with the last one: it gets its own session.
                    if let current = takeCurrent() { finishLater(current) }
                    currentEpoch = epoch
                    expected = nil
                }
                if let end = expected {
                    switch FrameContinuity.classify(frameStart: frame.startTime, frameCount: frame.frameCount,
                                                    sampleRate: frame.sampleRate, expected: end) {
                    case .overlap(let dropFrames):
                        // Speech sessions take ordered, nonoverlapping audio.
                        guard dropFrames < frame.frameCount,
                              let rest = try? PCMFrame(samples: Array(frame.samples[(dropFrames * frame.channels)...]),
                                                       sampleRate: frame.sampleRate, channels: frame.channels,
                                                       startTime: end) else { continue }
                        frame = rest
                    case .contiguous:
                        if let snapped = try? PCMFrame(samples: frame.samples, sampleRate: frame.sampleRate,
                                                       channels: frame.channels, startTime: end) { frame = snapped }
                    case .gap(let seconds):
                        if seconds > Self.sessionGapSeconds, let current = takeCurrent() { finishLater(current) }
                    }
                }
                let serial: Int
                if let current = state.withLock({ $0.current }) {
                    serial = current
                } else {
                    guard let started = await startSession(epoch: epoch, at: frame.startTime) else { break feeding }
                    serial = started
                }
                guard let (session, base) = state.withLock({ state -> (any LiveSpeechSession, Double)? in
                    guard let record = state.sessions[serial], let session = record.session else { return nil }
                    return (session, record.base ?? frame.startTime)
                }) else { break feeding }
                do {
                    let rebased = try PCMFrame(samples: frame.samples, sampleRate: frame.sampleRate,
                                               channels: frame.channels, startTime: max(0, frame.startTime - base))
                    try await session.append(rebased)
                    let end = frame.startTime + frame.duration
                    state.withLock { state in
                        state.sessions[serial]?.fed += frame.duration
                        state.lastFedEnd = end
                    }
                    expected = end
                } catch {
                    // Cancelled from here (the track, or a drain that timed out and records the point itself): stop.
                    // A session's own CancellationError is a failure like any other: the rest is replayed.
                    if Task.isCancelled || state.withLock({ $0.cancelled }) { break feeding }
                    reporter.message("Live transcription paused for \(track): \(Self.clause(error)). Audio remains on disk.")
                    _ = takeCurrent()
                    await session.cancel()
                    state.withLock { $0.sessions[serial]?.session = nil }
                    fallBehind(from: frame.startTime, reason: "speechFailed")
                    break feeding
                }
            }
        }
        if let current = takeCurrent() { finishLater(current) }
    }

    /// Makes the session prepared for `epoch` (or a new one) current for audio starting at `start`; nil when none can
    /// be made (the track falls behind from `start`).
    private func startSession(epoch: Int, at start: Double) async -> Int? {
        var serial = state.withLock { state -> Int? in
            state.pushedEpochs.remove(epoch)
            return state.prepared.removeValue(forKey: epoch)
        }
        if serial == nil {
            do {
                serial = try await makeSession()
            } catch {
                if !(error is CancellationError) {
                    reporter.message("Live \(track) transcription could not restart: \(Self.clause(error)). The rest is transcribed from the saved audio after stop.")
                }
                fallBehind(from: start, reason: "sessionUnavailable")
                return nil
            }
        }
        guard let serial else { return nil }
        state.withLock { state in
            state.sessions[serial]?.base = start
            state.current = serial
        }
        return serial
    }

    /// Makes a speech session and records it. One that arrives after the track or the calling task was cancelled (a
    /// factory that ignored the cancellation, after `cancel()`, `finish()`, or a restart's time limit stopped waiting
    /// for it) is cancelled at once and `CancellationError` thrown.
    private func makeSession() async throws -> Int {
        let serial = state.withLock { state -> Int in
            defer { state.nextSerial += 1 }
            return state.nextSerial
        }
        let session = try await makeSpeech(locale, backend, contextualStrings) { [weak self] update in
            guard update.isFinal else { return }
            self?.finalized(update.segment, session: serial)
        }
        let cancelled = Task.isCancelled
        let kept = state.withLock { state -> Bool in
            guard !state.cancelled, !cancelled else { return false }
            state.sessions[serial] = SessionRecord(session: session)
            return true
        }
        guard kept else {
            await session.cancel()
            throw CancellationError()
        }
        return serial
    }

    private func takeCurrent() -> Int? {
        state.withLock { state in
            defer { state.current = nil }
            return state.current
        }
    }

    private func currentFed() -> Double {
        state.withLock { state in state.current.flatMap { state.sessions[$0]?.fed } ?? 0 }
    }

    // MARK: - Finishing sessions

    /// Finishes `serial` in the background, within its timeout, and no later than the deadline of `finish()`, even
    /// when that deadline is set after this finish began.
    private func finishLater(_ serial: Int) {
        // Registered under the lock the task takes to remove itself, so a quick task never outlives its entry.
        tasks.withLock { tasks in
            tasks.finishing[serial] = Task { [weak self] () -> Void in
                await self?.finishSession(serial)
                self?.tasks.withLock { _ = $0.finishing.removeValue(forKey: serial) }
            }
        }
    }

    private func finishSession(_ serial: Int) async {
        guard let (session, fed) = state.withLock({ state -> (any LiveSpeechSession, Double)? in
            guard let record = state.sessions[serial], let session = record.session else { return nil }
            return (session, record.fed)
        }) else { return }
        let outcome = await awaitWithTimeout(timeouts.speechFinish(audioSeconds: fed), deadline: stopDeadline) {
            try await session.finish()
        }
        switch outcome {
        case .finished(.success(let segments)):
            // Done with the session: only its result is kept.
            state.withLock { state in
                state.sessions[serial]?.result = segments
                state.sessions[serial]?.finals = []
                state.sessions[serial]?.session = nil
            }
            return
        case .finished(.failure(let error)):
            if !(error is CancellationError) {
                Self.log.error("Live \(self.track, privacy: .public) transcription failed to finish: \(error.localizedDescription, privacy: .public)")
            }
        case .timedOut:
            Self.log.error("Live \(self.track, privacy: .public) transcription did not finish within its timeout or by the stop deadline; cancelled")
        case .cancelled:
            break
        }
        await session.cancel()
        // Its finalized segments are kept; the rest of its audio is transcribed from disk.
        let from = state.withLock { state -> Double? in
            state.sessions[serial]?.session = nil
            guard !state.cancelled, let record = state.sessions[serial] else { return nil }
            return record.finals.map(\.end).max() ?? record.base
        }
        if let from { fallBehind(from: from, reason: "speechTimedOut") }
    }

    private func waitForFinishing() async {
        while true {
            let pending = tasks.withLock { tasks -> [Task<Void, Never>] in
                defer { tasks.finishing.removeAll() }
                return Array(tasks.finishing.values)
            }
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }

    private func discardSession(_ serial: Int) async {
        let session = state.withLock { state -> (any LiveSpeechSession)? in
            state.sessions.removeValue(forKey: serial)?.session ?? nil
        }
        await session?.cancel()
    }

    private func cancelEverything() {
        let (sessions, running) = state.withLock { state -> ([any LiveSpeechSession], Bool) in
            let wasCancelled = state.cancelled
            state.cancelled = true
            return (state.sessions.values.compactMap(\.session), wasCancelled)
        }
        guard !running else { return }
        input.close(discardingQueued: true)
        let (speech, finishing) = tasks.withLock { ($0.speech, $0.finishing.values) }
        speech?.cancel()
        for task in finishing { task.cancel() }
        // A speech framework's `append` or `finish` need not observe task cancellation.
        for session in sessions { Task { await session.cancel() } }
    }

    // MARK: - Results and journal

    private func finalized(_ segment: TranscriptSegment, session serial: Int) {
        let absolute = state.withLock { state -> TranscriptSegment in
            let shifted = Self.shifted(segment, by: state.sessions[serial]?.base ?? 0, track: track)
            state.sessions[serial]?.finals.append(shifted)
            state.lastFinalized = max(state.lastFinalized ?? shifted.end, shifted.end)
            state.lastPhrase = String(shifted.text.prefix(200))
            return shifted
        }
        if showPhrases { reporter.phrase(absolute, track: track) }
        if !journal.push(.finalized(absolute)) {
            state.withLock { $0.journalDroppedFrom = min($0.journalDroppedFrom ?? absolute.start, absolute.start) }
        }
    }

    /// Records the first (or an earlier) point from which live transcription is incomplete, and stops live speech.
    private func fallBehind(from: Double, reason: String) {
        let record = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            if let current = state.behindFrom, current <= from { return false }
            state.behindFrom = from
            return true
        }
        guard record else { return }
        Self.log.notice("Live \(self.track, privacy: .public) transcription behind from \(from, privacy: .public) s (\(reason, privacy: .public))")
        journal.push(.behind(from: from, reason: reason), force: true)
        input.close(discardingQueued: true)
    }

    private func runJournal() async {
        var reportedFailure = false
        while let item = await journal.next() {
            do {
                switch item {
                case .finalized(let segment):
                    var details = ["track": track, "text": segment.text, "start": String(segment.start),
                                   "end": String(segment.end), "segmentID": segment.id]
                    if let words = try? HolosJSON.encoder(pretty: false).encode(segment.words) {
                        details["words"] = String(decoding: words, as: UTF8.self)
                    }
                    try await events(MeetingEventKind.transcriptFinalized, details)
                case .behind(let from, let reason):
                    try await events(MeetingEventKind.transcriptionBehind,
                                     ["track": track, "from": String(from), "reason": reason])
                }
            } catch {
                if !reportedFailure {
                    reportedFailure = true
                    reporter.message("Could not persist live text: \(error.localizedDescription).")
                }
            }
            if journal.isEmpty,
               let from = state.withLock({ state -> Double? in defer { state.journalDroppedFrom = nil }; return state.journalDroppedFrom }) {
                try? await events(MeetingEventKind.transcriptionBehind,
                                  ["track": track, "from": String(from), "reason": "journalFull"])
            }
        }
    }

    private func result() -> LiveTrackResult {
        state.withLock { state in
            var segments: [TranscriptSegment] = []
            for serial in state.sessions.keys.sorted() {
                guard let record = state.sessions[serial] else { continue }
                if let result = record.result {
                    segments += result.map { Self.shifted($0, by: record.base ?? 0, track: track) }
                } else {
                    segments += record.finals
                }
            }
            segments.sort { $0.start < $1.start }
            return LiveTrackResult(segments: segments, behindFrom: state.behindFrom)
        }
    }

    /// An error's description to use mid-sentence: without its closing period.
    static func clause(_ error: Error) -> String {
        var text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `segment` moved from its speech session's timeline to the session timeline.
    static func shifted(_ segment: TranscriptSegment, by base: Double, track: String) -> TranscriptSegment {
        var moved = segment
        moved.start += base
        moved.end += base
        moved.words = segment.words.map { word in
            var shifted = word
            shifted.start += base
            shifted.end += base
            return shifted
        }
        moved.track = track
        return moved
    }
}
