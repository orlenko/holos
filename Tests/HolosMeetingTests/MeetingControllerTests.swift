import Darwin
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// The app's side of a meeting without AppKit (docs/meeting-design.md §5.8, §4.1 "Reattach", §4.12).

private let controllerBuiltIn = InputDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
private let controllerAirPods = InputDevice(id: 2, uid: "AirPods", name: "AirPods Pro")

/// What a controller under test reported, and its relabel attempts (kept in memory, not in UserDefaults).
@MainActor
private final class ControllerProbe {
    var states: [MeetingState] = []
    var effects: [MeetingEffect] = []
    var attempts: [String: Int] = [:]
    /// The saved launched recorders (UserDefaults "meeting.launchedRecorders" in the app).
    var launched: [String: [Int]] = [:]
    /// The dismissed naming offers (UserDefaults "meeting.namingOffersDismissed" in the app).
    var dismissed: [String: String] = [:]

    var offers: [MeetingEffect] { effects.filter { if case .offerNaming = $0 { true } else { false } } }

    var dictation: [Bool] {
        effects.compactMap { if case .setDictationPaused(let paused) = $0 { paused } else { nil } }
    }
}

/// A controller over `root` with the fake launcher, in-memory relabel attempts, and a private vocabulary folder.
@MainActor
private func makeController(root: URL, launcher: FakeRecorderLauncher, probe: ControllerProbe,
                            free: Int64 = 500_000_000_000,
                            devices: InputDevices = InputDevices(builtIn: controllerBuiltIn,
                                                                 systemDefault: controllerBuiltIn),
                            vocabulary: [String] = [], vocabularyDirectory: URL? = nil,
                            maintenance: MaintenanceLauncher? = nil,
                            modelsInstalled: Bool = false,
                            now: @escaping @MainActor () -> Date = { Date() }) -> MeetingController {
    let controller = MeetingController(
        root: root, launcher: launcher, maintenance: maintenance, freeSpace: FixedFreeSpace(free),
        findInputDevices: { devices }, vocabulary: { vocabulary }, modelsInstalled: { modelsInstalled }, now: now,
        onChange: { probe.states.append($0) }, onEffect: { probe.effects.append($0) })
    controller.tuning = MeetingControllerTuning(poll: .milliseconds(20), rescan: .milliseconds(40),
                                                relabel: .seconds(3_600), ackTimeout: .milliseconds(200))
    controller.vocabularyDirectory = vocabularyDirectory ?? root.appendingPathComponent("tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: controller.vocabularyDirectory, withIntermediateDirectories: true)
    controller.loadRelabelAttempts = { probe.attempts }
    controller.saveRelabelAttempts = { probe.attempts = $0 }
    controller.loadLaunchedRecorders = { probe.launched }
    controller.saveLaunchedRecorders = { probe.launched = $0 }
    controller.loadDismissedOffers = { probe.dismissed }
    controller.saveDismissedOffers = { probe.dismissed = $0 }
    return controller
}

/// A live recording in `root`: the writer lock held by the returned archive and a fresh status with `phase`.
private func liveSession(in root: URL, id: String = UUID().uuidString,
                         phase: RecorderPhase = .recording) throws -> SessionArchive {
    let archive = try SessionArchive.create(root: root, name: "Council meeting", source: .microphone,
                                            locale: "en-CA", backend: .speech, id: id)
    try AtomicFile.writeJSON(meetingStatus(archive.id, phase: phase), to: SessionPaths.status(archive.directory))
    return archive
}

private func controllerMode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}

private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

@Test @MainActor func controllerReattachesToLiveSession() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let archive = try liveSession(in: temp.url)
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }
    controller.attachOnLaunch()
    guard case .active(let id, let status) = controller.state else {
        Issue.record("Expected active, got \(controller.state).")
        return
    }
    #expect(id == archive.id)
    #expect(status.phase == .recording)
    #expect(probe.dictation == [true])
    #expect(controller.dictationShouldPause)
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test @MainActor func controllerIgnoresStaleOrFinishedSessions() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    // A recorder that died long ago (no lock, old status) and one that exited.
    let dead = try SessionArchive.create(root: temp.url, name: "Old", source: .microphone, locale: "en-CA",
                                         backend: .speech)
    try AtomicFile.writeJSON(meetingStatus(dead.id, phase: .recording, updatedAt: Date().addingTimeInterval(-600)),
                             to: SessionPaths.status(dead.directory))
    try await dead.finish(status: ArchiveStatus.complete)
    let exited = try SessionArchive.create(root: temp.url, name: "Done", source: .microphone, locale: "en-CA",
                                           backend: .speech)
    try await exited.finish(status: ArchiveStatus.complete)
    try AtomicFile.writeJSON(meetingStatus(exited.id, phase: .exited), to: SessionPaths.status(exited.directory))
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }
    controller.attachOnLaunch()
    #expect(controller.state == .idle)
    #expect(probe.dictation.isEmpty)
}

/// Rewrites a test recorder's status.json at most once a second, as the recorder's heartbeat does, so a status stays
/// fresh however long a loaded machine takes to poll it.
@MainActor
private final class ControllerHeartbeat {
    private let session: URL
    var status: RecorderStatus
    private var last: ContinuousClock.Instant?

    init(session: URL, status: RecorderStatus) {
        self.session = session
        self.status = status
    }

    func beat(force: Bool = false) {
        let now = ContinuousClock.now
        guard force || last.map({ $0.duration(to: now) >= .seconds(1) }) ?? true else { return }
        last = now
        status.sequence += 1
        status.updatedAt = Date()
        try? AtomicFile.writeJSON(status, to: SessionPaths.status(session))
    }
}

