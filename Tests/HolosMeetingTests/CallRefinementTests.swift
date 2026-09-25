import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// Online-call refinements (docs/meeting-design.md §5.11, PR11): the echo filter in post-processing. (The echoRisk
// warning is gone: meetings record the microphone and the computer's audio without warning about it.)

// MARK: - Helpers

/// A finished call: the system track has two speakers taking 5 s turns (`SessionFixtures.alternatingSegments`), and
/// the microphone heard system turn 1 again 0.3 s later (echo), then its own words at 12 s.
private func echoCall(in root: URL, othersInRoom: Bool) async throws
    -> (session: URL, echo: TranscriptSegment, own: TranscriptSegment) {
    let system = SessionFixtures.alternatingSegments(track: "system")
    let echo = SessionFixtures.segment(system[0].words.map(\.text), track: "mic", start: system[0].start + 0.3)
    let own = SessionFixtures.segment(["thanks", "everyone", "for", "joining"], track: "mic", start: 12)
    let session = try await SessionFixtures.makeSession(
        in: root, source: .microphoneAndSystem, audioSeconds: ["mic": 20, "system": 20], mode: .call,
        othersInRoom: othersInRoom, transcript: SessionFixtures.transcript(system + [echo, own]))
    return (session, echo, own)
}

// MARK: - Post-processing

@Test func inPersonSessionsDoNotFilter() {
    let meeting = MeetingInfo(sessionID: "SESSION", mode: .inPerson, othersInRoom: false, createdAt: SessionFixtures.date)
    let parameters = SpeakerAnalysis.alignmentParameters(meeting: meeting)
    #expect(parameters == .v1)
    #expect(parameters.echoWindowSeconds == nil)
    // Even words that look exactly like echo stay.
    let transcript = SessionFixtures.transcript([
        SessionFixtures.segment(["we", "should", "vote", "now"], track: "system", start: 10),
        SessionFixtures.segment(["we", "should", "vote", "now"], track: "mic", start: 10.3),
    ])
    #expect(EchoFilter.echoSpans(transcript: transcript, parameters: parameters).isEmpty)
}

@Test func callSessionsFilterEchoWithinOneSecond() {
    for othersInRoom in [false, true] {
        let meeting = MeetingInfo(sessionID: "SESSION", mode: .call, othersInRoom: othersInRoom,
                                  createdAt: SessionFixtures.date)
        var expected = AlignmentParameters.v1
        expected.echoWindowSeconds = 1.0
        #expect(SpeakerAnalysis.alignmentParameters(meeting: meeting) == expected)
    }
    // Archives from before meeting.json: a recording with system audio counts as a call.
    let inferred = MeetingInfo.inferred(sessionID: "SESSION", source: .microphoneAndSystem, createdAt: SessionFixtures.date)
    #expect(SpeakerAnalysis.alignmentParameters(meeting: inferred).echoWindowSeconds == 1.0)
}

/// Without others in the room: the microphone's echo of the call leaves "Me", the run lists it, and the exports show
/// the phrase once.
@Test(.timeLimit(.minutes(1)))
func callPostProcessingLeavesEchoOut() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, echo, own) = try await echoCall(in: temp.url, othersInRoom: false)
    let diarizer = FakeDiarizer(outputs: ["system": SessionFixtures.alternatingOutput()])
    let record = try await MeetingPostProcessor(diarizer: diarizer, freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.alignment.parameters.echoWindowSeconds == 1.0)
    #expect(run.droppedWords == [DroppedWords(spans: [WordSpan(segmentID: echo.id, first: 0, end: echo.words.count)],
                                              reason: "echo")])
    let mine = run.turns.filter { $0.track == "mic" }
    #expect(mine.map(\.speakerID) == ["mic:me"])
    #expect(mine.flatMap(\.spans) == [WordSpan(segmentID: own.id, first: 0, end: own.words.count)])

    let phrase = echo.words.map(\.text).joined(separator: " ")
    for ext in ["md", "txt", "json"] {
        let text = SessionFixtures.text(SessionPaths.export(ext, in: session))
        #expect(text.components(separatedBy: phrase).count == 2, "transcript.\(ext) has the phrase once.")
        #expect(text.contains("thanks everyone for joining"))
    }
}

/// A hybrid call (H16): the microphone track is diarized, and the cluster the diarizer made of the call heard through
/// the speakers is no speaker.
@Test(.timeLimit(.minutes(1)))
func hybridCallHidesTheEchoCluster() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let (session, echo, own) = try await echoCall(in: temp.url, othersInRoom: true)
    let mic = DiarizerOutput(
        segments: [RawDiarizationSegment(speaker: "S2", start: 0.5, end: 4.5),
                   RawDiarizationSegment(speaker: "S1", start: 11.5, end: 15)],
        centroids: ["S1": FloatVector([1, 0, 0, 0, 0, 0, 0, 0]), "S2": FloatVector([0, 1, 0, 0, 0, 0, 0, 0])],
        windows: [], processingSeconds: 0)
    let diarizer = FakeDiarizer(outputs: ["system": SessionFixtures.alternatingOutput(), "mic": mic])
    let record = try await MeetingPostProcessor(diarizer: diarizer, freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    #expect(record.othersInRoom == true)
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.droppedWords.first?.spans == [WordSpan(segmentID: echo.id, first: 0, end: echo.words.count)])
    #expect(run.speakers.map(\.id) == ["system:S1", "system:S2", "mic:S1"])
    #expect(run.turns.filter { $0.track == "mic" }.map(\.speakerID) == ["mic:S1"])
    #expect(run.turns.filter { $0.track == "mic" }.flatMap(\.spans)
        == [WordSpan(segmentID: own.id, first: 0, end: own.words.count)])
    let markdown = SessionFixtures.text(SessionPaths.export("md", in: session))
    #expect(markdown.components(separatedBy: echo.words.map(\.text).joined(separator: " ")).count == 2)
}
