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

/// meeting.json's languages that the current transcript of a meeting in several languages misses, or that the
/// recorded transcript stands in for, which Label Speakers would detect again (docs/meeting-design.md §4.14).
public struct LanguageWork: Codable, Sendable, Equatable {
    /// The languages missed or stood in for, in meeting.json's order ("en-CA").
    public var languages: [String]
    /// The speaker labels were edited, so Label Speakers does not detect them (`voiceislocal session languages
    /// --force` does).
    public var labelsEdited: Bool
    /// A run would detect a language now (`LanguageStage.hasPendingWork`: one of them can be had, such as a speech
    /// model installed since). Set by `SessionCatalog.checkingLanguageModels`; false as listed.
    public var ready: Bool

    public init(languages: [String], labelsEdited: Bool = false, ready: Bool = false) {
        self.languages = languages; self.labelsEdited = labelsEdited; self.ready = ready
    }

    /// What the Meetings window says while the work is left: nil when the post-processing record's message says it
    /// (a language that cannot be had yet: the record names the reason and what to install).
    public var message: String? {
        let missing = LanguageStage.names(languages) + (languages.count == 1 ? " is" : " are")
            + " missing from the transcript."
        if labelsEdited {
            return "\(missing) Speaker labels were edited, so Label Speakers does not detect the languages again. To "
                + "detect them and label speakers again (names carry over), run voiceislocal session languages with "
                + "--force."
        }
        return ready ? "\(missing) Choose Label Speakers to detect the languages again." : nil
    }
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
    /// A meeting in several languages whose current transcript misses one of them (`LanguageWork`); nil otherwise.
    public var languageWork: LanguageWork?
    /// Where `name` came from (`MeetingNaming.source`: meeting.json's, else inferred from the name).
    public var nameSource: MeetingNameSource
    /// The manifest's name: a copy of `name` (`MeetingNaming.name`) a rename updates after meeting.json; different
    /// from it when that second write did not happen (`nameCopyIsStale`).
    public var manifestName: String
    /// Why meeting.json cannot be read (damaged, of another session, written by a newer build, unreadable now); nil
    /// when it can, or when there is none (a meeting saved before it existed). Rename refuses such a meeting.
    public var metadataProblem: String?
    /// Why the transcript files cannot be rewritten now (`SessionExports.recordProblem`): exports/.generated.json was
    /// written by a newer build, or cannot be read. Nil otherwise. Rename refuses such a meeting.
    public var exportsProblem: String?
    /// A summary or final transcript of this meeting running in any process (`SessionCatalog.jobInProgress`), or nil.
    /// Rename refuses such a meeting.
    public var jobInProgress: String?
    /// Why summary.json cannot be used now: written by a newer build, or not readable (permissions, not a regular
    /// file, an I/O error). Nil when it can, is missing or damaged. Rename refuses such a meeting.
    public var summaryProblem: String?
    /// summary.json, when it can be read: possibly of an earlier transcript (`summaryIsCurrent` says), whose summary
    /// text is still shown until the new one is made, but not its title (`displayTitle`).
    public var generatedSummary: MeetingSummaryRecord? = nil

    /// Every field but `generatedSummary`, which holds what the meeting was about: `session list --json` and anything
    /// else that encodes the catalog stay metadata only (summary.json and `session summarize --json` carry it).
    private enum CodingKeys: String, CodingKey {
        case id, directory, name, createdAt, source, origin, state, manifestStatus, savedSeconds, chunkCount
        case transcriptID, transcriptProblem, transcriptRefused, speakerState, labelMessage, runID, labelsReadyAt
        case hasSpeakerEdits, phase, pid, liveness, bytes, derivedBytes, audioDeleted, languageWork, nameSource
        case manifestName
        case metadataProblem, exportsProblem, jobInProgress, summaryProblem
    }

    /// The title the Meetings list shows (`MeetingNaming.title`, the rule the transcript files' heading follows too):
    /// the user's name, else the title of a summary of the current transcript, else the name.
    public var displayTitle: String {
        MeetingNaming.title(name: name, source: nameSource, summary: generatedSummary, transcriptID: transcriptID)
    }

    /// The manifest's copy of the name was not updated after a rename committed it to meeting.json: the meeting's
    /// files read as out of date, so Update Transcript Files (Finish Rename) writes the copy, and the files, again.
    public var nameCopyIsStale: Bool { manifestName != name }

    /// The generated title the meeting can show (`MeetingNaming.title`'s rule): a summary of the current transcript's;
    /// nil otherwise. What Use Generated Title and the rename editor offer.
    public var currentGeneratedTitle: String? {
        MeetingSummaryStore.current(generatedSummary, transcriptID: transcriptID).flatMap { $0.title.isEmpty ? nil : $0.title }
    }

