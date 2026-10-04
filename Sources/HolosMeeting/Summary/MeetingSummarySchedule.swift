import CryptoKit
import Foundation
import HolosCore
import HolosStorage

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
        /// The speaker labels or people's names changed since the summary of the current transcript was made
        /// (`speakerStamp`): it is checked again, and made again when the names it uses changed.
        public var speakersChanged = false

        public init(sessionID: String, path: String, createdAt: Date, transcriptID: String?,
                    summaryTranscriptID: String?, idle: Bool, finished: Bool = true, exportsPending: Bool = false,
                    summaryCreatedAt: Int64? = nil) {
            self.sessionID = sessionID; self.path = path; self.createdAt = createdAt
            self.transcriptID = transcriptID; self.summaryTranscriptID = summaryTranscriptID; self.idle = idle
            self.finished = finished; self.exportsPending = exportsPending; self.summaryCreatedAt = summaryCreatedAt
        }

        /// Only the transcript files are left to rewrite: no model call is needed.
        public var onlyExportsPending: Bool {
            exportsPending && transcriptID != nil && transcriptID == summaryTranscriptID
        }

        /// The summary is missing or of an earlier transcript, the transcript files still miss it, or its speakers
        /// changed.
        public var needsSummary: Bool {
            transcriptID != nil && (transcriptID != summaryTranscriptID || exportsPending || speakersChanged)
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
        /// The transcript each meeting was last tried with, when that try made no summary for good reasons
        /// (failed, unavailable): not tried again until its transcript changes.
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
        // model.
        for id in situation.requested.reversed() where situation.modelAvailable {
            if let candidate = candidates.first(where: { $0.sessionID == id }), ready(candidate) {
                return .run(sessionID: id, path: candidate.path, force: true)
            }
        }
        // With the setting off, or without the model, only transcript files left without their summary are
        // rewritten (no model call).
        let due = candidates
            .filter { candidate in
                ready(candidate) && candidate.needsSummary
                    && ((situation.enabled && situation.modelAvailable) || candidate.onlyExportsPending)
                    && !situation.finalTranscriptQueued.contains(candidate.sessionID)
                    && (candidate.onlyExportsPending
                        || situation.attempted[candidate.sessionID] != candidate.transcriptID)
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

    /// People's names and "Remember voices" as one string, for `speakerStamp`.
    public static func voiceStamp(names: [String: String], recognition: Bool) -> String {
        let text = names.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data((text + (recognition ? "|r" : "|-")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// What a summary's names depend on besides its transcript: the meeting's speaker labels (head and edit journal,
    /// `SessionSummarizeCommand.speakerRevision`) and `voice` (`voiceStamp`).
    public static func speakerStamp(session: URL, voice: String) -> String {
        SessionSummarizeCommand.speakerRevision(session) + "|" + voice
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
                  let made = candidate.summaryCreatedAt, candidate.transcriptID != nil,
                  candidate.summaryTranscriptID == candidate.transcriptID, !candidate.exportsPending,
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

    /// The meetings under `root`, as `next` needs them: lock probes, the transcript pointer and summary.json only (no
    /// transcript is decoded), so a scan of many meetings stays cheap. Folders that cannot be read are left out.
    public static func scan(root: URL, voiceStamp: String? = nil) -> [Candidate] {
        SessionCatalog.sessionFolders(in: root).compactMap { session in
            guard let manifest = try? SessionArchive.readManifest(at: session) else { return nil }
            let active = (try? SessionArchive.isActive(at: session)) ?? true
            let processing = (try? SessionArchive.isProcessing(at: session)) ?? true
            let transcriptID = (try? SessionArchive.currentTranscriptID(at: session)) ?? nil
            let summary = MeetingSummaryStore.readIfUsable(session: session, sessionID: manifest.id)
            let state = SessionCatalog.state(manifestStatus: manifest.status,
                                             liveness: RecorderChannel.liveness(session: session))
            var candidate = Candidate(sessionID: manifest.id, path: session.path, createdAt: manifest.createdAt,
                                      transcriptID: transcriptID, summaryTranscriptID: summary?.transcriptID,
                                      idle: !active && !processing, finished: isFinished(state),
                                      exportsPending: summary?.exportsPending == true,
                                      summaryCreatedAt: summary?.createdAtMilliseconds)
            if let voiceStamp, let summary, summary.transcriptID == transcriptID {
                candidate.speakersChanged = summary.speakerStamp != speakerStamp(session: session, voice: voiceStamp)
            }
            return candidate
        }
    }
}
