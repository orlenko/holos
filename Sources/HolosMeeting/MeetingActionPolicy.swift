import Foundation
import HolosCore

/// Which actions the Meetings window offers for the selected meeting (docs/meeting-design.md §5.8). Each rule is the
/// one the command behind the button applies, so a button is never enabled for a meeting its command refuses, nor
/// disabled for one its command would repair. Pure.
public enum MeetingActionPolicy {
    public enum Action: String, CaseIterable, Sendable {
        case recover, labelSpeakers, showInFinder, openTranscript, saveTranscript, deleteAudio, deleteMeeting, cleanUp
        case rename
    }

    /// The enabled actions for `summary` (nil: nothing selected). `inUse`: the app is working on the meeting
    /// (`MeetingController.sessionsInUse`); `hasExport`: exports/transcript.md is a regular file; `transcriptFiles`: any
    /// transcript file (Markdown, JSON, text) is there, as Rename checks it (`SessionExports.hasTranscriptFiles`;
    /// nil: `hasExport`).
    ///
    /// Show in Finder and Open Transcript take no lock. Every other action is off while the app works on the meeting.
    /// The ones that take the processing lease (Recover, Label Speakers, Delete Audio, Delete Meeting, Clean Up,
    /// Rename) are also off while another process holds the meeting (`isLive`), which would refuse them.
    public static func enabled(_ summary: SessionSummary?, inUse: Bool, hasExport: Bool,
                               transcriptFiles: Bool? = nil) -> Set<Action> {
        guard let summary else { return [] }
        var actions: Set<Action> = [.showInFinder]
        if hasExport { actions.insert(.openTranscript) }
        guard !inUse else { return actions }
        if summary.transcriptID != nil { actions.insert(.saveTranscript) }
        guard !isLive(summary) else { return actions }
        if recovers(summary) { actions.insert(.recover) }
        if labels(summary) { actions.insert(.labelSpeakers) }
        if deletesAudio(summary) { actions.insert(.deleteAudio) }
        actions.insert(.deleteMeeting)
        if summary.derivedBytes > 0 { actions.insert(.cleanUp) }
        if renameRefusal(summary, hasExport: transcriptFiles ?? hasExport) == nil { actions.insert(.rename) }
        return actions
    }

    /// `voiceislocal session rename` can rename the meeting (`SessionRenameCommand`): it is finished by the predicate
    /// summaries and final transcripts use (`MeetingSummarySchedule.isFinished`), so not still saving, interrupted
    /// (Recover first), incomplete, failed or damaged, and its current transcript, if any, can be read (the command
    /// refuses one that is damaged, from a newer build, or unreadable now).
    public static func renames(_ summary: SessionSummary) -> Bool {
        renameRefusal(summary) == nil
    }

    /// Why Rename is off for `summary` (its tooltip), or nil when the command would rename it; holding the meeting
    /// (in use, live) is said elsewhere.
    ///
    /// `hasExport`: transcript files are there, which a meeting without a current transcript cannot rewrite.
    public static func renameRefusal(_ summary: SessionSummary, hasExport: Bool = false) -> String? {
        guard MeetingSummarySchedule.isFinished(summary.state) else {
            return summary.state == .recording || summary.state == .processing
                ? "The meeting can be renamed once it is saved."
                : "The meeting was not saved properly; Recover it first, then rename it."
        }
        if let job = summary.jobInProgress {
            return job + " Rename it when that is done."
        }
        // As for the export record: without a transcript and transcript files the summary does not matter.
        if let problem = summary.summaryProblem,
           summary.transcriptID != nil || summary.transcriptProblem != nil || hasExport {
            if problem.contains("newer version") {
                return "Its summary was written by a newer version of Voice is Local, so its transcript files cannot "
                    + "follow a new name; update Voice is Local to rename it."
            }
            return "Its summary cannot be read now, so its transcript files cannot follow a new name; try again "
                + "later. \(problem)"
        }
        // A meeting without a transcript and transcript files is renamed without touching them: their record does not
        // matter then.
        if let problem = summary.exportsProblem,
           summary.transcriptID != nil || summary.transcriptProblem != nil || hasExport {
            if problem.contains("newer version") {
                return "Its transcript files were written by a newer version of Voice is Local, so they cannot follow "
                    + "a new name; update Voice is Local to rename it."
            }
            return "The record of its transcript files cannot be read now, so they cannot follow a new name; try "
                + "again later. \(problem)"
        }
        if summary.transcriptID == nil, summary.transcriptProblem == nil, hasExport {
            return "Its transcript is missing but its transcript files exist, so they cannot follow a new name; "
                + "Recover it first."
        }
        if let problem = summary.metadataProblem {
            return "Its meeting.json, which records where the name came from, cannot be read: \(problem)"
        }
        if let problem = summary.transcriptProblem {
            if summary.transcriptRefused, problem.localizedCaseInsensitiveContains("newer") {
                return "Its transcript was written by a newer version of Voice is Local, so its transcript files "
                    + "cannot follow a new name: \(problem)"
            }
            return "Its transcript cannot be read, so its transcript files cannot follow a new name: \(problem)"
        }
        return nil
    }

