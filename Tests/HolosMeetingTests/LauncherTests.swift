import Darwin
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
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
                                        applicationBundleID: "us.zoom.xos", othersInRoom: true, expectedSpeakers: 8)
    let id = "3F2A9C1E-0000-4000-8000-000000000001"
    let root = URL(fileURLWithPath: "/Users/me/Library/Application Support/Holos/Sessions", isDirectory: true)
    let vocabulary = URL(fileURLWithPath: "/private/tmp/holos-vocabulary-\(id).json")
    #expect(ChildProcessLauncher.arguments(settings, sessionID: id, root: root, vocabularyFile: vocabulary) == [
        "record", "start", "--session-id", id, "--name=Council meeting", "--source", "mic+system",
        "--app", "us.zoom.xos", "--others-in-room", "--expected-speakers", "8",
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

@Test @MainActor func childWatcherRetriesWhenTheExitEventComesBeforeTheChildIsWaitable() async throws {
    // The exit event can be posted before the child can be waited for: the first reaps after it find nothing.
    let pid = try ProcessSpawner.spawn(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.3"],
                                       standardOutput: .null, standardError: .null)
    let probe = ReaperProbe()
    let watcher = ChildWatcher(pid: pid, reaper: { pid in
        probe.calls += 1
        // The check at set-up (the child is still running) and the first check after the exit event.
        return probe.calls <= 2 ? nil : ProcessSpawner.reapIfExited(pid)
    }, retryInterval: .milliseconds(10)) { probe.code = $0 }
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
    let temp = try TemporaryDirectory("launcher")
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

@Test @MainActor func inProcessLeaseHandoffHasNoGap() async throws {
    let temp = try TemporaryDirectory("launcher")
    defer { temp.remove() }
    let session = try await launcherSession(in: temp.url)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    // Polls the lease from before the hand-off until well after the child started; the child holds it for 1 s.
    let probe = Task.detached { () -> (samples: Int, free: Int) in
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .milliseconds(600))
        var samples = 0
        var free = 0
        while clock.now < end {
            samples += 1
            if (try? SessionArchive.isProcessing(at: session)) != true { free += 1 }
        }
        return (samples, free)
    }
    let record = await InProcessLauncher.handOffPostProcessing(
        session: session, lease: lease, executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], log: nil,
        progress: { _ in }, pollInterval: .milliseconds(20))
    let seen = await probe.value
    #expect(seen.samples > 10)
    #expect(seen.free == 0, "The processing lease was free during the hand-off.")
    #expect(try !SessionArchive.isProcessing(at: session), "The child's exit ends the lease.")
    // /bin/sleep printed no record: the hook reports that labelling stopped.
    #expect(record.state == .failed)
    #expect(record.message?.contains("exit code 0") == true)
}

@Test @MainActor func failedHandOffSpawnKeepsTheLeaseAndReportsIt() async throws {
    let temp = try TemporaryDirectory("launcher")
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

@Test @MainActor func childLauncherLogsAndReportsTheExit() async throws {
    let temp = try TemporaryDirectory("launcher")
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
    let temp = try TemporaryDirectory("launcher")
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
    let temp = try TemporaryDirectory("launcher")
    defer { temp.remove() }
    let launcher = ChildProcessLauncher(executable: temp.url.appendingPathComponent("holos"), logDirectory: temp.url)
    #expect(throws: HolosError.self) {
        try launcher.launch(MeetingStartSettings(name: "Board", source: .microphone), sessionID: UUID().uuidString,
                            root: temp.url, vocabularyFile: nil)
    }
}

@Test @MainActor func maintenanceLauncherWritesOutputAndReportsTheCode() async throws {
    let temp = try TemporaryDirectory("launcher")
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
