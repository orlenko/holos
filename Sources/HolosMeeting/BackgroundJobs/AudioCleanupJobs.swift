import Foundation
import HolosCore
import HolosStorage
import os

/// Which meetings lose their audio on their own (Settings › Meetings, docs/design.md "Automatic audio cleanup"). Pure.
public enum AudioCleanupPolicy {
    /// The audio of `summary` may be deleted now: it is at least `days` old, it has audio and nothing works on it, its
    /// transcript is saved and readable, its speakers are labelled with no language left to detect, and no work queued
    /// on it still needs the audio (`pending`: a final transcript or an echo analysis).
    /// `underOwnLease`: read by `SessionAudioCleanupCommand` while it holds the meeting's processing lease, which the
    /// catalog shows as maintenance; a recorder still capturing is refused either way.
    public static func eligible(_ summary: SessionSummary, now: Date, days: Int, pending: Set<String>,
                                underOwnLease: Bool = false, audioNeeded: String? = nil) -> Bool {
        refusal(summary, now: now, days: days, pending: pending, underOwnLease: underOwnLease,
                audioNeeded: audioNeeded) == nil
    }

    /// Why `summary`'s audio stays, or nil when it may go (`eligible`). Unknown is never eligible: naming metadata or a
    /// transcript that cannot be read keeps the audio, and so does what `audioNeeded(session:transcriptID:)` finds on
    /// disk (`audioNeeded`, its reason).
    public static func refusal(_ summary: SessionSummary, now: Date, days: Int, pending: Set<String>,
                               underOwnLease: Bool = false, audioNeeded: String? = nil) -> String? {
        if summary.createdAt.addingTimeInterval(TimeInterval(days) * 86_400) > now { return "younger than \(days) days" }
        if !MeetingActionPolicy.deletesAudio(summary) { return "no audio to delete" }
        if underOwnLease ? summary.liveness == .capturing : MeetingActionPolicy.isLive(summary) {
            return "recording or worked on"
        }
        if summary.state != .complete && summary.state != .recovered { return "not finished" }
        if summary.transcriptID == nil || summary.transcriptProblem != nil || summary.transcriptRefused {
            return "no readable transcript"
        }
        if summary.metadataProblem != nil { return "meeting.json cannot be read" }
        if summary.speakerState != .labelled || summary.languageWork != nil { return "speakers not labelled" }
        if let audioNeeded { return audioNeeded }
        if pending.contains(summary.id) { return "a final transcript or echo analysis waits" }
        return nil
    }

    /// Why the meeting's files do not show that its audio may go, or nil when they do. Positive evidence only: what
    /// cannot be read or established keeps the audio. The files must show a manifest; an event journal that is there
    /// and reads whole (no torn tail, no unreadable line; the catalog reads a missing or unreadable one as no language
    /// work left); a current transcript not rebuilt without transcribing audio it leaves out
    /// (`TranscriptRebuilder.leftAudioUntranscribed`, `session recover --no-transcribe`); and speaker labels made for
    /// that transcript or one it was corrected from (`WordFixStage.correctionChain`). Reads files: off the main actor.
    public static func audioNeeded(session: URL, transcriptID: String?) -> String? {
        guard let transcriptID else { return "no readable transcript" }
        guard let manifest = try? SessionArchive.readManifest(at: session) else { return "its manifest cannot be read" }
        guard FileManager.default.fileExists(atPath: SessionPaths.events(session).path),
              let journal = try? SessionArchive.readEvents(at: session),
              journal.unreadableLines == 0, !journal.tornTail else {
            return "its event journal is missing or damaged"
        }
        if TranscriptRebuilder.leftAudioUntranscribed(transcriptID, events: journal.events, manifest: manifest) {
            return "part of its audio was never transcribed"
        }
        guard let head = try? SessionSpeakerStore.readHead(session: session),
              let run = try? SessionSpeakerStore.readRun(id: head.runID, session: session),
              WordFixStage.correctionChain(transcriptID, events: journal.events).contains(run.transcriptID) else {
            return "its speaker labels are not for its transcript"
        }
        return nil
    }

    /// A deletion of `summary`'s audio that began and did not finish (`unfinished`,
    /// `SessionDeletion.audioDeletionUnfinished`) may be finished now: nothing records or works on the meeting.
    /// Delete Audio is idempotent and keeps the marker.
    public static func finishes(_ summary: SessionSummary, unfinished: Bool) -> Bool {
        summary.audioDeleted && unfinished && !MeetingActionPolicy.isLive(summary)
    }
}

