import AVFoundation
import Foundation
import HolosAudio
import HolosCore
import HolosStorage
import os
import Synchronization

/// `holos session import` (docs/meeting-design.md §5.5 PR7c): turns an audio file into a finished session, so a meeting
/// recorded elsewhere (or a reference recording for evaluation) can be transcribed, labelled, and exported like one
/// Holos recorded.
public enum SessionImporter {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    /// Frames read from the file and written per step: about one second of audio, at least this many.
    static let minimumBlockFrames: AVAudioFrameCount = 4_096
    /// The share of `progress` that copying the audio takes when the import also transcribes.
    static let audioProgressShare = 0.1

    /// Creates a session from an audio file: track "mic", channels averaged to mono, source sample rate,
    /// Int16 chunks through AudioChunkWriter, meeting.json {mode: inPerson, origin: imported}, vocabulary.json;
    /// transcribes with TrackReplayer unless `transcribe == false`; finishes as complete or audioOnly.
    ///
    /// Details:
    /// - The file is anything `AVAudioFile` reads (WAV, CAF, AIFF, M4A, MP3, …). Its samples keep their sample rate
    ///   and their times from the start of the file; session time 0 is the file's first frame.
    /// - `vocabulary` becomes the speech sessions' contextual strings and `vocabulary.json`, cleaned as a recording's
    ///   is: entries trimmed, empty and over-100-character entries dropped, at most 1,000 kept. No vocabulary, no
    ///   file.
    /// - `meeting.json` records the file's name (`importedFileName`), not its folder.
    /// - The transcript becomes the current revision (`transcripts/current.json`) without the legacy speaker-less
    ///   exports; speaker labels and exports come from post-processing, which the caller runs.
    /// - `progress` receives 0...1, never decreasing, from any thread: copying the audio, then (when transcribing)
    ///   the share of the audio fed to speech recognition.
    /// - All or nothing: an unreadable file, a failed write, a transcription error, or cancellation removes the new
    ///   session folder (the source file is never changed) and throws; `CancellationError` passes through unchanged.
    ///   Throws before creating anything when the file is not a readable audio file with at least one frame, or the
    ///   name or locale is empty.
    public static func importAudio(from file: URL, name: String, root: URL, locale: String, backend: SpeechBackend,
                                   vocabulary: [String] = [], transcribe: Bool = true,
                                   makeSpeech: LiveSpeechFactory? = nil,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HolosError.invalidInput("The imported meeting needs a name.") }
        guard !locale.isEmpty else { throw HolosError.invalidInput("Choose a locale for the transcription.") }
        let audio = try openAudio(file)
        try Task.checkCancellation()
        let vocabulary = cleaned(vocabulary)
        let archive = try SessionArchive.create(root: root, name: name, source: .microphone, locale: locale,
                                                backend: backend)
        let directory = archive.directory
        log.notice("Session \(archive.id, privacy: .public): importing \(audio.length, privacy: .public) frames at \(audio.processingFormat.sampleRate, privacy: .public) Hz")
        do {
            let info = MeetingInfo(sessionID: archive.id, mode: .inPerson, othersInRoom: false, origin: .imported,
                                   importedFileName: file.lastPathComponent)
            try AtomicFile.create(try HolosJSON.encoder().encode(info), at: SessionPaths.meetingInfo(directory))
            if !vocabulary.isEmpty {
                try AtomicFile.create(try HolosJSON.encoder().encode(MeetingVocabulary(strings: vocabulary)),
                                      at: SessionPaths.vocabulary(directory))
            }
            let meter = ProgressMeter(progress)
            let audioShare = transcribe ? audioProgressShare : 1
            let seconds = try await copyAudio(audio, file: file, into: archive) { fraction in
                meter.report(audioShare * fraction)
            }
            guard transcribe else {
                try await archive.finish(status: ArchiveStatus.audioOnly)
                meter.report(1)
                log.notice("Session \(archive.id, privacy: .public): imported \(seconds, privacy: .public) s of audio without a transcript")
                return directory
            }
            try await archive.setStatus(ArchiveStatus.processing)
            let segments = try await transcribeAudio(
                session: directory, seconds: seconds, locale: locale, backend: backend, vocabulary: vocabulary,
                makeSpeech: makeSpeech ?? appleSpeechFactory
            ) { fraction in
                meter.report(audioShare + (1 - audioShare) * fraction)
            }
            try Task.checkCancellation()
            let transcript = Transcript(source: directory.path, locale: locale, backend: backend,
                                        segments: segments.sorted { ($0.start, $0.id) < ($1.start, $1.id) })
            try await archive.saveTranscript(transcript, writeLegacyExports: false)
            try await archive.finish(status: ArchiveStatus.complete)
            meter.report(1)
            log.notice("Session \(archive.id, privacy: .public): imported \(seconds, privacy: .public) s of audio, \(segments.count, privacy: .public) segments")
            return directory
        } catch {
            await discard(archive)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error is HolosError { throw error }
            throw HolosError.io("The import failed (\(error.localizedDescription)); nothing was imported.")
        }
    }

    // MARK: - Audio

    /// Opens `file` for reading and checks that it holds audio. The source is only read, so a symbolic link to it is
    /// followed.
    private static func openAudio(_ file: URL) throws -> AVAudioFile {
        guard file.isFileURL else { throw HolosError.invalidInput("The audio to import must be a local file.") }
        let resolved = file.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw HolosError.invalidInput("\(file.path) is not an audio file that can be read.")
        }
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: resolved)
        } catch {
            throw HolosError.invalidInput(
                "\(file.lastPathComponent) could not be read as audio (\(error.localizedDescription)).")
        }
        let format = audio.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0, audio.length > 0 else {
            throw HolosError.invalidInput("\(file.lastPathComponent) has no audio to import.")
        }
        return audio
    }

    /// Writes the file's audio as the session's "mic" track, channels averaged to mono, and returns its seconds.
    private static func copyAudio(_ audio: AVAudioFile, file: URL, into archive: SessionArchive,
                                  progress: (Double) -> Void) async throws -> Double {
        let format = audio.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let blockFrames = max(minimumBlockFrames, AVAudioFrameCount(min(sampleRate, 1_048_576)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw HolosError.io("Could not allocate an audio buffer for the import.")
        }
        let writer = AudioChunkWriter(archive: archive)
        let length = max(1, audio.length)
        var written = 0
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            do {
                try audio.read(into: buffer, frameCount: blockFrames)
            } catch {
                throw HolosError.io(
                    "Could not read the audio in \(file.lastPathComponent) (\(error.localizedDescription)).")
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            let mono = try monoSamples(buffer, channels: channels)
            let frame = try PCMFrame(samples: mono, sampleRate: sampleRate, channels: 1,
                                     startTime: Double(written) / sampleRate)
            try await writer.append(CapturedAudio(track: "mic", frame: frame))
            written += frames
            progress(min(1, Double(audio.framePosition) / Double(length)))
        }
        try await writer.finish()
        guard written > 0 else { throw HolosError.invalidInput("\(file.lastPathComponent) has no audio to import.") }
        return Double(written) / sampleRate
    }

    /// The buffer's frames with its channels averaged (the processing format is deinterleaved Float32).
    static func monoSamples(_ buffer: AVAudioPCMBuffer, channels: Int) throws -> [Float] {
        let frames = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else {
            throw HolosError.io("The imported audio did not decode to floating-point samples.")
        }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: frames)) }
        let stride = buffer.stride
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for channel in 0..<channels {
            let samples = buffer.format.isInterleaved ? data[0] + channel : data[channel]
            let step = buffer.format.isInterleaved ? stride : 1
            for index in 0..<frames { mono[index] += samples[index * step] }
        }
        for index in 0..<frames { mono[index] *= scale }
        return mono
    }

    // MARK: - Transcription

    /// Transcribes the session's "mic" track with `TrackReplayer`; `progress` receives the share of the audio fed.
    private static func transcribeAudio(session: URL, seconds: Double, locale: String, backend: SpeechBackend,
                                        vocabulary: [String], makeSpeech: @escaping LiveSpeechFactory,
                                        progress: @escaping @Sendable (Double) -> Void) async throws
        -> [TranscriptSegment] {
        let fed = Mutex(0.0)
        let total = max(seconds, 1e-9)
        let counting: LiveSpeechFactory = { locale, backend, contextualStrings, onUpdate in
            let session = try await makeSpeech(locale, backend, contextualStrings, onUpdate)
            return CountingSpeechSession(base: session) { duration in
                let sum = fed.withLock { value -> Double in
                    value += duration
                    return value
                }
                progress(min(1, sum / total))
            }
        }
        do {
            return try await TrackReplayer.replay(directory: session, track: "mic", locale: locale, backend: backend,
                                                  contextualStrings: vocabulary, makeSpeech: counting)
        } catch let error where !(error is CancellationError) && !Task.isCancelled {
            throw HolosError.unavailable(
                "The imported audio could not be transcribed (\(error.localizedDescription)); nothing was imported. "
                    + "Import it without transcription (holos session import --no-transcribe) to keep the audio alone.")
        }
    }

    // MARK: - Helpers

    /// The recording rules for `vocabulary.json` (§4.12): trimmed, non-empty entries of at most 100 characters,
    /// at most 1,000 of them.
    static func cleaned(_ vocabulary: [String]) -> [String] {
        Array(vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= RecordingWorkflow.maxVocabularyLength }
            .prefix(RecordingWorkflow.maxVocabularyEntries))
    }

    /// Removes a session whose import did not finish. The processing lease is taken first (while the writer lock is
    /// still held, as the recorder does), so no other Holos process can start on the folder between the writer lock
    /// being released and the folder being removed. Failures are logged; the caller's error is what matters.
    private static func discard(_ archive: SessionArchive) async {
        let directory = archive.directory
        let lease = try? SessionArchive.acquireProcessingLease(at: directory)
        defer { lease?.release() }
        try? await archive.finish(status: ArchiveStatus.failed)
        do {
            try AtomicFile.removeTree([directory.lastPathComponent], in: directory.deletingLastPathComponent())
            log.notice("Session \(archive.id, privacy: .public): import did not finish; the new session was removed")
        } catch {
            log.error("Session \(archive.id, privacy: .public): import did not finish and its folder could not be removed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// Reports progress without ever going backwards.
private final class ProgressMeter: Sendable {
    private let last = Mutex(-1.0)
    private let forward: @Sendable (Double) -> Void

    init(_ forward: @escaping @Sendable (Double) -> Void) { self.forward = forward }

    func report(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let value = min(1, max(0, fraction))
        let advanced = last.withLock { previous -> Bool in
            guard value > previous else { return false }
            previous = value
            return true
        }
        if advanced { forward(value) }
    }
}

/// A speech session that reports the seconds of audio each `append` fed, for import progress.
private struct CountingSpeechSession: LiveSpeechSession {
    let base: any LiveSpeechSession
    let fed: @Sendable (Double) -> Void

    func append(_ frame: PCMFrame) async throws {
        try await base.append(frame)
        fed(frame.duration)
    }

    func finish() async throws -> [TranscriptSegment] { try await base.finish() }

    func cancel() async { await base.cancel() }
}
