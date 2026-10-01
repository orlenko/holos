import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Synchronization
import Testing

// The live transcript (docs/design.md "Live transcript"): volatile words, echo hiding, following the newest words,
// and what opening a meeting shows.

/// A segment of `text` whose words start `step` seconds apart from `start`, with their UTF-16 ranges.
private func segment(_ id: String, _ track: String, _ text: String, start: Double, step: Double = 0.3) -> TranscriptSegment {
    var words: [TimedWord] = []
    var offset = 0
    for (index, token) in text.split(separator: " ").enumerated() {
        let length = token.utf16.count
        let wordStart = start + Double(index) * step
        words.append(TimedWord(text: String(token), start: wordStart, end: wordStart + step - 0.05,
                               utf16Offset: offset, utf16Length: length))
        offset += length + 1
    }
    return TranscriptSegment(id: id, start: start, end: words.last.map(\.end) ?? start, text: text, words: words,
                             track: track)
}

private let callEcho = LiveTranscript.echoParameters(mode: .call)

private func texts(_ paragraphs: [LiveParagraph]) -> [String] {
    paragraphs.map { paragraph in
        paragraph.track + ": " + paragraph.runs.map { ($0.isFinal ? "" : "~") + $0.text }.joined(separator: " ")
    }
}

// MARK: - Volatile words

@Test func volatileWordsTurnFinal() {
    let heard = segment("v1", "mic", "the budget is", start: 2)
    let before = LiveTranscript.paragraphs(finals: [], volatile: ["mic": [heard]], echo: callEcho)
    #expect(texts(before) == ["mic: ~the budget is"])
    #expect(before[0].isFinal == false)

    // The final result replaced them; live.json still holds the stale hypothesis for a moment.
    let final = segment("f1", "mic", "the budget is approved", start: 2)
    let after = LiveTranscript.paragraphs(finals: [final], volatile: ["mic": [heard]], echo: callEcho)
    #expect(texts(after) == ["mic: the budget is approved"])
    #expect(after[0].runs[0].segmentID == "f1", "Final words keep their segment, the seam for live corrections.")

    // Volatile words after the final ones follow them in the same paragraph.
    let next = segment("v2", "mic", "approved with changes", start: 2.9)
    let later = LiveTranscript.paragraphs(finals: [final], volatile: ["mic": [next]], echo: callEcho)
    #expect(texts(later) == ["mic: the budget is approved ~with changes"])
    #expect(later[0].runs[1].segmentID == nil)
}

@Test func paragraphsFollowTracksAndPauses() {
    let finals = [
        segment("a", "system", "good morning everyone", start: 0),
        segment("b", "system", "let us begin", start: 1.2),
        segment("c", "mic", "thanks for joining", start: 3),
        segment("d", "mic", "one more thing", start: 20),
    ]
    let paragraphs = LiveTranscript.paragraphs(finals: finals, volatile: [:], echo: callEcho)
    #expect(texts(paragraphs) == [
        "system: good morning everyone let us begin", "mic: thanks for joining", "mic: one more thing",
    ])
    #expect(paragraphs.map(\.start) == [0, 3, 20])
}

// MARK: - Echo

@Test func micEchoOfTheCallIsHidden() {
    let remote = segment("s1", "system", "we should vote on the proposal today", start: 10)
    // The laptop speakers play it into the microphone 0.3 s later.
    let echo = segment("m1", "mic", "we should vote on the proposal today", start: 10.3)
    let paragraphs = LiveTranscript.paragraphs(finals: [remote, echo], volatile: [:], echo: callEcho)
    #expect(texts(paragraphs) == ["system: we should vote on the proposal today"])
}

