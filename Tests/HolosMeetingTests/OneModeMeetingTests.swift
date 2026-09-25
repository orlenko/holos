import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// One meeting mode from the app (docs/status.md "Meeting recording"): the system default input and the computer's
// audio, both tracks split into speakers; the microphone alone when Setup's Advanced setting is off or the System
// audio permission is missing. Sessions recorded as in person, call, or hybrid keep their meaning.

private let oneModeRoot = URL(fileURLWithPath: "/Users/me/Library/Application Support/Holos/Sessions", isDirectory: true)
private let oneModeID = "3F2A9C1E-0000-4000-8000-000000000002"

// MARK: - Start settings

@Test func appMeetingRecordsTheMicrophoneAndTheComputer() {
    let settings = MeetingStartSettings.app(name: "Weekly", recordSystemAudio: true, systemAudioAllowed: true)
    #expect(settings.source == .microphoneAndSystem)
    #expect(settings.othersInRoom, "Both tracks are split into speakers.")
    #expect(settings.microphone == .systemDefault)
    #expect(settings.applicationBundleID == nil, "Everything the Mac plays, not one app.")
    #expect(settings.normalized() == settings, "The recorder accepts them as they are.")
    #expect(MeetingStartSettings.sourceNotice(settings, recordSystemAudio: true) == nil)
    #expect(MeetingStartSettings.sourcesDescription(recordSystemAudio: true, systemAudioAllowed: true)
        == "Microphone and the computer's audio")
    #expect(ChildProcessLauncher.arguments(settings, sessionID: oneModeID, root: oneModeRoot, vocabularyFile: nil) == [
        "record", "start", "--session-id", oneModeID, "--name=Weekly", "--source", "mic+system",
        "--others-in-room", "--microphone", "default", "--no-live-text", "--directory", oneModeRoot.path,
    ])
}

@Test func appMeetingWithTheComputerOffRecordsTheDefaultMicrophone() {
    for allowed in [true, false] {
        let settings = MeetingStartSettings.app(name: "Board", recordSystemAudio: false, systemAudioAllowed: allowed)
        #expect(settings.source == .microphone)
        #expect(!settings.othersInRoom)
        #expect(settings.microphone == .systemDefault, "The system default input, not the built-in microphone.")
        #expect(MeetingStartSettings.sourceNotice(settings, recordSystemAudio: false) == nil, "Nothing to explain.")
        #expect(MeetingStartSettings.sourcesDescription(recordSystemAudio: false, systemAudioAllowed: allowed)
            == "Microphone only — the computer's audio is off in Setup › Advanced.")
        #expect(ChildProcessLauncher.arguments(settings, sessionID: oneModeID, root: oneModeRoot, vocabularyFile: nil)
            == ["record", "start", "--session-id", oneModeID, "--name=Board", "--source", "mic",
                "--microphone", "default", "--no-live-text", "--directory", oneModeRoot.path])
    }
}

@Test func appMeetingWithoutThePermissionRecordsTheMicrophoneAndSaysSo() {
    let settings = MeetingStartSettings.app(name: "Board", recordSystemAudio: true, systemAudioAllowed: false)
    #expect(settings.source == .microphone)
    #expect(!settings.othersInRoom)
    #expect(settings.microphone == .systemDefault)
    #expect(MeetingStartSettings.sourceNotice(settings, recordSystemAudio: true)
        == "Recording the microphone only — allow System audio in Setup to include the computer's sound.")
    #expect(MeetingStartSettings.sourcesDescription(recordSystemAudio: true, systemAudioAllowed: false)
        == MeetingStartSettings.systemAudioNotAllowedNotice)
}

/// The fallback notice names its meeting and survives a relaunch of the app: a new app reading the same defaults
/// shows it for that meeting only, and a later meeting without one removes it.
@Test func sourceNoticeSurvivesARelaunchForItsMeetingOnly() throws {
    let suite = "holos.tests.sourceNotice.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(MeetingSourceNotice.load(from: defaults) == nil)

    let fallback = MeetingStartSettings.app(name: "Board", recordSystemAudio: true, systemAudioAllowed: false)
    let notice = try #require(MeetingSourceNotice.started(fallback, sessionID: oneModeID, recordSystemAudio: true))
    #expect(notice.text == MeetingStartSettings.systemAudioNotAllowedNotice)
    MeetingSourceNotice.save(notice, to: defaults)

    let reattached = try #require(MeetingSourceNotice.load(from: defaults))
    #expect(reattached == notice)
    #expect(reattached.text(for: oneModeID) == MeetingStartSettings.systemAudioNotAllowedNotice)
    #expect(reattached.text(for: "ANOTHER-SESSION") == nil, "A meeting started elsewhere does not show it.")
    #expect(reattached.text(for: nil) == nil)

    // Nothing to explain: the setting is off, the permission is there, or the start gave no session.
    let off = MeetingStartSettings.app(name: "Board", recordSystemAudio: false, systemAudioAllowed: false)
    #expect(MeetingSourceNotice.started(off, sessionID: oneModeID, recordSystemAudio: false) == nil)
    let both = MeetingStartSettings.app(name: "Call", recordSystemAudio: true, systemAudioAllowed: true)
    #expect(MeetingSourceNotice.started(both, sessionID: oneModeID, recordSystemAudio: true) == nil)
    #expect(MeetingSourceNotice.started(fallback, sessionID: nil, recordSystemAudio: true) == nil)

    MeetingSourceNotice.save(nil, to: defaults)
    #expect(MeetingSourceNotice.load(from: defaults) == nil, "A meeting started without one replaces it.")
}

