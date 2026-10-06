import Foundation
import HolosCore
import HolosStorage

/// The app's catch-up of acoustic echo analyses (docs/meeting-design.md §5.11, "Catching up in the app"): every
/// finished call whose analysis is needed (`EchoAnalysisStage.needed`: missing, or of other audio or an older analysis
/// version) gets `voiceislocal session echo-analyze`, run by the app in the background one meeting at a time, newest
/// first. Nothing records the work: the queue is worked out from the files at each launch (and after each meeting is
/// saved), so a run a quit cut short is simply needed again at the next launch. Pure, apart from `scan`, which reads
/// the meetings' files.
public enum EchoCatchUpSchedule {
    /// A meeting whose analysis is needed.
    public struct Candidate: Sendable, Equatable {
        public var sessionID: String
        /// The session folder's path when it was found.
        public var path: String
        public var createdAt: Date

        public init(sessionID: String, path: String, createdAt: Date) {
            self.sessionID = sessionID; self.path = path; self.createdAt = createdAt
        }
    }

    /// One meeting as the scan sees it, for `select`.
    public struct Found: Sendable, Equatable {
        public var candidate: Candidate
        /// Saved (complete, recovered, transcription incomplete, or audio only), with its audio
        /// (`DeepTranscriptionSchedule.isFinished`): one still recording, saving or interrupted waits for its own
        /// post-processing or Recover, which make the analysis themselves.
        public var finished: Bool
        /// `EchoAnalysisStage.needed`: a call with microphone and system audio and no saved analysis of it.
        public var needed: Bool

        public init(candidate: Candidate, finished: Bool, needed: Bool) {
            self.candidate = candidate; self.finished = finished; self.needed = needed
        }
    }

    /// The meetings that get the analysis, newest first (ties by session ID, as the Meetings list orders them).
    public static func select(_ found: [Found]) -> [Candidate] {
        ordered(found.filter { $0.finished && $0.needed }.map(\.candidate))
    }

    /// Newest first: the meeting the user most likely opens next is fixed first.
    public static func ordered(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { left, right in
            left.createdAt != right.createdAt ? left.createdAt > right.createdAt : left.sessionID < right.sessionID
        }
    }

    /// Reads every meeting under `root` (`SessionCatalog.list`) and returns the ones that get the analysis, newest
    /// first (`needsAnalysis`, with `profiles` for the voice samples). Off the main actor: it reads each call's
    /// manifest and saved analysis.
    public static func scan(root: URL, profiles: SpeakerProfileStore? = nil) -> [Candidate] {
        select(SessionCatalog.list(root: root).map { summary in
            let finished = DeepTranscriptionSchedule.isFinished(summary.state, audioDeleted: summary.audioDeleted)
            return Found(candidate: Candidate(sessionID: summary.id, path: summary.directory.path,
                                              createdAt: summary.createdAt),
                         finished: finished,
                         needed: finished && needsAnalysis(session: summary.directory, profiles: profiles))
        })
    }

