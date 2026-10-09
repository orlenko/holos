import Darwin
import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing

// The recorder and maintenance launchers and their posix_spawn helper (docs/meeting-design.md §4.1, §1.7 rule 4).

/// A finished session in `root`, for lock tests.
private func launcherSession(in root: URL) async throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Council", source: .microphone, locale: "en-CA",
                                            backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    return archive.directory
}

/// An executable shell script in `folder`.
private func launcherScript(_ body: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent("fake-holos-\(UUID().uuidString).sh")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else { throw HolosError.io("chmod failed") }
    return url
}

private func launcherMode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}

@Test func launcherArguments() {
    let settings = MeetingStartSettings(name: "Council meeting", source: .microphoneAndSystem,
                                        applicationBundleID: "us.zoom.xos", othersInRoom: true, expectedSpeakers: 8,
                                        locales: ["fr-CA", "en-CA"])
    let id = "3F2A9C1E-0000-4000-8000-000000000001"
    let root = URL(fileURLWithPath: "/Users/me/Library/Application Support/Holos/Sessions", isDirectory: true)
    let vocabulary = URL(fileURLWithPath: "/private/tmp/holos-vocabulary-\(id).json")
    // The recorder transcribes in the first language live, and detects the others afterwards (§4.14).
    #expect(ChildProcessLauncher.arguments(settings, sessionID: id, root: root, vocabularyFile: vocabulary) == [
        "record", "start", "--session-id", id, "--name=Council meeting", "--source", "mic+system",
        "--languages=fr-CA,en-CA", "--app", "us.zoom.xos", "--others-in-room", "--expected-speakers", "8",
        "--vocabulary-file", vocabulary.path, "--no-live-text", "--directory", root.path,
    ])
    let inPerson = MeetingStartSettings(name: "Board", source: .microphone)
    #expect(ChildProcessLauncher.arguments(inPerson, sessionID: id, root: root, vocabularyFile: nil) == [
        "record", "start", "--session-id", id, "--name=Board", "--source", "mic", "--no-live-text",
        "--directory", root.path,
    ])
    // A name that starts with a dash stays one element, joined to its option, so it is never read as an option.
    let dashed = MeetingStartSettings(name: "-1:1 with Sam", source: .microphone)
    let arguments = ChildProcessLauncher.arguments(dashed, sessionID: id, root: root, vocabularyFile: nil)
    #expect(arguments.contains("--name=-1:1 with Sam"))
    #expect(!arguments.contains("--name"))
}

@Test func screenCaptureIsPassedToChildAndLegacySettingsStayOff() throws {
    let settings = MeetingStartSettings(name: "Synthetic", source: .microphone, screen: .display)
    let root = URL(fileURLWithPath: "/tmp/test")
    let args = ChildProcessLauncher.arguments(settings, sessionID: "id", root: root, vocabularyFile: nil)
    let index = try #require(args.firstIndex(of: "--screen"))
    #expect(args[index + 1] == "display")
    #expect(!args.contains("--screen-window") && !args.contains("--screen-owner"))
    let off = MeetingStartSettings(name: "Synthetic", source: .microphone)
    #expect(!ChildProcessLauncher.arguments(off, sessionID: "id", root: root, vocabularyFile: nil).contains("--screen"))
    #expect(try HolosJSON.decoder().decode(MeetingStartSettings.self,
        from: HolosJSON.encoder().encode(settings)).screen == .display)
    let legacy = Data("{\"name\":\"Synthetic\",\"source\":\"mic\",\"othersInRoom\":false}".utf8)
    #expect(try HolosJSON.decoder().decode(MeetingStartSettings.self, from: legacy).screen == nil)
    // A window chosen before the whole display was captured, or a target this version does not know: no capture,
    // and the rest of the saved settings still load.
    let window = Data("""
        {"name":"Synthetic","source":"mic","othersInRoom":false,"screenWindow":{"windowID":1,"ownerPID":2}}
        """.utf8)
    #expect(try HolosJSON.decoder().decode(MeetingStartSettings.self, from: window).screen == nil)
    let unknown = Data("{\"name\":\"Synthetic\",\"source\":\"mic\",\"othersInRoom\":false,\"screen\":\"wall\"}".utf8)
    #expect(try HolosJSON.decoder().decode(MeetingStartSettings.self, from: unknown).name == "Synthetic")
}

