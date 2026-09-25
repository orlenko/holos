import Foundation
import HolosCore

/// Which actions the Meetings window offers for the selected meeting (docs/meeting-design.md §5.8). Each rule is the
/// one the command behind the button applies, so a button is never enabled for a meeting its command refuses, nor
/// disabled for one its command would repair. Pure.
public enum MeetingActionPolicy {
    public enum Action: String, CaseIterable, Sendable {
        case recover, labelSpeakers, showInFinder, openTranscript, saveTranscript, deleteAudio, deleteMeeting, cleanUp
    }

    /// The enabled actions for `summary` (nil: nothing selected). `inUse`: the app is working on the meeting
    /// (`MeetingController.sessionsInUse`); `hasExport`: exports/transcript.md is a regular file.
    ///
    /// Show in Finder and Open Transcript take no lock. Every other action is off while the app works on the meeting.
    /// The ones that take the processing lease (Recover, Label Speakers, Delete Audio, Delete Meeting, Clean Up) are
    /// also off while another process holds the meeting (`isLive`), which would refuse them.
    public static func enabled(_ summary: SessionSummary?, inUse: Bool, hasExport: Bool) -> Set<Action> {
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
        return actions
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

    /// `voiceislocal session diarize` labels the meeting: its speaker state is none, notLabelled, failed, or interrupted, it
    /// has a readable transcript and its audio, and it is not an interrupted recording (Recover rebuilds and labels
    /// that).
    public static func labels(_ summary: SessionSummary) -> Bool {
        let states: Set<SpeakerLabelState> = [.none, .notLabelled, .failed, .interrupted]
        return states.contains(summary.speakerState) && summary.transcriptID != nil && !summary.audioDeleted
            && summary.state != .interrupted && summary.state != .damaged
    }

    /// `voiceislocal session delete --audio-only` has audio to delete: the manifest reads and lists chunks, and the audio was
    /// not deleted already.
    public static func deletesAudio(_ summary: SessionSummary) -> Bool {
        summary.state != .damaged && !summary.audioDeleted && summary.chunkCount > 0
    }
}
