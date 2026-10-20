import HolosCore
import Testing
@testable import HolosAppModel

@Test(arguments: [(-0.1, 0), (0.426, 42), (1.4, 100)])
func aStageProgressUsesABoundedPercentage(input: Double, expected: Int) {
    let view = MeetingProgressPresentation(.init(stage: .deepTranscription, fraction: input, message: ""))
    #expect(view.title == "Transcribing")
    #expect(view.percent == expected)
}

@Test(arguments: [Double.nan, .infinity, -.infinity])
func invalidProgressShowsActivityWithoutAPercentage(input: Double) {
    let view = MeetingProgressPresentation(.init(stage: .diarize, fraction: input, message: ""))
    #expect(view.title == "Identifying speakers")
    #expect(view.fraction == nil)
    #expect(view.percent == nil)
}

@Test func anUnknownStageStillShowsItsActivity() {
    let view = MeetingProgressPresentation(.init(stage: .init(rawValue: "future"), message: ""))
    #expect(view.title == "Processing")
    #expect(view.percent == nil)
}

@Test func progressNamesAPerTrackStepWhileDeepTranscriptionCombinesBothTracks() {
    let speakers = MeetingProgressPresentation(.init(stage: .diarize, track: "mic", fraction: 0.4, message: ""))
    #expect(speakers.title == "Identifying speakers (microphone)")
    let transcription = MeetingProgressPresentation(.init(stage: .deepTranscription, track: "system", fraction: 0.4, message: ""))
    #expect(transcription.title == "Transcribing")
}
