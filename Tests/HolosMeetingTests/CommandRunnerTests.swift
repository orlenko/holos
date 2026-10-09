import Darwin
import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// `CommandRunner`: the app's `voiceislocal` commands with their output in temporary files, decoded off the main actor
// and always removed; and the outcome types the command-line tool writes and the app reads.

/// An executable shell script in `folder` standing in for `voiceislocal`.
private func commandScript(_ body: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent("fake-voiceislocal-\(UUID().uuidString).sh")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else { throw HolosError.io("chmod failed") }
    return url
}

/// A runner of `script` whose output files are made in a folder of their own, and that folder.
@MainActor private func commandRunner(_ script: URL, in temp: TemporaryDirectory) throws -> (CommandRunner, URL) {
    let folder = temp.url.appendingPathComponent("artifacts", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (CommandRunner(launcher: MaintenanceLauncher(executable: script), folder: folder), folder)
}

private func contents(of folder: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
}

private func echoOutcome() -> SessionEchoAnalyzeCommand.Outcome {
    SessionEchoAnalyzeCommand.Outcome(
        sessionID: "S1", verdict: nil, delay: nil, analysed: true, analysisSeconds: 1.5, microphoneTurnsBefore: 4,
        microphoneTurnsAfter: 2, hiddenWords: 7, summary: "Hid 7 words of echo.", exitCode: 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor func commandRunnerDecodesTheOutcomeAndRemovesItsFiles() async throws {
    let temp = try TemporaryDirectory("command")
    defer { temp.remove() }
    let printed = temp.url.appendingPathComponent("outcome.json")
    try HolosJSON.encoder().encode(echoOutcome()).write(to: printed)
    let script = try commandScript("""
        echo "args=$*" >&2
        cat '\(printed.path)'
        """, in: temp.url)
    let (runner, folder) = try commandRunner(script, in: temp)
    let result = try await runner.run(["session", "echo-analyze", "/tmp/x.holos", "--json"], output: "echo",
                                      errors: "echo-err", maxOutputBytes: 1 << 20,
                                      as: SessionEchoAnalyzeCommand.Outcome.self)
    #expect(result.code == 0)
    #expect(result.outcome == echoOutcome())
    #expect(result.errors == "args=session echo-analyze /tmp/x.holos --json\n")
    #expect(result.lastErrorLine == "args=session echo-analyze /tmp/x.holos --json")
    #expect(contents(of: folder).isEmpty, "The output files are removed.")
    #expect(runner.launcher.runningPIDs.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor func commandRunnerReportsAFailedCommand() async throws {
    let temp = try TemporaryDirectory("command")
    defer { temp.remove() }
    let script = try commandScript("""
        echo "Working…" >&2
        echo "Error: The meeting is still recording." >&2
        exit 3
        """, in: temp.url)
    let (runner, folder) = try commandRunner(script, in: temp)
    let ended = SharedValue<CommandResult<SessionEchoAnalyzeCommand.Outcome>?>(nil)
    let pid = try runner.start(["session", "echo-analyze", "x"], output: "echo", errors: "echo-err",
                               maxOutputBytes: 1 << 20, as: SessionEchoAnalyzeCommand.Outcome.self) {
        ended.set($0)
    }
    #expect(pid > 0)
    #expect(await eventually { ended.value != nil })
    #expect(ended.value?.code == 3)
    #expect(ended.value?.outcome == nil, "Nothing was printed on stdout.")
    #expect(ended.value?.errors == "Working…\nError: The meeting is still recording.\n")
    #expect(ended.value?.lastErrorLine == "The meeting is still recording.")
    #expect(contents(of: folder).isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor func commandRunnerGivesNoOutcomeForMalformedOutput() async throws {
    let temp = try TemporaryDirectory("command")
    defer { temp.remove() }
    let script = try commandScript(#"echo '{"summary": "half'"#, in: temp.url)
    let (runner, folder) = try commandRunner(script, in: temp)
    let result = try await runner.run(["doctor", "--json"], output: "doctor", errors: nil, maxOutputBytes: 1 << 20,
                                      as: DoctorReport.self)
    #expect(result.code == 0)
    #expect(result.outcome == nil)
    #expect(result.errors == "")
    #expect(result.lastErrorLine == nil)
    #expect(contents(of: folder).isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor func cancellingARunStopsTheCommandAndRemovesItsFiles() async throws {
    let temp = try TemporaryDirectory("command")
    defer { temp.remove() }
    let ready = temp.url.appendingPathComponent("ready")
    let script = try commandScript("""
        echo "partial" >&2
        touch '\(ready.path)'
        while :; do sleep 0.05; done
        """, in: temp.url)
    let (runner, folder) = try commandRunner(script, in: temp)
    let task = Task { @MainActor in
        try await runner.run(["session", "summarize", "x", "--json"], output: "summary", errors: "summary-err",
                             maxOutputBytes: 4 << 20, as: SessionSummarizeCommand.Outcome.self)
    }
    #expect(await eventually { FileManager.default.fileExists(atPath: ready.path) })
    #expect(contents(of: folder).count == 2, "Its stdout and stderr files exist while it runs.")
    task.cancel()
    let result = try await task.value
    #expect(result.code == 128 + SIGTERM)
    #expect(result.outcome == nil)
    #expect(result.errors == "partial\n")
    #expect(contents(of: folder).isEmpty)
    #expect(runner.launcher.runningPIDs.isEmpty)
}

@Test @MainActor func aRunCancelledBeforeItStartsSpawnsNothing() async throws {
    let temp = try TemporaryDirectory("command")
    defer { temp.remove() }
    let ran = temp.url.appendingPathComponent("ran")
    let script = try commandScript("touch '\(ran.path)'", in: temp.url)
    let (runner, folder) = try commandRunner(script, in: temp)
    let task = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await runner.run(["doctor", "--json"], output: "doctor", errors: nil, maxOutputBytes: 1 << 20,
                                    as: DoctorReport.self)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(runner.launcher.runningPIDs.isEmpty)
    #expect(contents(of: folder).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: ran.path))
}

@Test @MainActor func aCommandThatCannotStartLeavesNoFiles() throws {
    let temp = try TemporaryDirectory("command")
    defer { temp.remove() }
    let (runner, folder) = try commandRunner(temp.url.appendingPathComponent("voiceislocal"), in: temp)
    #expect(throws: HolosError.self) {
        try runner.start(["doctor", "--json"], output: "doctor", errors: "doctor-err", maxOutputBytes: 1 << 20,
                         as: DoctorReport.self) { _ in }
    }
    #expect(contents(of: folder).isEmpty)
}

/// A large outcome: its decoding notes whether it ran on the main thread.
private struct LargeOutcome: Decodable, Sendable {
    var lines: [String]
}

@Test(.timeLimit(.minutes(1))) @MainActor func largeOutputIsDecodedOffTheMainActor() async throws {
    let temp = try TemporaryDirectory("command")
    defer { temp.remove() }
    // About 8 MiB of JSON.
    let lines = (0..<80_000).map { "line \($0) " + String(repeating: "x", count: 90) }
    let printed = temp.url.appendingPathComponent("large.json")
    try JSONEncoder().encode(["lines": lines]).write(to: printed)
    let script = try commandScript("cat '\(printed.path)'", in: temp.url)
    let (runner, folder) = try commandRunner(script, in: temp)
    let decodedOnMain = SharedValue<Bool?>(nil)
    let result = try await runner.run(["session", "deep-transcribe", "x", "--json"], output: "deep",
                                      errors: "deep-err", maxOutputBytes: 16 << 20) { data in
        decodedOnMain.set(Thread.isMainThread)
        return try JSONDecoder().decode(LargeOutcome.self, from: data)
    }
    #expect(result.outcome?.lines.count == lines.count)
    #expect(decodedOnMain.value == false)
    #expect(contents(of: folder).isEmpty)

    // More than the command may print: no outcome, and the files still go.
    let capped = try await runner.run(["session", "deep-transcribe", "x", "--json"], output: "deep",
                                      errors: "deep-err", maxOutputBytes: 1 << 20, as: LargeOutcome.self)
    #expect(capped.code == 0)
    #expect(capped.outcome == nil)
    #expect(contents(of: folder).isEmpty)
}

// MARK: - Shared outcomes

@Test func sharedOutcomesReadBackWhatTheCommandsWrite() throws {
    let speech = SpeechCapabilities(backend: .speech, isAvailable: true, supportedLocales: ["en-CA", "fr-CA"],
                                    installedLocales: ["en-CA"])
    let report = DoctorReport(
        os: "macOS 27", microphone: "authorized", systemAudioPermission: false, accessibilityPermission: true,
        foundationModel: "available", contextSize: 4096, voiceCount: 3, speech: speech, dictation: speech,
        locale: "en-CA", speechAssetStatus: "installed", dictationAssetStatus: "supported",
        sessionsDirectory: "/tmp/Sessions", speakerModels: "verified", deepTranscriptionModel: .installed)
    let reportJSON = try HolosJSON.encoder().encode(report)
    let text = String(decoding: reportJSON, as: UTF8.self)
    #expect(text.contains(#""speakerModels" : "verified""#))
    #expect(text.contains(#""deepTranscriptionModel" : "installed""#))
    let doctor = try HolosJSON.decoder().decode(DoctorReport.self, from: reportJSON)
    #expect(doctor.speakerModels == "verified")
    #expect(doctor.deepTranscriptionModel == .installed)
    #expect(doctor.contextSize == 4096)
    #expect(doctor.speech.installedLocales == ["en-CA"])

    let summary = SessionSummarizeCommand.Outcome(sessionID: "S1", status: .busy, message: "Another job runs.",
                                                  exitCode: 1)
    let decoded = try HolosJSON.decoder().decode(SessionSummarizeCommand.Outcome.self,
                                                 from: HolosJSON.encoder().encode(summary))
    #expect(decoded.status == .busy)
    #expect(decoded.status.retriesLater)
    #expect(decoded.message == "Another job runs.")
    #expect(decoded.exitCode == 1)
    #expect(decoded.summary == nil)

    let echo = try HolosJSON.decoder().decode(SessionEchoAnalyzeCommand.Outcome.self,
                                              from: HolosJSON.encoder().encode(echoOutcome()))
    #expect(echo == echoOutcome())
}