/// `--screen display` is every display now (what the app passes); `--screen main` is the main display alone, as
/// `display` was before; `off` is no target.
@Test func theRecorderIsToldWhichDisplaysToCapture() throws {
    let root = URL(fileURLWithPath: "/tmp/test")
    for target in ScreenCaptureTarget.allCases {
        let settings = MeetingStartSettings(name: "Synthetic", source: .microphone, screen: target)
        let args = ChildProcessLauncher.arguments(settings, sessionID: "id", root: root, vocabularyFile: nil)
        let index = try #require(args.firstIndex(of: "--screen"))
        #expect(ScreenCaptureTarget(rawValue: args[index + 1]) == target)
        #expect(try HolosJSON.decoder().decode(MeetingStartSettings.self,
            from: HolosJSON.encoder().encode(settings)).screen == target)
    }
    #expect(ScreenCaptureTarget.allCases.map(\.rawValue) + ["off"] == ["display", "main", "off"])
    #expect(ScreenCaptureTarget(rawValue: "off") == nil)
}

@Test func screenSettingIsOffForNewInstallsAndOnForTheOldWindowOffer() throws {
    func defaults() throws -> (UserDefaults, String) {
        let suite = "holos-screen-preference-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }
    let (fresh, freshSuite) = try defaults()
    defer { fresh.removePersistentDomain(forName: freshSuite) }
    #expect(!MeetingScreenPreference.enabled(in: fresh))

    let (upgraded, upgradedSuite) = try defaults()
    defer { upgraded.removePersistentDomain(forName: upgradedSuite) }
    upgraded.set(true, forKey: MeetingScreenPreference.legacyKey)
    #expect(MeetingScreenPreference.enabled(in: upgraded))
    MeetingScreenPreference.set(false, in: upgraded)
    #expect(!MeetingScreenPreference.enabled(in: upgraded))
    #expect(upgraded.object(forKey: MeetingScreenPreference.legacyKey) == nil)
    MeetingScreenPreference.set(true, in: upgraded)
    #expect(MeetingScreenPreference.enabled(in: upgraded))

    let (declined, declinedSuite) = try defaults()
    defer { declined.removePersistentDomain(forName: declinedSuite) }
    declined.set(false, forKey: MeetingScreenPreference.legacyKey)
    #expect(!MeetingScreenPreference.enabled(in: declined))
}

@Test(.timeLimit(.minutes(1))) @MainActor func childWatcherRetriesWhenTheExitEventComesBeforeTheChildIsWaitable()
    async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    // The exit event can be posted before the child can be waited for: the first reaps after it find nothing. The
    // child exits only once the watcher is set up (the gate opens), however late that is.
    let gate = temp.url.appendingPathComponent("gate")
    let child = try launcherScript("while [ ! -e '\(gate.path)' ] && [ -d '\(temp.url.path)' ]; do sleep 0.01; done", in: temp.url)
    let pid = try ProcessSpawner.spawn(executable: child, arguments: [], standardOutput: .null, standardError: .null)
    let probe = ReaperProbe()
    let watcher = ChildWatcher(pid: pid, reaper: { pid in
        probe.calls += 1
        // The check at set-up (the child is still running) and the first check after the exit event.
        return probe.calls <= 2 ? nil : ProcessSpawner.reapIfExited(pid)
    }, retryInterval: .milliseconds(10)) { probe.code = $0 }
    try Data().write(to: gate)
    #expect(await eventually(timeout: .seconds(30)) { probe.code != nil })
    #expect(probe.code == 0)
    #expect(probe.calls >= 3)
    _ = watcher
}

@MainActor
private final class ReaperProbe {
    var calls = 0
    var code: Int32?
}