@Test @MainActor func controllerFindsTerminalMeetingAfterLaunch() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }
    controller.attachOnLaunch()
    #expect(controller.state == .idle)
    // `holos record start` in a terminal, after the app launched.
    let archive = try liveSession(in: temp.url)
    let heartbeat = ControllerHeartbeat(session: archive.directory, status: meetingStatus(archive.id, phase: .recording))
    heartbeat.beat(force: true)
    // Within one rescan: once the rescan interval has passed, the next pass of the loop follows it.
    try await Task.sleep(for: controller.tuning.rescan + .milliseconds(10))
    heartbeat.beat()
    controller.step()
    guard case .active(let id, _) = controller.state, id == archive.id else {
        Issue.record("Expected active after one rescan, got \(controller.state).")
        return
    }
    #expect(probe.dictation == [true])
    // It stops: capture ends, then the recorder exits.
    heartbeat.status.phase = .transcribing
    heartbeat.beat(force: true)
    #expect(await eventually(timeout: .seconds(60)) {
        heartbeat.beat()
        if case .finishing = controller.state { return true }
        return false
    })
    #expect(probe.dictation == [true, false])
    // A recorder writes exited before it lets its last lock go, so it never reads as dead on the way out.
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested)
    try AtomicFile.writeJSON(meetingStatus(archive.id, phase: .exited, exit: exit), to: SessionPaths.status(archive.directory))
    try await archive.finish(status: ArchiveStatus.complete)
    #expect(await eventually(timeout: .seconds(60)) { controller.state == .idle })
    #expect(probe.effects.contains { if case .finished(archive.id, _, false) = $0 { true } else { false } })
}

@Test @MainActor func startFollowsATerminalMeetingNotYetRescanned() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe)
    defer { controller.stopMonitoring() }
    // `holos record start` in a terminal a moment ago; the idle rescan has not seen it yet (it is not polling here).
    let archive = try liveSession(in: temp.url, phase: .starting)
    let error = #expect(throws: HolosError.self) {
        try controller.start(MeetingStartSettings(name: "Second", source: .microphone))
    }
    #expect(error?.localizedDescription == MeetingReducer.alreadyRecording)
    #expect(launcher.launches.isEmpty)
    guard case .active(let id, _) = controller.state, id == archive.id else {
        Issue.record("Expected the terminal meeting to be followed, got \(controller.state).")
        return
    }
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test @MainActor func startWhileAStoppedStartWaitsSaysItIsStopping() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let controller = makeController(root: temp.url, launcher: launcher, probe: ControllerProbe())
    defer { controller.stopMonitoring() }
    try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    controller.confirmStop()
    #expect(launcher.terminated == launcher.launches.map(\.sessionID))
    let error = #expect(throws: HolosError.self) {
        try controller.start(MeetingStartSettings(name: "Again", source: .microphone))
    }
    #expect(error?.localizedDescription == MeetingReducer.stillStopping)
    #expect(launcher.launches.count == 1)
}

@Test @MainActor func controllerWritesControlFiles() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let archive = try liveSession(in: temp.url)
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: ControllerProbe())
    defer { controller.stopMonitoring() }
    controller.attachOnLaunch()
    let before = RecorderChannel.continuousNanoseconds()
    controller.pause()
    let folder = SessionPaths.controlDirectory(archive.directory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let files = names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
    #expect(files.count == 1)
    let file = try #require(files.first)
    let request = try AtomicFile.readJSON(ControlRequest.self, from: folder.appendingPathComponent(file))
    #expect(file == "\(request.id).json")
    #expect(request.command == .pause)
    #expect(request.sessionID == archive.id)
    #expect(request.sender == "app")
    #expect((request.sentAtNanos ?? 0) >= before)
    #expect(request.schemaVersion == 1)
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test @MainActor func transcribingRecorderIsFollowedAfterRelaunch() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let archive = try liveSession(in: temp.url, phase: .transcribing)
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }
    controller.attachOnLaunch()
    guard case .finishing(let id, _) = controller.state else {
        Issue.record("Expected finishing, got \(controller.state).")
        return
    }
    #expect(id == archive.id)
    #expect(probe.dictation.isEmpty, "Capture has stopped: dictation is not paused.")
    #expect(throws: HolosError.self) { try controller.start(MeetingStartSettings(name: "Next", source: .microphone)) }
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test @MainActor func undeliveredStopIsAnnouncedAndCanBeRetried() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let archive = try liveSession(in: temp.url)
    // A file where control/ belongs: no request can be published.
    try Data().write(to: SessionPaths.controlDirectory(archive.directory))
    let probe = ControllerProbe()
    let launcher = FakeRecorderLauncher()
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe)
    defer { controller.stopMonitoring() }
    controller.attachOnLaunch()
    controller.confirmStop()
    controller.confirmStop()
    let announcements = probe.effects.filter { if case .announce = $0 { true } else { false } }
    #expect(announcements.count == 2, "Each failed stop is reported, and the second one was tried again.")
    #expect(launcher.terminated == [archive.id, archive.id])
    guard case .active = controller.state else {
        Issue.record("The meeting is still recording.")
        return
    }
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test @MainActor func failedStopRequestIsSignalledToALaunchedRecorder() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe)
    defer { controller.stopMonitoring() }
    try controller.start(MeetingStartSettings(name: "Council meeting", source: .microphone))
    let id = try #require(launcher.launches.first?.sessionID)
    let archive = try liveSession(in: temp.url, id: id, phase: .recording)
    controller.poll()
    // A file where control/ belongs: no request can be published, but the recorder gets SIGTERM.
    try Data().write(to: SessionPaths.controlDirectory(archive.directory))
    controller.confirmStop()
    #expect(launcher.terminated == [id])
    #expect(controller.reducer.stopRequested, "The stop was delivered by the signal.")
    controller.confirmStop()
    #expect(launcher.terminated == [id], "Stop is not sent twice.")
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test @MainActor func startAfterTimedOutStartWaitsForItsRecorder() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    var clock = Date()
    let controller = makeController(root: temp.url, launcher: launcher, probe: ControllerProbe(), now: { clock })
    defer { controller.stopMonitoring() }
    try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    let id = try #require(launcher.launches.first?.sessionID)
    // Its recorder is alive, still at a permission prompt, when the menu gives up on it 2 minutes later.
    let archive = try liveSession(in: temp.url, id: id, phase: .starting)
    clock = clock.addingTimeInterval(121)
    try AtomicFile.writeJSON(meetingStatus(id, phase: .starting, updatedAt: clock), to: SessionPaths.status(archive.directory))
    controller.poll()
    #expect(launcher.terminated == [id])
    guard case .failed(let failedID, _) = controller.state, failedID == id else {
        Issue.record("Expected failed, got \(controller.state).")
        return
    }
    #expect(throws: HolosError.self) { try controller.start(MeetingStartSettings(name: "Again", source: .microphone)) }
    #expect(launcher.launches.count == 1)
    // Once that recorder is gone, a new start goes ahead.
    try await archive.finish(status: ArchiveStatus.failed)
    launcher.exit(id, code: 1, logTail: nil)
    try controller.start(MeetingStartSettings(name: "Again", source: .microphone))
    #expect(launcher.launches.count == 2)
}

