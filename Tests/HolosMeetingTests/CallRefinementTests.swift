import Foundation
@testable import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Synchronization
import Testing

// Online-call refinements (docs/meeting-design.md §5.11, PR11): the echo filter in post-processing, and the echoRisk
// warning while a call plays on the laptop speakers.

// MARK: - Helpers

private let echoSpeakers = OutputRoute(name: "MacBook Pro Speakers", isBuiltInSpeakers: true)
private let echoHeadphones = OutputRoute(name: "External Headphones", isBuiltInSpeakers: false)

/// The output route a test changes while a recording runs, and how often the recorder looked it up.
private final class EchoRoute: Sendable {
    private struct State {
        var route: OutputRoute?
        var lookups = 0
    }

    private let state: Mutex<State>

    init(_ route: OutputRoute?) { state = Mutex(State(route: route)) }

    func set(_ route: OutputRoute?) { state.withLock { $0.route = route } }

    var lookups: Int { state.withLock { $0.lookups } }

    var lookup: @Sendable () -> OutputRoute? {
        {
            self.state.withLock { state in
                state.lookups += 1
                return state.route
            }
        }
    }
}

private func echoWarning(_ session: URL) -> RecorderWarning? {
    recorderStatus(session)?.warnings.first { $0.code == .echoRisk }
}

private func echoHasWarning(_ session: URL, _ code: RecorderWarningCode) -> Bool {
    recorderStatus(session)?.warnings.contains { $0.code == code } == true
}

/// A capture that delivers `audio` when started and ends when the test says so, with the error it gives.
@MainActor
private final class EchoTestCapture: MeetingCapture {
    nonisolated let frames: AsyncThrowingStream<CapturedAudio, Error>
    private let continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    private let audio: [FakeFrame]

    init(_ audio: [FakeFrame]) {
        (frames, continuation) = AsyncThrowingStream<CapturedAudio, Error>.makeStream()
        self.audio = audio
    }

    var hostTimeOrigin: Double { 1_000 }

    func start(_ request: CaptureRequest) async throws {
        for frame in audio { continuation.yield(try frame.captured(offset: request.timelineOffset)) }
    }

    func stop() async throws { continuation.finish() }

    nonisolated func end(throwing error: Error) { continuation.finish(throwing: error) }
}

/// Epoch 0 is `first`; later epochs come from `captures`.
@MainActor
private func echoFirstThen(_ first: EchoTestCapture, _ captures: FakeCaptureFactory)
    -> @MainActor @Sendable () -> any MeetingCapture {
    let made = SharedValue(0)
    return {
        let index = made.update { count -> Int in defer { count += 1 }; return count }
        return index == 0 ? first : captures.make()
    }
}

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

// MARK: - The echoRisk warning

