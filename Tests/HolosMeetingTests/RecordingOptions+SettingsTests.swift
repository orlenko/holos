import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing

// `RecordingOptions(settings:…)`: a meeting from the app gets the same options whether it records in process or as
// the `voiceislocal record start` child (docs/meeting-design.md §4.1).

private let mappingRoot = URL(fileURLWithPath: "/tmp/sessions", isDirectory: true)
private let mappingID = "3F2A9C1E-0000-4000-8000-000000000001"
/// The recorder's default language in these tests; never the inert `DictationLanguage.standard`.
private let mappingDefault = "de-DE"

/// What `voiceislocal record start` makes of the child's arguments (`Record.Start`): nil where its validation refuses
/// them (`--microphone` without the microphone). Without `--locale` or `--languages` it takes its default language,
/// without `--microphone` `RecordingOptions.microphone(for:)`.
private func childOptions(_ arguments: [String], defaultLocale: String) -> RecordingOptions? {
    func value(_ option: String) -> String? {
        if let joined = arguments.first(where: { $0.hasPrefix(option + "=") }) {
            return String(joined.dropFirst(option.count + 1))
        }
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    guard let source = value("--source").flatMap(AudioSource.init(rawValue:)) else { return nil }
    let microphone = value("--microphone").flatMap(MicrophoneSelection.init(argument:))
    if microphone != nil, source == .system { return nil }
    var locale = value("--locale") ?? defaultLocale
    var languages: [String] = []
    if let list = value("--languages") {
        let meeting = DictationLanguage.meetingLanguages(DictationLanguage.list(list))
        locale = meeting.first ?? locale
        languages = meeting.count > 1 ? meeting : []
    }
    return RecordingOptions(
        name: value("--name") ?? "Meeting", source: source, locale: locale, backend: .speech,
        root: URL(fileURLWithPath: value("--directory") ?? "", isDirectory: true),
        applicationBundleID: value("--app"), sessionID: value("--session-id"),
        othersInRoom: arguments.contains("--others-in-room"),
        expectedSpeakers: value("--expected-speakers").flatMap(Int.init), liveText: !arguments.contains("--no-live-text"),
        microphone: microphone ?? RecordingOptions.microphone(for: source), languages: languages,
        screen: value("--screen").flatMap(ScreenCaptureTarget.init(rawValue:)),
        nameSource: arguments.contains("--default-name") ? .default : .user)
}

private func inProcessOptions(_ settings: MeetingStartSettings) async -> RecordingOptions {
    await RecordingOptions(settings: settings, sessionID: mappingID, root: mappingRoot, vocabulary: [],
                           defaultLocale: { mappingDefault })
}

/// Every source, microphone choice and language list: the child is handed exactly the in-process options.
@Test(arguments: [AudioSource.microphone, .microphoneAndSystem, .system])
func childAndInProcessRecorderGetTheSameOptions(source: AudioSource) async throws {
    let microphones: [MicrophoneSelection?] = [nil, .systemDefault, .builtIn]
    let languageLists: [[String]] = [[], ["fr-CA"], ["fr-CA", "en-CA"]]
    for microphone in microphones {
        for locales in languageLists {
            var settings = MeetingStartSettings(name: "Synthetic", source: source,
                                                othersInRoom: source == .microphoneAndSystem, expectedSpeakers: 3,
                                                microphone: microphone, locales: locales, screen: .display)
            settings.nameIsDefault = locales.isEmpty
            let arguments = ChildProcessLauncher.arguments(settings, sessionID: mappingID, root: mappingRoot,
                                                           vocabularyFile: nil)
            let child = try #require(childOptions(arguments, defaultLocale: mappingDefault),
                                     "record start accepts \(arguments)")
            #expect(child == (await inProcessOptions(settings)), "\(source) \(String(describing: microphone)) \(locales)")
        }
    }
}

/// The two rules the paths used to disagree on: a meeting without a language takes the recorder's default (the child's
/// `AppleSpeechEngine.defaultLocale`; in process it was `DictationLanguage.standard`), and a recording without the
/// microphone ignores a microphone choice (the child was handed `--microphone` and refused to start).
@Test func aMeetingWithoutALanguageOrMicrophoneGetsTheRecordersDefaults() async {
    let unnamed = MeetingStartSettings(name: "Synthetic", source: .microphone)
    let options = await inProcessOptions(unnamed)
    #expect(options.locale == mappingDefault)
    #expect(options.languages.isEmpty)
    let arguments = ChildProcessLauncher.arguments(unnamed, sessionID: mappingID, root: mappingRoot, vocabularyFile: nil)
    #expect(!arguments.contains { $0.hasPrefix("--locale") || $0.hasPrefix("--languages") })

    let systemOnly = MeetingStartSettings(name: "Synthetic", source: .system, microphone: .builtIn, locales: ["fr-CA"])
    #expect(!ChildProcessLauncher.arguments(systemOnly, sessionID: mappingID, root: mappingRoot, vocabularyFile: nil)
        .contains("--microphone"))
    #expect(await inProcessOptions(systemOnly).microphone == .systemDefault)
}

/// The default language is asked only for a meeting that names none.
@Test func theDefaultLanguageIsAskedOnlyWithoutOne() async {
    let asked = SharedValue(0)
    let named = MeetingStartSettings(name: "Synthetic", source: .microphone, locales: ["fr-CA", "en-CA"])
    let options = await RecordingOptions(settings: named, sessionID: mappingID, root: mappingRoot, vocabulary: ["Strata"],
                                         defaultLocale: { asked.update { $0 += 1 }; return mappingDefault })
    #expect(asked.value == 0)
    #expect(options.locale == "fr-CA")
    #expect(options.languages == ["fr-CA", "en-CA"])
    #expect(options.vocabulary == ["Strata"])
    #expect(options.backend == .speech && !options.liveText && !options.recordOnly && options.duration == nil)
}

/// The in-process recorder takes its default language from its dependencies, as the child takes its own.
@Test(.timeLimit(.minutes(1))) @MainActor
func inProcessRecorderTakesTheDefaultLanguageOfItsDependencies() async throws {
    let temp = try TemporaryDirectory("meeting", permissions: 0o700)
    defer { temp.remove() }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let launcher = InProcessLauncher(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                     logDirectory: temp.url.appendingPathComponent("logs", isDirectory: true))
    launcher.makeDependencies = { stop, _ in
        var dependencies = recorderDependencies(captures: captures, stop: stop)
        dependencies.defaultLocale = { mappingDefault }
        return dependencies
    }
    let ended = SharedValue(false)
    launcher.onExit = { _, _ in ended.set(true) }
    let id = UUID().uuidString
    _ = try launcher.launch(MeetingStartSettings(name: "Synthetic", source: .microphone), sessionID: id,
                            root: temp.url, vocabularyFile: nil)
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    let session = temp.url.appendingPathComponent("\(id).holos", isDirectory: true)
    #expect(try SessionArchive.readManifest(at: session).locale == mappingDefault)
    #expect(launcher.terminate(sessionID: id))
    #expect(await eventually { ended.value })
}
