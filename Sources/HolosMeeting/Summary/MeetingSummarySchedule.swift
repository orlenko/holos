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
        /// The Summarize Again request summary.json was made for (`MeetingSummaryRecord.answersRequest`), if any.
        public var summaryAnswersRequest: String?
        /// summary.json's key is the meeting's (`MeetingSummaryKey.isCurrent`: this transcript, these speakers' names).
        public var summaryCurrent: Bool
        /// The meeting's key (`MeetingSummaryKey.text`): what a run that failed is remembered by.
        public var key: String?
        /// summary.json, or a file the summary is made from (the transcript, the speaker labels, meeting.json), was
        /// written by a newer Voice is Local, or the transcript files are left to rewrite and exports/.generated.json
        /// was: the meeting is left alone (only a Summarize Again the user asks for runs, and reports why it cannot).
        public var summaryFromNewerVersion: Bool

        /// `summaryCurrent` nil: the summary is current when it is of the current transcript; `key` nil: the
        /// transcript ID.
        public init(sessionID: String, path: String, createdAt: Date, transcriptID: String?,
                    summaryTranscriptID: String?, idle: Bool, finished: Bool = true, exportsPending: Bool = false,
                    summaryAnswersRequest: String? = nil, summaryCurrent: Bool? = nil, key: String? = nil,
                    summaryFromNewerVersion: Bool = false) {
            self.sessionID = sessionID; self.path = path; self.createdAt = createdAt
            self.transcriptID = transcriptID; self.summaryTranscriptID = summaryTranscriptID; self.idle = idle
            self.finished = finished; self.exportsPending = exportsPending; self.summaryAnswersRequest = summaryAnswersRequest
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
        /// A final transcript the user asked for (Make Final Transcript Now) is ready to run: asked-for work goes
        /// before automatic work, so only a summary the user asked for starts.
        public var askedForPassWaiting: Bool
        public var now: Date

        public init(enabled: Bool, modelAvailable: Bool, meetingBusy: Bool, deepPassRunning: Bool, running: String?,
                    inUse: Set<String> = [], attempted: [String: String] = [:], delayedUntil: [String: Date] = [:],
                    requested: [String] = [], onBattery: Bool = false, finalTranscriptQueued: Set<String> = [],
                    askedForPassWaiting: Bool = false, now: Date = Date()) {
            self.askedForPassWaiting = askedForPassWaiting
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
        // A final transcript the user asked for goes before automatic summaries.
        guard !situation.askedForPassWaiting else { return .wait }
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
        /// A random ID, new for each click (never a clock time, which can go back, nor a counter, which can be
        /// reset): the run made for it writes it into summary.json (`answersRequest`). A meeting has one request at a
        /// time (a new click replaces it), so the summary that answers it carries this ID.
        public var id: String

        public init(sessionID: String, id: String = UUID().uuidString) {
            self.sessionID = sessionID; self.id = id
        }

        private enum CodingKeys: String, CodingKey { case sessionID, id }

        /// A request saved before requests had IDs gets a new one: no summary answers it yet.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        }
    }

    /// The app's saved queue (`data`), and the data to save back at once when requests saved before they had IDs got
    /// theirs now (nil when none did): saved before anything can run, those IDs are the ones a run writes into
    /// summary.json, so a reload does not give them new ones that nothing answers.
    public static func decodeRequests(_ data: Data?) -> (requests: [Request], migrated: Data?) {
        struct Probe: Decodable { var id: String? }
        guard let data, let requests = try? HolosJSON.decoder().decode([Request].self, from: data) else {
            return ([], nil)
        }
        let probes = (try? HolosJSON.decoder().decode([Probe].self, from: data)) ?? []
        guard probes.contains(where: { $0.id == nil }) else { return (requests, nil) }
        return (requests, try? HolosJSON.encoder(pretty: false).encode(requests))
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
        keyChecked(session: session, sessionID: sessionID, transcriptID: transcriptID, profileNames: profileNames,
                   recognition: recognition, selfName: selfName).key
    }

    /// `key`, and whether it could not be worked out because a file was written by a newer Voice is Local (then the
    /// meeting is left alone, as its command would fail for good).
    static func keyChecked(session: URL, sessionID: String, transcriptID: String, profileNames: [String: String],
                           recognition: Bool, selfName: String) -> (key: MeetingSummaryKey?, newer: Bool) {
        // The echo analysis too (§5.11): the view the summary is made from hides the echo it finds.
        let inputs = transcriptID + "|" + SessionSummarizeCommand.speakerRevision(session) + "|"
            + MeetingPeopleCache.echoStamp(session) + "|"
            + voiceStamp(names: profileNames, recognition: recognition) + "|" + selfName
        if let cached = keyCache.withLock({ $0[sessionID] }), cached.inputs == inputs { return (cached.key, false) }
        do {
            let key = try MeetingSummaryKey.loadChecked(session: session, profileNames: profileNames,
                                                        applyRecognition: recognition, selfName: selfName)
            // Only a key that could be read is kept: a read that failed (a file busy or unreadable for now) is tried
            // again at the next scan.
            keyCache.withLock { $0[sessionID] = (inputs, key) }
            return (key, false)
        } catch {
            if case .unavailable? = error as? HolosError { return (nil, true) }
            return (nil, false)
        }
    }

    /// Milliseconds since 1970.
    public static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    /// The requests a summary already answers: summary.json is current, its files are written, and it was made for
    /// this request (`answersRequest` is its ID; a summary made for none answers none). A request saved before a quit
    /// whose command finished without the app is then not made again. No clock time or counter is compared, so
    /// neither a clock set back nor reset preferences can make an older summary answer a newer request.
    public static func satisfied(_ requests: [Request], by candidates: [Candidate]) -> Set<String> {
        var done: Set<String> = []
        for request in requests {
            guard let candidate = candidates.first(where: { $0.sessionID == request.sessionID }),
                  candidate.summaryCurrent, !candidate.exportsPending,
                  candidate.summaryAnswersRequest == request.id else { continue }
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
            let checked = transcriptID.map {
                Self.keyChecked(session: session, sessionID: manifest.id, transcriptID: $0, profileNames: profileNames,
                                recognition: recognition, selfName: selfName)
            }
            let key = checked?.key
            return Candidate(sessionID: manifest.id, path: session.path, createdAt: manifest.createdAt,
                             transcriptID: transcriptID, summaryTranscriptID: summary?.transcriptID,
                             idle: !active && !processing, finished: isFinished(state),
                             exportsPending: summary?.exportsPending == true,
                             summaryAnswersRequest: summary?.answersRequest,
                             summaryCurrent: key?.isCurrent(summary) ?? false, key: key?.text ?? transcriptID,
                             summaryFromNewerVersion: newer || checked?.newer == true
                                 || (summary?.exportsPending == true
                                     && SessionExports.recordIsFromNewerVersion(session: session)))
        }
    }
}