/// A timed-out start whose recorder is still at a permission prompt before creating its session folder (liveness
/// says dead) blocks a second recorder until the launcher reports that the first one exited, even after the failure
/// was dismissed.
@Test @MainActor func startAfterTimedOutStartWithoutAFolderWaitsForItsExit() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    var clock = Date()
    let controller = makeController(root: temp.url, launcher: launcher, probe: ControllerProbe(), now: { clock })
    defer { controller.stopMonitoring() }
    try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    let id = try #require(launcher.launches.first?.sessionID)
    clock = clock.addingTimeInterval(121)
    controller.poll()
    #expect(launcher.terminated == [id])
    guard case .failed(let failedID, _) = controller.state, failedID == id else {
        Issue.record("Expected failed, got \(controller.state).")
        return
    }
    #expect(!exists(controller.sessionURL(id)), "The recorder has not created its session yet.")
    let error = #expect(throws: HolosError.self) {
        try controller.start(MeetingStartSettings(name: "Again", source: .microphone))
    }
    #expect(error?.localizedDescription == MeetingReducer.stillStopping)
    controller.dismissFailure()
    #expect(controller.state == .idle)
    #expect(throws: HolosError.self) { try controller.start(MeetingStartSettings(name: "Again", source: .microphone)) }
    #expect(launcher.launches.count == 1)
    // The prompt was answered; the recorder saw SIGTERM and exited.
    launcher.exit(id, code: 1, logTail: nil)
    try controller.start(MeetingStartSettings(name: "Again", source: .microphone))
    #expect(launcher.launches.count == 2)
}

/// The app quit from a timed-out start's failure (or crashed) while its recorder still waited at a permission prompt
/// without a session folder: the relaunched app, which did not launch that recorder and cannot wait for it, finds it
/// by its saved pid and start time and launches no second recorder until that process is gone.
@Test @MainActor func timedOutRecorderStillBlocksAStartAfterARelaunch() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let pid = getpid()
    let started = try #require(ProcessSpawner.startTime(of: pid))
    let launcher = FakeRecorderLauncher()
    // A process that runs for the whole test: this one.
    launcher.pid = pid
    var clock = Date()
    let probe = ControllerProbe()
    // A saved recorder of an even earlier run that has ended (no such pid) is forgotten on launch.
    probe.launched = ["ended": [Int(Int32.max), 1]]
    let first = makeController(root: temp.url, launcher: launcher, probe: probe, now: { clock })
    first.attachOnLaunch()
    first.stopMonitoring()
    #expect(probe.launched.isEmpty)
    try first.start(MeetingStartSettings(name: "Council", source: .microphone))
    let id = try #require(launcher.launches.first?.sessionID)
    #expect(probe.launched == [id: [Int(pid), Int(started)]])
    clock = clock.addingTimeInterval(121)
    first.poll()
    guard case .failed = first.state else {
        Issue.record("Expected failed, got \(first.state).")
        return
    }
    // Quit from the failure, then relaunched: a new controller and launcher, the saved records kept.
    let relaunched = FakeRecorderLauncher()
    let second = makeController(root: temp.url, launcher: relaunched, probe: probe, now: { clock })
    defer { second.stopMonitoring() }
    second.attachOnLaunch()
    #expect(probe.launched == [id: [Int(pid), Int(started)]])
    let error = #expect(throws: HolosError.self) {
        try second.start(MeetingStartSettings(name: "Again", source: .microphone))
    }
    #expect(error?.localizedDescription == MeetingReducer.stillStopping)
    #expect(relaunched.launches.isEmpty)
    // The pid now names a process that started at another time (the recorder exited and its pid was reused).
    probe.launched[id] = [Int(pid), Int(started) - 1]
    try second.start(MeetingStartSettings(name: "Again", source: .microphone))
    #expect(relaunched.launches.count == 1)
    #expect(probe.launched[id] == nil)
}

/// The launcher reporting the recorder's exit forgets its saved pid.
@Test @MainActor func recorderExitForgetsItsSavedPid() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    launcher.pid = getpid()
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe)
    defer { controller.stopMonitoring() }
    try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    let id = try #require(launcher.launches.first?.sessionID)
    #expect(probe.launched.keys.sorted() == [id])
    launcher.exit(id, code: 1, logTail: nil)
    #expect(probe.launched.isEmpty)
}

@Test @MainActor func startRefusedOnLowDisk() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe, free: 2_000_000_000)
    let error = #expect(throws: HolosError.self) {
        try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    }
    #expect(error?.errorDescription?.contains("Not enough free disk space") == true)
    #expect(launcher.launches.isEmpty)
    #expect(controller.state == .idle)
    #expect(probe.dictation.isEmpty)
}

