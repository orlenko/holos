import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// A meeting's languages from the start panel to meeting.json (docs/meeting-design.md §4.14): the settings, the
// recorder's arguments, and the recording.

/// Records three scripted microphone frames with `options`, then stops.
@MainActor
private func meetingLanguageRecord(_ options: RecordingOptions) async throws -> RecordingOutcome {
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 3))])
    let stop = ManualStopSource()
    let dependencies = RecordingDependencies.testing(captures: captures, stop: stop)
    let run = Task { try await RecordingWorkflow.run(options, dependencies: dependencies) }
    let consumed = await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 3 }
    #expect(consumed)
    stop.requestStop()
    return try await run.value
}

@Test(.timeLimit(.minutes(1))) @MainActor
func recordingSavesTheMeetingLanguages() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    var options = RecordingOptions.testing(root: temp.url, recordOnly: true)
    options.languages = ["en_CA", "fr-CA"]
    let outcome = try await meetingLanguageRecord(options)
    let info = try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(outcome.directory))
    #expect(info.languages == ["en-CA", "fr-CA"])
    #expect(try SessionArchive.readManifest(at: outcome.directory).locale == "en-CA", "Live transcription: the first.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func recordingInOneLanguageWritesNoLanguages() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    var options = RecordingOptions.testing(root: temp.url, recordOnly: true)
    options.languages = ["en-CA"]
    let outcome = try await meetingLanguageRecord(options)
    let info = try AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(outcome.directory))
    #expect(info.languages == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func recordingRefusesLanguagesThatDoNotStartWithItsLocale() async throws {
    let temp = try TemporaryDirectory("languages")
    defer { temp.remove() }
    for languages in [["fr-CA", "en-CA"], ["en-CA", "en-US"], ["en-CA", "fr-CA", "es-ES", "de-DE"]] {
        var options = RecordingOptions.testing(root: temp.url, recordOnly: true)
        options.languages = languages
        let dependencies = RecordingDependencies.testing(captures: FakeCaptureFactory([]))
        await #expect(throws: HolosError.self) { try await RecordingWorkflow.run(options, dependencies: dependencies) }
    }
    #expect(sessionFolders(in: temp.url).isEmpty, "Refused before a session exists.")
}

@Test func recorderArgumentsNameEveryLanguage() {
    let id = "3F2A9C1E-0000-4000-8000-000000000001"
    let root = URL(fileURLWithPath: "/tmp/Sessions", isDirectory: true)
    let two = MeetingStartSettings(name: "Board", source: .microphone, locales: ["fr-CA", "en-CA"])
    let arguments = ChildProcessLauncher.arguments(two, sessionID: id, root: root, vocabularyFile: nil)
    #expect(arguments.contains("--languages=fr-CA,en-CA"))
    #expect(!arguments.contains { $0.hasPrefix("--locale") })
    let one = MeetingStartSettings(name: "Board", source: .microphone, locales: ["fr-CA"])
    #expect(ChildProcessLauncher.arguments(one, sessionID: id, root: root, vocabularyFile: nil)
        .contains("--locale=fr-CA"))
}

@Test func startSettingsKeepUpToThreeDifferentLanguages() {
    let settings = MeetingStartSettings(name: "Board", source: .microphone,
                                        locales: ["fr_CA", "fr-FR", "en-CA", " ", "es-ES", "de-DE"]).normalized()
    #expect(settings.locales == ["fr-CA", "en-CA", "es-ES"])
    #expect(settings.locale == "fr-CA")
}