    /// The summary was made from the current transcript.
    public var summaryIsCurrent: Bool {
        MeetingSummaryStore.current(generatedSummary, transcriptID: transcriptID) != nil
    }

    public init(id: String, directory: URL, name: String, createdAt: Date, source: AudioSource,
                origin: MeetingOrigin = .recorded, state: SessionState, manifestStatus: String,
                savedSeconds: Double = 0, chunkCount: Int = 0, transcriptID: String? = nil,
                transcriptProblem: String? = nil, transcriptRefused: Bool = false,
                speakerState: SpeakerLabelState = .none, labelMessage: String? = nil, runID: String? = nil,
                labelsReadyAt: Date? = nil,
                hasSpeakerEdits: Bool = false, phase: RecorderPhase? = nil, pid: Int32? = nil,
                liveness: RecorderLiveness, bytes: Int64 = 0, derivedBytes: Int64 = 0, audioDeleted: Bool = false,
                languageWork: LanguageWork? = nil, nameSource: MeetingNameSource? = nil,
                generatedSummary: MeetingSummaryRecord? = nil, metadataProblem: String? = nil,
                exportsProblem: String? = nil, jobInProgress: String? = nil, summaryProblem: String? = nil,
                manifestName: String? = nil) {
        self.id = id; self.directory = directory; self.name = name; self.createdAt = createdAt
        self.source = source; self.origin = origin; self.state = state; self.manifestStatus = manifestStatus
        self.savedSeconds = savedSeconds; self.chunkCount = chunkCount; self.transcriptID = transcriptID
        self.transcriptProblem = transcriptProblem; self.transcriptRefused = transcriptRefused
        self.speakerState = speakerState; self.labelMessage = labelMessage; self.runID = runID
        self.labelsReadyAt = labelsReadyAt
        self.hasSpeakerEdits = hasSpeakerEdits; self.phase = phase; self.pid = pid; self.liveness = liveness
        self.bytes = bytes; self.derivedBytes = derivedBytes; self.audioDeleted = audioDeleted
        self.languageWork = languageWork
        self.nameSource = MeetingNaming.source(stored: nameSource, name: name)
        self.generatedSummary = generatedSummary
        self.metadataProblem = metadataProblem
        self.exportsProblem = exportsProblem
        self.jobInProgress = jobInProgress
        self.summaryProblem = summaryProblem
        self.manifestName = manifestName ?? name
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
        // The background-job lock is read once for the whole listing.
        let job = DeepTranscriptionLock.state()
        return sessionFolders(in: root).map { summary(session: $0, now: now, jobState: job) }.sorted { left, right in
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id < right.id
        }
    }

    /// `jobState`: the background-job lock (`DeepTranscriptionLock.state()`, read when nil), which says whether a
    /// summary or final transcript of this meeting runs in any process (`jobInProgress`).
    public static func summary(session: URL, now: Date = Date(), jobState: DeepTranscriptionLock.State? = nil)
        -> SessionSummary {
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
        let meetingRead = Result { try SessionFiles.meetingInfo(session: session, manifest: manifest) }
        let summaryRead = MeetingSummaryStore.readChecked(session: session, sessionID: manifest.id)
        let meeting = try? meetingRead.get()
        let origin = meeting?.origin ?? .recorded
        let speakers = speakerLabels(session, liveness: liveness)
        // The revision is read, not only found, so a damaged, truncated, mislabelled, or newer one is never listed
        // as the session's transcript.
        var transcriptID: String?
        var transcriptProblem: String?
        var transcriptRefused = false
        var languageWork: LanguageWork?
        do {
            if let current = try SessionFiles.currentTranscript(session: session) {
                transcriptID = current.id
                languageWork = LanguageStage.pendingLanguages(session: session, manifest: manifest, transcript: current)
                    .map { LanguageWork(languages: $0.languages, labelsEdited: $0.labelsEdited) }
            }
        } catch {
            log.error("Session \(manifest.id, privacy: .public): current transcript unreadable: \(error.localizedDescription, privacy: .private)")
            transcriptProblem = error.localizedDescription
            transcriptRefused = !SessionFiles.isDamage(error)
        }
        // The meeting's name: meeting.json's when a rename wrote it there, else the manifest's.
        let name = MeetingNaming.name(manifestName: manifest.name, meeting: meeting)
        return SessionSummary(
            id: manifest.id, directory: session, name: name, createdAt: manifest.createdAt,
            source: manifest.source, origin: origin,
            state: state(manifestStatus: manifest.status, liveness: liveness), manifestStatus: manifest.status,
            savedSeconds: manifest.savedSeconds, chunkCount: manifest.chunks.count, transcriptID: transcriptID,
            transcriptProblem: transcriptProblem, transcriptRefused: transcriptRefused,
            speakerState: speakers.state, labelMessage: speakers.message,
            runID: speakers.runID, labelsReadyAt: speakers.readyAt,
            hasSpeakerEdits: hasSpeakerEdits(session), phase: phase, pid: pid, liveness: liveness,
            bytes: sizes.bytes, derivedBytes: sizes.derived,
            audioDeleted: audioDeleted(session, sessionID: manifest.id), languageWork: languageWork,
            // A meeting.json that is there but cannot be read (damaged, unreadable now, newer) leaves where the name
            // came from unknown: the user's, so a generated title never replaces it. Only a missing one (a meeting
            // saved before it existed) is inferred from the name.
            nameSource: meeting.map {
                MeetingNaming.source(stored: $0.nameSource, name: name,
                                     importedFileName: $0.origin == .imported ? $0.importedFileName : nil)
            } ?? .user,
            generatedSummary: summaryRead.record,
            metadataProblem: { if case .failure(let error) = meetingRead { error.localizedDescription } else { nil } }(),
            exportsProblem: SessionExports.recordProblem(session: session),
            jobInProgress: jobInProgress(jobState ?? DeepTranscriptionLock.state(), sessionID: manifest.id),
            summaryProblem: summaryRead.problem,
            manifestName: manifest.name)
    }

