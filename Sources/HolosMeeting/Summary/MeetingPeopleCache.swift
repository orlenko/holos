import Darwin
import Foundation
import HolosCore
import HolosStorage
import Synchronization

/// The people a meeting's speaker labels name (`MeetingSummarySource.people`), for the Meetings list, which reads the
/// catalog every 2 s: a meeting's labels are loaded again only when something they depend on changed (the current
/// transcript, the head run, the edit journal, people's names, "Remember voices").
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
        let people = (try? SpeakerSessionSnapshot.load(session: summary.directory, profileNames: profileNames,
                                                        applyRecognition: applyRecognition))
            .flatMap { snapshot in snapshot.transcriptChanged ? nil : snapshot.projection }
            .map(MeetingSummarySource.people) ?? []
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
                fileStamp(SessionPaths.edits(summary.directory)), applyRecognition ? "r" : "-", names]
            .joined(separator: "|")
    }

    /// Size and modification time of `url`, or "-" when it cannot be read.
    static func fileStamp(_ url: URL) -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "-" }
        return "\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }
}