@Test @MainActor func inPersonStartRefusedWithoutBuiltInMic() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let controller = makeController(root: temp.url, launcher: launcher, probe: ControllerProbe(),
                                    devices: InputDevices(builtIn: nil, systemDefault: controllerAirPods))
    let error = #expect(throws: HolosError.self) {
        try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    }
    #expect(error?.errorDescription == BuiltInMicrophone.unavailableMessage)
    #expect(launcher.launches.isEmpty)
}

@Test @MainActor func callStartAllowedWithoutBuiltInMic() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe,
                                    devices: InputDevices(builtIn: nil, systemDefault: controllerAirPods))
    try controller.start(MeetingStartSettings(name: "Weekly call", source: .microphoneAndSystem,
                                              applicationBundleID: "us.zoom.xos"))
    #expect(launcher.launches.count == 1)
    #expect(launcher.launches.first?.settings.source == .microphoneAndSystem)
    #expect(launcher.launches.first?.root == temp.url)
    guard case .starting(let id, _, let pid) = controller.state else {
        Issue.record("Expected starting, got \(controller.state).")
        return
    }
    #expect(id == launcher.launches.first?.sessionID)
    #expect(pid == 4_242)
    #expect(probe.dictation == [true])
}

@Test @MainActor func vocabularyFileIsPrivate() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let controller = makeController(root: temp.url, launcher: launcher, probe: ControllerProbe(),
                                    vocabulary: ["Maria Chen", "  ", String(repeating: "x", count: 101)])
    let settings = MeetingStartSettings(name: "Council", source: .microphone)
    try controller.start(settings)
    let launch = try #require(launcher.launches.first)
    let file = try #require(launch.vocabularyFile)
    #expect(file.lastPathComponent == "holos-vocabulary-\(launch.sessionID).json")
    #expect(controllerMode(file) == 0o600)
    let vocabulary = try AtomicFile.readJSON(MeetingVocabulary.self, from: file)
    #expect(vocabulary == MeetingVocabulary(strings: ["Maria Chen"]))
    let arguments = ChildProcessLauncher.arguments(launch.settings, sessionID: launch.sessionID, root: temp.url,
                                                   vocabularyFile: file)
    let flag = try #require(arguments.firstIndex(of: "--vocabulary-file"))
    #expect(arguments[flag + 1] == file.path)
    // What the recorder does with it: reads it and deletes it.
    #expect(try VocabularyFile.consume(file) == ["Maria Chen"])
}

@Test @MainActor func noVocabularyMeansNoFile() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let controller = makeController(root: temp.url, launcher: launcher, probe: ControllerProbe())
    try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    #expect(launcher.launches.first?.vocabularyFile == nil)
}

@Test @MainActor func vocabularyFileRemovedOnLaunchFailure() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    launcher.launchError = HolosError.io("Cannot start holos: spawn failed.")
    let probe = ControllerProbe()
    let vocabularyFolder = temp.url.appendingPathComponent("tmp", isDirectory: true)
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe, vocabulary: ["Maria Chen"],
                                    vocabularyDirectory: vocabularyFolder)
    #expect(throws: HolosError.self) {
        try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    }
    let left = (try? FileManager.default.contentsOfDirectory(atPath: vocabularyFolder.path)) ?? []
    #expect(left.isEmpty, "The vocabulary file must not outlive a failed launch: \(left)")
    #expect(controller.state == .failed(sessionID: nil, message: "Cannot start holos: spawn failed."))
    #expect(!probe.dictation.contains(true), "Dictation was never paused for a start that did not happen.")
}

@Test @MainActor func vocabularyFileRemovedOnEarlyExit() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe, vocabulary: ["Maria Chen"])
    defer { controller.stopMonitoring() }
    try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    let file = try #require(launcher.launches.first?.vocabularyFile)
    #expect(exists(file))
    // The child exits before writing any status (the built-in microphone vanished).
    launcher.exit(code: 1, logTail: "The built-in microphone is unavailable. Open the lid and try again.")
    #expect(!exists(file))
    #expect(controller.state == .failed(sessionID: launcher.launches.first?.sessionID,
                                        message: "The built-in microphone is unavailable. Open the lid and try again."))
    #expect(probe.dictation == [true, false])
}

@Test @MainActor func vocabularyFileRemovedOnFirstStatus() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let controller = makeController(root: temp.url, launcher: launcher, probe: ControllerProbe(),
                                    vocabulary: ["Maria Chen"])
    defer { controller.stopMonitoring() }
    try controller.start(MeetingStartSettings(name: "Council", source: .microphone))
    let launch = try #require(launcher.launches.first)
    let file = try #require(launch.vocabularyFile)
    controller.poll()
    #expect(exists(file), "No status yet: the recorder may not have copied the vocabulary.")
    // The recorder's first status (it copied the vocabulary into the session before writing it).
    let archive = try liveSession(in: temp.url, id: launch.sessionID, phase: .starting)
    controller.poll()
    #expect(!exists(file))
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test @MainActor func staleVocabularyFilesSwept() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let folder = temp.url.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-2 * 3_600)
    let stale = folder.appendingPathComponent("holos-vocabulary-\(UUID().uuidString).json")
    let fresh = folder.appendingPathComponent("holos-vocabulary-\(UUID().uuidString).json")
    let unrelated = folder.appendingPathComponent("notes.json")
    let staleFolder = folder.appendingPathComponent("holos-vocabulary-folder.json", isDirectory: true)
    for file in [stale, fresh, unrelated] { try Data("{}".utf8).write(to: file) }
    try FileManager.default.createDirectory(at: staleFolder, withIntermediateDirectories: true)
    for url in [stale, unrelated, staleFolder] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let link = folder.appendingPathComponent("holos-vocabulary-link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
    // A vocabulary file whose removal a crash interrupted after it was moved aside (AtomicFile.removeIfSame).
    let handedOff = folder.appendingPathComponent("holos-vocabulary-\(UUID().uuidString).json")
    try Data("{}".utf8).write(to: handedOff)
    var info = stat()
    #expect(lstat(handedOff.path, &info) == 0)
    let aside = folder.appendingPathComponent(
        ".holos-remove-\(UInt32(bitPattern: info.st_dev)).\(info.st_ino).\(UUID().uuidString)", isDirectory: true)
    #expect(mkdir(aside.path, 0o700) == 0)
    #expect(rename(handedOff.path, aside.appendingPathComponent("file").path) == 0)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: aside.path)
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: ControllerProbe(),
                                    vocabularyDirectory: folder)
    defer { controller.stopMonitoring() }
    controller.attachOnLaunch()
    #expect(!exists(aside), "An interrupted removal is finished on launch.")
    #expect(!exists(stale))
    #expect(exists(fresh))
    #expect(exists(unrelated))
    #expect(exists(staleFolder), "Only regular files are swept.")
    #expect(exists(link))
}