/// Settings saved by the app before the microphone choice existed still decode, with the recorder's own choice.
@Test func savedSettingsWithoutAMicrophoneStillDecode() throws {
    let old = Data(#"{"name":"","source":"mic","othersInRoom":false}"#.utf8)
    let decoded = try HolosJSON.decoder().decode(MeetingStartSettings.self, from: old)
    #expect(decoded == MeetingStartSettings(name: "", source: .microphone))
    #expect(decoded.microphone == nil)
    let app = MeetingStartSettings.app(name: "", recordSystemAudio: true, systemAudioAllowed: true)
    #expect(try HolosJSON.decoder().decode(MeetingStartSettings.self, from: HolosJSON.encoder().encode(app)) == app)
}

/// The start panel's language travels with the one-mode sources: the recorder gets `--locale` and `--microphone`, and
/// both survive saving the settings.
@Test func appMeetingCarriesTheMeetingLanguage() throws {
    let settings = MeetingStartSettings.app(name: "Weekly", recordSystemAudio: true, systemAudioAllowed: true,
                                            locales: ["fr-CA"])
    #expect(settings.locale == "fr-CA")
    #expect(settings.normalized() == settings)
    #expect(ChildProcessLauncher.arguments(settings, sessionID: oneModeID, root: oneModeRoot, vocabularyFile: nil) == [
        "record", "start", "--session-id", oneModeID, "--name=Weekly", "--source", "mic+system", "--locale=fr-CA",
        "--others-in-room", "--microphone", "default", "--no-live-text", "--directory", oneModeRoot.path,
    ])
    let decoded = try HolosJSON.decoder().decode(MeetingStartSettings.self, from: HolosJSON.encoder().encode(settings))
    #expect(decoded == settings)
    #expect(decoded.microphone == .systemDefault)
}

@Test func microphoneArguments() {
    for selection in [MicrophoneSelection.systemDefault, .builtIn] {
        #expect(MicrophoneSelection(argument: selection.argument) == selection)
    }
    #expect(MicrophoneSelection(argument: "headset") == nil)
}

/// A microphone-only meeting from the app needs an input device, not the built-in microphone; an in-person meeting
/// from the CLI's `--source mic` still needs the built-in one.
@Test @MainActor func startCheckFollowsTheMicrophoneChoice() throws {
    let airPods = InputDevice(id: 2, uid: "AirPods", name: "AirPods Pro")
    let app = MeetingStartSettings.app(name: "Board", recordSystemAudio: false, systemAudioAllowed: true)
    let free = FixedFreeSpace(500_000_000_000)
    try MeetingController.checkStart(app, freeSpace: free, root: oneModeRoot,
                                     devices: InputDevices(builtIn: nil, systemDefault: airPods))
    let noInput = #expect(throws: HolosError.self) {
        try MeetingController.checkStart(app, freeSpace: free, root: oneModeRoot,
                                         devices: InputDevices(builtIn: nil, systemDefault: nil))
    }
    #expect(noInput?.errorDescription == MeetingController.noMicrophone)
    let builtIn = #expect(throws: HolosError.self) {
        try MeetingController.checkStart(MeetingStartSettings(name: "Board", source: .microphone), freeSpace: free,
                                         root: oneModeRoot, devices: InputDevices(builtIn: nil, systemDefault: airPods))
    }
    #expect(builtIn?.errorDescription == BuiltInMicrophone.unavailableMessage)
    // Both sources: no microphone still records the computer's audio.
    try MeetingController.checkStart(.app(name: "Call", recordSystemAudio: true, systemAudioAllowed: true),
                                     freeSpace: free, root: oneModeRoot,
                                     devices: InputDevices(builtIn: nil, systemDefault: nil))
}

