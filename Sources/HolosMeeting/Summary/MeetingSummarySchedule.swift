import CryptoKit
import Foundation
import HolosCore
import HolosStorage
import Synchronization

/// When the app makes a meeting's summary (docs/meeting-design.md §4.17): one meeting at a time, in the background,
/// with `voiceislocal session summarize`. A finished meeting whose summary.json is missing or of an earlier transcript
/// is summarized once per transcript (a run that failed is not repeated until the transcript changes or the app starts
/// again); one the user asked for comes first. Nothing starts while a meeting records or saves, while a final
/// transcript is made (it replaces the transcript anyway), or while the meeting is in use.
public enum MeetingSummarySchedule {
    /// What the scan found about one meeting.
    public struct Candidate: Sendable, Equatable {
        public var sessionID: String
        public var path: String
        public var createdAt: Date
        /// The current transcript; nil when there is none.
        public var transcriptID: String?
        /// The transcript summary.json is of; nil when there is none.
        public var summaryTranscriptID: String?
        /// Not recording, saving or post-processing (no writer, no processing lease).
        public var idle: Bool
        /// Finished as a final transcript requires it (`isFinished`): an interrupted or still processing meeting
        /// waits for Recover or its save, so a partial transcript is never summarized.
        public var finished: Bool
        /// summary.json says the transcript files were not rewritten with it (`exportsPending`).
        public var exportsPending: Bool
        /// When summary.json was made, in milliseconds since 1970 (`MeetingSummaryRecord.createdAtMilliseconds`).
        public var summaryCreatedAt: Int64?
        /// summary.json's key is the meeting's (`MeetingSummaryKey.isCurrent`: this transcript, these speakers' names).
        public var summaryCurrent: Bool
        /// The meeting's key (`MeetingSummaryKey.text`): what a run that failed is remembered by.
        public var key: String?
        /// summary.json was written by a newer Voice is Local: the meeting is left alone (only a Summarize Again the
        /// user asks for runs, and reports why it cannot).
        public var summaryFromNewerVersion: Bool

        /// `summaryCurrent` nil: the summary is current when it is of the current transcript; `key` nil: the
        /// transcript ID.
        public init(sessionID: String, path: String, createdAt: Date, transcriptID: String?,
                    summaryTranscriptID: String?, idle: Bool, finished: Bool = true, exportsPending: Bool = false,
                    summaryCreatedAt: Int64? = nil, summaryCurrent: Bool? = nil, key: String? = nil,
                    summaryFromNewerVersion: Bool = false) {
            self.sessionID = sessionID; self.path = path; self.createdAt = createdAt
            self.transcriptID = transcriptID; self.summaryTranscriptID = summaryTranscriptID; self.idle = idle
            self.finished = finished; self.exportsPending = exportsPending; self.summaryCreatedAt = summaryCreatedAt
            self.summaryCurrent = summaryCurrent ?? (transcriptID != nil && summaryTranscriptID == transcriptID)
            self.key = key ?? transcriptID
            self.summaryFromNewerVersion = summaryFromNewerVersion
        }

        /// Only the transcript files are left to rewrite, with a current summary: no model call is needed.
        public var onlyExportsPending: Bool { summaryCurrent && exportsPending }

        /// The summary is not current (missing, of another transcript, or made with other speakers' names), or the
        /// transcript files still miss it; never one a newer Voice is Local wrote.
        public var needsSummary: Bool {
            transcriptID != nil && !summaryFromNewerVersion && (!summaryCurrent || exportsPending)
        }
    }

    public struct Situation: Sendable, Equatable {
        /// Settings › Meetings › "Title and summarize meetings with Apple Intelligence".
        public var enabled: Bool
        /// Apple's on-device model can be used.
        public var modelAvailable: Bool
        /// A meeting is starting, recording, or saving.
        public var meetingBusy: Bool
        /// A final transcript is being made (by this app or another process).
        public var deepPassRunning: Bool
        /// The meeting summarized now, if any.
        public var running: String?
        /// Meetings the app is working on or a review holds.
        public var inUse: Set<String>
        /// The key (`Candidate.key`: transcript and speakers' names) each meeting was last tried with, when that try
        /// made no summary for good reasons (failed, unavailable): not tried again until its key changes.
        public var attempted: [String: String]
        /// Meetings whose try was refused for now (busy, transcript changed): skipped until the time given.
        public var delayedUntil: [String: Date]
        /// Meetings the user asked to summarize again (newest request last), with `--force`.
        public var requested: [String]
        /// On battery only meetings from the last `recentOnBattery` are summarized; the rest wait for power.
        public var onBattery: Bool
        /// Meetings a final transcript is queued for: their transcript is about to change, so they are summarized
        /// after it (automatically; a request still runs).
        public var finalTranscriptQueued: Set<String>
        public var now: Date