@Test func echoIsHiddenWhileStillVolatile() {
    let remote = segment("s1", "system", "the next item is the schedule", start: 10)
    let heard = segment("vm", "mic", "the next item is", start: 10.4)
    let paragraphs = LiveTranscript.paragraphs(finals: [remote], volatile: ["mic": [heard]], echo: callEcho)
    #expect(texts(paragraphs) == ["system: the next item is the schedule"])
    // Both tracks still volatile.
    let both = LiveTranscript.paragraphs(
        finals: [], volatile: ["system": [segment("vs", "system", "the next item is", start: 10)], "mic": [heard]],
        echo: callEcho)
    #expect(texts(both) == ["system: ~the next item is"])
}

@Test func ownSpeechOverRemoteSpeechStays() {
    let remote = segment("s1", "system", "we should vote on the proposal today", start: 10)
    let mine = segment("m1", "mic", "sorry could you repeat that", start: 10.5)
    let paragraphs = LiveTranscript.paragraphs(finals: [remote, mine], volatile: [:], echo: callEcho)
    #expect(texts(paragraphs) == ["system: we should vote on the proposal today", "mic: sorry could you repeat that"])
}

@Test func ownWordsAroundEchoStay() {
    let remote = segment("s1", "system", "please send the report by friday", start: 10)
    let mixed = TranscriptSegment(
        id: "m1", start: 9, end: 13, text: "okay please send the report by friday sure",
        words: [
            TimedWord(text: "okay", start: 9.0, end: 9.2, utf16Offset: 0, utf16Length: 4),
            TimedWord(text: " please", start: 10.3, end: 10.5, utf16Offset: 4, utf16Length: 7),
            TimedWord(text: " send", start: 10.6, end: 10.8, utf16Offset: 11, utf16Length: 5),
            TimedWord(text: " the", start: 10.9, end: 11.1, utf16Offset: 16, utf16Length: 4),
            TimedWord(text: " report", start: 11.2, end: 11.4, utf16Offset: 20, utf16Length: 7),
            TimedWord(text: " by", start: 11.5, end: 11.7, utf16Offset: 27, utf16Length: 3),
            TimedWord(text: " friday", start: 11.8, end: 12.0, utf16Offset: 30, utf16Length: 7),
            TimedWord(text: " sure", start: 12.6, end: 12.8, utf16Offset: 37, utf16Length: 5),
        ],
        track: "mic")
    let paragraphs = LiveTranscript.paragraphs(finals: [remote, mixed], volatile: [:], echo: callEcho)
    #expect(texts(paragraphs) == ["mic: okay sure", "system: please send the report by friday"])
}

@Test func shortRepeatsAreNotEcho() {
    // Two words are below the filter's three-word run: a reply that repeats them stays.
    let remote = segment("s1", "system", "sounds good", start: 10)
    let reply = segment("m1", "mic", "sounds good", start: 10.4)
    let paragraphs = LiveTranscript.paragraphs(finals: [remote, reply], volatile: [:], echo: callEcho)
    #expect(texts(paragraphs) == ["system: sounds good", "mic: sounds good"])
}

@Test func micAheadOfTheSystemIsTheUser() {
    // Echo only follows the system audio: the same words a second earlier on the microphone are the user's.
    let mine = segment("m1", "mic", "we should vote on the proposal today", start: 9)
    let returned = segment("s1", "system", "we should vote on the proposal today", start: 10)
    let paragraphs = LiveTranscript.paragraphs(finals: [mine, returned], volatile: [:], echo: callEcho)
    #expect(texts(paragraphs).count == 2)
}

@Test func inPersonHidesNothing() {
    #expect(LiveTranscript.echoParameters(mode: .inPerson) == nil)
    #expect(LiveTranscript.echoParameters(mode: .call)?.echoWindowSeconds == SpeakerAnalysis.callEchoWindowSeconds)
    let remote = segment("s1", "system", "we should vote on the proposal today", start: 10)
    let echo = segment("m1", "mic", "we should vote on the proposal today", start: 10.3)
    let paragraphs = LiveTranscript.paragraphs(finals: [remote, echo], volatile: [:], echo: nil)
    #expect(paragraphs.count == 2)
}