@Test func spawnedChildInheritsNoLocks() async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    let session = try await launcherSession(in: temp.url)
    // The worst case: the speaker lock held on a descriptor without close-on-exec.
    let lockFile = session.appendingPathComponent(".speakers.lock").path
    let fd = open(lockFile, O_RDWR | O_CREAT, 0o600)
    #expect(fd >= 0)
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    let pid = try ProcessSpawner.spawn(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"],
                                       standardOutput: .null, standardError: .null)
    defer {
        kill(pid, SIGKILL)
        _ = ProcessSpawner.reapIfExited(pid)
    }
    // Closing (not unlocking) releases the lock unless the child shares the open file description.
    close(fd)
    let acquired = try SessionArchive.withSpeakerLock(at: session, timeout: .zero) { true }
    #expect(acquired, "The sleeping child must not hold the speaker lock.")
}

@Test(.timeLimit(.minutes(1))) @MainActor func inProcessLeaseHandoffHasNoGap() async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    let session = try await launcherSession(in: temp.url)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    // The child marks that it runs, then holds the lease until the probe opens the gate. The probe polls the lease
    // from before the hand-off until it has seen the child running for 50 samples, however slowly it is scheduled;
    // it also stops once the hand-off has returned (a child that failed to start or exited early), so such a failure
    // is reported rather than left spinning.
    let started = temp.url.appendingPathComponent("started")
    let gate = temp.url.appendingPathComponent("gate")
    defer { try? Data().write(to: gate) }
    let child = try launcherScript(
        "touch '\(started.path)'\nwhile [ ! -e '\(gate.path)' ] && [ -d '\(temp.url.path)' ]; do sleep 0.01; done", in: temp.url)
    let probing = SharedValue(false)
    let handedOff = SharedValue(false)
    let probe = Task.detached { () -> (samples: Int, free: Int, whileRunning: Int) in
        var samples = 0
        var free = 0
        var afterStart = 0
        while afterStart < 50, !handedOff.value, !Task.isCancelled {
            samples += 1
            if (try? SessionArchive.isProcessing(at: session)) != true { free += 1 }
            probing.set(true)
            if FileManager.default.fileExists(atPath: started.path) { afterStart += 1 }
            // Lets the hand-off run on a pool of one worker; sampling still runs between its steps.
            await Task.yield()
        }
        try? Data().write(to: gate)
        return (samples, free, afterStart)
    }
    #expect(await eventually { probing.value })
    let record = await InProcessLauncher.handOffPostProcessing(
        session: session, lease: lease, executable: child, arguments: [], log: nil,
        progress: { _ in }, pollInterval: .milliseconds(20))
    handedOff.set(true)
    let seen = await probe.value
    #expect(seen.whileRunning >= 50, "The child ran while the probe watched the lease.")
    #expect(seen.free == 0, "The processing lease was free during the hand-off.")
    #expect(try !SessionArchive.isProcessing(at: session), "The child's exit ends the lease.")
    // /bin/sleep printed no record: the hook reports that labelling stopped.
    #expect(record.state == .failed)
    #expect(record.message?.contains("exit code 0") == true)
}

@Test @MainActor func failedHandOffSpawnKeepsTheLeaseAndReportsIt() async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    let session = try await launcherSession(in: temp.url)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let record = await InProcessLauncher.handOffPostProcessing(
        session: session, lease: lease, executable: temp.url.appendingPathComponent("missing-holos"),
        arguments: [], log: nil, progress: { _ in })
    #expect(record.state == .failed)
    #expect(record.message?.contains("could not start") == true)
    #expect(try SessionArchive.isProcessing(at: session), "A failed spawn leaves the lease with this process.")
}

/// A log folder that cannot be made, or a log that cannot be opened, is dropped: the labelling child still starts,
/// with its stderr discarded, instead of the labelling being reported as failed because of the log.
@Test @MainActor func unusableLabellingLogDoesNotStopTheLabelling() async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    // A regular file where the log folder should be: the folder cannot be made.
    let blocker = temp.url.appendingPathComponent("not-a-folder")
    try Data().write(to: blocker)
    let folder = blocker.appendingPathComponent("logs", isDirectory: true)
    #expect(InProcessLauncher.labellingLog(in: folder, sessionID: "3F2A9C1E-0000-4000-8000-000000000001") == nil)
    let usable = temp.url.appendingPathComponent("logs", isDirectory: true)
    #expect(InProcessLauncher.labellingLog(in: usable, sessionID: "3F2A9C1E-0000-4000-8000-000000000001")?
        .lastPathComponent == "recorder-3F2A9C1E-0000-4000-8000-000000000001.log")

    let session = try await launcherSession(in: temp.url)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let record = await InProcessLauncher.handOffPostProcessing(
        session: session, lease: lease, executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
        log: folder.appendingPathComponent("recorder.log"), progress: { _ in }, pollInterval: .milliseconds(20))
    // /usr/bin/true ran (and printed no record): not "could not start", and no log is named.
    #expect(record.message?.contains("could not start") == false)
    #expect(record.message?.contains("exit code 0") == true)
    #expect(record.message?.contains("Details:") == false)
}

