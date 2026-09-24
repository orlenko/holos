import Foundation
import CryptoKit
import AVFoundation
import Darwin
import os
import HolosCore

public struct AudioChunkRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var track: String
    public var relativePath: String
    public var start: Double
    public var end: Double
    public var sampleRate: Double
    public var channels: Int
    public var frameCount: Int
    public var sha256: String?

    public init(id: String = UUID().uuidString, track: String, relativePath: String,
                start: Double, end: Double, sampleRate: Double, channels: Int,
                frameCount: Int, sha256: String? = nil) {
        self.id = id; self.track = track; self.relativePath = relativePath
        self.start = start; self.end = end; self.sampleRate = sampleRate
        self.channels = channels; self.frameCount = frameCount; self.sha256 = sha256
    }
}

public struct SessionManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var createdAt: Date
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    public var status: String
    public var chunks: [AudioChunkRecord]

    public init(schemaVersion: Int = 1, id: String, name: String, createdAt: Date,
                source: AudioSource, locale: String, backend: SpeechBackend,
                status: String, chunks: [AudioChunkRecord] = []) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name
        self.createdAt = createdAt; self.source = source; self.locale = locale
        self.backend = backend; self.status = status; self.chunks = chunks
    }
}

public struct ArchiveEvent: Codable, Sendable, Equatable {
    public let sequence: Int
    public let at: Date
    public let kind: String
    public let details: [String: String]
}

/// The event journal (`events.jsonl`) as read by `SessionArchive.readEvents(at:)`.
public struct EventJournal: Sendable, Equatable {
    /// Readable events in file order; sequences never decrease. Builds before PR6 could repeat a sequence
    /// after a failed fsync, so two events may share one; this build never writes a repeat.
    public var events: [ArchiveEvent]
    /// The file does not end with "\n"; the partial last line was skipped.
    public var tornTail: Bool
    /// Complete lines skipped because they do not decode, because their sequence is outside
    /// 1...`Int.max - 1`, or because their sequence is lower than the previous readable event's.
    public var unreadableLines: Int

    public init(events: [ArchiveEvent] = [], tornTail: Bool = false, unreadableLines: Int = 0) {
        self.events = events; self.tornTail = tornTail; self.unreadableLines = unreadableLines
    }
}

/// When the archive fsyncs `events.jsonl` (docs/meeting-design.md §4.3).
public enum JournalSync: Sendable, Equatable {
    /// Every event is fsync'd before `recordEvent` returns (the default).
    case everyEvent
    /// Events are written at once and fsync'd at most once per interval, at `finish`, and at once for
    /// `captureStopped`, `archiveRecovered`, and `transcriptRebuilt`.
    case interval(seconds: Double)
}

public struct RecoveryReport: Sendable, Equatable {
    public let manifest: SessionManifest?
    public let manifestError: String?
    public let events: [ArchiveEvent]
    public let tornFinalJournalLine: Bool
    /// Complete journal lines that could not be read; they are skipped. Nothing can repair them, so they do not
    /// make the archive need attention.
    public let unreadableEventLines: Int
    public let missingChunks: [String]
    public let corruptChunks: [String]
    public let unindexedChunks: [String]
    public let unrecoveredChunks: [String]

    public var needsAttention: Bool {
        manifestError != nil || tornFinalJournalLine || !missingChunks.isEmpty ||
        !corruptChunks.isEmpty || !unindexedChunks.isEmpty || !unrecoveredChunks.isEmpty
    }
}