@Test @MainActor func launchedMeetingIsFollowedToTheEnd() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let launcher = FakeRecorderLauncher()
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: launcher, probe: probe)
    defer { controller.stopMonitoring() }
    try controller.start(MeetingStartSettings(name: "Council meeting", source: .microphone))
    let id = try #require(launcher.launches.first?.sessionID)
    let archive = try liveSession(in: temp.url, id: id, phase: .recording)
    controller.poll()
    guard case .active = controller.state else {
        Issue.record("Expected active, got \(controller.state).")
        return
    }
    controller.confirmStop()
    controller.confirmStop()
    let requests = (try? FileManager.default.contentsOfDirectory(
        atPath: SessionPaths.controlDirectory(archive.directory).path))?.filter { $0.hasSuffix(".json") } ?? []
    #expect(requests.count == 1, "Stop is sent once.")
    try await archive.finish(status: ArchiveStatus.complete)
    // Post-processing succeeded without labels (speaker models not installed): no naming offer.
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: .succeeded,
                            postprocessingMessage: "No speaker labels: speaker models are not installed.")
    try AtomicFile.writeJSON(meetingStatus(id, phase: .exited, exit: exit), to: SessionPaths.status(archive.directory))
    controller.poll()
    #expect(controller.state == .idle)
    #expect(await eventually {
        probe.effects.contains { if case .finished(id, _, false) = $0 { true } else { false } }
    })
    #expect(!probe.effects.contains { if case .offerNaming = $0 { true } else { false } })
    #expect(probe.dictation == [true, false])
    // The child's exit afterwards changes nothing.
    launcher.exit(code: 0, logTail: nil)
    #expect(controller.state == .idle)
}

/// A recording whose post-processing ran to its end, even with a warning (partial), and saved labels that load is
/// offered for naming.
@Test(arguments: [PostProcessingState.succeeded, .partial]) @MainActor
func finishedMeetingWithLabelsOffersNaming(postprocessing: PostProcessingState) async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let labelled = try await SessionFixtures.labelledSession(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: labelled.session)
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }
    // Followed while labelling, then exited with labels.
    let lease = try SessionArchive.acquireProcessingLease(at: labelled.session)
    try AtomicFile.writeJSON(meetingStatus(manifest.id, phase: .postprocessing, name: manifest.name),
                             to: SessionPaths.status(labelled.session))
    controller.attachOnLaunch()
    guard case .finishing = controller.state else {
        Issue.record("Expected finishing, got \(controller.state).")
        return
    }
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: postprocessing)
    try AtomicFile.writeJSON(meetingStatus(manifest.id, phase: .exited, name: manifest.name, exit: exit),
                             to: SessionPaths.status(labelled.session))
    lease.release()
    controller.poll()
    #expect(await eventually {
        probe.effects.contains(.offerNaming(sessionID: manifest.id, name: manifest.name))
    })
    #expect(probe.effects.contains { if case .finished(manifest.id, _, true) = $0 { true } else { false } })
    #expect(probe.effects.filter { if case .offerNaming = $0 { true } else { false } }.count == 1)
    controller.reviewOpened(sessionID: manifest.id)
    #expect(probe.effects.last == .clearNamingOffer(sessionID: manifest.id))
}

/// A recording whose post-processing ended without labels (speaker models not installed: succeeded or partial) is
/// reported without speakers and not offered for naming.
@Test(arguments: [PostProcessingState.succeeded, .partial]) @MainActor
func finishedMeetingWithoutLabelsOffersNothing(postprocessing: PostProcessingState) async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }
    let id = UUID().uuidString
    // Followed while labelling (the recording saved, the processing lease held), then exited without labels.
    let archive = try liveSession(in: temp.url, id: id, phase: .postprocessing)
    try await archive.finish(status: ArchiveStatus.complete)
    let lease = try SessionArchive.acquireProcessingLease(at: archive.directory)
    defer { lease.release() }
    controller.attachOnLaunch()
    guard case .finishing = controller.state else {
        Issue.record("Expected finishing, got \(controller.state).")
        return
    }
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: postprocessing,
                            postprocessingMessage: "No speaker labels: speaker models are not installed.")
    try AtomicFile.writeJSON(meetingStatus(id, phase: .exited, exit: exit), to: SessionPaths.status(archive.directory))
    lease.release()
    controller.poll()
    #expect(controller.state == .idle)
    #expect(await eventually {
        probe.effects.contains { if case .finished(id, _, false) = $0 { true } else { false } }
    })
    try await Task.sleep(for: .milliseconds(100))
    #expect(!probe.effects.contains { if case .offerNaming = $0 { true } else { false } })
}