        public init(enabled: Bool, modelAvailable: Bool, meetingBusy: Bool, deepPassRunning: Bool, running: String?,
                    inUse: Set<String> = [], attempted: [String: String] = [:], delayedUntil: [String: Date] = [:],
                    requested: [String] = [], onBattery: Bool = false, finalTranscriptQueued: Set<String> = [],
                    now: Date = Date()) {
            self.enabled = enabled; self.modelAvailable = modelAvailable; self.meetingBusy = meetingBusy
            self.deepPassRunning = deepPassRunning; self.running = running; self.inUse = inUse
            self.attempted = attempted; self.delayedUntil = delayedUntil; self.requested = requested
            self.onBattery = onBattery; self.finalTranscriptQueued = finalTranscriptQueued; self.now = now
        }
    }

    public enum Decision: Sendable, Equatable {
        case wait
        /// Summarize this meeting; `force` for one the user asked for.
        case run(sessionID: String, path: String, force: Bool)
    }

    /// Meetings saved within this long are summarized on battery too.
    public static let recentOnBattery: TimeInterval = 2 * 24 * 3600

    /// The next meeting to summarize: one the user asked for, else the newest that needs a summary, has not been
    /// tried with its transcript, and is idle, not in use and not delayed.
    public static func next(_ candidates: [Candidate], _ situation: Situation) -> Decision {
        guard situation.running == nil, !situation.meetingBusy, !situation.deepPassRunning else { return .wait }
        func ready(_ candidate: Candidate) -> Bool {
            candidate.idle && candidate.finished && candidate.transcriptID != nil
                && !situation.inUse.contains(candidate.sessionID)
                && (situation.delayedUntil[candidate.sessionID].map { $0 <= situation.now } ?? true)
        }
        // Asked for by the user: also with the setting off, and also when the summary is current; not without the
        // model. One whose summary is current with its transcript files left to rewrite (a command that ended while
        // the app was closed) only gets them rewritten, not forced through the model again.
        for id in situation.requested.reversed() {
            guard let candidate = candidates.first(where: { $0.sessionID == id }), ready(candidate) else { continue }
            if candidate.onlyExportsPending { return .run(sessionID: id, path: candidate.path, force: false) }
            if situation.modelAvailable { return .run(sessionID: id, path: candidate.path, force: true) }
        }
        // With the setting off, or without the model, only transcript files left without their summary are
        // rewritten (no model call).
        let due = candidates
            .filter { candidate in
                ready(candidate) && candidate.needsSummary
                    && ((situation.enabled && situation.modelAvailable) || candidate.onlyExportsPending)
                    && !situation.finalTranscriptQueued.contains(candidate.sessionID)
                    && (candidate.onlyExportsPending || situation.attempted[candidate.sessionID] != candidate.key)
                    && (!situation.onBattery || candidate.onlyExportsPending
                        || situation.now.timeIntervalSince(candidate.createdAt) <= recentOnBattery)
            }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.sessionID < $1.sessionID }
        guard let first = due.first else { return .wait }
        return .run(sessionID: first.sessionID, path: first.path, force: false)
    }

    /// A Summarize Again the user asked for, saved until it ends for good (the app's queue).
    public struct Request: Codable, Sendable, Equatable {
        public var sessionID: String
        /// When it was asked for, in milliseconds since 1970.
        public var requestedAtMilliseconds: Int64

        public init(sessionID: String, requestedAt: Date) {
            self.sessionID = sessionID; requestedAtMilliseconds = MeetingSummarySchedule.milliseconds(requestedAt)
        }
    }

    /// People's names and "Remember voices" as one string, for the key cache.
    static func voiceStamp(names: [String: String], recognition: Bool) -> String {
        let text = names.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data((text + (recognition ? "|r" : "|-")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Keys worked out by earlier scans, by meeting, with what they were worked out from (the transcript, the speaker
    /// head, edit journal and recognition results, people's names and Remember voices): a meeting's labels are read again only when one of
    /// those changed.
    private static let keyCache = Mutex<[String: (inputs: String, key: MeetingSummaryKey?)]>([:])

    /// The meeting's key (`MeetingSummaryKey.load`), from the cache while its inputs are unchanged.
    static func key(session: URL, sessionID: String, transcriptID: String, profileNames: [String: String],
                    recognition: Bool, selfName: String) -> MeetingSummaryKey? {
        let inputs = transcriptID + "|" + SessionSummarizeCommand.speakerRevision(session) + "|"
            + voiceStamp(names: profileNames, recognition: recognition) + "|" + selfName
        if let cached = keyCache.withLock({ $0[sessionID] }), cached.inputs == inputs { return cached.key }
        let key = MeetingSummaryKey.load(session: session, profileNames: profileNames, applyRecognition: recognition,
                                         selfName: selfName)
        // Only a key that could be read is kept: a read that failed (a file busy or unreadable for now) is tried again
        // at the next scan.
        if let key { keyCache.withLock { $0[sessionID] = (inputs, key) } }
        return key
    }

    /// Milliseconds since 1970.
    public static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    /// The requests a summary already answers: summary.json is of the current transcript, its files are written,
    /// and it was made at or after the request, to the millisecond (a summary without that time answers none). A
    /// request saved before a quit whose command finished without the app is then not made again.
    public static func satisfied(_ requests: [Request], by candidates: [Candidate]) -> Set<String> {
        var done: Set<String> = []
        for request in requests {
            guard let candidate = candidates.first(where: { $0.sessionID == request.sessionID }),
                  let made = candidate.summaryCreatedAt, candidate.summaryCurrent, !candidate.exportsPending,
                  made >= request.requestedAtMilliseconds else { continue }
            done.insert(request.sessionID)
        }
        return done
    }

    /// A meeting that can be summarized: finished as `DeepTranscriptionSchedule.isFinished` says (saved, recovered,
    /// audio only, transcript incomplete), with or without its audio.
    public static func isFinished(_ state: SessionState) -> Bool {
        DeepTranscriptionSchedule.isFinished(state, audioDeleted: false)
    }

    /// The meetings under `root`, as `next` needs them: lock probes, the transcript pointer, summary.json, and each
    /// meeting's key (`MeetingSummaryKey`, with `profileNames` and `recognition` as the exports apply them; read again
    /// only when its inputs changed). Folders that cannot be read are left out.
    public static func scan(root: URL, profileNames: [String: String] = [:], recognition: Bool = true,
                            selfName: String = VoiceProfileService.ownName()) -> [Candidate] {
        SessionCatalog.sessionFolders(in: root).compactMap { session in
            guard let manifest = try? SessionArchive.readManifest(at: session) else { return nil }
            let active = (try? SessionArchive.isActive(at: session)) ?? true
            let processing = (try? SessionArchive.isProcessing(at: session)) ?? true
            let transcriptID = (try? SessionArchive.currentTranscriptID(at: session)) ?? nil
            let (summary, newer) = MeetingSummaryStore.readForSchedule(session: session, sessionID: manifest.id)
            let state = SessionCatalog.state(manifestStatus: manifest.status,
                                             liveness: RecorderChannel.liveness(session: session))
            let key = transcriptID.flatMap {
                Self.key(session: session, sessionID: manifest.id, transcriptID: $0, profileNames: profileNames,
                         recognition: recognition, selfName: selfName)
            }
            return Candidate(sessionID: manifest.id, path: session.path, createdAt: manifest.createdAt,
                             transcriptID: transcriptID, summaryTranscriptID: summary?.transcriptID,
                             idle: !active && !processing, finished: isFinished(state),
                             exportsPending: summary?.exportsPending == true,
                             summaryCreatedAt: summary?.createdAtMilliseconds,
                             summaryCurrent: key?.isCurrent(summary) ?? false, key: key?.text ?? transcriptID,
                             summaryFromNewerVersion: newer)
        }
    }
}