/// The only mutable owner of a session archive. A POSIX advisory lock is held until finish or deinit.
public actor SessionArchive {
    public nonisolated let directory: URL
    public nonisolated let id: String

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "storage")
    /// Event kinds that are fsync'd at once even with `JournalSync.interval`.
    private static let immediateSyncKinds: Set<String> = [
        MeetingEventKind.captureStopped, MeetingEventKind.archiveRecovered, MeetingEventKind.transcriptRebuilt,
    ]
    private static let maxJournalBytes = 1 << 30
    /// The highest event sequence a reader accepts or a writer assigns, so "last + 1" never overflows.
    static let maxEventSequence = Int.max - 1
    /// The longest group-commit interval; also keeps `Duration.seconds` from overflowing.
    static let maxJournalSyncInterval: Double = 3_600
    private static let maxTranscriptBytes = 256 << 20

    private var manifest: SessionManifest
    private var nextSequence: Int
    private var lockFD: Int32
    private var closed = false

    private var journalSync: JournalSync = .everyEvent
    private var lastJournalSync: ContinuousClock.Instant?
    private var journalDirty = false
    private var journalFlushTask: Task<Void, Never>?
    /// Bumped whenever a flush is scheduled or cancelled; a flush runs only for the current generation.
    private var journalFlushGeneration: UInt64 = 0
    /// Set by `openForMaintenance` when the journal ends with a partial line; repaired before the first append.
    private var journalNeedsRepair: Bool

    private init(directory: URL, manifest: SessionManifest, nextSequence: Int, lockFD: Int32,
                 journalNeedsRepair: Bool = false) {
        self.directory = directory; self.id = manifest.id; self.manifest = manifest
        self.nextSequence = nextSequence; self.lockFD = lockFD
        self.journalNeedsRepair = journalNeedsRepair
    }

    deinit { if lockFD >= 0 { SessionLockFile.unlockAndClose(lockFD) } }

    /// Creates `<root>/<id>.holos` and takes its writer lock. `id` must be an uppercase UUID string
    /// (`UUID().uuidString`); nil generates one. Refuses a folder that already exists.
    public static func create(root: URL, name: String, source: AudioSource,
                              locale: String, backend: SpeechBackend, id: String? = nil) throws -> SessionArchive {
        guard root.isFileURL, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !locale.isEmpty else { throw HolosError.invalidInput("Invalid archive root, name, or locale.") }
        let id = id ?? UUID().uuidString
        guard UUID(uuidString: id)?.uuidString == id else {
            throw HolosError.invalidInput("A session ID must be an uppercase UUID, like \(UUID().uuidString).")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("\(id).holos", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            let code = errno
            if code == EEXIST { throw HolosError.invalidInput("A session with ID \(id) already exists.") }
            throw HolosError.io("Cannot create the session folder: \(AtomicFile.errnoText(code)).")
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw HolosError.io("Cannot make session directory private.")
        }
        // A failed creation leaves its distinct directory for inspection; never delete user data.
        for path in ["audio/mic", "audio/system", "transcripts", "exports"] {
            let child = directory.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            guard chmod(child.path, 0o700) == 0 else {
                throw HolosError.io("Cannot make archive directory private.")
            }
        }
        guard chmod(directory.appendingPathComponent("audio").path, 0o700) == 0 else {
            throw HolosError.io("Cannot make audio directory private.")
        }
        // Publish the new folders durably: audio/ holds mic/ and system/, and the root holds the session folder.
        // The session folder itself is fsync'd once its files exist.
        try AtomicFile.syncDirectory(directory.appendingPathComponent("audio", isDirectory: true))
        try AtomicFile.syncDirectory(root)
        let fd = try acquireLock(directory)
        do {
            let manifest = SessionManifest(id: id, name: name, createdAt: Date(),
                                           source: source, locale: locale, backend: backend,
                                           status: ArchiveStatus.recording)
            try writeManifest(manifest, in: directory)
            try AtomicFile.append(Data(), to: SessionPaths.events(directory))
            try AtomicFile.syncDirectory(directory)
            return SessionArchive(directory: directory, manifest: manifest, nextSequence: 1, lockFD: fd)
        } catch {
            SessionLockFile.unlockAndClose(fd)
            throw error
        }
    }

    /// Reopens an unfinished archive after a process exits; refuses a second active writer.
    /// The manifest and journal are read only once the writer lock is held (retry 1 s), so a writer that
    /// registered chunks or finished while this call waited is never overwritten with an older manifest.
    public static func open(at directory: URL) throws -> SessionArchive {
        try requireSafeLayout(directory)
        let fd = try acquireLock(directory)
        do {
            let manifest = try readManifest(at: directory)
            guard manifest.status == ArchiveStatus.recording else {
                throw HolosError.invalidInput("Only a recording archive can be reopened.")
            }
            let report = try inspectRecovery(at: directory)
            guard report.manifestError == nil, !report.tornFinalJournalLine else {
                throw HolosError.incomplete("Repair the journal before reopening this archive.")
            }
            return SessionArchive(directory: directory, manifest: manifest,
                                  nextSequence: (report.events.last?.sequence ?? 0) + 1, lockFD: fd)
        } catch {
            SessionLockFile.unlockAndClose(fd)
            throw error
        }
    }

    /// Reopens an archive whose manifest is not "recording" and that has no writer, for maintenance
    /// writes (events, transcript revision, status). Requires the caller's lease for this session
    /// (`lease.session` must match); takes the writer lock (retry 1 s). Repairs a torn journal tail
    /// (truncates to the last newline, keeping a backup) before the first append.
    public static func openForMaintenance(at directory: URL, lease: ProcessingLease) throws -> SessionArchive {
        try requireMaintenanceLayout(directory)
        try lease.require(for: directory)
        let fd = try acquireLock(directory)
        do {
            let manifest = try readManifest(at: directory)
            guard manifest.status != ArchiveStatus.recording else {
                throw HolosError.invalidInput("This archive is still marked as recording; recover it first.")
            }
            let journal = try readEvents(at: directory)
            return SessionArchive(directory: directory, manifest: manifest,
                                  nextSequence: (journal.events.last?.sequence ?? 0) + 1, lockFD: fd,
                                  journalNeedsRepair: journal.tornTail)
        } catch {
            SessionLockFile.unlockAndClose(fd)
            throw error
        }
    }

    public func registerChunk(_ chunk: AudioChunkRecord) throws {
        try ensureOpen()
        guard Self.validToken(chunk.id), (chunk.track == "mic" || chunk.track == "system"),
              Self.validChunkPath(chunk.relativePath, track: chunk.track),
              chunk.start.isFinite, chunk.end.isFinite, chunk.end > chunk.start, chunk.start >= 0,
              chunk.sampleRate.isFinite, chunk.sampleRate > 0, chunk.channels > 0, chunk.frameCount > 0,
              !manifest.chunks.contains(where: { $0.id == chunk.id || $0.relativePath == chunk.relativePath }) else {
            throw HolosError.invalidInput("Invalid or duplicate audio chunk metadata.")
        }
        let url = directory.appendingPathComponent(chunk.relativePath)
        let digest = try Self.hashChunk(at: url, sync: true)
        if let expected = chunk.sha256, expected.lowercased() != digest {
            throw HolosError.invalidInput("Audio chunk checksum does not match its file.")
        }
        var finalized = chunk
        finalized.sha256 = digest
        var updated = manifest
        updated.chunks.append(finalized)
        try Self.writeManifest(updated, in: directory)
        manifest = updated
    }

    /// Chooses when `events.jsonl` is fsync'd. An interval that is not a positive number means `everyEvent`;
    /// one longer than `maxJournalSyncInterval` is shortened to it.
    /// A change replaces any pending flush, so the new interval sets the next deadline.
    public func setJournalSync(_ mode: JournalSync) {
        let previous = journalSync
        if case .interval(let seconds) = mode, seconds.isFinite, seconds > 0 {
            let clamped = min(seconds, Self.maxJournalSyncInterval)
            journalSync = .interval(seconds: clamped)
            guard journalSync != previous else { return }
            cancelJournalFlush()
            if journalDirty, !closed {
                let interval = Duration.seconds(clamped)
                let elapsed = lastJournalSync.map { $0.duration(to: .now) } ?? interval
                scheduleJournalFlush(after: interval - elapsed)
            }
        } else {
            journalSync = .everyEvent
            cancelJournalFlush()
            if journalDirty, !closed {
                do { try syncJournal() } catch {
                    Self.log.error("Cannot sync the event journal: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Appends one event. A failed append leaves no partial line and does not consume a sequence number.
    public func recordEvent(kind: String, details: [String: String]) throws {
        try ensureOpen()
        guard !kind.isEmpty else { throw HolosError.invalidInput("Event kind is empty.") }
        guard nextSequence <= Self.maxEventSequence else {
            throw HolosError.incomplete("The event journal has no sequence numbers left.")
        }
        try repairJournalIfNeeded()
        let event = ArchiveEvent(sequence: nextSequence, at: Date(), kind: kind, details: details)
        let line = try HolosJSON.line(event)
        let journal = SessionPaths.events(directory)
        switch journalSync {
        case .everyEvent:
            try AtomicFile.append(line, to: journal)
        case .interval(let seconds):
            let now = ContinuousClock.now
            let interval = Duration.seconds(seconds)
            let due = lastJournalSync.map { $0.duration(to: now) >= interval } ?? true
            if due || Self.immediateSyncKinds.contains(kind) {
                try AtomicFile.append(line, to: journal, sync: true)
                journalDirty = false
                lastJournalSync = now
            } else {
                try AtomicFile.append(line, to: journal, sync: false)
                journalDirty = true
                let elapsed = lastJournalSync.map { $0.duration(to: now) } ?? .zero
                scheduleJournalFlush(after: interval - elapsed)
            }
        }
        nextSequence += 1
    }

    /// Saves an immutable transcript revision and the legacy exports, then points `transcripts/current.json`
    /// at it. `writeLegacyExports: false` skips the speaker-less `exports/transcript.{txt,md}` (new code passes
    /// false).
    public func saveTranscript(_ transcript: Transcript, writeLegacyExports: Bool = true) throws {
        try ensureOpen()
        guard TranscriptPointer.validTranscriptID(transcript.id) else {
            throw HolosError.invalidInput("Invalid transcript ID.")
        }
        let snapshot = SessionPaths.transcript(transcript.id, in: directory)
        let encoded = try Self.encode(transcript)
        let pending = SessionPaths.pendingTranscript(directory)
        if let existing = try AtomicFile.readIfPresent(snapshot, maxBytes: Self.maxTranscriptBytes) {
            // A retry finishes only the save that `current.pending` names: the same bytes, not yet current,
            // left by a save that failed after creating the revision (for example while publishing the
            // pointer). Any other existing revision is refused, so a finished older revision can never be
            // republished over a newer one. A damaged or newer pointer is refused, never overwritten.
            let current = try TranscriptPointer.read(session: directory)?.transcriptID
            guard existing == encoded, current != transcript.id,
                  try TranscriptPointer.readPending(session: directory)?.transcriptID == transcript.id else {
                throw HolosError.invalidInput("Transcript revision already exists.")
            }
        } else {
            // Written first, so a revision is never left without it; a later save replaces it, which abandons
            // this one.
            try AtomicFile.writeJSON(TranscriptPointer(transcriptID: transcript.id), to: pending)
            try AtomicFile.create(encoded, at: snapshot)
        }
        if writeLegacyExports {
            // Before the pointer: a failed export leaves the revision not current, so a retry rewrites both.
            let text = transcript.text + "\n"
            try AtomicFile.write(Data(text.utf8), to: SessionPaths.export("txt", in: directory))
            var markdown = "# \(manifest.name)\n\n"
            for segment in transcript.segments {
                let source = segment.track ?? "unknown source"
                markdown += "### [\(Self.timestamp(segment.start))–\(Self.timestamp(segment.end))] Source: \(source)\n\n"
                if let speakerID = segment.speakerID {
                    markdown += "Speaker label (not verified identity): \(speakerID)\n\n"
                }
                markdown += "\(segment.text)\n\n"
            }
            try AtomicFile.write(Data(markdown.utf8), to: SessionPaths.export("md", in: directory))
        }
        try AtomicFile.writeJSON(TranscriptPointer(transcriptID: transcript.id),
                                 to: SessionPaths.transcriptPointer(directory))
        // The save is finished. A marker left behind names the current revision, which is refused anyway, and
        // the next save replaces it.
        do {
            try AtomicFile.removeTree(["transcripts", "current.pending"], in: directory)
        } catch {
            Self.log.error("Cannot remove transcripts/current.pending: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func finish(status: String) throws {
        try ensureOpen()
        guard !status.isEmpty, status != ArchiveStatus.recording else {
            throw HolosError.invalidInput("Finish requires a final status.")
        }
        if journalDirty { try syncJournal() }
        var updated = manifest
        updated.status = status
        try Self.writeManifest(updated, in: directory)
        manifest = updated
        closed = true
        SessionLockFile.unlockAndClose(lockFD)
        lockFD = -1
    }

    /// Persist a lifecycle state while retaining the exclusive writer lock.
    public func setStatus(_ status: String) throws {
        try ensureOpen()
        guard !status.isEmpty else { throw HolosError.invalidInput("Status is empty.") }
        var updated = manifest
        updated.status = status
        try Self.writeManifest(updated, in: directory)
        manifest = updated
    }

    private func ensureOpen() throws {
        if closed { throw HolosError.invalidInput("Archive writer is closed.") }
    }

    private func syncJournal() throws {
        try AtomicFile.sync(SessionPaths.events(directory))
        journalDirty = false
        lastJournalSync = .now
    }

    private func scheduleJournalFlush(after delay: Duration) {
        guard journalFlushTask == nil else { return }
        journalFlushGeneration &+= 1
        let generation = journalFlushGeneration
        journalFlushTask = Task { [weak self] in
            do { try await Task.sleep(for: max(delay, .zero)) } catch { return }
            await self?.flushJournalIfDirty(generation: generation)
        }
    }

    /// Drops the pending flush; one already past its sleep sees a newer generation and does nothing.
    private func cancelJournalFlush() {
        journalFlushTask?.cancel()
        journalFlushTask = nil
        journalFlushGeneration &+= 1
    }

    private func flushJournalIfDirty(generation: UInt64) {
        guard generation == journalFlushGeneration else { return }
        journalFlushTask = nil
        guard journalDirty, !closed else { return }
        do { try syncJournal() } catch {
            // Stays dirty: the next event or `finish` syncs again.
            Self.log.error("Cannot sync the event journal: \(String(describing: error), privacy: .public)")
        }
    }

    private func repairJournalIfNeeded() throws {
        guard journalNeedsRepair else { return }
        let journal = SessionPaths.events(directory)
        if let data = try AtomicFile.readIfPresent(journal, maxBytes: Self.maxJournalBytes),
           let last = data.last, last != 0x0A {
            let backup = directory.appendingPathComponent("events.torn-\(UUID().uuidString).jsonl", isDirectory: false)
            try AtomicFile.create(data, at: backup)
            let keep = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
            try AtomicFile.truncate(journal, to: Int64(keep))
            Self.log.notice("Repaired a torn event journal in session \(self.id, privacy: .public); backup kept")
        }
        journalNeedsRepair = false
    }

    public nonisolated static func readManifest(at directory: URL) throws -> SessionManifest {
        guard directory.isFileURL, plainDirectory(directory),
              plainFile(SessionPaths.manifest(directory)) else {
            throw HolosError.invalidInput("Archive or manifest is not a regular path.")
        }
        let data = try Data(contentsOf: SessionPaths.manifest(directory))
        let manifest = try HolosJSON.decoder().decode(SessionManifest.self, from: data)
        guard manifest.schemaVersion == 1, validToken(manifest.id),
              directory.lastPathComponent == "\(manifest.id).holos",
              !manifest.name.isEmpty, !manifest.locale.isEmpty, !manifest.status.isEmpty,
              Set(manifest.chunks.map(\.id)).count == manifest.chunks.count,
              Set(manifest.chunks.map(\.relativePath)).count == manifest.chunks.count,
              manifest.chunks.allSatisfy({ chunk in
                  validToken(chunk.id) && (chunk.track == "mic" || chunk.track == "system") &&
                  validChunkPath(chunk.relativePath, track: chunk.track) &&
                  chunk.start.isFinite && chunk.start >= 0 && chunk.end.isFinite && chunk.end > chunk.start &&
                  chunk.sampleRate.isFinite && chunk.sampleRate > 0 &&
                  chunk.channels > 0 && chunk.frameCount > 0
              }) else {
            throw HolosError.invalidInput("Unsupported or mismatched session manifest.")
        }
        return manifest
    }

    /// Reads `events.jsonl` only (no chunk hashing). A partial last line is reported as `tornTail`; a complete
    /// line that fails to decode, whose sequence is outside 1...`maxEventSequence`, or whose sequence is lower
    /// than the previous event's, is skipped and counted.
    /// A missing journal is empty.
    public nonisolated static func readEvents(at directory: URL) throws -> EventJournal {
        guard directory.isFileURL, plainDirectory(directory) else {
            throw HolosError.invalidInput("The session folder is missing or is not a regular folder.")
        }
        guard let data = try AtomicFile.readIfPresent(SessionPaths.events(directory), maxBytes: maxJournalBytes) else {
            return EventJournal()
        }
        let (lines, torn) = JournalLines.split(data)
        let decoder = HolosJSON.decoder()
        var events: [ArchiveEvent] = []
        var unreadable = 0
        for line in lines {
            // `>=`: older builds reused a sequence after an append whose fsync failed; both lines are real.
            guard let event = try? decoder.decode(ArchiveEvent.self, from: line), !event.kind.isEmpty,
                  event.sequence >= 1, event.sequence <= maxEventSequence,
                  event.sequence >= (events.last?.sequence ?? 0) else {
                unreadable += 1
                continue
            }
            events.append(event)
        }
        return EventJournal(events: events, tornTail: torn, unreadableLines: unreadable)
    }

    /// The ID of the current transcript revision (docs/meeting-design.md §2.4): the one named by
    /// `transcripts/current.json`, else, for archives saved before the pointer existed, the revision with the
    /// newest `createdAt`. Nil when the archive has no transcript.
    public nonisolated static func currentTranscriptID(at directory: URL) throws -> String? {
        guard directory.isFileURL, plainDirectory(directory) else {
            throw HolosError.invalidInput("The session folder is missing or is not a regular folder.")
        }
        if let pointer = try TranscriptPointer.read(session: directory) {
            guard plainFile(SessionPaths.transcript(pointer.transcriptID, in: directory)) else {
                throw HolosError.incomplete("transcripts/current.json names a transcript revision that is missing.")
            }
            return pointer.transcriptID
        }
        return try legacyCurrentTranscriptID(at: directory)
    }

    /// Checks the actual archive writer lock, without creating or changing a file.
    public nonisolated static func isActive(at directory: URL) throws -> Bool {
        // Only the session folder itself is required: Delete Audio removes audio/, and the lock stays meaningful.
        guard directory.isFileURL, plainDirectory(directory) else {
            throw HolosError.invalidInput("Archive contains an unsafe or incomplete directory layout.")
        }
        return try SessionLockFile.isHeld(SessionLockFile.writer, in: directory)
    }

    /// Repairs only a stale, structurally valid archive. Raw audio and damaged finalized chunks are never
    /// rewritten. Takes the processing lease itself (retry 1 s), so it refuses while another process holds it.
    public nonisolated static func recover(at directory: URL) async throws -> RecoveryReport {
        // Check the layout first, so a folder that is not a session never gets a lock file.
        try requireMaintenanceLayout(directory)
        let lease = try acquireProcessingLease(at: directory)
        defer { lease.release() }
        return try await recover(at: directory, lease: lease)
    }

    /// The existing recovery, run under the caller's lease. `recover(at:)` keeps its signature and
    /// takes a lease itself. Audio folders may be absent (Delete Audio removes them); chunks missing because
    /// of that are expected once `audio-deleted.json` exists.
    public nonisolated static func recover(at directory: URL, lease: ProcessingLease) async throws -> RecoveryReport {
        try requireMaintenanceLayout(directory)
        try lease.require(for: directory)
        let fd = try acquireLock(directory)
        defer { SessionLockFile.unlockAndClose(fd) }
        let before = try inspectRecovery(at: directory)
        guard var manifest = before.manifest else {
            throw HolosError.incomplete("Cannot recover an archive without a valid manifest.")
        }
        guard before.missingChunks.isEmpty, before.corruptChunks.isEmpty else {
            throw HolosError.incomplete("Finalized audio is missing or corrupt; recovery did not change the archive.")
        }

        let opened = Dictionary(before.events.compactMap { event -> (String, ArchiveEvent)? in
            guard event.kind == MeetingEventKind.chunkOpened, let path = event.details["relativePath"] else { return nil }
            return (path, event)
        }, uniquingKeysWith: { _, latest in latest })
        var unrecovered: [String] = []
        var recovered: [String] = []
        for path in before.unindexedChunks {
            guard let event = opened[path],
                  let track = event.details["track"],
                  validChunkPath(path, track: track),
                  let startText = event.details["start"], let start = Double(startText),
                  start.isFinite, start >= 0,
                  let rateText = event.details["sampleRate"], let rate = Double(rateText),
                  rate.isFinite, rate > 0,
                  let channelText = event.details["channels"], let channels = Int(channelText), channels > 0 else {
                unrecovered.append(path); continue
            }
            let url = directory.appendingPathComponent(path)
            guard plainFile(url) else { unrecovered.append(path); continue }
            do {
                let file = try AVAudioFile(forReading: url)
                let actualRate = file.fileFormat.sampleRate
                let actualChannels = Int(file.fileFormat.channelCount)
                let frames = file.length
                guard frames > 0, frames <= Int.max, actualRate == rate,
                      actualChannels == channels else {
                    unrecovered.append(path); continue
                }
                let end = start + Double(frames) / rate
                guard end.isFinite, end > start else { unrecovered.append(path); continue }
                let digest = try hashChunk(at: url, sync: true)
                let basename = String(url.deletingPathExtension().lastPathComponent)
                var recoveredID = "recovered-\(track)-\(basename)"
                if manifest.chunks.contains(where: { $0.id == recoveredID }) {
                    recoveredID = UUID().uuidString
                }
                manifest.chunks.append(AudioChunkRecord(id: recoveredID,
                    track: track, relativePath: path, start: start, end: end,
                    sampleRate: rate, channels: channels, frameCount: Int(frames), sha256: digest))
                recovered.append(path)
            } catch { unrecovered.append(path) }
        }
        let wasStale = manifest.status == ArchiveStatus.recording || manifest.status == ArchiveStatus.processing
        if wasStale { manifest.status = ArchiveStatus.interrupted }
        let changed = wasStale || !recovered.isEmpty || before.tornFinalJournalLine
        if changed {
            let journal = SessionPaths.events(directory)
            if before.tornFinalJournalLine {
                guard let original = try AtomicFile.readIfPresent(journal, maxBytes: maxJournalBytes) else {
                    throw HolosError.incomplete("The event journal disappeared during recovery.")
                }
                let backup = directory.appendingPathComponent("events.before-recovery-\(UUID().uuidString).jsonl")
                try AtomicFile.create(original, at: backup)
                let complete = original.lastIndex(of: 0x0A).map { Data(original.prefix(through: $0)) } ?? Data()
                try AtomicFile.write(complete, to: journal)
            }
            let details = [
                "chunks": recovered.joined(separator: ","),
                "unrecovered": unrecovered.joined(separator: ","),
                "previousStatus": before.manifest?.status ?? "unknown",
            ]
            // Readable sequences stop at `maxEventSequence`, so `+ 1` cannot overflow; an exhausted journal
            // gets no recovery event rather than one that would read back as unreadable.
            let sequence = (before.events.last?.sequence ?? 0) + 1
            if sequence <= maxEventSequence, before.tornFinalJournalLine ||
                before.events.last?.kind != MeetingEventKind.archiveRecovered ||
                before.events.last?.details != details {
                let event = ArchiveEvent(sequence: sequence,
                                         at: Date(), kind: MeetingEventKind.archiveRecovered, details: details)
                try AtomicFile.append(try HolosJSON.line(event), to: journal)
            }
            try writeManifest(manifest, in: directory)
        }
        let after = try inspectRecovery(at: directory)
        return RecoveryReport(manifest: after.manifest, manifestError: after.manifestError,
                              events: after.events, tornFinalJournalLine: after.tornFinalJournalLine,
                              unreadableEventLines: after.unreadableEventLines,
                              missingChunks: after.missingChunks, corruptChunks: after.corruptChunks,
                              unindexedChunks: after.unindexedChunks,
                              unrecoveredChunks: unrecovered.sorted())
    }

    /// Read-only inspection. It never repairs, deletes, or rewrites archive contents. Looks only at the
    /// manifest, the journal, and `audio/`; missing chunks are expected once `audio-deleted.json` exists.
    public nonisolated static func inspectRecovery(at directory: URL) throws -> RecoveryReport {
        guard directory.isFileURL else { throw HolosError.invalidInput("Archive path must be a file URL.") }
        var manifest: SessionManifest?
        var manifestError: String?
        do { manifest = try readManifest(at: directory) }
        catch { manifestError = String(describing: error) }

        let journal = plainDirectory(directory) ? try readEvents(at: directory) : EventJournal()
        let audioDeleted = plainFile(SessionPaths.audioDeleted(directory))

        var missing: [String] = []
        var corrupt: [String] = []
        let indexed = Set(manifest?.chunks.map(\.relativePath) ?? [])
        for chunk in manifest?.chunks ?? [] {
            guard validChunkPath(chunk.relativePath, track: chunk.track) else {
                corrupt.append(chunk.relativePath); continue
            }
            let url = directory.appendingPathComponent(chunk.relativePath)
            if !FileManager.default.fileExists(atPath: url.path) {
                if !audioDeleted { missing.append(chunk.relativePath) }
                continue
            }
            do {
                let hash = try hashChunk(at: url)
                if chunk.sha256 == nil || chunk.sha256?.lowercased() != hash { corrupt.append(chunk.relativePath) }
            } catch { corrupt.append(chunk.relativePath) }
        }
        var unindexed: [String] = []
        for track in ["mic", "system"] {
            let trackURL = directory.appendingPathComponent("audio/\(track)")
            guard plainDirectory(trackURL) else { continue }
            for url in (try? FileManager.default.contentsOfDirectory(at: trackURL, includingPropertiesForKeys: nil)) ?? [] {
                let path = "audio/\(track)/\(url.lastPathComponent)"
                if validChunkPath(path, track: track), !indexed.contains(path) { unindexed.append(path) }
            }
        }
        return RecoveryReport(manifest: manifest, manifestError: manifestError,
                              events: journal.events, tornFinalJournalLine: journal.tornTail,
                              unreadableEventLines: journal.unreadableLines,
                              missingChunks: missing.sorted(), corruptChunks: corrupt.sorted(),
                              unindexedChunks: unindexed.sorted(), unrecoveredChunks: [])
    }

    /// The ID rule for sessions, runs, edits, batches, transcripts, and chunks: non-empty ASCII letters,
    /// digits, `-`, and `_` (a `UUID().uuidString` qualifies). Such an ID is safe as a file name.
    public nonisolated static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
            ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }
    }

    private nonisolated static func legacyCurrentTranscriptID(at directory: URL) throws -> String? {
        let folder = SessionPaths.transcripts(directory)
        guard plainDirectory(folder) else { return nil }
        struct Header: Decodable { var id: String; var createdAt: Date }
        var newest: Header?
        var count = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard TranscriptPointer.validTranscriptID(id),
                  let header = try? AtomicFile.readJSON(Header.self, from: folder.appendingPathComponent(name)),
                  header.id == id else { continue }
            count += 1
            if let best = newest, (best.createdAt, best.id) >= (header.createdAt, header.id) { continue }
            newest = header
        }
        if count > 1 {
            log.warning("Archive has \(count, privacy: .public) transcripts and no current pointer; using the newest")
        }
        return newest?.id
    }

    private nonisolated static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 1_000 else {
            return "??:??:??.???"
        }
        let milliseconds = Int((seconds * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let remainder = (milliseconds / 1_000) % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, remainder, milliseconds % 1_000)
    }

    private nonisolated static func plainDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private nonisolated static func plainFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private nonisolated static func requireSafeLayout(_ directory: URL) throws {
        guard directory.isFileURL, plainDirectory(directory),
              ["audio", "audio/mic", "audio/system", "transcripts", "exports"].allSatisfy({
                  plainDirectory(directory.appendingPathComponent($0))
              }) else {
            throw HolosError.invalidInput("Archive contains an unsafe or incomplete directory layout.")
        }
    }

    /// Like `requireSafeLayout`, but audio folders may be absent (Delete Audio removes them); present ones must
    /// still be real folders.
    private nonisolated static func requireMaintenanceLayout(_ directory: URL) throws {
        guard directory.isFileURL, plainDirectory(directory),
              ["transcripts", "exports"].allSatisfy({ plainDirectory(directory.appendingPathComponent($0)) }),
              ["audio", "audio/mic", "audio/system"].allSatisfy({ path in
                  var info = stat()
                  guard lstat(directory.appendingPathComponent(path).path, &info) == 0 else { return errno == ENOENT }
                  return (info.st_mode & S_IFMT) == S_IFDIR
              }) else {
            throw HolosError.invalidInput("Archive contains an unsafe or incomplete directory layout.")
        }
    }

    private nonisolated static func validChunkPath(_ path: String, track: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "audio" && parts[1] == Substring(track) &&
               parts[2].hasSuffix(".caf") && validToken(String(parts[2].dropLast(4)))
    }

    private nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
        try HolosJSON.encoder().encode(value)
    }

    private nonisolated static func writeManifest(_ manifest: SessionManifest, in directory: URL) throws {
        try AtomicFile.write(try encode(manifest), to: SessionPaths.manifest(directory))
    }

    /// Takes the writer lock, retrying for up to 1 s so a concurrent probe cannot make it fail.
    private nonisolated static func acquireLock(_ directory: URL) throws -> Int32 {
        guard let fd = try SessionLockFile.acquire(SessionLockFile.writer, in: directory, timeout: .seconds(1)) else {
            throw HolosError.unavailable("Session archive already has an active writer.")
        }
        return fd
    }

    private nonisolated static func hashChunk(at url: URL, sync: Bool = false) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            throw HolosError.invalidInput("Audio chunk is missing, empty, or not a regular file.")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw HolosError.io("Cannot open audio chunk.") }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_ino == info.st_ino else {
            throw HolosError.invalidInput("Audio chunk changed while opening.")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw HolosError.io("Cannot read audio chunk.")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var finished = stat()
        guard fstat(fd, &finished) == 0, finished.st_size == opened.st_size,
              finished.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              finished.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw HolosError.incomplete("Audio chunk changed while hashing.")
        }
        if sync, fsync(fd) != 0 { throw HolosError.io("Cannot sync audio chunk.") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