/// Recover and Label Speakers from the Meetings window or the launch prompt: `labellingCommandEnded` tells the result
/// alert whether the command ran to its end (0, or 3 with a warning) and left labels that load. The offer itself comes
/// from the end of the command's use of the meeting (`endUsing`), once.
@Test @MainActor func labellingCommandThatLeavesLabelsOffersNaming() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    // Labels still being written while the command runs: the head is put back when it "ends".
    let labelled = try await SessionFixtures.labelledSession(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: labelled.session)
    let head = SessionPaths.head(labelled.session)
    let aside = temp.url.appendingPathComponent("head.json")
    try FileManager.default.moveItem(at: head, to: aside)
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }

    #expect(controller.beginUsing(manifest.id, for: "Labelling speakers…"))
    try FileManager.default.moveItem(at: aside, to: head)
    #expect(!(await controller.labellingCommandEnded(session: labelled.session, code: 1)), "A failed command.")
    #expect(await controller.labellingCommandEnded(session: labelled.session, code: 0))
    #expect(await controller.labellingCommandEnded(session: labelled.session, code: 3))
    #expect(probe.offers.isEmpty, "The result check offers nothing by itself.")
    controller.endUsing(manifest.id)
    #expect(await eventually { probe.offers == [.offerNaming(sessionID: manifest.id, name: manifest.name)] })
    #expect(controller.namingOffer?.sessionID == manifest.id)
    #expect(controller.state == .idle)
    // Another command that changed nothing: the offer stands and is not repeated.
    #expect(controller.beginUsing(manifest.id, for: "Recovering…"))
    controller.endUsing(manifest.id)
    try await Task.sleep(for: .milliseconds(200))
    #expect(probe.offers.count == 1)

    // Labels that do not load (the run's transcript is gone): the result says so, and the offer is withdrawn.
    try FileManager.default.removeItem(at: SessionPaths.transcript(labelled.run.transcriptID, in: labelled.session))
    #expect(!(await controller.labellingCommandEnded(session: labelled.session, code: 0)))
    controller.refreshNamingOffer()
    #expect(await eventually { probe.effects.last == .clearNamingOffer(sessionID: manifest.id) })
    #expect(controller.namingOffer == nil)
}

/// A meeting labelled while Holos was not running (the recorder finished its labelling after a quit, or a command ran
/// in a terminal) is offered on the next launch; the offer is not repeated by later refreshes, and once the user
/// opens it the dismissal survives a relaunch. New labels for the meeting (another run) are offered again.
@Test @MainActor func meetingLabelledWhileHolosWasNotRunningIsOfferedOnLaunch() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let labelled = try await SessionFixtures.labelledSession(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: labelled.session)
    // The recorder wrote exited after labelling, while no app was running.
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: .succeeded)
    try AtomicFile.writeJSON(meetingStatus(manifest.id, phase: .exited, name: manifest.name, exit: exit),
                             to: SessionPaths.status(labelled.session))
    let probe = ControllerProbe()
    let first = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    first.attachOnLaunch()
    #expect(first.state == .idle)
    #expect(await eventually { first.namingOffer?.sessionID == manifest.id })
    #expect(probe.offers == [.offerNaming(sessionID: manifest.id, name: manifest.name)])
    first.refreshNamingOffer()
    try await Task.sleep(for: .milliseconds(200))
    #expect(probe.offers.count == 1)
    first.stopMonitoring()

    // Quit and relaunched before it was opened: offered again.
    let second = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    second.attachOnLaunch()
    #expect(await eventually { second.namingOffer?.sessionID == manifest.id })
    second.reviewOpened(sessionID: manifest.id)
    #expect(second.namingOffer == nil)
    #expect(probe.effects.last == .clearNamingOffer(sessionID: manifest.id))
    #expect(probe.dismissed == [manifest.id: labelled.run.id])
    second.stopMonitoring()

    // Opened, then relaunched: not offered.
    let third = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    let offersBefore = probe.offers.count
    third.attachOnLaunch()
    try await Task.sleep(for: .milliseconds(300))
    #expect(third.namingOffer == nil)
    #expect(probe.offers.count == offersBefore)

    // Labelled again (a new run): offered again.
    let run = try SessionFixtures.writeHeadRun(session: labelled.session, transcript: labelled.transcript,
                                               outputs: ["system": SessionFixtures.alternatingOutput()])
    third.refreshNamingOffer()
    #expect(await eventually { third.namingOffer?.runID == run.id })
    third.stopMonitoring()
}

/// A meeting whose speakers were edited (named) is not offered, and one deleted meanwhile has its offer withdrawn.
@Test @MainActor func namingOfferFollowsEditsAndDeletion() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let labelled = try await SessionFixtures.labelledSession(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: labelled.session)
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }
    controller.refreshNamingOffer()
    #expect(await eventually { controller.namingOffer?.sessionID == manifest.id })
    let speaker = try #require(labelled.run.speakers.first)
    try SessionFixtures.appendEdits([.rename(speakerID: speaker.id, name: "Ada")], session: labelled.session)
    controller.refreshNamingOffer()
    #expect(await eventually { controller.namingOffer == nil })
    #expect(probe.effects.last == .clearNamingOffer(sessionID: manifest.id))

    let other = try await SessionFixtures.labelledSession(in: temp.url)
    let otherManifest = try SessionArchive.readManifest(at: other.session)
    controller.refreshNamingOffer()
    #expect(await eventually { controller.namingOffer?.sessionID == otherManifest.id })
    try FileManager.default.removeItem(at: other.session)
    controller.refreshNamingOffer()
    #expect(await eventually { controller.namingOffer == nil })
}