@Test func microphoneOnlyFromTheAppPlansTheDefaultInput() {
    var options = RecordingOptions.testing(root: oneModeRoot, source: .microphone)
    options.microphone = .systemDefault
    #expect(EpochPlan.make(options, devices: InputDevices(builtIn: nil, systemDefault: recorderAirPods))
        == EpochPlan(source: .microphone, tracks: ["mic"], microphoneName: "AirPods Pro"))
    // The built-in microphone's lid rule does not apply to another input.
    #expect(EpochPlan.make(options, devices: InputDevices(builtIn: recorderBuiltIn, systemDefault: recorderAirPods),
                           lidOpen: false)
        == EpochPlan(source: .microphone, tracks: ["mic"], microphoneName: "AirPods Pro"))
}

/// The default input is the built-in microphone: a closed lid refuses the epoch as it does for `--microphone built-in`
/// (the device may stay listed while it records silence), matched by device ID or by UID.
@Test func microphoneOnlyDefaultBuiltInKeepsTheLidGuard() {
    var options = RecordingOptions.testing(root: oneModeRoot, source: .microphone)
    options.microphone = .systemDefault
    let builtInDefault = InputDevices(builtIn: recorderBuiltIn, systemDefault: recorderBuiltIn)
    #expect(EpochPlan.make(options, devices: builtInDefault)
        == EpochPlan(source: .microphone, tracks: ["mic"], microphoneName: "MacBook Pro Microphone"))
    #expect(EpochPlan.make(options, devices: builtInDefault, lidOpen: false) == nil)
    let sameUID = InputDevice(id: 999, uid: recorderBuiltIn.uid, name: recorderBuiltIn.name)
    #expect(EpochPlan.make(options, devices: InputDevices(builtIn: recorderBuiltIn, systemDefault: sameUID),
                           lidOpen: false) == nil)
}

@Test func microphoneLineNamesTheSystemDefaultOnlyWhenRecorded() {
    var status = RecorderStatus(sessionID: oneModeID, name: "Weekly", pid: 1, phase: .recording, sequence: 1,
                                startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                                source: .microphoneAndSystem, microphoneName: "MacBook Pro Microphone",
                                microphoneIsSystemDefault: false)
    // `record start --source mic+system --microphone built-in` with AirPods as the default input.
    #expect(status.microphoneLine == "Microphone: MacBook Pro Microphone")
    status.microphoneName = "AirPods Pro"
    status.microphoneIsSystemDefault = true
    #expect(status.microphoneLine == "Microphone: AirPods Pro (system default)")
    status.source = .microphone
    #expect(status.microphoneLine == "Microphone: AirPods Pro (system default)")
    // A recorder from before the field: no claim either way.
    status.microphoneIsSystemDefault = nil
    #expect(status.microphoneLine == "Microphone: AirPods Pro")
    status.microphoneName = nil
    #expect(status.microphoneLine == nil)
}

// MARK: - Recording

extension RecorderEnvironmentLoopTests {
    /// The app's meeting writes meeting.json as a call with others in the room: both tracks are diarized and the echo
    /// filter is on.
    @Test(.timeLimit(.minutes(1)))
    func appMeetingIsSavedAsACallWithOthersInTheRoom() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: recorderCallFrames(count: 2))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices(builtIn: nil, systemDefault: recorderAirPods).lookup
        var options = RecordingOptions.testing(root: temp.url, source: .microphoneAndSystem, recordOnly: true)
        options.othersInRoom = true
        options.microphone = .systemDefault
        let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 4 })
        stop.requestStop()
        let outcome = try await run.value
        let meeting = try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(outcome.directory))
        #expect(meeting.mode == .call)
        #expect(meeting.othersInRoom)
        #expect(SpeakerAnalysis.alignmentParameters(meeting: meeting).echoWindowSeconds == 1.0)
        #expect(captures.requests.map(\.microphone) == [.systemDefault])
        #expect(captures.requests.map(\.source) == [.microphoneAndSystem])
        #expect(recorderStatus(outcome.directory)?.warnings.isEmpty == true, "Nothing to warn about.")
    }

    /// The microphone alone (Advanced setting off, or no permission): the system default input, saved in person, so
    /// the microphone is diarized.
    @Test(.timeLimit(.minutes(1)))
    func microphoneOnlyMeetingRecordsTheDefaultInput() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        var options = RecordingOptions.testing(root: temp.url, source: .microphone, recordOnly: true)
        options.microphone = .systemDefault
        let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 })
        #expect(recorderStatus(session)?.microphoneName == "AirPods Pro")
        #expect(recorderStatus(session)?.microphoneIsSystemDefault == true)
        stop.requestStop()
        _ = try await run.value
        #expect(captures.requests.map(\.microphone) == [.systemDefault])
        #expect(captures.requests.map(\.source) == [.microphone])
        let meeting = try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(session))
        #expect(meeting.mode == .inPerson)
        #expect(!meeting.othersInRoom)
    }

    /// The microphone alone from the app, the default input is the built-in microphone, and the lid is closed: the
    /// recorder refuses as it does for the built-in microphone chosen explicitly.
    @Test(.timeLimit(.minutes(1)))
    func microphoneOnlyDefaultBuiltInRefusesWithTheLidClosed() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory()
        var dependencies = recorderDependencies(captures: captures, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices(builtIn: recorderBuiltIn, systemDefault: recorderBuiltIn).lookup
        dependencies.power = RecorderFakePower(lidOpen: false)
        var options = RecordingOptions.testing(root: temp.url, source: .microphone, recordOnly: true)
        options.microphone = .systemDefault
        var message: String?
        do {
            _ = try await RecordingWorkflow.run(options, dependencies: dependencies)
        } catch HolosError.unavailable(let text) {
            message = text
        }
        #expect(message == BuiltInMicrophone.unavailableMessage)
        #expect(sessionFolders(in: temp.url).isEmpty, "No session folder.")
        #expect(captures.captures.isEmpty)
    }
}

