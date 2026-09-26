import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// Which actions the Meetings window offers (docs/meeting-design.md §5.8): the rules of the commands behind them.

private func actionSummary(state: SessionState = .complete, manifestStatus: String? = nil,
                           transcriptID: String? = UUID().uuidString, transcriptRefused: Bool = false,
                           speakers: SpeakerLabelState = .labelled, liveness: RecorderLiveness = .exited,
                           chunkCount: Int = 20, derivedBytes: Int64 = 0, audioDeleted: Bool = false) -> SessionSummary {
    let id = UUID().uuidString
    return SessionSummary(
        id: id, directory: URL(fileURLWithPath: "/tmp/\(id).holos", isDirectory: true), name: "Council",
        createdAt: Date(), source: .microphone, state: state, manifestStatus: manifestStatus ?? state.rawValue,
        savedSeconds: 600, chunkCount: chunkCount, transcriptID: transcriptID,
        transcriptProblem: transcriptID == nil && transcriptRefused ? "newer" : nil,
        transcriptRefused: transcriptRefused, speakerState: speakers, liveness: liveness,
        derivedBytes: derivedBytes, audioDeleted: audioDeleted)
}

@Test func recoverFollowsTheRecoverCommand() {
    typealias Policy = MeetingActionPolicy
    // Interrupted (a dead recorder's manifest, or one recovery marked): recover rebuilds or labels.
    #expect(Policy.recovers(actionSummary(state: .interrupted, manifestStatus: ArchiveStatus.recording)))
    #expect(Policy.recovers(actionSummary(state: .interrupted, manifestStatus: ArchiveStatus.processing)))
    #expect(Policy.recovers(actionSummary(state: .interrupted)))
    #expect(Policy.recovers(actionSummary(state: .recovered)), "A rebuild recover repeats idempotently.")
    // Transcription unfinished at stop: only while the saved transcript cannot be read.
    for state in [SessionState.transcriptionIncomplete, .incomplete] {
        #expect(!Policy.recovers(actionSummary(state: state)), "\(state) keeps a readable transcript.")
        #expect(Policy.recovers(actionSummary(state: state, transcriptID: nil)), "\(state) with none is rebuilt.")
        #expect(!Policy.recovers(actionSummary(state: state, transcriptID: nil, transcriptRefused: true)),
                "\(state) with a transcript from a newer version of Voice is Local is refused.")
    }
    #expect(!Policy.recovers(actionSummary(state: .interrupted, transcriptID: nil, transcriptRefused: true)))
    for state in [SessionState.complete, .audioOnly, .failed, .damaged] {
        #expect(!Policy.recovers(actionSummary(state: state, transcriptID: nil)), "\(state)")
    }
}

@Test func labelSpeakersFollowsTheDiarizeCommand() {
    typealias Policy = MeetingActionPolicy
    for speakers in [SpeakerLabelState.none, .notLabelled, .failed, .interrupted] {
        #expect(Policy.labels(actionSummary(speakers: speakers)), "\(speakers)")
        #expect(!Policy.labels(actionSummary(transcriptID: nil, speakers: speakers)), "\(speakers) without transcript")
        #expect(!Policy.labels(actionSummary(speakers: speakers, audioDeleted: true)), "\(speakers) without audio")
        #expect(!Policy.labels(actionSummary(state: .interrupted, speakers: speakers)), "Recover labels those.")
    }
    for speakers in [SpeakerLabelState.labelled, .running, .unreadable] {
        #expect(!Policy.labels(actionSummary(speakers: speakers)), "\(speakers)")
    }
}

@Test func labelSpeakersIsOfferedWhileAMissedLanguageCanBeDetected() {
    typealias Policy = MeetingActionPolicy
    func summary(_ work: LanguageWork?, speakers: SpeakerLabelState = .labelled, state: SessionState = .complete,
                 audioDeleted: Bool = false, transcriptID: String? = UUID().uuidString) -> SessionSummary {
        var summary = actionSummary(state: state, transcriptID: transcriptID, speakers: speakers,
                                    audioDeleted: audioDeleted)
        summary.languageWork = work
        return summary
    }
    let ready = LanguageWork(languages: ["es-ES"], ready: true)
    // Labelled speakers: offered once `session diarize` would detect the language (its model is installed now).
    #expect(Policy.labels(summary(ready)))
    #expect(Policy.enabled(summary(ready), inUse: false, hasExport: false).contains(.labelSpeakers))
    #expect(!Policy.labels(summary(LanguageWork(languages: ["es-ES"]))), "Its speech model is still missing.")
    #expect(!Policy.labels(summary(LanguageWork(languages: ["es-ES"], labelsEdited: true))),
            "Edited labels: only session languages --force detects it.")
    #expect(!Policy.labels(summary(nil)))
    // The command's other conditions still hold.
    #expect(!Policy.labels(summary(ready, audioDeleted: true)))
    #expect(!Policy.labels(summary(ready, transcriptID: nil)))
    #expect(!Policy.labels(summary(ready, state: .interrupted)), "Recover labels those.")
    #expect(!Policy.labels(summary(ready, speakers: .unreadable)), "Recover replaces unreadable speaker files.")
    #expect(!Policy.enabled(summary(ready, speakers: .running), inUse: false, hasExport: false)
        .contains(.labelSpeakers))
}

