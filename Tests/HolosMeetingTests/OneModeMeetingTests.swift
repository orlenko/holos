import Foundation
@testable import HolosAudio
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

/// Microphone and system with the lid closed (review finding): when the microphone recorded is the built-in one,
/// chosen explicitly or as the system default input (by device ID or UID), the epoch records system audio alone and
/// says why; another default input is recorded as usual.
@Test func callWithTheBuiltInMicrophoneKeepsTheLidGuard() {
    var byDefault = RecordingOptions.testing(root: oneModeRoot, source: .microphoneAndSystem)
    byDefault.microphone = .systemDefault
    var explicit = byDefault
    explicit.microphone = .builtIn
    let systemOnly = EpochPlan(source: .system, tracks: ["system"], microphoneName: nil,
                               microphoneOffWithLidClosed: true)
    let builtInDefault = InputDevices(builtIn: recorderBuiltIn, systemDefault: recorderBuiltIn)
    let withBuiltIn = EpochPlan(source: .microphoneAndSystem, tracks: ["mic", "system"],
                                microphoneName: "MacBook Pro Microphone")
    #expect(EpochPlan.make(byDefault, devices: builtInDefault) == withBuiltIn)
    #expect(EpochPlan.make(byDefault, devices: builtInDefault, lidOpen: false) == systemOnly)
    let sameUID = InputDevice(id: 999, uid: recorderBuiltIn.uid, name: recorderBuiltIn.name)
    #expect(EpochPlan.make(byDefault, devices: InputDevices(builtIn: recorderBuiltIn, systemDefault: sameUID),
                           lidOpen: false) == systemOnly)

    let headsetDefault = InputDevices(builtIn: recorderBuiltIn, systemDefault: recorderAirPods)
    #expect(EpochPlan.make(explicit, devices: headsetDefault) == withBuiltIn)
    #expect(EpochPlan.make(explicit, devices: headsetDefault, lidOpen: false) == systemOnly)
    #expect(EpochPlan.make(explicit, devices: InputDevices(builtIn: nil, systemDefault: recorderAirPods),
                           lidOpen: false) == systemOnly, "Gone from the list with the lid closed: the lid.")

    // An external default input is unaffected by the lid.
    #expect(EpochPlan.make(byDefault, devices: headsetDefault, lidOpen: false)
        == EpochPlan(source: .microphoneAndSystem, tracks: ["mic", "system"], microphoneName: "AirPods Pro"))
    // No input device at all is not the lid's doing.
    #expect(EpochPlan.make(byDefault, devices: InputDevices(builtIn: nil, systemDefault: nil), lidOpen: false)
        == EpochPlan(source: .system, tracks: ["system"], microphoneName: nil))
}

