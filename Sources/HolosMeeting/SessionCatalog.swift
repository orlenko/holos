import Darwin
import Foundation
import HolosCore
import HolosStorage
import os

/// What a session is, as the Meetings window and `voiceislocal session list` show it (docs/meeting-design.md §5.6).
public enum SessionState: String, Codable, Sendable {
    case recording, processing, interrupted, complete, audioOnly, transcriptionIncomplete,
         incomplete, failed, recovered, damaged
}

public enum SpeakerLabelState: String, Codable, Sendable {
    /// No postprocess.json.
    case none
    case running
    case labelled
    /// Post-processing finished without a run (e.g. speaker models not installed); see `labelMessage`.
    case notLabelled
    case failed
    case interrupted
    /// postprocess.json or speakers/head.json cannot be read: damaged, written by a newer Holos, or an I/O error;
    /// `labelMessage` says why.
    case unreadable
}

/// One session in the catalog. Reading it takes no lock and changes nothing.
public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var directory: URL
    public var name: String
    public var createdAt: Date
    public var source: AudioSource
    public var origin: MeetingOrigin
    public var state: SessionState
    public var manifestStatus: String
    /// Longest track's total chunk duration.
    public var savedSeconds: Double
    public var chunkCount: Int
    /// The current transcript, once its revision was read and holds this ID; nil when there is none or it cannot be
    /// read (`transcriptProblem` then says why).
    public var transcriptID: String?
    /// Why the current transcript cannot be read (the pointer or revision is missing, damaged, holds another ID, or
    /// was written by a newer Holos); nil when it can, or when the session has none.
    public var transcriptProblem: String?
    /// The current transcript cannot be read for a reason other than damage: written by a newer Holos, or an I/O
    /// error. Recovery and labelling refuse such a session (`SessionFiles.isDamage` tells the two apart).
    public var transcriptRefused: Bool
    public var speakerState: SpeakerLabelState
    public var labelMessage: String?
    public var runID: String?
    /// When the head's run was made, while the saved labels are usable (`SavedSpeakerState.labelsReady`, the one test
    /// for "labels are ready"); nil otherwise.
    public var labelsReadyAt: Date?
    public var hasSpeakerEdits: Bool
    public var phase: RecorderPhase?
    public var pid: Int32?
    public var liveness: RecorderLiveness
    public var bytes: Int64
    public var derivedBytes: Int64
    public var audioDeleted: Bool

    public init(id: String, directory: URL, name: String, createdAt: Date, source: AudioSource,
                origin: MeetingOrigin = .recorded, state: SessionState, manifestStatus: String,
                savedSeconds: Double = 0, chunkCount: Int = 0, transcriptID: String? = nil,
                transcriptProblem: String? = nil, transcriptRefused: Bool = false,
                speakerState: SpeakerLabelState = .none, labelMessage: String? = nil, runID: String? = nil,
                labelsReadyAt: Date? = nil,
                hasSpeakerEdits: Bool = false, phase: RecorderPhase? = nil, pid: Int32? = nil,
                liveness: RecorderLiveness, bytes: Int64 = 0, derivedBytes: Int64 = 0, audioDeleted: Bool = false) {
        self.id = id; self.directory = directory; self.name = name; self.createdAt = createdAt
        self.source = source; self.origin = origin; self.state = state; self.manifestStatus = manifestStatus
        self.savedSeconds = savedSeconds; self.chunkCount = chunkCount; self.transcriptID = transcriptID
        self.transcriptProblem = transcriptProblem; self.transcriptRefused = transcriptRefused
        self.speakerState = speakerState; self.labelMessage = labelMessage; self.runID = runID
        self.labelsReadyAt = labelsReadyAt
        self.hasSpeakerEdits = hasSpeakerEdits; self.phase = phase; self.pid = pid; self.liveness = liveness
        self.bytes = bytes; self.derivedBytes = derivedBytes; self.audioDeleted = audioDeleted
    }
}

/// `SessionSummary` is Codable, so its liveness is too (encoded as its raw value).
extension RecorderLiveness: Codable {}

/// The sessions under a folder and their state (docs/meeting-design.md §5.6). Every read is lock-free and
/// tolerant: a file that cannot be read makes its part of the summary unknown, never the listing fail.
public enum SessionCatalog {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")
    /// Folders deeper than this inside a session are not counted in its size.
    private static let maxDepth = 16

    /// Newest first. A folder whose manifest cannot be read is `damaged` (named by its folder).
    ///
    /// Lists the folders named `<something>.holos` directly inside `root` (not symbolic links, not hidden folders
    /// such as an import's staging folder). A missing or unreadable `root` gives an empty list. Sessions created in
    /// the same second are ordered by ID.
    public static func list(root: URL = HolosPaths.sessions, now: Date = Date()) -> [SessionSummary] {
        sessionFolders(in: root).map { summary(session: $0, now: now) }.sorted { left, right in
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id < right.id
        }
    }

