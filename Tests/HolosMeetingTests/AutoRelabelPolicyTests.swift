import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// Which meeting is labelled again by itself (docs/meeting-design.md §5.8 "Automatic relabel").

private let relabelNow = Date(timeIntervalSince1970: 1_790_000_000)

private func relabelSummary(_ name: String, speakers: SpeakerLabelState = .interrupted, daysOld: Double = 1,
                            edited: Bool = false, message: String? = nil,
                            liveness: RecorderLiveness = .dead, state: SessionState = .complete,
                            origin: MeetingOrigin = .recorded, audioDeleted: Bool = false) -> SessionSummary {
    let id = UUID().uuidString
    return SessionSummary(
        id: id, directory: URL(fileURLWithPath: "/tmp/\(id).holos", isDirectory: true), name: name,
        createdAt: relabelNow.addingTimeInterval(-daysOld * 86_400), source: .microphone, origin: origin,
        state: state, manifestStatus: state.rawValue, savedSeconds: 600, chunkCount: 20,
        transcriptID: UUID().uuidString, speakerState: speakers, labelMessage: message, hasSpeakerEdits: edited,
        liveness: liveness, audioDeleted: audioDeleted)
}

@Test func autoRelabelPicksInterruptedRecentUnedited() {
    let pick = relabelSummary("interrupted, recent, unedited", daysOld: 1)
    let summaries = [
        relabelSummary("labelled", speakers: .labelled),
        relabelSummary("interrupted with edits", edited: true),
        relabelSummary("interrupted 10 days old", daysOld: 10),
        relabelSummary("not labelled: models missing", speakers: .notLabelled,
                       message: "No speaker labels: speaker models are not installed. Install them from Setup, or run holos setup --speakers."),
        pick,
    ]
    #expect(AutoRelabelPolicy.candidates(summaries, attempts: [:], modelsInstalled: true, meetingActive: false,
                                         now: relabelNow) == [pick])
}

@Test func autoRelabelWaitsForModelsAndIdle() {
    let session = relabelSummary("interrupted")
    #expect(AutoRelabelPolicy.candidates([session], attempts: [:], modelsInstalled: false, meetingActive: false,
                                         now: relabelNow).isEmpty)
    #expect(AutoRelabelPolicy.candidates([session], attempts: [:], modelsInstalled: true, meetingActive: true,
                                         now: relabelNow).isEmpty)
    #expect(AutoRelabelPolicy.candidates([session], attempts: [session.id: 2], modelsInstalled: true,
                                         meetingActive: false, now: relabelNow).isEmpty)
    #expect(AutoRelabelPolicy.candidates([session], attempts: [session.id: 1], modelsInstalled: true,
                                         meetingActive: false, now: relabelNow) == [session])
}

@Test func autoRelabelTakesNeverLabelledAndOtherNotLabelledReasons() {
    let never = relabelSummary("never labelled", speakers: .none, daysOld: 2)
    let disk = relabelSummary("no disk space", speakers: .notLabelled, daysOld: 3,
                              message: "Not enough disk space to label speakers. Free some space, then use Label Speakers.")
    #expect(AutoRelabelPolicy.candidates([disk], attempts: [:], modelsInstalled: true, meetingActive: false,
                                         now: relabelNow) == [disk])
    // At most one: the newest.
    #expect(AutoRelabelPolicy.candidates([disk, never], attempts: [:], modelsInstalled: true, meetingActive: false,
                                         now: relabelNow) == [never])
}

@Test func autoRelabelSkipsLiveImportedRecordingAndAudioless() {
    let summaries = [
        relabelSummary("labelling now", liveness: .processing),
        relabelSummary("maintenance", liveness: .maintenance),
        relabelSummary("imported", origin: .imported),
        relabelSummary("recording never recovered", state: .interrupted),
        relabelSummary("audio only", state: .audioOnly),
        relabelSummary("audio deleted", audioDeleted: true),
        relabelSummary("failed labelling", speakers: .failed),
    ]
    #expect(AutoRelabelPolicy.candidates(summaries, attempts: [:], modelsInstalled: true, meetingActive: false,
                                         now: relabelNow).isEmpty)
    let exited = relabelSummary("exited", liveness: .exited, state: .recovered)
    #expect(AutoRelabelPolicy.candidates([exited], attempts: [:], modelsInstalled: true, meetingActive: false,
                                         now: relabelNow) == [exited])
}