/// A quit once the transcript is saved (§5.8): the in-process recording stops waiting for its labelling child, writes
/// exited with post-processing still running, and ends; the child keeps the processing lease and finishes on its own.
/// A recording that has not reached labelling is not told.
@Test(.timeLimit(.minutes(1))) @MainActor
func quitLeavesLabellingToTheChildAndEndsTheRecording() async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    // The labelling child runs until the test opens the gate (the defer opens it however the test ends), or until the
    // test's folder is gone (a test that timed out removes it in teardown, and the time limit does not kill children).
    let gate = temp.url.appendingPathComponent("gate")
    let script = try launcherScript("while [ ! -e '\(gate.path)' ] && [ -d '\(temp.url.path)' ]; do sleep 0.05; done", in: temp.url)
    defer { try? Data().write(to: gate) }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let launcher = InProcessLauncher(executable: script,
                                     logDirectory: temp.url.appendingPathComponent("logs", isDirectory: true))
    launcher.makeDependencies = { stop, hook in
        recorderDependencies(captures: captures, postProcess: hook, stop: stop)
    }
    let id = UUID().uuidString
    let session = temp.url.appendingPathComponent("\(id).holos", isDirectory: true)
    let exits = SharedValue(0)
    launcher.onExit = { _, _ in exits.update { $0 += 1 } }
    _ = try launcher.launch(MeetingStartSettings(name: "Standup", source: .microphone), sessionID: id,
                            root: temp.url, vocabularyFile: nil)
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    #expect(!launcher.leaveLabellingToItsChild(), "A recording that has not reached labelling is left alone.")
    #expect(launcher.terminate(sessionID: id))
    #expect(await eventually { launcher.leaveLabellingToItsChild() })
    #expect(await eventually { !launcher.isRecording },
            "The recording ends without waiting for the labelling child.")
    #expect(!exists(gate), "The child was still labelling.")
    let status = try #require(try RecorderChannel.readStatus(session: session))
    #expect(status.phase == .exited)
    #expect(status.exit?.postprocessing == .running)
    #expect(status.exit?.archiveStatus == ArchiveStatus.complete)
    #expect(exits.value == 1)
    #expect(try SessionArchive.isProcessing(at: session), "The labelling child keeps the lease.")
    try Data().write(to: gate)
    #expect(await eventually { (try? SessionArchive.isProcessing(at: session)) == false })
}

/// A waiting quit goes ahead in child mode once capture stopped; in-process only once the recording here has ended,
/// whatever phase the followed status shows (post-processing included).
@Test func quitReadinessByLauncherMode() {
    let id = "3F2A9C1E-0000-4000-8000-000000000001"
    let finishing = MeetingState.finishing(sessionID: id, status: nil)
    let starting = MeetingState.starting(sessionID: id, since: Date(), pid: nil)
    let failed = MeetingState.failed(sessionID: id, message: "The recorder did not start within 2 minutes.")
    for state in [MeetingState.idle, finishing, failed] {
        #expect(QuitReadiness.ready(state, inProcess: false, recordingHere: false))
        #expect(!QuitReadiness.ready(state, inProcess: true, recordingHere: true))
        #expect(QuitReadiness.ready(state, inProcess: true, recordingHere: false))
    }
    #expect(!QuitReadiness.ready(starting, inProcess: false, recordingHere: false))
    #expect(!QuitReadiness.ready(starting, inProcess: true, recordingHere: true))
    #expect(QuitReadiness.ready(starting, inProcess: true, recordingHere: false), "The recording here ended.")
}

private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