    public static func summary(session: URL, now: Date = Date()) -> SessionSummary {
        let liveness = RecorderChannel.liveness(session: session, now: now)
        let status = try? RecorderChannel.readStatus(session: session)
        let sizes = sizes(of: session)
        let live = liveness == .capturing || liveness == .processing
        let phase: RecorderPhase? = live ? status?.phase : (liveness == .exited ? .exited : nil)
        let pid = live ? status?.pid : nil

        let manifest: SessionManifest
        do {
            manifest = try SessionArchive.readManifest(at: session)
        } catch {
            let folder = session.standardizedFileURL.lastPathComponent
            return SessionSummary(
                id: folder.hasSuffix(".holos") ? String(folder.dropLast(6)) : folder, directory: session,
                name: folder, createdAt: folderCreationDate(session), source: .microphone, state: .damaged,
                manifestStatus: "", phase: phase, pid: pid, liveness: liveness, bytes: sizes.bytes,
                derivedBytes: sizes.derived, audioDeleted: audioDeleted(session, sessionID: nil))
        }
        let origin = (try? SessionFiles.meetingInfo(session: session, manifest: manifest))?.origin ?? .recorded
        let speakers = speakerLabels(session, liveness: liveness)
        // The revision is read, not only found, so a damaged, truncated, mislabelled, or newer one is never listed
        // as the session's transcript.
        var transcriptID: String?
        var transcriptProblem: String?
        var transcriptRefused = false
        do {
            transcriptID = try SessionFiles.currentTranscript(session: session)?.id
        } catch {
            log.error("Session \(manifest.id, privacy: .public): current transcript unreadable: \(error.localizedDescription, privacy: .private)")
            transcriptProblem = error.localizedDescription
            transcriptRefused = !SessionFiles.isDamage(error)
        }
        return SessionSummary(
            id: manifest.id, directory: session, name: manifest.name, createdAt: manifest.createdAt,
            source: manifest.source, origin: origin,
            state: state(manifestStatus: manifest.status, liveness: liveness), manifestStatus: manifest.status,
            savedSeconds: manifest.savedSeconds, chunkCount: manifest.chunks.count, transcriptID: transcriptID,
            transcriptProblem: transcriptProblem, transcriptRefused: transcriptRefused,
            speakerState: speakers.state, labelMessage: speakers.message,
            runID: speakers.runID, labelsReadyAt: speakers.readyAt,
            hasSpeakerEdits: hasSpeakerEdits(session), phase: phase, pid: pid, liveness: liveness,
            bytes: sizes.bytes, derivedBytes: sizes.derived,
            audioDeleted: audioDeleted(session, sessionID: manifest.id))
    }

    // MARK: - State mapping

    /// Manifest `recording`/`processing`: liveness `capturing` → `recording`; `processing` or `maintenance` →
    /// `processing`; else `interrupted`. Otherwise the manifest status maps 1:1; a status this build does not know
    /// (written by a newer Holos) is `incomplete`.
    static func state(manifestStatus: String, liveness: RecorderLiveness) -> SessionState {
        guard manifestStatus == ArchiveStatus.recording || manifestStatus == ArchiveStatus.processing else {
            return SessionState(rawValue: manifestStatus) ?? .incomplete
        }
        switch liveness {
        case .capturing: return .recording
        case .processing, .maintenance: return .processing
        case .exited, .dead: return .interrupted
        }
    }

    /// `postprocess.json` `running` with liveness `processing` or `maintenance` → `running`; `running` otherwise →
    /// `interrupted`; `failed` → `failed`; a finished record with a run → `labelled`; a finished record without a run
    /// → `notLabelled` with the record's message; no record → `none`, or `labelled` when a head run exists (labels
    /// written without a record, as by builds before post-processing kept one). The run is the head's, else the
    /// record's.
    static func speakerState(record: PostProcessingRecord?, headRunID: String?, liveness: RecorderLiveness)
        -> (state: SpeakerLabelState, message: String?, runID: String?) {
        let runID = headRunID ?? record?.runID
        guard let record else {
            return (headRunID == nil ? SpeakerLabelState.none : SpeakerLabelState.labelled, nil, runID)
        }
        switch record.state {
        case .running:
            if liveness == .processing || liveness == .maintenance {
                return (.running, record.progress?.message ?? record.message, runID)
            }
            return (.interrupted, record.message, runID)
        case .failed:
            return (.failed, record.message, runID)
        default:
            return (record.runID == nil ? SpeakerLabelState.notLabelled : SpeakerLabelState.labelled,
                    record.message, runID)
        }
    }