@Test func languageWorkSaysWhatToDo() {
    #expect(LanguageWork(languages: ["es-ES"], ready: true).message
        == "Spanish (Spain) is missing from the transcript. Choose Label Speakers to detect the languages again.")
    #expect(LanguageWork(languages: ["en-CA", "es-ES"], labelsEdited: true).message?.hasPrefix(
        "English (Canada) and Spanish (Spain) are missing from the transcript. Speaker labels were edited, so Label "
            + "Speakers does not detect the languages again.") == true)
    #expect(LanguageWork(languages: ["es-ES"]).message == nil, "The record's message says why and what to install.")
}

@Test func meetingActionsAreOffWhileTheMeetingIsInUseOrLive() {
    let summary = actionSummary(state: .interrupted, speakers: .none, derivedBytes: 10)
    let all = MeetingActionPolicy.enabled(summary, inUse: false, hasExport: true)
    #expect(all == [.recover, .showInFinder, .openTranscript, .saveTranscript, .deleteAudio, .deleteMeeting, .cleanUp])
    // The app works on it (a command, Clean Up, Save Transcript As…, the automatic relabel).
    #expect(MeetingActionPolicy.enabled(summary, inUse: true, hasExport: true) == [.showInFinder, .openTranscript])
    // Another process holds it: nothing that takes the lease.
    for liveness in [RecorderLiveness.capturing, .processing, .maintenance] {
        var live = summary
        live.liveness = liveness
        #expect(MeetingActionPolicy.enabled(live, inUse: false, hasExport: false)
            == [.showInFinder, .saveTranscript], "\(liveness)")
    }
    var labelling = actionSummary(speakers: .running)
    labelling.liveness = .dead
    #expect(!MeetingActionPolicy.enabled(labelling, inUse: false, hasExport: false).contains(.deleteMeeting))
    #expect(MeetingActionPolicy.enabled(nil, inUse: false, hasExport: false).isEmpty)
    // Delete Audio needs audio; Clean Up needs renders.
    let gone = MeetingActionPolicy.enabled(actionSummary(audioDeleted: true), inUse: false, hasExport: false)
    #expect(!gone.contains(.deleteAudio) && !gone.contains(.cleanUp) && gone.contains(.deleteMeeting))
    #expect(!MeetingActionPolicy.enabled(actionSummary(state: .damaged, transcriptID: nil), inUse: false,
                                         hasExport: false).contains(.deleteAudio))
}

/// The Recover button and `voiceislocal session recover` agree on real sessions: the catalog's summary of a
/// transcriptionIncomplete meeting whose transcript is unreadable (the revision is missing) enables Recover, and the
/// command rebuilds it; a readable transcript is kept by both; one from a newer version of Voice is Local is refused by both.
@Test func recoverButtonAgreesWithTheCommandOnSavedSessions() async throws {
    let temp = try TemporaryDirectory("actions")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: temp.url, transcript: transcript)
    do {
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        try await archive.finish(status: ArchiveStatus.transcriptionIncomplete)
    }
    func agree() throws -> Bool {
        let summary = SessionCatalog.summary(session: session)
        let command = try SessionRecoveryCommand.rebuilds(status: summary.manifestStatus, session: session)
        #expect(MeetingActionPolicy.recovers(summary) == command)
        return command
    }
    #expect(try !agree(), "A readable transcript is kept.")

    try FileManager.default.removeItem(at: SessionPaths.transcript(transcript.id, in: session))
    let unreadable = SessionCatalog.summary(session: session)
    #expect(unreadable.transcriptID == nil && unreadable.transcriptProblem != nil && !unreadable.transcriptRefused)
    #expect(unreadable.state == .transcriptionIncomplete)
    #expect(try agree(), "An unreadable transcript is rebuilt.")
    #expect(MeetingActionPolicy.enabled(unreadable, inUse: false, hasExport: false).contains(.recover))

    try AtomicFile.writeJSON(TranscriptPointer(schemaVersion: 99, transcriptID: transcript.id),
                             to: SessionPaths.transcriptPointer(session))
    let newer = SessionCatalog.summary(session: session)
    #expect(newer.transcriptRefused)
    #expect(!MeetingActionPolicy.recovers(newer))
    #expect(throws: (any Error).self) { try SessionRecoveryCommand.rebuilds(status: newer.manifestStatus,
                                                                            session: session) }
}
