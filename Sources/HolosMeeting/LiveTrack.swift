import Foundation
import HolosCore
import HolosStorage

/// Live transcription of one track while it records. Finalized phrases go to the reporter and the event
/// journal. If transcription falls behind or fails, the track is marked for replay from disk after stop.
final class LiveTrack: Sendable {
    let track: String
    private let continuation: AsyncStream<PCMFrame>.Continuation
    private let worker: Task<[TranscriptSegment], Error>
    private let journalWorker: Task<Void, Error>
    private let journal: AsyncStream<TranscriptSegment>.Continuation
    private let needsReplay: LockedValue<Bool>
    private let reporter: any RecordingReporter
    /// Cancelled directly as well as through `worker`: a speech framework's `finish()` may not observe task
    /// cancellation.
    private let session: any LiveSpeechSession

    private init(track: String, continuation: AsyncStream<PCMFrame>.Continuation,
                 worker: Task<[TranscriptSegment], Error>, journalWorker: Task<Void, Error>,
                 journal: AsyncStream<TranscriptSegment>.Continuation, needsReplay: LockedValue<Bool>,
                 reporter: any RecordingReporter, session: any LiveSpeechSession) {
        self.track = track; self.continuation = continuation; self.worker = worker
        self.journalWorker = journalWorker; self.journal = journal; self.needsReplay = needsReplay
        self.reporter = reporter; self.session = session
    }

    static func make(track: String, locale: String, backend: SpeechBackend, contextualStrings: [String],
                     makeSpeech: LiveSpeechFactory, archive: SessionArchive,
                     reporter: any RecordingReporter) async throws -> LiveTrack {
        let frames = AsyncStream<PCMFrame>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let updates = AsyncStream<TranscriptSegment>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let replay = LockedValue(false)
        let session = try await makeSpeech(locale, backend, contextualStrings) { update in
            if update.isFinal {
                reporter.phrase(update.segment, track: track)
                if case .dropped = updates.continuation.yield(update.segment) {
                    replay.withLock { $0 = true }
                }
            }
        }
        let journalWorker = Task {
            for await segment in updates.stream {
                try await archive.recordEvent(kind: MeetingEventKind.transcriptFinalized, details: [
                    "track": track, "text": segment.text, "start": String(segment.start), "end": String(segment.end),
                ])
            }
        }
        let worker = Task {
            do {
                for await frame in frames.stream { try await session.append(frame) }
                return try await session.finish()
            } catch {
                replay.withLock { $0 = true }
                reporter.message("Live transcription paused for \(track): \(error.localizedDescription). Audio remains on disk.")
                await session.cancel()
                throw error
            }
        }
        return LiveTrack(track: track, continuation: frames.continuation, worker: worker,
                         journalWorker: journalWorker, journal: updates.continuation, needsReplay: replay,
                         reporter: reporter, session: session)
    }

    /// Never blocks: a full queue stops live transcription for the rest of the recording.
    func submit(_ frame: PCMFrame) {
        guard !needsReplay.value else { return }
        if case .dropped = continuation.yield(frame) {
            needsReplay.withLock { $0 = true }
            reporter.message("Transcription is behind on \(track); recording continues and saved audio will be processed after stop.")
            continuation.finish()
            worker.cancel()
        }
    }

    /// The finalized segments, or nil when the track must be replayed from disk. Cancelling the calling task
    /// cancels the speech session and returns nil.
    func finish() async -> [TranscriptSegment]? {
        continuation.finish()
        let result = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
            let session = session
            Task { await session.cancel() }
        }
        journal.finish()
        do { try await journalWorker.value }
        catch {
            reporter.message("Could not persist live text: \(error.localizedDescription).")
            needsReplay.withLock { $0 = true }
        }
        return needsReplay.value ? nil : result
    }

    func cancel() async {
        continuation.finish(); worker.cancel()
        // The worker may be inside `session.finish()`, which need not observe task cancellation.
        await session.cancel()
        _ = try? await worker.value
        journal.finish()
        _ = try? await journalWorker.value
    }
}