    // MARK: - Reading

    /// The `.holos` folders directly inside `root`.
    static func sessionFolders(in root: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasSuffix(".holos") && !$0.hasPrefix(".") && $0.count > 6 }.sorted().compactMap { name in
            let url = root.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return url
        }
    }

    /// The speaker state from postprocess.json, speakers/head.json and the run the head names (`speakerState`), as
    /// `SavedSpeakerState` validates them (recovery validates them the same way): a head counts as labels only when
    /// `SpeakerSessionSnapshot.load`, which the exports and speaker commands use, loads its run. When any of them
    /// exists but cannot be read (damaged, of another session, written by a newer Holos, an I/O error), the head's run
    /// or its transcript is missing or damaged, a span does not fit that transcript, or the record names a run while
    /// the head is missing, the state is `unreadable` with why, never the state of a session without that file; the
    /// run is the head's, else the record's. `readyAt` is the head run's creation time while
    /// `SavedSpeakerState.labelsReady`.
    static func speakerLabels(_ session: URL, liveness: RecorderLiveness)
        -> (state: SpeakerLabelState, message: String?, runID: String?, readyAt: Date?) {
        let saved = SavedSpeakerState.read(session: session)
        guard saved.problems.isEmpty else {
            let message = saved.problems.map(\.localizedDescription).joined(separator: " ")
            log.error("Cannot read the speaker state: \(message, privacy: .private)")
            return (.unreadable, message, saved.head?.runID ?? saved.record?.runID, nil)
        }
        let state = speakerState(record: saved.record, headRunID: saved.head?.runID, liveness: liveness)
        return (state.state, state.message, state.runID, saved.labelsReady ? saved.headRun?.createdAt : nil)
    }

    /// Whether the speaker edit journal holds any edit, including lines this build cannot read and a partial last
    /// line (an edit a crash cut short). A journal that cannot be read at all counts as edited, so nothing treats the
    /// labels as untouched.
    static func hasSpeakerEdits(_ session: URL) -> Bool {
        guard let journal = try? SessionSpeakerStore.readEdits(session: session) else { return true }
        return !journal.edits.isEmpty || journal.unreadableLines > 0 || journal.tornTail
    }

    /// Whether the session's audio was deleted on purpose: audio-deleted.json is a readable record of this session
    /// (`AudioDeletedRecord.isDeleted`). A marker that is damaged, of another session, written by a newer Holos, or
    /// cannot be read now is not listed as deleted audio (the error is logged).
    static func audioDeleted(_ session: URL, sessionID: String?) -> Bool {
        do {
            return try SessionFiles.audioDeleted(session: session, sessionID: sessionID)
        } catch {
            log.error("Cannot read audio-deleted.json: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// When the folder was created (for a session whose manifest cannot be read).
    private static func folderCreationDate(_ session: URL) -> Date {
        var info = stat()
        guard lstat(session.path, &info) == 0 else { return Date(timeIntervalSince1970: 0) }
        return Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
    }

    /// Bytes of the regular files in the session folder and in its `derived/`, without following a symbolic link.
    static func sizes(of session: URL) -> (bytes: Int64, derived: Int64) {
        let folder = Darwin.open(session.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return (0, 0) }
        defer { Darwin.close(folder) }
        let derivedFD = openat(folder, "derived", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let derived = derivedFD >= 0 ? treeBytes(consuming: derivedFD, depth: 1) : 0
        let whole = dup(folder)
        return (whole >= 0 ? treeBytes(consuming: whole, depth: 0) : 0, derived)
    }

    /// Bytes of the regular files under the open folder `fd`, which this closes. Symbolic links are not followed and
    /// count as nothing; entries that vanish meanwhile are skipped.
    private static func treeBytes(consuming fd: Int32, depth: Int) -> Int64 {
        guard let stream = fdopendir(fd) else {
            Darwin.close(fd)
            return 0
        }
        defer { closedir(stream) }
        let parent = dirfd(stream)
        var total: Int64 = 0
        while let entry = readdir(stream) {
            let name: [CChar] = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                raw.prefix(Int(entry.pointee.d_namlen)).map { CChar(bitPattern: $0) } + [0]
            }
            if name == [46, 0] || name == [46, 46, 0] { continue }  // "." and ".."
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                total += Int64(info.st_size)
            case S_IFDIR where depth < maxDepth:
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 { total += treeBytes(consuming: child, depth: depth + 1) }
            default:
                break
            }
        }
        return total
    }
}