// MARK: - Sessions recorded before

/// in person, call, and hybrid sessions are labelled as before: the in-person microphone is diarized, a call's
/// microphone is "Me", a hybrid call's microphone is diarized; only calls filter echo.
@Test func earlierModesKeepTheirTrackPlans() {
    let transcript = SessionFixtures.transcript([
        SessionFixtures.segment(["hello", "there"], track: "mic", start: 1),
        SessionFixtures.segment(["good", "morning"], track: "system", start: 3),
    ])
    let manifest = SessionManifest(id: "SESSION", name: "Old", createdAt: SessionFixtures.date,
                                   source: .microphoneAndSystem, locale: "en-CA", backend: .speech,
                                   status: "complete", chunks: [])
    func plans(_ mode: MeetingMode, othersInRoom: Bool) -> [String: Bool] {
        let meeting = MeetingInfo(sessionID: "SESSION", mode: mode, othersInRoom: othersInRoom,
                                  createdAt: SessionFixtures.date)
        let plans = SpeakerAnalysis.trackPlans(transcript: transcript, manifest: manifest, meeting: meeting,
                                               othersInRoom: othersInRoom)
        return Dictionary(uniqueKeysWithValues: plans.map { ($0.track, $0.isDiarized) })
    }
    #expect(plans(.inPerson, othersInRoom: false) == ["mic": true, "system": true])
    #expect(plans(.call, othersInRoom: false) == ["mic": false, "system": true])
    #expect(plans(.call, othersInRoom: true) == ["mic": true, "system": true])
    let callMe = SpeakerAnalysis.trackPlans(
        transcript: transcript, manifest: manifest,
        meeting: MeetingInfo(sessionID: "SESSION", mode: .call, othersInRoom: false, createdAt: SessionFixtures.date),
        othersInRoom: false).first { $0.track == "mic" }
    #expect(callMe?.policy == .channel(speakerID: SpeakerAnalysis.meSpeakerID, displayName: "Me"))
    for (mode, window) in [(MeetingMode.inPerson, nil), (.call, 1.0)] as [(MeetingMode, Double?)] {
        let meeting = MeetingInfo(sessionID: "SESSION", mode: mode, othersInRoom: false, createdAt: SessionFixtures.date)
        #expect(SpeakerAnalysis.alignmentParameters(meeting: meeting).echoWindowSeconds == window)
    }
}

/// An in-person session from before the change (the built-in microphone, mic diarized) post-processes as before.
@Test(.timeLimit(.minutes(1)))
func inPersonSessionStillPostProcesses() async throws {
    let temp = try TemporaryDirectory("postprocess")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(
        in: temp.url, source: .microphone, audioSeconds: ["mic": 20], mode: .inPerson, othersInRoom: false,
        transcript: SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic")))
    let diarizer = FakeDiarizer(outputs: ["mic": SessionFixtures.alternatingOutput()])
    let record = try await MeetingPostProcessor(diarizer: diarizer, freeSpace: FixedFreeSpace(.max))
        .run(session: session, lease: nil)
    #expect(record.state == .succeeded)
    let run = try SessionSpeakerStore.readRun(id: try #require(record.runID), session: session)
    #expect(run.alignment.parameters.echoWindowSeconds == nil)
    #expect(run.tracks.map(\.policy) == [.diarized])
    #expect(Set(run.turns.map(\.speakerID)) == ["mic:S1", "mic:S2"])
}
