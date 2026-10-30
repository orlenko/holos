import Foundation
import HolosCore
import os

/// Which meetings lose their audio on their own (Settings › Meetings, docs/design.md "Automatic audio cleanup"). Pure.
public enum AudioCleanupPolicy {
    /// The audio of `summary` may be deleted now: it is at least `days` old, it has audio and nothing works on it, its
    /// transcript is saved and readable, its speakers are labelled with no language left to detect, and no work queued
    /// on it still needs the audio (`pending`: a final transcript or an echo analysis).
    public static func eligible(_ summary: SessionSummary, now: Date, days: Int, pending: Set<String>) -> Bool {
        guard summary.createdAt.addingTimeInterval(TimeInterval(days) * 86_400) <= now,
              MeetingActionPolicy.deletesAudio(summary), !MeetingActionPolicy.isLive(summary),
              summary.state == .complete || summary.state == .recovered,
              summary.transcriptID != nil, summary.transcriptProblem == nil, !summary.transcriptRefused,
              summary.speakerState == .labelled, summary.languageWork == nil else { return false }
        return !pending.contains(summary.id)
    }
}

/// The automatic audio cleanup as a `BackgroundJobKind`: while Settings › Meetings has it on, the meetings
/// `AudioCleanupPolicy` allows get `voiceislocal session delete --audio-only`, oldest first, one at a time. Automatic
/// work: after everything else. The candidates come from a scan of the sessions folder, run again at most hourly or
/// when `rescan` is asked for (the setting changed); each one is read again just before its command runs.
///
/// Invariants:
/// 1. Nothing runs while `olderThanDays` is nil (the cleanup is off).
/// 2. A meeting whose run ended in this launch, however it ended, is not run again before the next launch.
@MainActor public final class AudioCleanupJobs: BackgroundJobKind {
    public struct Outcome: Decodable, Sendable {
        /// "audio" once the audio is deleted.
        public var deleted: String?
    }

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")
    /// How long a scan's candidates stand before the next look scans again.
    public static let rescanAfter: TimeInterval = 3600

    public let name = "Audio cleanup"
    public let runningText = "Deleting old audio…"

    /// The sessions folder (unset: no scan).
    public var root: URL?
    /// After how many days a meeting's audio goes, or nil while the cleanup is off.
    public var olderThanDays: @MainActor () -> Int? = { nil }
    /// Meetings other queued work still needs the audio of.
    public var pending: @MainActor () -> Set<String> = { [] }
    /// A scan ended (the app looks for work again).
    public var onScanned: @MainActor () -> Void = {}
    /// A meeting's audio was deleted.
    public var onDeleted: @MainActor (String) -> Void = { _ in }

    /// The last scan's meetings, oldest first.
    public private(set) var candidates: [SessionSummary] = []
    private var scanning = false
    private var scannedAt: Date?
    /// Meetings whose run ended in this launch (invariant 2).
    public private(set) var ended: Set<String> = []

    private let list: @Sendable (URL, Date) -> [SessionSummary]
    private let read: @Sendable (URL, Date) -> SessionSummary

    public init(list: @escaping @Sendable (URL, Date) -> [SessionSummary] = { SessionCatalog.list(root: $0, now: $1) },
                read: @escaping @Sendable (URL, Date) -> SessionSummary = {
                    SessionCatalog.summary(session: $0, now: $1)
                }) {
        self.list = list
        self.read = read
    }

    /// The next look scans again (the setting changed).
    public func rescan() {
        scannedAt = nil
    }

    public func lookForWork(_ holds: BackgroundJobHolds) {
        guard olderThanDays() != nil, let root, !scanning else { return }
        if let scannedAt, holds.now.timeIntervalSince(scannedAt) < Self.rescanAfter { return }
        scanning = true
        let list = list, now = holds.now
        Task { [weak self] in
            let found = await Task.detached { list(root, now) }.value
            guard let self else { return }
            self.candidates = found.sorted { $0.createdAt < $1.createdAt }
            self.scanning = false
            self.scannedAt = now
            self.onScanned()
        }
    }

    public func next(_ holds: BackgroundJobHolds) -> BackgroundJobPick? {
        guard let days = olderThanDays() else { return nil }
        let pending = pending()
        guard let pick = candidates.first(where: { summary in
            !ended.contains(summary.id) && !holds.inUse.contains(summary.id) && holds.running != summary.id
                && holds.delayOver(summary.id)
                && AudioCleanupPolicy.eligible(summary, now: holds.now, days: days, pending: pending)
        }) else { return nil }
        let path = pick.directory.path
        return BackgroundJobPick(
            sessionID: pick.id, path: path, priority: .automatic,
            command: BackgroundJobCommand(arguments: ["session", "delete", path, "--audio-only", "--yes", "--json"],
                                          output: "audio-cleanup", errors: "audio-cleanup-err",
                                          maxOutputBytes: 1 << 16))
    }

    /// The meeting as it is now, since the scan may be an hour old: still allowed (a Delete Audio, a relabel, or a
    /// Recover meanwhile turns it down).
    public func preparation(for pick: BackgroundJobPick) -> (@Sendable () -> Bool)? {
        guard let days = olderThanDays() else { return { false } }
        let read = read, pending = pending(), session = URL(fileURLWithPath: pick.path)
        return { AudioCleanupPolicy.eligible(read(session, Date()), now: Date(), days: days, pending: pending) }
    }

    public func nothingToDo(_ sessionID: String) -> BackgroundJobEnd { finish(sessionID) }

    public func ended(_ sessionID: String, result: CommandResult<Outcome>, preempted: Bool) -> BackgroundJobEnd {
        if preempted { return .stopped }
        if result.code == 0 {
            Self.log.notice("Audio cleanup deleted the audio of \(sessionID, privacy: .public)")
            onDeleted(sessionID)
        } else {
            Self.log.error("Audio cleanup of \(sessionID, privacy: .public) ended with code \(result.code); next launch")
        }
        return finish(sessionID)
    }

    /// Another process held the meeting: ten minutes.
    public func retryDelay(attempts: Int) -> TimeInterval { 600 }

    private func finish(_ sessionID: String) -> BackgroundJobEnd {
        ended.insert(sessionID)
        candidates.removeAll { $0.id == sessionID }
        return .finished
    }
}