// MARK: - Following the newest words

@Test func followingStopsWhenScrolledUpAndResumes() {
    var follow = LiveFollow()
    #expect(follow.following && !follow.showsJumpToLive && follow.scrollsToNewWords)
    follow.moved(distanceFromBottom: 10)
    #expect(follow.following, "Within the slack counts as the bottom.")
    follow.moved(distanceFromBottom: 400)
    #expect(!follow.following && follow.showsJumpToLive && !follow.scrollsToNewWords)
    follow.moved(distanceFromBottom: 0)
    #expect(follow.following, "Scrolling back to the bottom follows again.")
    follow.moved(distanceFromBottom: 400)
    follow.jumpToLive()
    #expect(follow.following && !follow.showsJumpToLive)
}

// MARK: - Opening a meeting

private func summary(_ id: String, state: SessionState = .complete, runID: String? = "R1",
                     speakers: SpeakerLabelState = .labelled) -> SessionSummary {
    SessionSummary(id: id, directory: URL(fileURLWithPath: "/tmp/\(id).holos"), name: "Meeting \(id)",
                   createdAt: Date(timeIntervalSince1970: 0), source: .microphoneAndSystem, state: state,
                   manifestStatus: "complete", speakerState: speakers, runID: runID, liveness: .exited)
}

@Test func openingAMeetingShowsWhatFitsIt() {
    let live = summary("A", state: .recording, runID: nil, speakers: .none)
    #expect(MeetingOpenPolicy.target(live, liveSessionID: "A", inUse: false, hasExport: false) == .live)
    // Recorded by the voiceislocal tool: the app does not follow it, but it is live.
    #expect(MeetingOpenPolicy.target(live, liveSessionID: nil, inUse: false, hasExport: false) == .live)
    // Saving after the stop: still the live transcript.
    let saving = summary("B", state: .processing, runID: nil, speakers: .running)
    #expect(MeetingOpenPolicy.target(saving, liveSessionID: "B", inUse: false, hasExport: false) == .live)
    #expect(MeetingOpenPolicy.target(saving, liveSessionID: nil, inUse: false, hasExport: true) == .transcript)
    let labelled = summary("C")
    #expect(MeetingOpenPolicy.target(labelled, liveSessionID: "A", inUse: false, hasExport: true) == .review)
    #expect(MeetingOpenPolicy.target(labelled, liveSessionID: nil, inUse: true, hasExport: true) == .transcript,
            "A command working on it keeps Review closed.")
    let unlabelled = summary("D", runID: nil, speakers: .notLabelled)
    #expect(MeetingOpenPolicy.target(unlabelled, liveSessionID: nil, inUse: false, hasExport: true) == .transcript)
    #expect(MeetingOpenPolicy.target(unlabelled, liveSessionID: nil, inUse: false, hasExport: false) == .none)
    #expect(MeetingOpenPolicy.finishedTarget(labelled, inUse: false, hasExport: true) == .review)
}

@Test func liveMeetingsComeFirst() {
    let older = summary("old")
    let newer = summary("new")
    let recording = summary("rec", state: .recording)
    let ordered = MeetingOpenPolicy.ordered([newer, older, recording], liveSessionID: "rec")
    #expect(ordered.map(\.id) == ["rec", "new", "old"])
    #expect(MeetingOpenPolicy.ordered([newer, older], liveSessionID: "old").map(\.id) == ["old", "new"])
}

