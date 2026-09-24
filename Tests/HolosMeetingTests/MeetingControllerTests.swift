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
                            modelsInstalled: Bool = false) -> MeetingController {
    let controller = MeetingController(
        root: root, launcher: launcher, maintenance: maintenance, freeSpace: FixedFreeSpace(free),
        findInputDevices: { devices }, vocabulary: { vocabulary }, modelsInstalled: { modelsInstalled },
        onChange: { probe.states.append($0) }, onEffect: { probe.effects.append($0) })
    controller.tuning = MeetingControllerTuning(poll: .milliseconds(20), rescan: .milliseconds(40),
                                                relabel: .seconds(3_600), ackTimeout: .milliseconds(200))
    controller.vocabularyDirectory = vocabularyDirectory ?? root.appendingPathComponent("tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: controller.vocabularyDirectory, withIntermediateDirectories: true)
    controller.loadRelabelAttempts = { probe.attempts }
    controller.saveRelabelAttempts = { probe.attempts = $0 }
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
    #expect(await eventually(timeout: .seconds(10)) {
        if case .active(let id, _) = controller.state { return id == archive.id }
        return false
    })
    #expect(probe.dictation == [true])
    // It stops: capture ends, then the recorder exits.
    try AtomicFile.writeJSON(meetingStatus(archive.id, phase: .transcribing), to: SessionPaths.status(archive.directory))
    #expect(await eventually(timeout: .seconds(10)) {
        if case .finishing = controller.state { return true }
        return false
    })
    #expect(probe.dictation == [true, false])
    // A recorder writes exited before it lets its last lock go, so it never reads as dead on the way out.
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested)
    try AtomicFile.writeJSON(meetingStatus(archive.id, phase: .exited, exit: exit), to: SessionPaths.status(archive.directory))
    try await archive.finish(status: ArchiveStatus.complete)
    #expect(await eventually(timeout: .seconds(10)) { controller.state == .idle })
    #expect(probe.effects.contains { if case .finished(archive.id, _, false) = $0 { true } else { false } })
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
    let controller = makeController(root: temp.url, launcher: FakeRecorderLauncher(), probe: ControllerProbe(),
                                    vocabularyDirectory: folder)
    defer { controller.stopMonitoring() }
    controller.attachOnLaunch()
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
    #expect(probe.effects.contains { if case .finished(id, _, false) = $0 { true } else { false } })
    #expect(!probe.effects.contains { if case .offerNaming = $0 { true } else { false } })
    #expect(probe.dictation == [true, false])
    // The child's exit afterwards changes nothing.
    launcher.exit(code: 0, logTail: nil)
    #expect(controller.state == .idle)
}

@Test @MainActor func finishedMeetingWithLabelsOffersNaming() async throws {
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
    let exit = RecorderExit(archiveStatus: ArchiveStatus.complete, reason: .requested, postprocessing: .succeeded)
    try AtomicFile.writeJSON(meetingStatus(manifest.id, phase: .exited, name: manifest.name, exit: exit),
                             to: SessionPaths.status(labelled.session))
    lease.release()
    controller.poll()
    #expect(probe.effects.contains(.offerNaming(sessionID: manifest.id, name: manifest.name)))
    #expect(probe.effects.contains { if case .finished(manifest.id, _, true) = $0 { true } else { false } })
    controller.reviewOpened(sessionID: manifest.id)
    #expect(probe.effects.last == .clearNamingOffer(sessionID: manifest.id))
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
    #expect(controller.interruptedSessions(excluding: []).map(\.id) == [id])
    #expect(controller.interruptedSessions(excluding: [id]).isEmpty)
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
    controller.runAutoRelabel()
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
}