/// The automatic audio cleanup as a `BackgroundJobKind`: while Settings › Meetings has it on, the meetings
/// `AudioCleanupPolicy` allows get `voiceislocal session clean-audio`, which decides again under the meeting's lease
/// (`SessionAudioCleanupCommand`), oldest first, one at a time. Automatic
/// work: after everything else. The candidates come from a scan of the sessions folder, run again at most hourly or
/// when `rescan` is asked for (the setting changed); each one is read again just before its command runs.
///
/// Invariants:
/// 1. Nothing runs while `olderThanDays` is nil (the cleanup is off).
/// 2. A meeting whose run ended in this launch is not run again before the next launch; a run stopped part-way (a
///    meeting started) is not an end, and the next look scans again.
/// 3. A deletion that began and did not finish, as the files show it (`unfinished`: marked deleted with its audio
///    still there, from a scan), is finished before any new one starts, whatever the meeting's age, state or queued
///    work, as long as nothing records or works on it. Nothing else is assumed under way.
/// 4. Nothing is picked before the launch's final-transcript reconciliation ended or while one runs (`waiting`), and a
///    pick starts only if the setting is still what it was when it was picked (`stillWanted`).
@MainActor public final class AudioCleanupJobs: BackgroundJobKind {
    public typealias Outcome = SessionAudioCleanupCommand.Outcome

    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")
    /// How long a scan's candidates stand before the next look scans again.
    public static let rescanAfter: TimeInterval = 3600

    public let name = "Audio cleanup"
    public let runningText = "Deleting old audio…"
    /// A review open on the meeting turns read-only and rereads it once the audio is gone, as for Delete Audio.
    public var reviewHold: ReviewMaintenance.Command? { .deleteAudio }

    /// The sessions folder (unset: no scan).
    public var root: URL?
    /// After how many days a meeting's audio goes, or nil while the cleanup is off.
    public var olderThanDays: @MainActor () -> Int? = { nil }
    /// Meetings other queued work still needs the audio of.
    public var pending: @MainActor () -> Set<String> = { [] }
    /// The launch's final-transcript reconciliation has not ended, or one runs: meetings it may queue are not known.
    public var waiting: @MainActor () -> Bool = { false }
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
    /// Meetings whose audio deletion began and did not finish: found by the scan, or stopped in this launch
    /// (invariant 3).
    public private(set) var unfinished: Set<String> = []
    /// The days each pick was made with (invariant 4).
    private var pickedDays: [String: Int] = [:]

    private let list: @Sendable (URL, Date) -> [SessionSummary]
    private let read: @Sendable (URL, Date) -> SessionSummary
    private let deletionUnfinished: @Sendable (URL) -> Bool
    /// The time just before a command runs (tests pin it).
    private let clock: @Sendable () -> Date
    private let audioNeeded: @Sendable (URL, String?) -> String?

    public init(list: @escaping @Sendable (URL, Date) -> [SessionSummary] = { SessionCatalog.list(root: $0, now: $1) },
                read: @escaping @Sendable (URL, Date) -> SessionSummary = {
                    SessionCatalog.summary(session: $0, now: $1)
                },
                deletionUnfinished: @escaping @Sendable (URL) -> Bool = {
                    SessionDeletion.audioDeletionUnfinished(session: $0)
                }, clock: @escaping @Sendable () -> Date = { Date() },
                audioNeeded: @escaping @Sendable (URL, String?) -> String? = {
                    AudioCleanupPolicy.audioNeeded(session: $0, transcriptID: $1)
                }) {
        self.list = list
        self.read = read
        self.deletionUnfinished = deletionUnfinished
        self.clock = clock
        self.audioNeeded = audioNeeded
    }

    /// The next look scans again (the setting changed).
    public func rescan() {
        scannedAt = nil
    }

    public func lookForWork(_ holds: BackgroundJobHolds) {
        guard olderThanDays() != nil, let root, !scanning else { return }
        if let scannedAt, holds.now.timeIntervalSince(scannedAt) < Self.rescanAfter { return }
        scanning = true
        let list = list, deletionUnfinished = deletionUnfinished, now = holds.now
        Task { [weak self] in
            let (found, unfinished) = await Task.detached { () -> ([SessionSummary], Set<String>) in
                let found = list(root, now)
                let unfinished = found.filter { $0.audioDeleted && deletionUnfinished($0.directory) }.map(\.id)
                return (found, Set(unfinished))
            }.value
            guard let self else { return }
            self.candidates = found.sorted { $0.createdAt < $1.createdAt }
            self.unfinished.formUnion(unfinished)
            self.scanning = false
            self.scannedAt = now
            self.onScanned()
        }
    }