extension RecorderEnvironmentLoopTests {
    @Test(.timeLimit(.minutes(1)))
    func callOnLaptopSpeakersWarnsOfEcho() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: recorderCallFrames(count: 3))])
        let stop = ManualStopSource()
        let reporter = CollectingReporter()
        var dependencies = recorderDependencies(captures: captures, stop: stop, reporter: reporter,
                                                clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        dependencies.findOutputRoute = EchoRoute(echoSpeakers).lookup
        let run = recorderRecordOnly(temp.url, source: .microphoneAndSystem, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { echoWarning(session) != nil })
        #expect(echoWarning(session)?.message == OutputRoute.echoRiskMessage)
        // The CLI's reporter prints it on stderr, once.
        #expect(reporter.messages.filter { $0 == OutputRoute.echoRiskMessage }.count == 1)
        stop.requestStop()
        #expect(try await run.value.stopReason == .requested)
    }

    /// Headphones connected or removed change the device list: the warning follows at once.
    @Test(.timeLimit(.minutes(1)))
    func echoRiskFollowsDeviceChanges() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: recorderCallFrames(count: 3))])
        let stop = ManualStopSource()
        let reporter = CollectingReporter()
        let route = EchoRoute(echoSpeakers)
        let environment = AudioEnvironmentEvents.silent()
        var dependencies = recorderDependencies(captures: captures, stop: stop, reporter: reporter,
                                                clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        dependencies.findOutputRoute = route.lookup
        dependencies.environmentEvents = environment
        // No periodic look during the test: only the device changes move the warning.
        dependencies.tuning.outputRouteInterval = .seconds(3_600)
        let run = recorderRecordOnly(temp.url, source: .microphoneAndSystem, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { echoWarning(session) != nil })
        route.set(echoHeadphones)
        environment.post(AudioEnvironmentEvents.audioDevicesChanged)
        #expect(await eventually { echoWarning(session) == nil })
        route.set(echoSpeakers)
        environment.post(AudioEnvironmentEvents.audioDevicesChanged)
        #expect(await eventually { echoWarning(session) != nil })
        #expect(reporter.messages.filter { $0 == OutputRoute.echoRiskMessage }.count == 2, "Shown again, said again.")
        stop.requestStop()
        #expect(try await run.value.stopReason == .requested)
        #expect(captures.captures.count == 1, "A device-list change with the microphone present restarts nothing.")
    }

    /// Headphones on the built-in jack, or another output picked in Control Center, change no device list: a periodic
    /// look finds them.
    @Test(.timeLimit(.minutes(1)))
    func echoRiskFollowsTheOutputPeriodically() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: recorderCallFrames(count: 3))])
        let stop = ManualStopSource()
        let route = EchoRoute(echoHeadphones)
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        dependencies.findOutputRoute = route.lookup
        dependencies.tuning.outputRouteInterval = .milliseconds(50)
        let run = recorderRecordOnly(temp.url, source: .microphoneAndSystem, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { route.lookups >= 3 })
        #expect(echoWarning(session) == nil, "Headphones: no warning.")
        route.set(echoSpeakers)
        #expect(await eventually { echoWarning(session) != nil })
        route.set(echoHeadphones)
        #expect(await eventually { echoWarning(session) == nil })
        // An unknown route leaves the warning as it is.
        route.set(echoSpeakers)
        #expect(await eventually { echoWarning(session) != nil })
        route.set(nil)
        let seen = route.lookups
        #expect(await eventually { route.lookups >= seen + 3 })
        #expect(echoWarning(session) != nil)
        stop.requestStop()
        #expect(try await run.value.stopReason == .requested)
    }

    /// In person there is no call audio to echo: the output is never even looked up.
    @Test(.timeLimit(.minutes(1)))
    func inPersonRecordingHasNoEchoRisk() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
        let stop = ManualStopSource()
        let route = EchoRoute(echoSpeakers)
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        dependencies.findOutputRoute = route.lookup
        dependencies.tuning.outputRouteInterval = .milliseconds(50)
        let run = recorderRecordOnly(temp.url, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
        #expect(await eventually { (recorderStatus(session)?.sequence ?? 0) >= 5 })
        #expect(echoWarning(session) == nil)
        #expect(route.lookups == 0)
        stop.requestStop()
        #expect(try await run.value.stopReason == .requested)
    }

    /// A call that records no microphone has no echo: the warning goes when the microphone does, and comes back with
    /// it.
    @Test(.timeLimit(.minutes(1)))
    func echoRiskFollowsTheMicrophone() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let devices = RecorderDevices(builtIn: nil, systemDefault: recorderAirPods)
        let environment = AudioEnvironmentEvents.silent()
        let clock = ManualSessionClock(0)
        let first = EchoTestCapture(recorderCallFrames(count: 2))
        let captures = FakeCaptureFactory([
            FakeCaptureScript(frames: FakeFrame.run(track: "system", from: 0, count: 3)),
            FakeCaptureScript(frames: recorderCallFrames(count: 2)),
        ])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: clock,
                                                makeCapture: echoFirstThen(first, captures))
        dependencies.findInputDevices = devices.lookup
        dependencies.environmentEvents = environment
        dependencies.findOutputRoute = EchoRoute(echoSpeakers).lookup
        dependencies.tuning.outputRouteInterval = .seconds(3_600)
        let run = recorderRecordOnly(temp.url, source: .microphoneAndSystem, dependencies)
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { echoWarning(session) != nil })
        #expect(await eventually { recorderStatus(session)?.tracks.allSatisfy { $0.lastFrameSeconds != nil } == true })
        // The headset goes away and capture fails: the restart records system audio alone.
        devices.set(builtIn: nil, systemDefault: nil)
        first.end(throwing: HolosError.io("Headset gone."))
        #expect(await eventually { echoHasWarning(session, .microphoneUnavailable) })
        #expect(await eventually { echoWarning(session) == nil })
        // The headset is back; the restart records the microphone again.
        devices.set(builtIn: nil, systemDefault: recorderAirPods)
        clock.set(2)
        environment.post(AudioEnvironmentEvents.audioDevicesChanged)
        #expect(await eventually { captures.captures.count == 2 && echoWarning(session) != nil })
        #expect(await eventually { !echoHasWarning(session, .microphoneUnavailable) })
        stop.requestStop()
        #expect(try await run.value.stopReason == .requested)
    }
}