/// The machine's side: a call epoch without the built-in microphone because the lid is closed journals why and warns;
/// opening the lid or unlocking the screen restarts capture with the microphone, and its return clears the warning.
/// Without any input device, the lid and unlock still restart nothing.
@Test func callWithoutTheBuiltInMicrophoneReturnsWhenTheLidOpens() {
    var machine = RecorderMachine(tracks: ["mic", "system"])
    #expect(machine.handle(.captureStarted(epoch: 0, tracks: ["system"], at: 0, lidClosed: true)) == [
        .recordEvent(kind: MeetingEventKind.deviceChanged,
                     details: ["track": "mic", "at": "0.0", "reason": RecorderMachine.lidClosedReason]),
        .warn(RecorderWarning(code: .microphoneUnavailable, message: RecorderMachine.builtInMicrophoneOffInCall,
                              since: RecorderMachine.placeholderDate)),
    ])
    #expect(machine.microphoneMissing)
    #expect(machine.microphoneOffWithLidClosed)
    _ = machine.handle(.captureRunning(epoch: 0, at: 0.1))
    for reason in [RecorderMachine.lidOpened, AudioEnvironmentEvents.screenUnlocked,
                   AudioEnvironmentEvents.audioDevicesChanged] {
        var copy = machine
        #expect(copy.handle(.retryNow(reason: reason, at: 5)) == [
            .recordEvent(kind: MeetingEventKind.deviceChanged, details: ["track": "mic", "at": "5.0", "reason": reason]),
            .stopCapture(reason: .deviceChanged),
            .startCapture(epoch: 1),
        ])
    }
    #expect(machine.handle(.retryNow(reason: RecorderMachine.lidOpened, at: 5)).last == .startCapture(epoch: 1))
    #expect(machine.handle(.retryNow(reason: RecorderMachine.lidOpened, at: 5.1)).isEmpty,
            "Not again while the restart is in flight.")
    #expect(machine.handle(.captureStarted(epoch: 1, tracks: ["mic", "system"], at: 5.5))
        == [.clearWarning(.microphoneUnavailable)])
    #expect(!machine.microphoneMissing)
    #expect(!machine.microphoneOffWithLidClosed)

    var noInput = RecorderMachine(tracks: ["mic", "system"])
    _ = noInput.handle(.captureStarted(epoch: 0, tracks: ["system"], at: 0))
    #expect(!noInput.microphoneOffWithLidClosed)
    #expect(noInput.handle(.retryNow(reason: RecorderMachine.lidOpened, at: 1)).isEmpty)
    #expect(noInput.handle(.retryNow(reason: AudioEnvironmentEvents.screenUnlocked, at: 1)).isEmpty)
    // The lid then closes on a built-in default that comes back: the warning names the lid.
    #expect(noInput.handle(.retryNow(reason: AudioEnvironmentEvents.audioDevicesChanged, at: 2)).last
        == .startCapture(epoch: 1))
    #expect(noInput.handle(.captureStarted(epoch: 1, tracks: ["system"], at: 2.5, lidClosed: true)).last
        == .warn(RecorderWarning(code: .microphoneUnavailable, message: RecorderMachine.builtInMicrophoneOffInCall,
                                 since: RecorderMachine.placeholderDate)))
    #expect(noInput.microphoneOffWithLidClosed)
}