/// One set of meetings in use: a second use of a meeting is turned down until the first ends, and each change is
/// reported.
@Test @MainActor func sessionsInUseTurnDownASecondUse() throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: ControllerProbe())
    var changes = 0
    controller.onSessionsInUseChanged = { changes += 1 }
    #expect(controller.beginUsing("A", for: "Cleaning up…"))
    #expect(!controller.beginUsing("A", for: "Recovering…"))
    #expect(controller.sessionsInUse == ["A": "Cleaning up…"])
    #expect(controller.beginUsing("B", for: "Saving the transcript…"))
    controller.endUsing("A")
    controller.endUsing("A")
    #expect(controller.sessionsInUse == ["B": "Saving the transcript…"])
    #expect(controller.beginUsing("A", for: "Recovering…"))
    #expect(changes == 4)
}

/// A meeting whose post-processing succeeded but whose head names a run that cannot be used (its transcript is
/// missing) is not offered for naming and does not report speakers ready: the catalog calls those labels unreadable
/// and the exports leave them out.
@Test @MainActor func finishedMeetingWithUnusableLabelsIsNotOfferedForNaming() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let labelled = try await SessionFixtures.labelledSession(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: labelled.session)
    try FileManager.default.removeItem(at: SessionPaths.transcript(labelled.run.transcriptID,
                                                               in: labelled.session))
    #expect(try SessionSpeakerStore.readHead(session: labelled.session) != nil, "The head alone still reads.")
    #expect(!MeetingController.speakerLabelsReady(session: labelled.session))
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe)
    defer { controller.stopMonitoring() }
    let lease = try SessionArchive.acquireProcessingLease(at: labelled.session)
    try AtomicFile.writeJSON(meetingStatus(manifest.id, phase: .postprocessing, name: manifest.name),
                             to: SessionPaths.status(labelled.session))
    controller.attachOnLaunch()
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: .succeeded)
    try AtomicFile.writeJSON(meetingStatus(manifest.id, phase: .exited, name: manifest.name, exit: exit),
                             to: SessionPaths.status(labelled.session))
    lease.release()
    controller.poll()
    #expect(await eventually {
        probe.effects.contains { if case .finished(manifest.id, _, false) = $0 { true } else { false } }
    })
    #expect(!probe.effects.contains { if case .offerNaming = $0 { true } else { false } })
}

@Test func speakerLabelsReadyFollowsTheSharedValidation() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let labelled = try await SessionFixtures.labelledSession(in: temp.url)
    #expect(MeetingController.speakerLabelsReady(session: labelled.session))
    // A damaged run file: the head still reads, the labels do not load.
    try Data("{".utf8).write(to: SessionPaths.run(labelled.run.id, in: labelled.session))
    #expect(!MeetingController.speakerLabelsReady(session: labelled.session))
    let unlabelled = try await SessionFixtures.makeSession(
        in: temp.url, mode: .inPerson,
        transcript: SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic")))
    #expect(!MeetingController.speakerLabelsReady(session: unlabelled))
    #expect(!MeetingController.speakerLabelsReady(session: temp.url.appendingPathComponent("missing.holos")))
}

@Test @MainActor func interruptedSessionsAreListedOnce() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    // A recorder that died: manifest still recording, no lock.
    let id: String = try {
        let archive = try SessionArchive.create(root: temp.url, name: "Council", source: .microphone,
                                                locale: "en-CA", backend: .speech)
        return archive.id
    }()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: ControllerProbe())
    #expect(await controller.interruptedSessions(excluding: []).map(\.id) == [id])
    #expect(await controller.interruptedSessions(excluding: [id]).isEmpty)
}

@Test @MainActor func automaticRelabelRunsDiarizeOnce() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(
        in: temp.url, mode: .inPerson,
        transcript: SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic")))
    // Labelling was cut short: a running record and no lock.
    let manifest = try SessionArchive.readManifest(at: session)
    try AtomicFile.writeJSON(PostProcessingRecord(sessionID: manifest.id, state: .running, pid: Int32.max,
                                                  startedAt: Date(), updatedAt: Date()),
                             to: SessionPaths.postprocess(session))
    let arguments = temp.url.appendingPathComponent("arguments.txt")
    let script = temp.url.appendingPathComponent("fake-holos.sh")
    try Data("#!/bin/sh\necho \"$*\" >> '\(arguments.path)'\n".utf8).write(to: script)
    #expect(chmod(script.path, 0o700) == 0)
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe,
                                    maintenance: MaintenanceLauncher(executable: script), modelsInstalled: true)
    defer { controller.stopMonitoring() }
    // While the app uses the meeting (a Meetings command, Clean Up, Save Transcript As…), the relabel leaves it alone.
    for doing in ["Recovering…", "Cleaning up…", "Saving the transcript…"] {
        #expect(controller.beginUsing(manifest.id, for: doing))
        controller.runAutoRelabel()
        #expect(await eventually(timeout: .seconds(10)) { !controller.relabelling })
        controller.endUsing(manifest.id)
    }
    #expect(!exists(arguments))
    #expect(probe.attempts.isEmpty)
    controller.runAutoRelabel()
    #expect(controller.relabelling)
    #expect(await eventually(timeout: .seconds(10)) { !controller.relabelling && exists(arguments) })
    let text = (try? String(contentsOf: arguments, encoding: .utf8)) ?? ""
    #expect(text == "session diarize \(session.path) --json\n")
    #expect(probe.attempts == [manifest.id: 1])
    // The fake labelling changed nothing, so the session is still a candidate: a second attempt, then no more.
    controller.runAutoRelabel()
    #expect(await eventually(timeout: .seconds(10)) { probe.attempts[manifest.id] == 2 && !controller.relabelling })
    controller.runAutoRelabel()
    #expect(await eventually(timeout: .seconds(10)) { !controller.relabelling })
    #expect(probe.attempts[manifest.id] == 2)
    let lines = ((try? String(contentsOf: arguments, encoding: .utf8)) ?? "").split(separator: "\n")
    #expect(lines.count == 2)
    // The command succeeded without labelling anything: no naming offer.
    try await Task.sleep(for: .milliseconds(200))
    #expect(!probe.effects.contains { if case .offerNaming = $0 { true } else { false } })
}