    /// What the background-job lock says runs on meeting `sessionID`: a summary, a final transcript or an echo analysis
    /// of it, in any process (one started in Terminal holds the lock without holding the meeting until it saves). Nil
    /// otherwise.
    ///
    /// A lock held by a job that has not written who it is yet (`held(nil)`) holds every meeting, as the rename command
    /// counts it.
    static func jobInProgress(_ state: DeepTranscriptionLock.State, sessionID: String) -> String? {
        guard case .held(let named) = state else { return nil }
        guard let holder = named else {
            return "A background job (a summary, final transcript or echo removal) is starting."
        }
        guard holder.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame else { return nil }
        if holder.isSummary { return "A summary of this meeting is being written." }
        if holder.isEcho { return "The call's echo is being removed from this meeting." }
        return "A final transcript of this meeting is being made."
    }

    /// `summaries` with `LanguageWork.ready` set where a run would detect a language now
    /// (`LanguageStage.hasPendingWork`, which asks `dependencies.modelStatus` for the languages not transcribed yet).
    /// Only meetings with `languageWork` whose labels were not edited are checked, so a listing without any costs
    /// nothing. The Meetings window lists through this, off the main actor.
    public static func checkingLanguageModels(_ summaries: [SessionSummary],
                                              dependencies: LanguageDetectionDependencies = .live) async
        -> [SessionSummary] {
        var checked = summaries
        for index in checked.indices {
            let session = checked[index].directory
            guard let work = checked[index].languageWork, !work.labelsEdited,
                  let manifest = try? SessionArchive.readManifest(at: session),
                  let current = try? SessionFiles.currentTranscript(session: session),
                  current.id == checked[index].transcriptID else { continue }
            let ready = await LanguageStage.hasPendingWork(session: session, manifest: manifest, transcript: current,
                                                           dependencies: dependencies)
            checked[index].languageWork?.ready = ready
        }
        return checked
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

    /// The most of a manifest `hasSession` reads for its `id`.
    static let maximumProbedManifestBytes: off_t = 1 << 20

    /// Whether a folder under `root` holds the session `id`, whatever the folder is named (`<id>.holos`, or any
    /// `<something>.holos` whose manifest names it, read for its `id` alone): false only when `root` could be listed
    /// and every folder with a manifest had it read and naming another session; nil when that cannot be told (`root`
    /// or a manifest unreadable for now).
    public static func hasSession(_ id: String, in root: URL) -> Bool? {
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else { return nil }
        struct ManifestID: Decodable { var id: String }
        var unsure = false
        for folder in sessionFolders(in: root) {
            if folder.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(id) == .orderedSame {
                return true
            }
            // Only a regular file is read (never followed, never a FIFO that would block), and at most 1 MiB: a missing
            // manifest, or a link or other entry in its place, is no session; a larger one is not told apart.
            let manifest = SessionPaths.manifest(folder)
            var info = stat()
            guard lstat(manifest.path, &info) == 0 else {
                let code = errno
                if code != ENOENT, code != ENOTDIR { unsure = true }
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
            guard info.st_size <= Self.maximumProbedManifestBytes,
                  let data = try? AtomicFile.readIfPresent(manifest, maxBytes: Int(Self.maximumProbedManifestBytes)),
                  let found = try? HolosJSON.decoder().decode(ManifestID.self, from: data) else {
                unsure = true
                continue
            }
            if found.id.caseInsensitiveCompare(id) == .orderedSame { return true }
        }
        return unsure ? nil : false
    }

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