    public func next(_ holds: BackgroundJobHolds) -> BackgroundJobPick? {
        guard let days = olderThanDays(), !waiting() else { return nil }
        let pending = pending()
        let ready = { (summary: SessionSummary) in
            !self.ended.contains(summary.id) && !holds.inUse.contains(summary.id) && holds.running != summary.id
                && holds.delayOver(summary.id) && !MeetingActionPolicy.isLive(summary)
        }
        // Invariant 3: a deletion left part-way goes first.
        guard let pick = candidates.first(where: { unfinished.contains($0.id) && ready($0) })
            ?? candidates.first(where: {
                ready($0) && AudioCleanupPolicy.eligible($0, now: holds.now, days: days, pending: pending)
            }) else { return nil }
        let path = pick.directory.path
        pickedDays[pick.id] = days
        return BackgroundJobPick(
            sessionID: pick.id, path: path, priority: .automatic,
            command: BackgroundJobCommand(arguments: ["session", "clean-audio", path, "--older-than", String(days),
                                                      "--json"],
                                          output: "audio-cleanup", errors: "audio-cleanup-err",
                                          maxOutputBytes: 1 << 16))
    }

    /// The cleanup is still on with the days it was picked with, and no work was queued on the meeting meanwhile
    /// unless its deletion is under way (invariant 4).
    public func stillWanted(_ pick: BackgroundJobPick) -> Bool {
        guard let days = olderThanDays(), days == pickedDays[pick.sessionID], !waiting() else { return false }
        // Finishing a deletion the files show under way takes nothing from queued work: that audio is going anyway
        // (invariant 3).
        return unfinished.contains(pick.sessionID) || !pending().contains(pick.sessionID)
    }

    /// The meeting as it is now, since the scan may be an hour old: still allowed (a Delete Audio, a relabel, or a
    /// Recover meanwhile turns it down).
    public func preparation(for pick: BackgroundJobPick) -> (@Sendable () -> Bool)? {
        guard let days = olderThanDays() else { return { false } }
        let read = read, deletionUnfinished = deletionUnfinished, clock = clock, audioNeeded = audioNeeded
        let pending = pending()
        let session = URL(fileURLWithPath: pick.path)
        return {
            let now = clock(), summary = read(session, now)
            // Marked deleted: only a deletion the files show unfinished goes on. Otherwise (a run stopped before the
            // marker left nothing to finish) the meeting is judged as any other.
            if summary.audioDeleted {
                return AudioCleanupPolicy.finishes(summary, unfinished: deletionUnfinished(session))
            }
            return AudioCleanupPolicy.eligible(summary, now: now, days: days, pending: pending,
                                               audioNeeded: audioNeeded(session, summary.transcriptID))
        }
    }

    public func nothingToDo(_ sessionID: String) -> BackgroundJobEnd { finish(sessionID) }

    public func ended(_ sessionID: String, result: CommandResult<Outcome>, preempted: Bool) -> BackgroundJobEnd {
        if preempted {
            // The marker may be written already: the next scan reads the files and finds out (invariants 2 and 3).
            rescan()
            return .stopped
        }
        if result.code == 0 {
            Self.log.notice("Audio cleanup deleted the audio of \(sessionID, privacy: .public)")
            onDeleted(sessionID)
        } else if result.code == 3 {
            // Decided again under the lease and kept (the meeting changed since the scan).
            Self.log.notice("Audio cleanup kept the audio of \(sessionID, privacy: .public): \(result.outcome?.reason ?? "", privacy: .public)")
        } else {
            Self.log.error("Audio cleanup of \(sessionID, privacy: .public) ended with code \(result.code); next launch")
        }
        return finish(sessionID)
    }

    /// Another process held the meeting: ten minutes.
    public func retryDelay(attempts: Int) -> TimeInterval { 600 }

    private func finish(_ sessionID: String) -> BackgroundJobEnd {
        pickedDays[sessionID] = nil
        ended.insert(sessionID)
        unfinished.remove(sessionID)
        candidates.removeAll { $0.id == sessionID }
        return .finished
    }
}