    /// Whether the meeting still needs its analysis (`EchoAnalysisStage.needed`), read again just before a run starts:
    /// a relabel, Recover or a run in Terminal may have made it since the scan.
    /// Whether `voiceislocal session echo-analyze` has work to do on `session`: the analysis is needed
    /// (`EchoAnalysisStage.needed`), or it is saved but the transcript files were not rewritten for it
    /// (`SessionExports.echoMaskIsCurrent`) or a voice sample learned from the meeting was not brought in step with it
    /// (`VoiceProfileService.samplesOutOfStep`, with `profiles`): a run cut short after saving the mask, or one whose
    /// rewrite or refresh failed. Run again, the command keeps the saved analysis and finishes the rest.
    public static func needsAnalysis(session: URL, profiles: SpeakerProfileStore? = nil) -> Bool {
        if EchoAnalysisStage.needed(session: session) { return true }
        guard let manifest = try? SessionArchive.readManifest(at: session),
              let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest),
              EchoAnalysisStage.applies(meeting: meeting, manifest: manifest),
              !EchoAnalysisStage.renderTracks(manifest: manifest).isEmpty,
              (try? SessionFiles.audioDeleted(session: session, sessionID: manifest.id)) == false,
              case .current = EchoAnalysisStage.saved(session: session, manifest: manifest) else { return false }
        if !SessionExports.echoMaskIsCurrent(session: session) { return true }
        guard let profiles else { return false }
        return VoiceProfileService.samplesOutOfStep(session: session, store: profiles)
    }

    public struct Situation: Sendable, Equatable {
        /// A meeting is starting, recording, or saving: it has the Mac to itself.
        public var meetingBusy: Bool
        /// Another background job runs: this app's final transcript or summary, or any process's
        /// (`DeepTranscriptionLock` held). One at a time.
        public var otherJobRunning: Bool
        /// Work the user asked for is about to start (Make Final Transcript Now ready to run, or a Summarize Again the
        /// summary scan going on may start): it goes first.
        public var askedForWorkWaiting: Bool
        /// The meeting this app analyses now, if any.
        public var running: String?
        /// Meetings another command of the app works on, and meetings open (or opening, or saving) in Review, which
        /// owns their labels until it closes: they wait.
        public var inUse: Set<String>
        /// Meetings whose run failed in this launch: not tried again until the next launch.
        public var failed: Set<String>
        /// Meetings whose run was turned down for now (another process held the meeting): skipped until then.
        public var delayedUntil: [String: Date]
        public var now: Date

        public init(meetingBusy: Bool = false, otherJobRunning: Bool = false, askedForWorkWaiting: Bool = false,
                    running: String? = nil, inUse: Set<String> = [], failed: Set<String> = [],
                    delayedUntil: [String: Date] = [:], now: Date = Date()) {
            self.meetingBusy = meetingBusy; self.otherJobRunning = otherJobRunning
            self.askedForWorkWaiting = askedForWorkWaiting; self.running = running; self.inUse = inUse
            self.failed = failed; self.delayedUntil = delayedUntil; self.now = now
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Analyse this meeting now.
        case run(Candidate)
        /// A meeting is ready, but a meeting, another job, or work the user asked for goes first.
        case wait
        /// Nothing is ready: the queue is empty, or every meeting in it is in use, delayed, or failed.
        case idle
    }

    /// The queued meetings that could run were nothing else going on, in queue order: not running, not in use or
    /// under review, not failed in this launch, and not delayed. The final transcript and summary schedulers ask this
    /// to let an automatic job wait while echo work is ready.
    public static func ready(_ queue: [Candidate], _ situation: Situation) -> [Candidate] {
        queue.filter { candidate in
            candidate.sessionID != situation.running && !situation.inUse.contains(candidate.sessionID)
                && !situation.failed.contains(candidate.sessionID)
                && (situation.delayedUntil[candidate.sessionID].map { $0 <= situation.now } ?? true)
        }
    }

    /// The next run: none while one runs; else the first ready meeting (the queue is newest first), unless a meeting
    /// is busy, another background job runs, or work the user asked for waits (then `wait`).
    public static func next(_ queue: [Candidate], _ situation: Situation) -> Decision {
        guard situation.running == nil, let first = ready(queue, situation).first else { return .idle }
        guard !situation.meetingBusy, !situation.otherJobRunning, !situation.askedForWorkWaiting else { return .wait }
        return .run(first)
    }

    /// What becomes of a meeting whose run ended.
    public enum RunEnd: Sendable, Equatable {
        /// Analysed (or found current): off the queue.
        case done
        /// Off the queue, and not tried again in this launch; the text says why, for the Meetings list.
        case failed(String)
        /// Exit 3: the analysis was saved (so it is no longer needed), but the transcript files or a voice sample were
        /// not brought in step; the command's summary says which, for the Meetings list.
        case partial(String)
        /// Turned down for now: another process held the meeting, or it records again. Stays queued, tried again
        /// after `retryDelay`.
        case retryLater
    }

    /// What a run that exited with `code` comes to. `summary` is the command's `--json` summary, `errors` its error
    /// output. A run the app did not see end (a quit) is not reported: the files say the
    /// analysis is still needed at the next launch.
    public static func runEnded(code: Int32, summary: String?, errors: String) -> RunEnd {
        if code == 0 { return .done }
        if code == 1, errors.contains("processing this session") || errors.contains("still recording") {
            return .retryLater
        }
        if code == 3 { return .partial(summary ?? "") }
        return .failed(DeepTranscriptionSchedule.failureText(code: code, record: nil, errors: errors))
    }

    /// How long a meeting turned down `attempts` times in a row waits: a minute, doubling each time, at most 30
    /// minutes, so a meeting another process holds for long is not retried every tick.
    public static func retryDelay(attempts: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(0, attempts - 1))), 1_800)
    }

    /// The Meetings list's badge of a queued meeting (the one running shows `runningText`, as its use of the meeting).
    public static let queuedText = "Echo removal queued"
    /// What the Meetings list shows while a meeting is analysed (`MeetingController.beginUsing`).
    public static let runningText = "Removing echo…"

    /// The badge texts of the queued meetings that wait (not the running one, nor failed ones), by session ID.
    public static func stateTexts(_ queue: [Candidate], running: String?, failed: Set<String>) -> [String: String] {
        var texts: [String: String] = [:]
        for candidate in queue where candidate.sessionID != running && !failed.contains(candidate.sessionID) {
            texts[candidate.sessionID] = queuedText
        }
        return texts
    }

    /// The Meetings list's status line for a meeting whose run did not finish in this launch, in the command's own
    /// words; nil for one that did.
    public static func problemText(_ end: RunEnd) -> String? {
        func sentence(_ text: String) -> String {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "" : " " + (text.hasSuffix(".") ? text : text + ".")
        }
        switch end {
        case .done, .retryLater:
            return nil
        case .failed(let reason):
            return "The call's echo was not removed from this meeting.\(sentence(reason)) Voice is Local tries again "
                + "the next time it starts."
        case .partial(let summary):
            return "The call's echo was removed from this meeting, but not everything was brought in step."
                + sentence(summary)
        }
    }
}
