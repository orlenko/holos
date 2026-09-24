import AVFoundation
import Darwin
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
    /// - Every speech call has the limits of `timeouts` (§1.3): creating a session and each `append` at most
    ///   `speechFinishBase`, each `finish` at most `speechFinish(audioSeconds:)`. A call that does not return in time
    ///   fails the import like any other transcription error.
    /// - All or nothing, even when the process is killed: the session is built in a hidden staging folder in `root`
    ///   (`.import-<UUID>/<id>.holos`, which no listing, recovery, or catalog takes for a session) and appears as
    ///   `<root>/<id>.holos` in one rename once it is finished. An unreadable file, a failed write, a transcription
    ///   error, or cancellation removes the staging folder (the source file is never changed) and throws;
    ///   `CancellationError` passes through unchanged. A staging folder left by a killed import is removed by the
    ///   next import in the same root. Throws before creating anything when the file is not a readable audio file
    ///   with at least one frame, or the name or locale is empty.
    public static func importAudio(from file: URL, name: String, root: URL, locale: String, backend: SpeechBackend,
                                   vocabulary: [String] = [], transcribe: Bool = true,
                                   makeSpeech: LiveSpeechFactory? = nil, timeouts: StopTimeouts = .standard,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let imported = try await importSession(from: file, name: name, root: root, locale: locale, backend: backend,
                                               vocabulary: vocabulary, transcribe: transcribe, makeSpeech: makeSpeech,
                                               timeouts: timeouts, progress: progress)
        imported.lease.release()
        return imported.directory
    }

    /// A published import and the processing lease taken before its writer lock was released, so the session is
    /// never without a lock between the import and post-processing (as after a recording, §4.1). The caller releases
    /// the lease. `lease.session` names the staging path the lease was taken at; the lease itself belongs to the
    /// folder (it is checked by device and inode), which the rename keeps.
    struct ImportedSession: Sendable {
        let directory: URL
        let lease: ProcessingLease
    }

    /// `importAudio`, returning the processing lease with the session.
    static func importSession(from file: URL, name: String, root: URL, locale: String, backend: SpeechBackend,
                              vocabulary: [String], transcribe: Bool, makeSpeech: LiveSpeechFactory?,
                              timeouts: StopTimeouts,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> ImportedSession {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HolosError.invalidInput("The imported meeting needs a name.") }
        guard !locale.isEmpty else { throw HolosError.invalidInput("Choose a locale for the transcription.") }
        guard root.isFileURL else { throw HolosError.invalidInput("The sessions folder must be a local folder.") }
        let audio = try openAudio(file)
        try Task.checkCancellation()
        let vocabulary = cleaned(vocabulary)
        let staging = try ImportStaging.create(in: root)
        let archive: SessionArchive
        do {
            archive = try SessionArchive.create(root: staging.url, name: name, source: .microphone, locale: locale,
                                                backend: backend)
        } catch {
            throw failure(error, leftover: staging.discard())
        }
        let directory = archive.directory
        log.notice("Session \(archive.id, privacy: .public): importing \(audio.length, privacy: .public) frames at \(audio.processingFormat.sampleRate, privacy: .public) Hz")
        var lease: ProcessingLease?
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
            var status = ArchiveStatus.audioOnly
            var segmentCount = 0
            if transcribe {
                try await archive.setStatus(ArchiveStatus.processing)
                let segments = try await transcribeAudio(
                    session: directory, seconds: seconds, locale: locale, backend: backend, vocabulary: vocabulary,
                    makeSpeech: makeSpeech ?? appleSpeechFactory, timeouts: timeouts
                ) { fraction in
                    meter.report(audioShare + (1 - audioShare) * fraction)
                }
                try Task.checkCancellation()
                let transcript = Transcript(source: directory.path, locale: locale, backend: backend,
                                            segments: segments.sorted { ($0.start, $0.id) < ($1.start, $1.id) })
                try await archive.saveTranscript(transcript, writeLegacyExports: false)
                status = ArchiveStatus.complete
                segmentCount = segments.count
            }
            // The lease is taken while the writer lock is still held, as the recorder does. No one else can hold it:
            // the staging folder is this import's alone.
            let held = try SessionArchive.acquireProcessingLease(at: directory, retry: .zero)
            lease = held
            try await archive.finish(status: status)
            try Task.checkCancellation()
            // Nothing after the rename throws: once published, the session is the caller's.
            let published = try staging.publish(directory.lastPathComponent)
            meter.report(1)
            log.notice("Session \(archive.id, privacy: .public): imported \(seconds, privacy: .public) s of audio, \(segmentCount, privacy: .public) segments, as \(status, privacy: .public)")
            return ImportedSession(directory: published, lease: held)
        } catch {
            lease?.release()
            // Closes the writer lock if the archive is still open; an archive already finished refuses, harmlessly.
            try? await archive.finish(status: ArchiveStatus.failed)
            let leftover = staging.discard()
            if leftover == nil {
                log.notice("Session \(archive.id, privacy: .public): import did not finish; its staging folder was removed")
            }
            throw failure(error, leftover: leftover)
        }
    }

    /// The error an import that did not finish throws. `leftover` is nil when the staging folder was removed (then
    /// nothing was imported), else the sentence that says it was not.
    private static func failure(_ error: any Error, leftover: String?) -> any Error {
        if error is CancellationError || Task.isCancelled {
            guard let leftover else { return CancellationError() }
            return HolosError.incomplete("The import was cancelled. \(leftover)")
        }
        let outcome = leftover ?? "Nothing was imported."
        switch error {
        case let failure as TranscriptionFailure:
            return HolosError.unavailable("\(failure.message) \(outcome) Import it without transcription "
                                          + "(holos session import --no-transcribe) to keep the audio alone.")
        case HolosError.invalidInput(let message): return HolosError.invalidInput("\(message) \(outcome)")
        case HolosError.unavailable(let message): return HolosError.unavailable("\(message) \(outcome)")
        case HolosError.permissionDenied(let message): return HolosError.permissionDenied("\(message) \(outcome)")
        case HolosError.incomplete(let message): return HolosError.incomplete("\(message) \(outcome)")
        case HolosError.io(let message): return HolosError.io("\(message) \(outcome)")
        default: return HolosError.io("The import failed (\(error.localizedDescription)). \(outcome)")
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

    /// Transcribes the session's "mic" track with `TrackReplayer`, every speech call within `timeouts`; `progress`
    /// receives the share of the audio fed. Throws `TranscriptionFailure` for a speech error or a call that timed
    /// out (`ReplayIncomplete`), `CancellationError` when cancelled.
    private static func transcribeAudio(session: URL, seconds: Double, locale: String, backend: SpeechBackend,
                                        vocabulary: [String], makeSpeech: @escaping LiveSpeechFactory,
                                        timeouts: StopTimeouts,
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
                                                  contextualStrings: vocabulary, makeSpeech: counting,
                                                  timeouts: timeouts)
        } catch let error where !(error is CancellationError) && !Task.isCancelled {
            // A timed-out replay (`ReplayIncomplete`) fails the import too: all or nothing.
            throw TranscriptionFailure(
                message: "The imported audio could not be transcribed (\(error.localizedDescription)).")
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

}

/// Speech could not transcribe the imported audio (an error, or a call that did not return in time).
private struct TranscriptionFailure: Error {
    var message: String
}

/// The hidden folder `<root>/.import-<UUID>` that holds one import until it is published. Its `.import.lock` is
/// locked (`flock`) from just after the folder is made until it is removed, so the sweep of another import leaves a
/// running import alone. The folder's name does not end in `.holos`, so nothing lists it as a session, and
/// `holos session recover` never turns a killed import into an interrupted recording.
final class ImportStaging {
    static let prefix = ".import-"
    static let lockName = ".import.lock"
    /// A staging folder without its lock file is removed by a sweep only when it has not changed for this long: it
    /// may belong to an import that has just made it.
    static let unlockedGrace: TimeInterval = 3_600

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    /// The sessions root as the caller named it; published sessions are named under it.
    let root: URL
    let name: String
    var url: URL { root.appendingPathComponent(name, isDirectory: true) }
    /// The locked `.import.lock`, or -1 once closed.
    private var lockFD: Int32

    private init(root: URL, name: String, lockFD: Int32) {
        self.root = root; self.name = name; self.lockFD = lockFD
    }

    deinit { closeLock() }

    /// Creates `root` if needed, removes abandoned staging folders in it (`sweep`), then makes and locks a new one.
    static func create(in root: URL) throws -> ImportStaging {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sweep(root)
        let name = prefix + UUID().uuidString
        let url = root.appendingPathComponent(name, isDirectory: true)
        guard mkdir(url.path, 0o700) == 0 else {
            throw HolosError.io("Cannot create the import folder: \(String(cString: strerror(errno))).")
        }
        var code: Int32 = 0
        var lock: Int32 = -1
        let folder = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0 {
            code = errno
        } else {
            lock = openat(folder, lockName, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if lock < 0 {
                code = errno
            } else if flock(lock, LOCK_EX | LOCK_NB) != 0 {
                code = errno
                Darwin.close(lock)
                lock = -1
            }
            Darwin.close(folder)
        }
        guard lock >= 0 else {
            _ = try? AtomicFile.removeTree([name], in: resolved(root))
            throw HolosError.io("Cannot lock the import folder: \(String(cString: strerror(code))).")
        }
        return ImportStaging(root: root, name: name, lockFD: lock)
    }

    /// Moves the finished session folder `sessionName` from the staging folder to `root` in one rename (never over
    /// an existing folder), makes the rename durable, and removes the empty staging folder. Throws, having moved
    /// nothing, when the rename fails; after the rename it never throws (a staging folder it cannot remove is left
    /// for the next sweep).
    func publish(_ sessionName: String) throws -> URL {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw HolosError.io("Cannot open the sessions folder: \(Self.errnoText()).") }
        defer { Darwin.close(rootFD) }
        let stagingFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingFD >= 0 else { throw HolosError.io("Cannot open the import folder: \(Self.errnoText()).") }
        defer { Darwin.close(stagingFD) }
        var moved = renameatx_np(stagingFD, sessionName, rootFD, sessionName, UInt32(RENAME_EXCL)) == 0
        if !moved, errno == ENOTSUP || errno == EINVAL {
            // A volume without RENAME_EXCL: the name is a new UUID, and it is checked to be free just before.
            var info = stat()
            if fstatat(rootFD, sessionName, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
                moved = renameat(stagingFD, sessionName, rootFD, sessionName) == 0
            } else {
                errno = EEXIST
            }
        }
        guard moved else {
            throw HolosError.io("Cannot move the imported session into the sessions folder: \(Self.errnoText()).")
        }
        if fsync(rootFD) != 0 || fsync(stagingFD) != 0 {
            Self.log.error("Cannot save the sessions folder after an import: \(Self.errnoText(), privacy: .public)")
        }
        unlinkat(stagingFD, Self.lockName, 0)
        closeLock()
        if unlinkat(rootFD, name, AT_REMOVEDIR) != 0 {
            Self.log.error("Cannot remove an empty import folder: \(Self.errnoText(), privacy: .public)")
        } else if fsync(rootFD) != 0 {
            Self.log.error("Cannot save the sessions folder after an import: \(Self.errnoText(), privacy: .public)")
        }
        return root.appendingPathComponent(sessionName, isDirectory: true)
    }

    /// Removes the staging folder and everything in it, then lets go of the lock. Returns nil when it is gone, else
    /// a sentence for the user that says where the partial files are.
    func discard() -> String? {
        defer { closeLock() }
        do {
            try AtomicFile.removeTree([name], in: Self.resolved(root))
            return nil
        } catch {
            Self.log.error("Cannot remove an import folder: \(error.localizedDescription, privacy: .private)")
            return "Its partial files in \(url.path) could not be removed (\(error.localizedDescription)). They are "
                + "not a session; delete that folder, or the next import removes it."
        }
    }

    /// Removes the staging folders in `root` that no running import holds: those whose lock file can be locked, and
    /// those without one that have not changed for `unlockedGrace`. Failures are logged; an import never fails
    /// because of an older one's leftovers.
    static func sweep(_ root: URL, now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let path = root.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let folder = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { continue }
            defer { Darwin.close(folder) }
            let lock = openat(folder, lockName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if lock < 0 {
                let missing = errno == ENOENT
                let changed = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                guard missing, now.timeIntervalSince(changed) > unlockedGrace else { continue }
            } else if flock(lock, LOCK_EX | LOCK_NB) != 0 {
                Darwin.close(lock)
                continue
            }
            // Held (when there is a lock file) until the folder is gone, so no other sweep starts on it meanwhile.
            defer { if lock >= 0 { Darwin.close(lock) } }
            do {
                try AtomicFile.removeTree([name], in: resolved(root))
                log.notice("Removed an import that did not finish")
            } catch {
                log.error("Cannot remove an import that did not finish: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func closeLock() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
        lockFD = -1
    }

    /// `root` with symbolic links resolved: `AtomicFile.removeTree` opens its root's last component without
    /// following a link, and a sessions root may be reached through one.
    private static func resolved(_ root: URL) -> URL { root.resolvingSymlinksInPath() }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
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
