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

    /// Test hook: while set (a task-local value), called with the session's staging path just after it is created,
    /// before anything else is written into it, so tests can swap folders on the way.
    @TaskLocal static var afterSession: (@Sendable (URL) -> Void)? = nil

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
    ///   `<root>/<id>.holos` in one rename once it is finished, and only once the published entry is checked to be
    ///   that session's folder. The returned URL is where it is: under `root`, or under the sessions folder's current
    ///   path when `root` was renamed (or a link to it retargeted) during the import. An unreadable file, a failed write, a transcription
    ///   error, or cancellation removes the staging folder (the source file is never changed) and throws;
    ///   `CancellationError` passes through unchanged. A staging folder left by a killed import is removed by a
    ///   later import in the same root once it is an hour old. Throws before creating anything when the file is not a readable audio file
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
            archive = try staging.createSession(name: name, locale: locale, backend: backend)
        } catch {
            throw failure(error, leftover: staging.discard())
        }
        let directory = archive.directory
        afterSession?(directory)
        // Where the session appears once published. Anything persisted that names the session names this path,
        // never the staging folder, which is gone once the import finishes.
        let publishedDirectory = staging.publishedURL(directory.lastPathComponent)
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
                let transcript = Transcript(source: publishedDirectory.path, locale: locale, backend: backend,
                                            segments: segments.sorted { ($0.start, $0.id) < ($1.start, $1.id) })
                try await archive.saveTranscript(transcript, writeLegacyExports: false)
                status = ArchiveStatus.complete
                segmentCount = segments.count
            }
            // The lease is taken while the writer lock is still held, as the recorder does. No one else can hold it:
            // the staging folder is this import's alone. It is taken in the session folder `createSession` made.
            let held = try staging.acquireLease()
            lease = held
            try await archive.finish(status: status)
            try Task.checkCancellation()
            // Once published, the session is the caller's; `publish` throws after its rename only when `root` no
            // longer leads to the sessions folder it was published in, so the location it would return is never one
            // other than `publishedDirectory`, which the transcript names (the catch below leaves the published
            // session alone).
            let published = try staging.publish(directory.lastPathComponent)
            assert(published == publishedDirectory)
            meter.report(1)
            log.notice("Session \(archive.id, privacy: .public): imported \(seconds, privacy: .public) s of audio, \(segmentCount, privacy: .public) segments, as \(status, privacy: .public)")
            return ImportedSession(directory: published, lease: held)
        } catch {
            lease?.release()
            if staging.published {
                _ = staging.discard()
                throw error
            }
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
        // Through each chunk's descriptor: `AVAudioFile` would open the chunk by path, outside the session's pin.
        let writer = AudioChunkWriter(archive: archive, throughDescriptor: true)
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
///
/// The sessions root may be any folder the user names (`--directory`), so a sweep removes only a folder Holos
/// made: one named exactly `.import-` + `UUID().uuidString` (upper case) that holds the ownership marker
/// `.holos-import` with `markerContents`, both reached without following a symbolic link. Any other folder, such
/// as `.import-notes`, is never touched.
///
/// The marker is visible only while the lock is held: `create` makes and locks `.import.lock` before it writes the
/// marker, and `publish` removes the marker before it lets go of the lock, so a sweep never finds a marked folder
/// whose import is running but not yet (or no longer) holding its lock.
///
/// Everything that removes or moves entries of a staging folder goes through a descriptor of that folder, opened and
/// checked once (the import keeps its own open from `create` on; a sweep opens each candidate and checks its marker
/// and lock through it), never through its name again. The sessions root may be a folder other programs change, and
/// a folder renamed in at a staging folder's name after the check is never emptied (`AtomicFile.removeOpenFolder`).
/// The session is made through that descriptor too (`createSession`), and its staging path is then pinned to the
/// session folder's descriptor (`AtomicFile.pinSessionFolder`) until it is published or discarded: every later write
/// that names the session by path goes through that descriptor, so a folder renamed in at the staging name, or at the
/// session's name inside it, never receives anything the import writes.
final class ImportStaging {
    static let prefix = ".import-"
    static let lockName = ".import.lock"
    /// Written into every staging folder after its lock file is locked; removed first when it is published, last when
    /// it is discarded or swept (`remove(folder:named:in:root:)`).
    static let markerName = ".holos-import"
    static let markerContents = Array("{\"holos\":\"import-staging\",\"version\":1}\n".utf8)
    /// A marked staging folder whose lock file is missing or unlocked is removed by a sweep only when the folder has
    /// not changed for this long, so a sweep never races an import that is making or publishing its folder.
    static let unlockedGrace: TimeInterval = 3_600

    /// The points between the steps of `create` and `publish`, for tests that run a sweep at each of them.
    enum Step: Equatable, CaseIterable {
        case folderMade, lockFileMade, locked, marked
        case moved, unmarked, lockFileRemoved, unlocked
    }

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "recorder")

    /// Test hook: while set (a task-local value), `createSession` calls it with the staging folder's URL before it
    /// makes the session folder, so tests can swap the staging folder on the way.
    @TaskLocal static var beforeSession: (@Sendable (URL) -> Void)? = nil

    /// The sessions root as the caller named it; published sessions are named under it.
    let root: URL
    let name: String
    var url: URL { root.appendingPathComponent(name, isDirectory: true) }
    /// The sessions root, open since `create` made the staging folder in it.
    private let rootFD: Int32
    /// The staging folder, open since `create` made it; every removal and the publishing rename go through it.
    private let folderFD: Int32
    /// The locked `.import.lock`, or -1 once closed.
    private var lockFD: Int32
    /// The session folder `createSession` made in the staging folder, open since, or -1 before.
    private var sessionFD: Int32 = -1
    /// Its name (`<id>.holos`), once made.
    private(set) var sessionName: String?
    /// Whether `publish` moved the session folder into the root (and checked it got there): from then on the session
    /// is no longer the staging folder's, and `discard` leaves it alone.
    private(set) var published = false
    /// Binds the session's staging path (`url/<sessionName>`) to `sessionFD` from `createSession` until the session
    /// is published or discarded, so no write that names the session by path reaches another folder.
    private var pin: SessionFolderPin?

    private init(root: URL, name: String, rootFD: Int32, folderFD: Int32, lockFD: Int32) {
        self.root = root; self.name = name; self.rootFD = rootFD; self.folderFD = folderFD; self.lockFD = lockFD
    }

    deinit {
        closeLock()
        if sessionFD >= 0 { Darwin.close(sessionFD) }
        Darwin.close(folderFD)
        Darwin.close(rootFD)
    }

    /// Makes the import's session folder `<id>.holos` in the staging folder through the descriptor `create` opened
    /// (`mkdirat`), keeps it open, pins the path every later write takes (`url/<id>.holos`) to it
    /// (`AtomicFile.pinSessionFolder`, until `publish` or `discard`), and creates the session archive in it
    /// (`SessionArchive.create(inEmptyFolder:)`). So a folder renamed in at the staging name, before or after this
    /// call, is never given anything: the manifest, journal, locks, metadata, audio chunks (written through their
    /// descriptors, `AudioChunkWriter(throughDescriptor:)`), and transcript all go into the folder made here. Once
    /// made, the session folder is the one `acquireLease` locks, `publish` moves, and `discard` checks for. Call it
    /// once. On a throw, `discard` removes whatever was made.
    func createSession(name sessionTitle: String, locale: String, backend: SpeechBackend) throws -> SessionArchive {
        precondition(sessionFD < 0, "createSession is called once")
        Self.beforeSession?(url)
        let sessionName = "\(UUID().uuidString).holos"
        guard mkdirat(folderFD, sessionName, 0o700) == 0 else {
            throw HolosError.io("Cannot create the session folder: \(Self.errnoText()).")
        }
        let fd = openat(folderFD, sessionName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            unlinkat(folderFD, sessionName, AT_REMOVEDIR)
            throw HolosError.io("Cannot open the session folder: \(String(cString: strerror(code))).")
        }
        self.sessionFD = fd
        self.sessionName = sessionName
        guard Self.isEmptyFolder(fd) else {
            throw HolosError.io("The folder for the new session was replaced while it was being made.")
        }
        if fsync(folderFD) != 0 {
            throw HolosError.io("Cannot save the import folder: \(Self.errnoText()).")
        }
        let directory = url.appendingPathComponent(sessionName, isDirectory: true)
        // From here on, every write that names the session by `directory` goes through `fd` (the archive's manifest,
        // journal, and locks, meeting.json, vocabulary.json, audio chunks, the transcript), whatever the path
        // leads to meanwhile.
        pin = try AtomicFile.pinSessionFolder(fd, at: directory)
        return try SessionArchive.create(inEmptyFolder: fd, directory: directory, name: sessionTitle,
                                         source: .microphone, locale: locale, backend: backend)
    }

    /// The processing lease of the session `createSession` made, taken in the folder it holds open (so its lock file
    /// and identity are that folder's, wherever the staging name leads). `lease.session` names the staging path.
    func acquireLease() throws -> ProcessingLease {
        guard sessionFD >= 0, let sessionName else {
            throw HolosError.invalidInput("The import has no session to lock yet.")
        }
        return try SessionArchive.acquireProcessingLease(
            inFolder: sessionFD, session: url.appendingPathComponent(sessionName, isDirectory: true), retry: .zero)
    }

    /// Whether `name` in the open folder `parent` is the folder open as `folder` (device and inode, no link
    /// followed).
    private static func names(_ name: String, in parent: Int32, folder: Int32) -> Bool {
        var opened = stat()
        var named = stat()
        return fstat(folder, &opened) == 0 && fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0
            && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
    }

    /// A sentence for the user when the session folder `createSession` made is no longer in the staging folder
    /// (another program moved it out, so neither `publish` nor `discard` reaches it), naming where it is now when
    /// that can be found; nil when it is still there, or none was made.
    private func straySessionNote() -> String? {
        guard sessionFD >= 0, let sessionName, !Self.names(sessionName, in: folderFD, folder: sessionFD) else {
            return nil
        }
        if let path = Self.currentPath(of: sessionFD) {
            return "Its session folder was moved out of the import folder while it was being imported, to "
                + "\(path), and was left there; it is not a finished session, so delete it."
        }
        return "Its session folder was moved out of the import folder while it was being imported and could not be "
            + "found to remove."
    }

    /// Creates `root` if needed, removes abandoned staging folders in it (`sweep`), then makes a new one: the folder,
    /// its lock file (locked at once), and last the ownership marker. `after` runs after each step (for tests).
    ///
    /// The folder is made and opened relative to the open root, and must be empty when opened: a folder renamed in
    /// at its name before the open (holding anything) is refused and left as it is. When a later step fails, only
    /// what this call made (the lock file, the marker, and the folder once empty) is removed.
    static func create(in root: URL, after: (Step) -> Void = { _ in }) throws -> ImportStaging {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sweep(root)
        let name = prefix + UUID().uuidString
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw HolosError.io("Cannot open the sessions folder: \(errnoText()).") }
        guard mkdirat(rootFD, name, 0o700) == 0 else {
            let code = errno
            Darwin.close(rootFD)
            throw HolosError.io("Cannot create the import folder: \(String(cString: strerror(code))).")
        }
        after(.folderMade)
        var code: Int32 = 0
        var lock: Int32 = -1
        var madeLockFile = false
        let folder = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0 {
            code = errno
        } else if !isEmptyFolder(folder) {
            code = ENOTEMPTY
        } else {
            lock = openat(folder, lockName, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if lock < 0 {
                code = errno
            } else {
                madeLockFile = true
                after(.lockFileMade)
                if flock(lock, LOCK_EX | LOCK_NB) != 0 {
                    code = errno
                } else {
                    after(.locked)
                    if let failed = writeMarker(in: folder) { code = failed } else { after(.marked) }
                }
                if code != 0 {
                    Darwin.close(lock)
                    lock = -1
                }
            }
        }
        guard lock >= 0 else {
            if folder >= 0 {
                // A folder that was not empty when opened is not this call's to remove at all.
                if code != ENOTEMPTY {
                    if madeLockFile { unlinkat(folder, lockName, 0) }
                    removeIfEmpty(folder, named: name, in: rootFD)
                }
                Darwin.close(folder)
            }
            Darwin.close(rootFD)
            throw HolosError.io("Cannot lock the import folder: \(String(cString: strerror(code))).")
        }
        return ImportStaging(root: root, name: name, rootFD: rootFD, folderFD: folder, lockFD: lock)
    }

    /// Moves the finished session folder `sessionName` from the staging folder to `root` in one rename (never over
    /// an existing folder), makes the rename durable, and removes the empty staging folder. Throws, having moved
    /// nothing, when the rename fails; after the rename it throws only when the root can no longer be found (below);
    /// a staging folder it cannot remove is left for the next sweep. The marker is removed before the lock file and
    /// the lock, so a sweep leaves the emptied folder alone. `beforeMove` runs just before the rename and `after`
    /// after each step (both for tests).
    ///
    /// The rename, the unlinks, and the removal of the emptied folder go through the folder `create` opened, so a
    /// folder renamed in at the staging name meanwhile is never published from or changed. Once `createSession` has
    /// made the session, only that folder is published: `sessionName` must be its name, and the entry of that name
    /// must still be the folder it made (device and inode), not one another program moved in in its place. The
    /// rename itself names its source by name, so the published entry is checked again after it: a folder swapped in
    /// between the check and the rename is moved back into the staging folder and the call throws.
    ///
    /// Returns where the session is, `publishedURL(sessionName)`, the one location the import names in what it
    /// persists (`Transcript.source`). When `root` no longer leads to the folder `create` opened (the root was
    /// renamed, or a link to it retargeted, during the import), it throws instead, naming where the session is now
    /// when that can be found: the session is published all the same (`published` is true), but no location that
    /// disagrees with the persisted one is ever returned as the import's result (§1.7 threat model: fail clearly
    /// when the folder changes under Holos).
    func publish(_ sessionName: String, beforeMove: () -> Void = {},
                 after: (Step) -> Void = { _ in }) throws -> URL {
        let stagingFD = folderFD
        if sessionFD >= 0 {
            guard sessionName == self.sessionName, Self.names(sessionName, in: stagingFD, folder: sessionFD) else {
                throw HolosError.io("The imported session was moved or replaced in its import folder, so it was not "
                                    + "published.")
            }
        }
        beforeMove()
        guard Self.renameExclusive(sessionName, from: stagingFD, to: rootFD) else {
            throw HolosError.io("Cannot move the imported session into the sessions folder: \(Self.errnoText()).")
        }
        // The rename names its source entry, so a folder swapped in between the check above and the rename is what
        // it moved. That window cannot be closed on macOS; its consequence is: the published entry is checked to be
        // the session folder, and anything else is moved back into the staging folder (which `discard` empties).
        if sessionFD >= 0, !Self.names(sessionName, in: rootFD, folder: sessionFD) {
            let restored = Self.renameExclusive(sessionName, from: rootFD, to: stagingFD)
            let code = errno
            if restored, fsync(rootFD) != 0 || fsync(stagingFD) != 0 {
                Self.log.error("Cannot save the sessions folder after an import: \(Self.errnoText(), privacy: .public)")
            }
            throw HolosError.io("The imported session was replaced in its import folder just before it was published, "
                                + "so it was not published."
                                + (restored ? "" : " The folder moved into the sessions folder in its place, "
                                   + "\(publishedURL(sessionName).path), could not be moved back "
                                   + "(\(String(cString: strerror(code)))); it is not the imported session."))
        }
        published = true
        // The staging path no longer names the session; the published one is reached by path, as any session is.
        pin?.release()
        pin = nil
        if fsync(rootFD) != 0 || fsync(stagingFD) != 0 {
            Self.log.error("Cannot save the sessions folder after an import: \(Self.errnoText(), privacy: .public)")
        }
        after(.moved)
        unlinkat(stagingFD, Self.markerName, 0)
        after(.unmarked)
        unlinkat(stagingFD, Self.lockName, 0)
        after(.lockFileRemoved)
        closeLock()
        after(.unlocked)
        Self.removeIfEmpty(stagingFD, named: name, in: rootFD)
        guard rootStillNamed() else {
            let whereNow = Self.currentPath(of: rootFD).map {
                "It is now in \(URL(fileURLWithPath: $0).appendingPathComponent(sessionName).path)."
            } ?? "Look for \(sessionName) where \(root.path) was."
            throw HolosError.io("The session was imported as \(sessionName), but the sessions folder \(root.path) "
                                + "was moved or replaced during the import, so the session is not in it. \(whereNow)")
        }
        return publishedURL(sessionName)
    }

    /// Where `publish(sessionName)` puts the session: `<root>/<sessionName>`.
    func publishedURL(_ sessionName: String) -> URL {
        root.appendingPathComponent(sessionName, isDirectory: true)
    }

    /// Whether `root` still leads to the folder open as `rootFD` (device and inode, links followed as `create`
    /// followed them).
    private func rootStillNamed() -> Bool {
        var opened = stat()
        var named = stat()
        return fstat(rootFD, &opened) == 0 && stat(root.path, &named) == 0
            && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
    }

    /// The path of the open folder `folder`, when the path the system reports for it (`F_GETPATH`) still names it.
    private static func currentPath(of folder: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(folder, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // F_GETPATH can report where a folder was before it was removed; the path counts only if it still names
        // this folder.
        let parent = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return nil }
        defer { Darwin.close(parent) }
        return names((path as NSString).lastPathComponent, in: parent, folder: folder) ? path : nil
    }

    /// Renames `name` in the open folder `source` to the same name in `target`, never over an existing entry.
    /// Sets errno on failure.
    private static func renameExclusive(_ name: String, from source: Int32, to target: Int32) -> Bool {
        if renameatx_np(source, name, target, name, UInt32(RENAME_EXCL)) == 0 { return true }
        guard errno == ENOTSUP || errno == EINVAL else { return false }
        // A volume without RENAME_EXCL: the name is a new UUID, and it is checked to be free just before.
        var info = stat()
        if fstatat(target, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
            return renameat(source, name, target, name) == 0
        }
        errno = EEXIST
        return false
    }

    /// Removes the staging folder `create` made, through the descriptor it opened, and everything in it (`remove`),
    /// then lets go of the lock. Returns nil when it is gone, else a sentence for the user that says where the partial
    /// files are. A folder it could not remove keeps its ownership marker, so a later sweep finishes the job.
    ///
    /// The session folder `createSession` made is removed with the staging folder. When another program moved it
    /// out of the staging folder, it is not removed (it is no longer anywhere the import owns), and the sentence says
    /// so, naming where it is when that can be found.
    func discard() -> String? {
        defer {
            pin?.release()
            pin = nil
            closeLock()
        }
        // A published session is the caller's, and `publish` already removed the staging folder.
        if published { return nil }
        let stray = straySessionNote()
        do {
            try Self.remove(folder: folderFD, named: name, in: rootFD, root: root)
            return stray
        } catch {
            Self.log.error("Cannot remove an import folder: \(error.localizedDescription, privacy: .private)")
            return "Its partial files in \(url.path) could not be removed (\(error.localizedDescription)). They are "
                + "not a session; delete that folder, or the next import removes it." + (stray.map { " " + $0 } ?? "")
        }
    }

    /// Removes the staging folder open as `folder` (named `name` in the open root `rootFD`, which `root` names in
    /// messages) through that descriptor, in an order that keeps its ownership marker until nothing else is left:
    /// every other entry first, then the lock file, then the marker, then the emptied folder
    /// (`AtomicFile.removeOpenFolder`). A removal that fails part-way therefore leaves a folder that still has the
    /// marker, which a later sweep recognizes and finishes; only a failure after the marker can leave one without
    /// it, and that folder is empty. Nothing is followed through a symbolic link, and a folder renamed in at `name`
    /// after `folder` was opened is never emptied; the emptied folder is left where it is when it no longer has that
    /// name.
    static func remove(folder: Int32, named name: String, in rootFD: Int32, root: URL) throws {
        let removed = try AtomicFile.removeOpenFolder(folder, named: name, in: rootFD, parentURL: root,
                                                      removingLast: [lockName, markerName])
        if !removed { log.notice("An emptied import folder had been moved; it was left where it is") }
    }

    /// Removes the folder open as `folder` when it is empty and `name` in `rootFD` still names it, then fsyncs the
    /// root. Failures are logged: an empty folder without a marker is harmless.
    private static func removeIfEmpty(_ folder: Int32, named name: String, in rootFD: Int32) {
        var opened = stat()
        var named = stat()
        guard fstat(folder, &opened) == 0, fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            log.error("Cannot remove an empty import folder: it is no longer where it was made")
            return
        }
        if unlinkat(rootFD, name, AT_REMOVEDIR) != 0 {
            log.error("Cannot remove an empty import folder: \(errnoText(), privacy: .public)")
        } else if fsync(rootFD) != 0 {
            log.error("Cannot save the sessions folder after an import: \(errnoText(), privacy: .public)")
        }
    }

    /// Whether the open folder `folder` has no entries ("." and ".." aside). False when it cannot be listed.
    private static func isEmptyFolder(_ folder: Int32) -> Bool {
        let copy = dup(folder)
        guard copy >= 0 else { return false }
        guard let directory = fdopendir(copy) else {
            Darwin.close(copy)
            return false
        }
        defer { closedir(directory) }
        // The copy shares its offset with `folder`; start from the beginning.
        rewinddir(directory)
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let dots = withUnsafeBytes(of: entry.pointee.d_name) { raw in raw.prefix(length).allSatisfy { $0 == 46 } }
            if !(dots && (length == 1 || length == 2)) { return false }
        }
        return true
    }

    /// Removes the staging folders in `root` that no running import holds: those whose lock file is missing or can
    /// be locked, once the folder has not changed for `unlockedGrace`. Only a folder with a staging name
    /// (`isStagingName`) and the ownership marker (`hasMarker`) is a staging folder; nothing else is touched, and a
    /// folder without the marker (one being made or published) is skipped. Failures are logged; an import never
    /// fails because of an older one's leftovers.
    ///
    /// Each folder is removed through the descriptor its marker and lock were checked through (`remove`), so a
    /// folder renamed in at the same name after the check is never emptied. `beforeRemoving` runs with each folder's
    /// name just before it is removed (for tests).
    static func sweep(_ root: URL, now: Date = Date(), beforeRemoving: (String) -> Void = { _ in }) {
        let base = resolved(root)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        let rootFD = open(base.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return }
        defer { Darwin.close(rootFD) }
        for name in names where isStagingName(name) {
            let folder = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { continue }
            defer { Darwin.close(folder) }
            var info = stat()
            guard fstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, hasMarker(in: folder) else { continue }
            let lock = openat(folder, lockName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if lock < 0 {
                guard errno == ENOENT else { continue }
            } else if flock(lock, LOCK_EX | LOCK_NB) != 0 {
                Darwin.close(lock)
                continue
            }
            // Held (when there is a lock file) until the folder is gone, so no other sweep starts on it meanwhile.
            defer { if lock >= 0 { Darwin.close(lock) } }
            // Checked again now that the lock is ours: an import that published meanwhile removed the marker first.
            guard fstat(folder, &info) == 0, hasMarker(in: folder) else { continue }
            let changed = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(changed) > unlockedGrace else { continue }
            beforeRemoving(name)
            do {
                try remove(folder: folder, named: name, in: rootFD, root: base)
                log.notice("Removed an import that did not finish")
            } catch {
                log.error("Cannot remove an import that did not finish: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Whether `name` is one `create` makes: `prefix` followed by a UUID in `UUID().uuidString` form (upper case).
    static func isStagingName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        return UUID(uuidString: suffix)?.uuidString == suffix
    }

    /// Whether the open folder `folder` holds the ownership marker: a regular file (not a symbolic link) named
    /// `markerName` whose contents are exactly `markerContents`.
    static func hasMarker(in folder: Int32) -> Bool {
        let fd = openat(folder, markerName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == off_t(markerContents.count) else { return false }
        var buffer = [UInt8](repeating: 0, count: markerContents.count + 1)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return count == markerContents.count && Array(buffer.prefix(count)) == markerContents
    }

    /// Writes the ownership marker into the open, new folder `folder` (never over an existing file) and fsyncs it.
    /// Returns nil, or the errno of the failure, having removed the marker file it made.
    private static func writeMarker(in folder: Int32) -> Int32? {
        let fd = openat(folder, markerName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return errno }
        defer { Darwin.close(fd) }
        let written = markerContents.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        var code: Int32?
        if written != markerContents.count {
            code = written < 0 ? errno : EIO
        } else if fsync(fd) != 0 {
            code = errno
        }
        if code != nil { unlinkat(folder, markerName, 0) }
        return code
    }

    private func closeLock() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
        lockFD = -1
    }

    /// `root` with symbolic links resolved (a sessions root may be reached through one), as a sweep names it.
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