    /// A recorder or another Holos command holds the meeting (its writer lock or processing lease): recording,
    /// saving, labelling, or a maintenance command run elsewhere.
    public static func isLive(_ summary: SessionSummary) -> Bool {
        summary.state == .recording || summary.state == .processing || summary.speakerState == .running
            || summary.liveness == .capturing || summary.liveness == .processing || summary.liveness == .maintenance
    }

    /// `voiceislocal session recover` (without `--force`) repairs the meeting: it rebuilds the transcript
    /// (`SessionRecoveryCommand.rebuilds`, asked with the catalog's readable transcript), or the meeting is
    /// interrupted, which recovery marks it and then either rebuilds or labels the transcript saved at stop. An
    /// `incomplete` or `transcriptionIncomplete` meeting qualifies only while its current transcript cannot be read;
    /// one it can read keeps it, and recover would change nothing. Refused for a manifest that cannot be read
    /// (`damaged`) and a transcript written by a newer Holos or that cannot be read now (`transcriptRefused`).
    ///
    /// A transcript that a rebuild saved but could not record looks like the recorder's here (telling them apart takes
    /// the event journal); the recover that left it said to run `voiceislocal session recover` again.
    public static func recovers(_ summary: SessionSummary) -> Bool {
        guard summary.state != .damaged, !summary.transcriptRefused else { return false }
        if summary.state == .interrupted { return true }
        return SessionRecoveryCommand.rebuilds(status: summary.manifestStatus) { summary.transcriptID }
    }

    /// `voiceislocal session diarize` labels the meeting: its speaker state is none, notLabelled, failed, or
    /// interrupted, or (for labelled speakers too) a language of a meeting in several was missed and can be detected
    /// now (`LanguageWork.ready`: `session diarize` detects it first, also without speaker models,
    /// docs/meeting-design.md §4.14); it has a readable transcript and its audio, and it is not an interrupted
    /// recording (Recover rebuilds and labels that). Speaker files that cannot be read (`unreadable`) are left to
    /// Recover.
    public static func labels(_ summary: SessionSummary) -> Bool {
        let states: Set<SpeakerLabelState> = [.none, .notLabelled, .failed, .interrupted]
        let languagesReady = summary.languageWork?.ready == true && summary.speakerState != .unreadable
        return (states.contains(summary.speakerState) || languagesReady) && summary.transcriptID != nil
            && !summary.audioDeleted && summary.state != .interrupted && summary.state != .damaged
    }

    /// `voiceislocal session delete --audio-only` has audio to delete: the manifest reads and lists chunks, and the audio was
    /// not deleted already.
    public static func deletesAudio(_ summary: SessionSummary) -> Bool {
        summary.state != .damaged && !summary.audioDeleted && summary.chunkCount > 0
    }
}