@Test func livePhaseFollowsTheMeetingState() {
    let status = { (phase: RecorderPhase) in
        RecorderStatus(sessionID: "A", name: "Weekly", pid: 1, phase: phase, sequence: 1, startedAt: Date(),
                       updatedAt: Date(), source: .microphoneAndSystem)
    }
    let of = { (state: MeetingState, summary: SessionSummary?) in
        LiveMeetingPhase.of(sessionID: "A", state: state, summary: summary)
    }
    #expect(of(.starting(sessionID: "A", since: Date(), pid: nil), nil) == .starting)
    #expect(of(.active(sessionID: "A", status: status(.recording)), nil) == .recording)
    #expect(of(.active(sessionID: "A", status: status(.paused)), nil) == .paused)
    #expect(of(.active(sessionID: "A", status: status(.transcribing)), nil) == .saving)
    #expect(of(.finishing(sessionID: "A", status: nil), nil) == .saving)
    #expect(of(.failed(sessionID: "A", message: "No microphone."), nil) == .failed)
    #expect(of(.idle, summary("A")) == .saved)
    #expect(of(.idle, summary("A", state: .recording)) == .recording, "A recording the app does not follow.")
    #expect(of(.active(sessionID: "B", status: status(.recording)), summary("A", state: .processing)) == .saving)
    #expect(LiveMeetingPhase.recording.capturing && LiveMeetingPhase.paused.capturing)
    #expect(!LiveMeetingPhase.saving.capturing && !LiveMeetingPhase.saved.capturing)
}

// MARK: - Recorder side

@Test func volatileTextFollowsTheSpeechFramework() {
    var text = VolatileText()
    let added = text.volatile(segment("v1", "mic", "the budget", start: 1), session: 0)
    #expect(added)
    // A longer hypothesis over the same audio replaces it.
    text.volatile(segment("v2", "mic", "the budget is", start: 1), session: 0)
    #expect(text.segments.map(\.text) == ["the budget is"])
    // A final result confirms the words it covers.
    let confirmed = text.final(segment("f1", "mic", "the budget is", start: 1))
    #expect(confirmed)
    #expect(text.segments.isEmpty)
    text.volatile(segment("v3", "mic", "next", start: 5), session: 1)
    let otherSession = text.endSession(0)
    let ownSession = text.endSession(1)
    #expect(!otherSession && ownSession)
    #expect(text.segments.isEmpty)
}

private final class VolatileLog: Sendable {
    private let updates = Mutex<[[String]]>([])
    var sink: @Sendable (String, [TranscriptSegment]) -> Void {
        { _, segments in self.updates.withLock { $0.append(segments.map(\.text)) } }
    }
    var all: [[String]] { updates.withLock { $0 } }
}

@Test(.timeLimit(.minutes(1))) func liveTrackReportsVolatileWordsUntilFinal() async throws {
    let heard = TranscriptSegment(start: 0, end: 0.2, text: "Call to")
    let final = TranscriptSegment(start: 0, end: 0.3, text: "Call to order")
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [final], volatile: [heard])])
    let log = VolatileLog()
    let track = LiveTrack(track: "system", locale: "en-CA", backend: .speech, contextualStrings: [],
                          makeSpeech: speech.factory, events: { _, _ in }, reporter: CollectingReporter(),
                          onVolatile: log.sink)
    try await track.prepareSession(epoch: 0, epochStart: 4)
    for index in 0..<4 {
        track.push(try PCMFrame(samples: [Float](repeating: 0.1, count: 1_600), sampleRate: 16_000, channels: 1,
                                startTime: 4 + Double(index) / 10), epoch: 0)
    }
    let result = await track.finish()
    #expect(result.segments.map(\.text) == ["Call to order"])
    #expect(log.all == [["Call to"], []], "Shown while volatile, gone once final.")
}

