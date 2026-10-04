import Darwin
import Foundation
import HolosCore
import HolosStorage
import Synchronization

/// The people a meeting's speaker labels name (`MeetingSummarySource.people`), for the Meetings list, which reads the
/// catalog every 2 s: a meeting's labels are loaded again only when something they depend on changed (the current
/// transcript, the head run, the edit journal, the recognition results, people's names, "Remember voices").
public final class MeetingPeopleCache: Sendable {
    private struct Entry {
        var key: String
        var people: [String]
    }

    private let entries = Mutex<[String: Entry]>([:])

    public init() {}

    /// The people of `summary`'s meeting; none until its speaker labels are ready (`labelsReadyAt`), or when they
    /// cannot be read.
    public func people(of summary: SessionSummary, profileNames: [String: String], applyRecognition: Bool) -> [String] {
        guard summary.labelsReadyAt != nil else { return [] }
        let key = Self.key(summary, profileNames: profileNames, applyRecognition: applyRecognition)
        if let entry = entries.withLock({ $0[summary.id] }), entry.key == key { return entry.people }
        let snapshot: SpeakerSessionSnapshot
        do {
            snapshot = try SpeakerSessionSnapshot.load(session: summary.directory, profileNames: profileNames,
                                                       applyRecognition: applyRecognition)
        } catch {
            // Not read now (a file busy or unreadable): nobody shown, and nothing kept, so it is read again next time.
            return []
        }
        let people = (snapshot.transcriptChanged ? nil : snapshot.projection).map(MeetingSummarySource.people) ?? []
        entries.withLock { $0[summary.id] = Entry(key: key, people: people) }
        return people
    }

    /// Forgets meetings no longer listed.
    public func keep(only ids: Set<String>) {
        entries.withLock { entries in entries = entries.filter { ids.contains($0.key) } }
    }

    /// What the people depend on, as one string.
    static func key(_ summary: SessionSummary, profileNames: [String: String], applyRecognition: Bool) -> String {
        let names = profileNames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1F}")
        return [summary.transcriptID ?? "-", summary.runID ?? "-", fileStamp(SessionPaths.head(summary.directory)),
                fileStamp(SessionPaths.edits(summary.directory)), recognitionStamp(summary.directory),
                applyRecognition ? "r" : "-", names]
            .joined(separator: "|")
    }

    /// The recognition results (`speakers/recognition/<run>.json`, written after the head run): each file's name, size
    /// and modification time, so a result written or replaced changes it.
    static func recognitionStamp(_ session: URL) -> String {
        let folder = SessionPaths.recognitionDirectory(session)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return "-" }
        return names.sorted().map { $0 + "=" + fileStamp(folder.appendingPathComponent($0)) }
            .joined(separator: ",")
    }

    /// Size and modification time of `url`, or "-" when it cannot be read.
    static func fileStamp(_ url: URL) -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "-" }
        return "\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }
}

/// `SessionExports.filesState` per meeting, read again only when a transcript file or its record changed (by size and
/// modification time) or the title shown did; the Meetings list asks for every finished meeting every 2 s.
public final class TranscriptFilesCache: Sendable {
    private struct Entry {
        var stamp: String
        var title: String
        var state: SessionExports.FilesState
    }

    private let entries = Mutex<[String: Entry]>([:])

    public init() {}

    public func state(of summary: SessionSummary) -> SessionExports.FilesState {
        // The manifest's copy of the name not updated after a rename: out of date whatever the files hold.
        if summary.nameCopyIsStale { return .stale }
        let session = summary.directory
        let stamp = (SessionExports.formats.map { SessionPaths.export($0.rawValue, in: session) }
            + [SessionPaths.generatedExports(session), SessionPaths.transcriptPointer(session)])
            .map(MeetingPeopleCache.fileStamp).joined(separator: "|")
        // The title shown and the name transcript.json records.
        let title = summary.displayTitle + "\u{1F}" + summary.name
        if let entry = entries.withLock({ $0[summary.id] }), entry.stamp == stamp, entry.title == title {
            return entry.state
        }
        let state = SessionExports.filesState(session: session, title: summary.displayTitle, name: summary.name)
        entries.withLock { $0[summary.id] = Entry(stamp: stamp, title: title, state: state) }
        return state
    }

    /// Forgets meetings no longer listed.
    public func keep(only ids: Set<String>) {
        entries.withLock { all in all = all.filter { ids.contains($0.key) } }
    }
}