/// A relabel whose command could not start (here the bundled tool is missing) uses up no attempt: once the tool is
/// back, the meeting is still relabelled.
@Test @MainActor func automaticRelabelThatCannotStartUsesNoAttempt() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(
        in: temp.url, mode: .inPerson,
        transcript: SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic")))
    let manifest = try SessionArchive.readManifest(at: session)
    try AtomicFile.writeJSON(PostProcessingRecord(sessionID: manifest.id, state: .running, pid: Int32.max,
                                                  startedAt: Date(), updatedAt: Date()),
                             to: SessionPaths.postprocess(session))
    let arguments = temp.url.appendingPathComponent("arguments.txt")
    let script = temp.url.appendingPathComponent("fake-holos.sh")
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe,
                                    maintenance: MaintenanceLauncher(executable: script), modelsInstalled: true)
    defer { controller.stopMonitoring() }
    // More failed launches than `AutoRelabelPolicy.maxAttempts`.
    for _ in 0...AutoRelabelPolicy.maxAttempts {
        controller.runAutoRelabel()
        #expect(controller.relabelling)
        #expect(await eventually(timeout: .seconds(10)) { !controller.relabelling })
        #expect(probe.attempts[manifest.id] == nil, "A command that did not start is not an attempt.")
    }
    #expect(controller.relabellingSessionID == nil)
    try Data("#!/bin/sh\necho \"$*\" >> '\(arguments.path)'\n".utf8).write(to: script)
    #expect(chmod(script.path, 0o700) == 0)
    controller.runAutoRelabel()
    #expect(await eventually(timeout: .seconds(10)) { !controller.relabelling && exists(arguments) })
    #expect(probe.attempts == [manifest.id: 1])
}

/// A meeting labelled by the automatic relabel is offered for naming once, as a meeting that just ended is, also when
/// the labelling ended with a warning (exit code 3); one the relabel did not label is not.
@Test(arguments: [Int32(0), 3]) @MainActor
func automaticRelabelThatLabelsOffersNamingOnce(code: Int32) async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let labelled = try await SessionFixtures.labelledSession(in: temp.url)
    let session = labelled.session
    let manifest = try SessionArchive.readManifest(at: session)
    // Labelling was cut short before the head was written: a running record and no head. The fake command writes
    // the head (moves it back).
    let head = SessionPaths.head(session)
    let aside = temp.url.appendingPathComponent("head.json")
    try FileManager.default.moveItem(at: head, to: aside)
    try AtomicFile.writeJSON(PostProcessingRecord(sessionID: manifest.id, state: .running, pid: Int32.max,
                                                  startedAt: Date(), updatedAt: Date()),
                             to: SessionPaths.postprocess(session))
    let script = temp.url.appendingPathComponent("fake-holos.sh")
    try Data("#!/bin/sh\nmv '\(aside.path)' '\(head.path)' || exit 1\nexit \(code)\n".utf8).write(to: script)
    #expect(chmod(script.path, 0o700) == 0)
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe,
                                    maintenance: MaintenanceLauncher(executable: script), modelsInstalled: true)
    defer { controller.stopMonitoring() }
    controller.runAutoRelabel()
    #expect(await eventually {
        probe.effects.contains(.offerNaming(sessionID: manifest.id, name: manifest.name))
    })
    #expect(!controller.relabelling)
    // The record still says running, so the meeting is picked once more; that attempt labels nothing new (the
    // command fails), and no second offer follows.
    controller.runAutoRelabel()
    #expect(await eventually { probe.attempts[manifest.id] == 2 && !controller.relabelling })
    try await Task.sleep(for: .milliseconds(200))
    #expect(probe.effects.filter { if case .offerNaming = $0 { true } else { false } }.count == 1)
}

@Test @MainActor func automaticRelabelNamesTheMeetingWhileItRuns() async throws {
    let temp = try TemporaryDirectory("controller")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(
        in: temp.url, mode: .inPerson,
        transcript: SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic")))
    let manifest = try SessionArchive.readManifest(at: session)
    try AtomicFile.writeJSON(PostProcessingRecord(sessionID: manifest.id, state: .running, pid: Int32.max,
                                                  startedAt: Date(), updatedAt: Date()),
                             to: SessionPaths.postprocess(session))
    // A labelling that runs until the test opens the gate (10 s at most).
    let gate = temp.url.appendingPathComponent("gate")
    let script = temp.url.appendingPathComponent("fake-holos.sh")
    try Data("#!/bin/sh\ni=0\nwhile [ ! -e '\(gate.path)' ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done\n".utf8)
        .write(to: script)
    #expect(chmod(script.path, 0o700) == 0)
    let probe = ControllerProbe()
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: probe,
                                    maintenance: MaintenanceLauncher(executable: script), modelsInstalled: true)
    defer { controller.stopMonitoring() }
    defer { try? Data().write(to: gate) }
    #expect(controller.relabellingSessionID == nil)
    controller.runAutoRelabel()
    // While it runs, the meeting is in use: the app turns down Meetings commands, Clean Up, and Save Transcript As…
    // for it (they would contend for its lease).
    #expect(await eventually(timeout: .seconds(10)) { controller.relabellingSessionID == manifest.id })
    #expect(controller.relabelling)
    #expect(controller.sessionsInUse == [manifest.id: MeetingController.relabelDoing])
    #expect(!controller.beginUsing(manifest.id, for: "Cleaning up…"))
    try Data().write(to: gate)
    #expect(await eventually(timeout: .seconds(10)) { !controller.relabelling })
    #expect(controller.relabellingSessionID == nil)
    #expect(controller.sessionsInUse.isEmpty)
    #expect(controller.beginUsing(manifest.id, for: "Cleaning up…"))
}