@Test(.timeLimit(.minutes(1))) func publisherWritesLiveTextAndRemovesItAtClose() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let publisher = LiveTextPublisher(session: folder)
    publisher.set(track: "mic", segments: [segment("v", "mic", "hello there", start: 1)])
    var budget = PollBudget(timeout: .seconds(30))
    while LiveTextFile.read(session: folder)?.volatile["mic"]?.first?.text != "hello there", !budget.isSpent {
        await budget.poll()
    }
    #expect(LiveTextFile.read(session: folder)?.volatile["mic"]?.map(\.text) == ["hello there"])
    await publisher.close()
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.liveText(folder).path))
    publisher.set(track: "mic", segments: [segment("w", "mic", "too late", start: 2)])
    await publisher.close()
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.liveText(folder).path))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func recordingPublishesVolatileWordsUntilItExits() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    // The final result covers more audio than is fed, so it arrives only when speech finishes at the stop.
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [TranscriptSegment(start: 0, end: 5, text: "Call to order")],
                                                     volatile: [TranscriptSegment(start: 0, end: 0.1, text: "Call to")])])
    let stop = ManualStopSource()
    let dependencies = RecordingDependencies.testing(captures: captures, speech: speech, stop: stop)
    let run = Task { try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies) }
    let shown = await eventually {
        sessionFolders(in: temp.url).first.flatMap { LiveTextFile.read(session: $0) }?.volatile["mic"]?.first?.text
            == "Call to"
    }
    #expect(shown, "The volatile words reach live.json while recording.")
    stop.requestStop()
    let outcome = try await run.value
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.liveText(outcome.directory).path),
            "live.json is gone once the recorder exits.")
    #expect(try transcript(of: outcome).segments.map(\.text) == ["Call to order"])
}

private func transcript(of outcome: RecordingOutcome) throws -> Transcript {
    let id = try #require(outcome.transcriptID)
    return try AtomicFile.readJSON(Transcript.self, from: SessionPaths.transcript(id, in: outcome.directory))
}

// MARK: - Reading a session

@Test func readerReadsFinalizedSegmentsIncrementally() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try HolosJSON.encoder().encode(MeetingInfo(sessionID: "S", mode: .call, othersInRoom: false))
        .write(to: SessionPaths.meetingInfo(folder))
    func line(_ sequence: Int, _ details: [String: String]) throws -> String {
        let event: [String: Any] = ["sequence": sequence, "at": "2026-01-01T00:00:00Z",
                                    "kind": MeetingEventKind.transcriptFinalized, "details": details]
        return String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
    }
    let words = String(decoding: try HolosJSON.encoder(pretty: false).encode(segment("x", "mic", "hi all", start: 1).words),
                       as: UTF8.self)
    let first = try line(1, ["track": "mic", "text": "hi all", "start": "1.0", "end": "1.55", "segmentID": "S1",
                             "words": words])
    try (first + "\n").write(to: SessionPaths.events(folder), atomically: false, encoding: .utf8)
    var reader = LiveTranscriptReader(session: folder)
    reader.read(includeVolatile: true)
    #expect(reader.mode == .call)
    #expect(reader.finals.map(\.id) == ["S1"])
    #expect(reader.finals.first?.words.count == 2)
    let revision = reader.revision
    reader.read(includeVolatile: true)
    #expect(reader.revision == revision, "Nothing new, nothing changes.")

    let handle = try FileHandle(forWritingTo: SessionPaths.events(folder))
    try handle.seekToEnd()
    let second = try line(2, ["track": "system", "text": "welcome", "start": "2.0", "end": "2.4", "segmentID": "S2"])
    // Half a line first: kept for the next read.
    try handle.write(contentsOf: Data(second.prefix(20).utf8))
    reader.read(includeVolatile: true)
    #expect(reader.finals.count == 1)
    try handle.write(contentsOf: Data((second.dropFirst(20) + "\n").utf8))
    try handle.close()
    try HolosJSON.encoder().encode(LiveTextFile(sequence: 1, volatile: ["system": [segment("v", "system", "and", start: 2.5)]]))
        .write(to: SessionPaths.liveText(folder))
    reader.read(includeVolatile: true)
    #expect(reader.finals.map(\.track) == ["mic", "system"])
    #expect(reader.revision > revision)
    #expect(reader.volatile["system"]?.map(\.text) == ["and"])
    reader.read(includeVolatile: false)
    #expect(reader.volatile.isEmpty, "Once saving, volatile words are not read.")
}