@Test @MainActor func childLauncherLogsAndReportsTheExit() async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    let script = try launcherScript("""
        echo "parent=$HOLOS_RECORDER_PARENT args=$*"
        echo "Error: The built-in microphone is unavailable. Open the lid and try again." >&2
        exit 1
        """, in: temp.url)
    let logs = temp.url.appendingPathComponent("Logs", isDirectory: true)
    let launcher = ChildProcessLauncher(executable: script, logDirectory: logs)
    let exit = SharedValue<(code: Int32, tail: String?)?>(nil)
    launcher.onExit = { code, tail in exit.set((code, tail)) }
    let id = UUID().uuidString
    let pid = try launcher.launch(MeetingStartSettings(name: "Board", source: .microphone), sessionID: id,
                                  root: temp.url, vocabularyFile: nil)
    #expect(pid != nil)
    #expect(await eventually { exit.value != nil })
    #expect(exit.value?.code == 1)
    #expect(exit.value?.tail == "The built-in microphone is unavailable. Open the lid and try again.")
    let log = launcher.logFile(sessionID: id)
    #expect(launcherMode(log) == 0o600)
    #expect(launcherMode(logs) == 0o700)
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    #expect(text.contains("parent=app args=record start --session-id \(id)"))
    #expect(launcher.pid(sessionID: id) == nil, "The exited child was reaped.")
}

@Test @MainActor func childLauncherTerminateIsAGracefulSignal() async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    let ready = temp.url.appendingPathComponent("ready")
    let script = try launcherScript("""
        trap 'echo "Stopped by SIGTERM."; exit 0' TERM
        touch '\(ready.path)'
        while :; do sleep 0.05; done
        """, in: temp.url)
    let launcher = ChildProcessLauncher(executable: script, logDirectory: temp.url)
    let exit = SharedValue<(code: Int32, tail: String?)?>(nil)
    launcher.onExit = { code, tail in exit.set((code, tail)) }
    let id = UUID().uuidString
    _ = try launcher.launch(MeetingStartSettings(name: "Board", source: .microphone), sessionID: id, root: temp.url,
                            vocabularyFile: nil)
    // Signal only once the script has installed its handler.
    #expect(await eventually { FileManager.default.fileExists(atPath: ready.path) })
    launcher.terminate(sessionID: id)
    #expect(await eventually { exit.value != nil })
    #expect(exit.value?.code == 0)
    #expect(exit.value?.tail == "Stopped by SIGTERM.")
}

@Test @MainActor func missingRecorderExecutableIsUnavailable() throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    let launcher = ChildProcessLauncher(executable: temp.url.appendingPathComponent("holos"), logDirectory: temp.url)
    #expect(throws: HolosError.self) {
        try launcher.launch(MeetingStartSettings(name: "Board", source: .microphone), sessionID: UUID().uuidString,
                            root: temp.url, vocabularyFile: nil)
    }
}

@Test @MainActor func maintenanceLauncherWritesOutputAndReportsTheCode() async throws {
    let temp = try TemporaryDirectory("launcher", permissions: 0o700)
    defer { temp.remove() }
    let script = try launcherScript("""
        echo "{\\"summary\\": \\"$*\\"}"
        echo "progress" >&2
        exit 3
        """, in: temp.url)
    let maintenance = MaintenanceLauncher(executable: script)
    let output = temp.url.appendingPathComponent("out.json")
    let errors = temp.url.appendingPathComponent("err.txt")
    let code = SharedValue<Int32?>(nil)
    try maintenance.run(["session", "diarize", "/tmp/x.holos", "--json"], standardOutput: output,
                        standardError: errors) { code.set($0) }
    #expect(await eventually { code.value != nil })
    #expect(code.value == 3)
    #expect(maintenance.runningPIDs.isEmpty)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: String]
    #expect(object?["summary"] == "session diarize /tmp/x.holos --json")
    #expect((try? String(contentsOf: errors, encoding: .utf8)) == "progress\n")
    #expect(launcherMode(output) == 0o600)
}

@Test func exitCodesDecodeWaitStatus() {
    #expect(ProcessSpawner.exitCode(3 << 8) == 3)
    #expect(ProcessSpawner.exitCode(0) == 0)
    #expect(ProcessSpawner.exitCode(SIGKILL) == 128 + SIGKILL)
}