/// The lid closes while an epoch records the microphone (review finding): `lidClosed` restarts capture once, journaled
/// on the microphone track. A repeat while the restart is in flight, an epoch already without the microphone, a
/// waiting recorder, and a system-only recording ignore it.
@Test func closingTheLidRestartsAnEpochThatRecordsTheMicrophone() {
    let lidClosed = RecorderMachine.lidClosed
    var call = RecorderMachine(tracks: ["mic", "system"])
    _ = call.handle(.captureStarted(epoch: 0, tracks: ["mic", "system"], at: 0))
    _ = call.handle(.captureRunning(epoch: 0, at: 0.1))
    #expect(call.handle(.retryNow(reason: lidClosed, at: 5)) == [
        .recordEvent(kind: MeetingEventKind.deviceChanged, details: ["track": "mic", "at": "5.0", "reason": lidClosed]),
        .stopCapture(reason: .deviceChanged),
        .startCapture(epoch: 1),
    ])
    #expect(call.handle(.retryNow(reason: lidClosed, at: 5.1)).isEmpty, "Not again while the restart is in flight.")
    // The next epoch records the computer's audio alone and says why.
    #expect(call.handle(.captureStarted(epoch: 1, tracks: ["system"], at: 5.5, lidClosed: true)).last
        == .warn(RecorderWarning(code: .microphoneUnavailable, message: RecorderMachine.builtInMicrophoneOffInCall,
                                 since: RecorderMachine.placeholderDate)))
    #expect(call.handle(.retryNow(reason: lidClosed, at: 6)).isEmpty, "The microphone is already missing.")
    #expect(call.epoch == 1)

    // Microphone only: the restart fails without the built-in microphone, and the recorder waits for the lid.
    var inPerson = RecorderMachine(tracks: ["mic"])
    _ = inPerson.handle(.captureStarted(epoch: 0, tracks: ["mic"], at: 0))
    _ = inPerson.handle(.captureRunning(epoch: 0, at: 0.1))
    #expect(inPerson.handle(.retryNow(reason: lidClosed, at: 3)).last == .startCapture(epoch: 1))
    let off = CaptureEnd.startFailed(message: RecorderMachine.builtInMicrophoneOff)
    #expect(inPerson.handle(.captureEnded(epoch: 1, off, at: 3.1)).last == .startCapture(epoch: 2))
    _ = inPerson.handle(.captureEnded(epoch: 2, off, at: 3.2))
    #expect(inPerson.phase == .waiting)
    #expect(inPerson.handle(.retryNow(reason: lidClosed, at: 4)).isEmpty, "Waiting already follows the lid.")
    #expect(inPerson.handle(.retryNow(reason: RecorderMachine.lidOpened, at: 5)) == [.startCapture(epoch: 3)])

    var system = RecorderMachine(tracks: ["system"])
    _ = system.handle(.captureStarted(epoch: 0, tracks: ["system"], at: 0))
    #expect(system.handle(.retryNow(reason: lidClosed, at: 1)).isEmpty)
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

    /// The app's meeting starts with the lid closed and the built-in microphone as the default input: it records the
    /// computer's audio alone, says why, and brings the microphone back when the lid opens.
    @Test(.timeLimit(.minutes(1)))
    func callWithTheDefaultBuiltInMicrophoneWaitsForTheLid() async throws {
        try await recordCallWithTheLidClosed(
            microphone: .systemDefault,
            devices: RecorderDevices(builtIn: recorderBuiltIn, systemDefault: recorderBuiltIn))
    }

    /// The same with `record start --source mic+system --microphone built-in` and a headset as the default input.
    @Test(.timeLimit(.minutes(1)))
    func callWithTheExplicitBuiltInMicrophoneWaitsForTheLid() async throws {
        try await recordCallWithTheLidClosed(microphone: .builtIn, devices: RecorderDevices())
    }

    /// An external default input is recorded with the lid closed, with nothing to warn about.
    @Test(.timeLimit(.minutes(1)))
    func callWithAnExternalMicrophoneIgnoresTheLid() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: recorderCallFrames(count: 2))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        dependencies.power = RecorderFakePower(lidOpen: false)
        var options = RecordingOptions.testing(root: temp.url, source: .microphoneAndSystem, recordOnly: true)
        options.microphone = .systemDefault
        let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 4 })
        #expect(recorderStatus(session)?.microphoneName == "AirPods Pro")
        stop.requestStop()
        let outcome = try await run.value
        #expect(captures.requests.map(\.source) == [.microphoneAndSystem])
        #expect(recorderStatus(outcome.directory)?.warnings.isEmpty == true)
        #expect(try recorderEvents(outcome.directory, MeetingEventKind.deviceChanged).isEmpty)
    }

    private func recordCallWithTheLidClosed(microphone: MicrophoneSelection, devices: RecorderDevices) async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let power = RecorderFakePower(lidOpen: false)
        let environment = AudioEnvironmentEvents.silent()
        let clock = ManualSessionClock(0)
        let captures = FakeCaptureFactory([
            FakeCaptureScript(frames: FakeFrame.run(track: "system", from: 0, count: 3)),
            FakeCaptureScript(frames: recorderCallFrames(count: 2)),
        ])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: clock)
        dependencies.findInputDevices = devices.lookup
        dependencies.power = power
        dependencies.environmentEvents = environment
        var options = RecordingOptions.testing(root: temp.url, source: .microphoneAndSystem, recordOnly: true)
        options.othersInRoom = true
        options.microphone = microphone
        let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { captures.captures.count == 1 && captures.captures[0].consumedFrames >= 3 })
        #expect(captures.requests[0].source == .system, "The system track alone while the lid is closed.")
        let warningMessage = {
            recorderStatus(session)?.warnings.first { $0.code == .microphoneUnavailable }?.message
        }
        #expect(await eventually { warningMessage() == RecorderMachine.builtInMicrophoneOffInCall })
        #expect(recorderStatus(session)?.microphoneName == nil)
        // An unlock or a device-list change with the lid still closed restarts nothing.
        environment.post(AudioEnvironmentEvents.screenUnlocked)
        environment.post(AudioEnvironmentEvents.audioDevicesChanged)
        try await Task.sleep(for: .milliseconds(200))
        #expect(captures.captures.count == 1)
        // The lid opens: capture restarts with the microphone.
        clock.set(2)
        power.setLid(open: true)
        #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 4 })
        #expect(captures.requests[1].source == .microphoneAndSystem)
        #expect(captures.requests.map(\.microphone) == [microphone, microphone])
        #expect(await eventually { warningMessage() == nil })
        #expect(recorderStatus(session)?.microphoneName == "MacBook Pro Microphone")
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        let changes = try recorderEvents(outcome.directory, MeetingEventKind.deviceChanged)
        #expect(changes.map { $0.details["reason"] } == [RecorderMachine.lidClosedReason, RecorderMachine.lidOpened])
        #expect(changes.allSatisfy { $0.details["track"] == "mic" })
        let tracks = Set(try SessionArchive.readManifest(at: outcome.directory).chunks.map(\.track))
        #expect(tracks == ["mic", "system"])
    }

    /// The app's meeting records the default built-in microphone and the lid closes mid-meeting while Core Audio
    /// keeps the device listed (review finding): capture restarts with the computer's audio alone and the warning,
    /// and the microphone comes back when the lid opens.
    @Test(.timeLimit(.minutes(1)))
    func callOnTheDefaultBuiltInMicrophoneDropsItWhenTheLidCloses() async throws {
        try await closeTheLidDuringACall(
            microphone: .systemDefault,
            devices: RecorderDevices(builtIn: recorderBuiltIn, systemDefault: recorderBuiltIn))
    }

    /// The same with `--microphone built-in` and a headset as the default input.
    @Test(.timeLimit(.minutes(1)))
    func callOnTheExplicitBuiltInMicrophoneDropsItWhenTheLidCloses() async throws {
        try await closeTheLidDuringACall(microphone: .builtIn, devices: RecorderDevices())
    }

    /// A microphone-only meeting on the default built-in microphone: closing the lid stops capture and the recorder
    /// waits for the lid, then resumes.
    @Test(.timeLimit(.minutes(1)))
    func microphoneOnlyOnTheBuiltInMicrophoneWaitsWhenTheLidCloses() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let power = RecorderFakePower()
        let clock = ManualSessionClock(0)
        let captures = FakeCaptureFactory([
            FakeCaptureScript(frames: FakeFrame.run(count: 3)),
            FakeCaptureScript(frames: FakeFrame.run(count: 3)),
        ])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: clock)
        dependencies.findInputDevices = RecorderDevices(builtIn: recorderBuiltIn, systemDefault: recorderBuiltIn).lookup
        dependencies.power = power
        var options = RecordingOptions.testing(root: temp.url, source: .microphone, recordOnly: true)
        options.microphone = .systemDefault
        let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { power.attached && recorderStatus(session)?.phase == .recording })
        #expect(await eventually { captures.captures[0].consumedFrames >= 3 })
        // The lid closes; the built-in microphone stays listed.
        clock.set(1)
        power.setLid(open: false)
        #expect(await eventually { recorderStatus(session)?.phase == .waiting })
        #expect(captures.captures[0].stopCalls == 1, "The silent capture is stopped.")
        #expect(captures.captures.count == 1, "No capture is attempted without the built-in microphone.")
        let warning = recorderStatus(session)?.warnings.first { $0.code == .audioUnavailable }
        #expect(warning?.message == RecorderMachine.builtInMicrophoneOff)
        // The lid opens: the recording resumes.
        clock.set(2)
        power.setLid(open: true)
        #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 3 })
        #expect(captures.requests.map(\.source) == [.microphone, .microphone])
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        let changes = try recorderEvents(outcome.directory, MeetingEventKind.deviceChanged)
        #expect(changes.map { $0.details["reason"] } == [RecorderMachine.lidClosed])
        let waiting = try #require(try recorderEvents(outcome.directory, MeetingEventKind.captureWaiting).first)
        #expect(waiting.details["reason"] == RecorderMachine.builtInMicrophoneOff)
    }

    /// An external default input keeps recording when the lid closes: nothing restarts or warns.
    @Test(.timeLimit(.minutes(1)))
    func callOnAnExternalMicrophoneIgnoresTheLidClosing() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let power = RecorderFakePower()
        let captures = FakeCaptureFactory([FakeCaptureScript(frames: recorderCallFrames(count: 2))])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: ManualSessionClock(0))
        dependencies.findInputDevices = RecorderDevices().lookup
        dependencies.power = power
        var options = RecordingOptions.testing(root: temp.url, source: .microphoneAndSystem, recordOnly: true)
        options.microphone = .systemDefault
        let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { power.attached && recorderStatus(session)?.phase == .recording })
        #expect(await eventually { captures.captures[0].consumedFrames >= 4 })
        power.setLid(open: false)
        #expect(await eventually { power.lidSeen })
        try await Task.sleep(for: .milliseconds(200))
        #expect(captures.captures.count == 1)
        #expect(captures.captures[0].stopCalls == 0)
        stop.requestStop()
        let outcome = try await run.value
        #expect(captures.requests.map(\.source) == [.microphoneAndSystem])
        #expect(recorderStatus(outcome.directory)?.warnings.isEmpty == true)
        #expect(try recorderEvents(outcome.directory, MeetingEventKind.deviceChanged).isEmpty)
    }

    private func closeTheLidDuringACall(microphone: MicrophoneSelection, devices: RecorderDevices) async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let power = RecorderFakePower()
        let clock = ManualSessionClock(0)
        let captures = FakeCaptureFactory([
            FakeCaptureScript(frames: recorderCallFrames(count: 2)),
            FakeCaptureScript(frames: FakeFrame.run(track: "system", from: 0, count: 3)),
            FakeCaptureScript(frames: recorderCallFrames(count: 2)),
        ])
        let stop = ManualStopSource()
        var dependencies = recorderDependencies(captures: captures, stop: stop, clock: clock)
        dependencies.findInputDevices = devices.lookup
        dependencies.power = power
        var options = RecordingOptions.testing(root: temp.url, source: .microphoneAndSystem, recordOnly: true)
        options.othersInRoom = true
        options.microphone = microphone
        let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
        let session = try #require(await recorderSession(in: temp.url))
        #expect(await eventually { power.attached && recorderStatus(session)?.phase == .recording })
        #expect(await eventually { captures.captures[0].consumedFrames >= 4 })
        #expect(captures.requests[0].source == .microphoneAndSystem)
        let warningMessage = {
            recorderStatus(session)?.warnings.first { $0.code == .microphoneUnavailable }?.message
        }
        // The lid closes; the built-in microphone stays listed and would record silence.
        clock.set(1)
        power.setLid(open: false)
        #expect(await eventually { captures.captures.count == 2 && captures.captures[1].consumedFrames >= 3 })
        #expect(captures.requests[1].source == .system, "The system track alone while the lid is closed.")
        #expect(captures.captures[0].stopCalls == 1)
        #expect(await eventually { warningMessage() == RecorderMachine.builtInMicrophoneOffInCall })
        #expect(await eventually { recorderStatus(session)?.microphoneName == nil })
        // The lid opens: capture restarts with the microphone.
        clock.set(2)
        power.setLid(open: true)
        #expect(await eventually { captures.captures.count == 3 && captures.captures[2].consumedFrames >= 4 })
        #expect(captures.requests[2].source == .microphoneAndSystem)
        #expect(captures.requests.map(\.microphone) == [microphone, microphone, microphone])
        #expect(await eventually { warningMessage() == nil })
        #expect(recorderStatus(session)?.microphoneName == "MacBook Pro Microphone")
        stop.requestStop()
        let outcome = try await run.value
        #expect(outcome.stopReason == .requested)
        let changes = try recorderEvents(outcome.directory, MeetingEventKind.deviceChanged)
        #expect(changes.map { $0.details["reason"] }
            == [RecorderMachine.lidClosed, RecorderMachine.lidClosedReason, RecorderMachine.lidOpened])
        #expect(changes.allSatisfy { $0.details["track"] == "mic" })
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

@Test func microphoneOnlyWithoutADefaultInputIsRefusedBeforeASession() {
    var options = RecordingOptions.testing(root: oneModeRoot, source: .microphone)
    options.microphone = .systemDefault
    let none = InputDevices(builtIn: nil, systemDefault: nil)
    #expect(EpochPlan.make(options, devices: none) == nil)
    #expect(EpochPlan.unavailableMessage(options, devices: none) == EpochPlan.noMicrophone)
    options.microphone = .builtIn
    #expect(EpochPlan.make(options, devices: none) == nil)
    #expect(EpochPlan.unavailableMessage(options, devices: none) == BuiltInMicrophone.unavailableMessage)
}
