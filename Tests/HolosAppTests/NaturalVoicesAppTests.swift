import AppKit
import Foundation
@testable import HolosContent
import HolosCore
import HolosSynthesis
import Synchronization
import HolosTestSupport
import Testing
@testable import HolosApp

/// Settings › Reading's natural voice download (`NaturalVoiceDownload`), the voice a reading gets
/// (`ReadingVoices.choose`), and the renderer that runs `voiceislocal say` for a natural voice's part
/// (`HelperNaturalRenderer`), with a fake launcher: nothing is downloaded or spoken.
@MainActor @Suite(.serialized) struct NaturalVoicesAppTests {
    // MARK: Download

    @Test func aDownloadRunsSaysItsProgressAndEndsInstalled() {
        var download = NaturalVoiceDownload(pack: .english)
        #expect(download.row.button == "Download (530 MB)…")
        #expect(download.row.detail.contains("about 530 MB"))
        let result1 = download.start()
        #expect(result1)
        #expect(download.phase == .downloading(NaturalVoiceDownload.startingLine))
        let result2 = download.start()
        #expect(!result2)
        download.said("[19:20:09.487] [INFO] [FluidAudio.DownloadUtils] Found 48 files")
        #expect(download.phase == .downloading(NaturalVoiceDownload.startingLine))
        download.said("Natural voices (English): 45%")
        #expect(download.row.detail == "Natural voices (English): 45%")
        #expect(download.row.button == "Cancel")
        // The files are not looked at while this app's download runs.
        download.checked(.notInstalled)
        #expect(download.isRunning)
        download.ended(code: 0, lastLine: "Ready: natural voices (English, Kyutai Pocket TTS).", installed: true)
        #expect(download.phase == .installed)
        #expect(download.row.done)
        #expect(download.row.button == nil)
        let result3 = download.start()
        #expect(!result3)
    }

    @Test func cancelStopsTheDownloadAndOffersItAgain() {
        var download = NaturalVoiceDownload(pack: .french)
        let result4 = download.cancel()
        #expect(!result4)
        let result5 = download.start()
        #expect(result5)
        let result6 = download.cancel()
        #expect(result6)
        #expect(download.phase == .cancelling)
        #expect(!download.row.enabled)
        let result7 = download.cancel()
        #expect(!result7)
        download.ended(code: 143, lastLine: nil, installed: false)
        #expect(download.phase == .notInstalled)
        #expect(download.row.button == "Download (1.9 GB)…")
    }

    @Test func aFailureIsShownUntilTheFilesSayOtherwise() {
        var download = NaturalVoiceDownload(pack: .english)
        let result8 = download.start()
        #expect(result8)
        download.ended(code: 1, lastLine: "Error: Could not download the natural voices (offline).", installed: false)
        #expect(download.phase == .failed("Could not download the natural voices (offline)."))
        #expect(download.row.problem)
        #expect(download.row.button == "Try Again (530 MB)…")
        download.checked(.notInstalled)
        #expect(download.phase == .failed("Could not download the natural voices (offline)."))
        download.checked(.downloading)
        #expect(download.phase == .otherProcess)
        #expect(!download.row.enabled)
        download.checked(.installed)
        #expect(download.phase == .installed)
        var silent = NaturalVoiceDownload(pack: .english)
        let result9 = silent.start()
        #expect(result9)
        silent.ended(code: 9, lastLine: nil, installed: false)
        #expect(silent.phase == .failed("The download failed (code 9)."))
    }

    // MARK: Voice choice

    private let ava = VoiceDescriptor(id: "ava", name: "Ava (Premium)", language: "en-US", quality: "premium")
    private let amelie = VoiceDescriptor(id: "amelie", name: "Amélie", language: "fr-CA", quality: "default")

    private func choose(fixed: String? = nil, language: String?, saved: ReadingManifest? = nil,
                        installed: Set<NaturalVoicePack>) throws -> VoiceDescriptor {
        let apple = [ava, amelie]
        return try ReadingVoices.choose(
            fixed: fixed, fixedName: nil, language: language, saved: saved, installed: installed, appleVoices: apple,
            bestApple: { tag in apple.first { $0.language.hasPrefix(String(tag.prefix(2))) } },
            appleDefault: { "ava" })
    }

    @Test func automaticPicksTheNaturalVoiceOnceItsPackIsInstalled() throws {
        #expect(try choose(language: "en-US", installed: []).id == "ava")
        #expect(try choose(language: "en-US", installed: [.english]).id == "pocket:en:alba")
        #expect(try choose(language: "fr-CA", installed: [.english]).id == "amelie")
        #expect(try choose(language: "fr-CA", installed: [.english, .french]).id == "pocket:fr:estelle")
        // A reading started with a voice keeps it.
        #expect(try choose(fixed: "ava", language: "en-US", installed: [.english]).id == "ava")
        #expect(try choose(fixed: "pocket:en:george", language: "en", installed: [.english]).id == "pocket:en:george")
    }

    @Test func aNaturalVoiceWhosePackIsMissingSaysWhereToGetIt() {
        let error = #expect(throws: HolosError.self) {
            try choose(fixed: "pocket:fr:estelle", language: "fr", installed: [.english])
        }
        #expect(error?.localizedDescription.contains("The French natural voices are not installed. Download them in "
            + "Settings › Reading, then choose Resume.") == true)
        #expect(throws: HolosError.self) { try choose(fixed: "pocket:en:cosette", language: "en", installed: [.english]) }
    }

    @Test func aReadingFromAnotherCommitOfTheVoicesIsRefusedBeforeItsPackIsAskedFor() throws {
        func manifest(revision: String?) -> ReadingManifest {
            ReadingManifest(kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
                            sourceSHA256: "s", voiceIdentifier: "pocket:fr:estelle", rate: nil, title: "Jardin",
                            author: nil, language: "fr", comment: "c", format: .current, output: "/tmp/Jardin.m4a",
                            outputSHA256: nil, duration: nil, chapters: [], status: "incomplete", parts: [],
                            modelRevision: revision)
        }
        // The French pack is not installed, and installing it would not help: the commit is said first.
        let stale = manifest(revision: "0000000000000000000000000000000000000000")
        let error = #expect(throws: HolosError.self) {
            try choose(fixed: "pocket:fr:estelle", language: "fr", saved: stale, installed: [.english])
        }
        #expect(error?.localizedDescription.contains("another version of the natural voices") == true)
        #expect(error?.localizedDescription.contains("Delete this reading and make it again.") == true)
        // The same commit: the missing pack is what is said.
        let current = manifest(revision: NaturalVoiceModels.revision)
        let missing = #expect(throws: HolosError.self) {
            try choose(fixed: "pocket:fr:estelle", language: "fr", saved: current, installed: [.english])
        }
        #expect(missing?.localizedDescription.contains("natural voices are not installed") == true)
        #expect(try choose(fixed: "pocket:fr:estelle", language: "fr", saved: current, installed: [.french]).id
            == "pocket:fr:estelle")
    }

    @Test func theVoiceMenuListsNaturalVoicesFirstOrSaysWhereToGetThem() {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        ReadingVoicePopup.fill(popup, selecting: "pocket:en:alba", installed: [.english])
        let titles = popup.itemArray.map(\.title)
        #expect(titles.first == ReadingVoicePopup.automaticTitle)
        #expect(titles.dropFirst(2).first == "Natural — Alba (English)")
        #expect(popup.titleOfSelectedItem == "Natural — Alba (English)")
        #expect(titles.contains(ReadingVoicePopup.naturalHint))
        #expect(popup.itemArray.first { $0.title == ReadingVoicePopup.naturalHint }?.isEnabled == false)
        ReadingVoicePopup.fill(popup, selecting: "pocket:fr:estelle", installed: [])
        #expect(!popup.itemArray.contains { $0.title.hasPrefix("Natural —") })
        #expect(popup.titleOfSelectedItem == ReadingVoicePopup.automaticTitle)
        ReadingVoicePopup.fill(popup, selecting: nil, installed: [.english, .french])
        #expect(!popup.itemArray.map(\.title).contains(ReadingVoicePopup.naturalHint))
    }

    @Test func previewOfAutomaticUsesTheVoiceMakeAudioWouldUse() async throws {
        let preview = VoicePreview()
        let asked = Mutex<[String]>([])
        preview.installedPacks = { [.english] }
        preview.preferredLanguage = { "en-CA" }
        // The sample is never made (nor played): the render fails once it is asked for.
        preview.renderNatural = { _, voice, _, _ in
            asked.withLock { $0.append(voice) }
            throw HolosError.io("not rendered in tests")
        }
        let failed = Mutex(false)
        preview.onError = { _ in failed.withLock { $0 = true } }
        preview.speak(voiceIdentifier: nil, speed: 1)
        #expect(await eventually { failed.withLock { $0 } })
        #expect(asked.withLock { $0 } == ["pocket:en:alba"])
        #expect(!preview.isSpeaking)
        #expect(ReadingVoices.automatic(language: "fr-CA", installed: [.english], bestApple: { _ in nil }) == nil)
        #expect(ReadingVoices.automatic(language: "fr-CA", installed: [.english, .french], bestApple: { _ in nil })?.id
            == "pocket:fr:estelle")
    }

    @Test func installingNaturalVoicesKeepsTheCardsVoiceAndSpeed() async throws {
        let pane = ReadingPane(controller: ReadingController())
        let popup = pane.voicePopup
        // A voice and a speed other than Settings' defaults, as if just chosen on the card.
        let chosen = try #require(popup.itemArray.last { item in
            item.isEnabled && (item.representedObject as? String).map { $0 != ReadingPreferences.voice } == true
        })
        popup.select(chosen)
        _ = popup.sendAction(popup.action, to: popup.target)
        let speed = ReadingPreferences.speed == 1.3 ? 0.9 : 1.3
        pane.speedSlider.doubleValue = speed
        let before = popup.itemArray.first
        ReadingVoices.announceInstalled()
        // The menu is filled again (new items), on the main queue.
        #expect(await eventually { popup.itemArray.first !== before })
        #expect(popup.itemArray.first !== before)
        #expect(popup.selectedItem?.representedObject as? String == chosen.representedObject as? String)
        #expect(abs(pane.speedSlider.doubleValue - speed) < 0.001, "\(pane.speedSlider.doubleValue) vs \(speed)")
    }

    @Test func aNaturalVoiceBrieflyMissingIsChosenAgainWhenItsPackIsBack() async throws {
        let pane = ReadingPane(controller: ReadingController())
        let popup = pane.voicePopup
        var installed: Set<NaturalVoicePack> = [.english]
        pane.installedPacks = { installed }
        func announced() async {
            let before = popup.itemArray.first
            ReadingVoices.announceInstalled()
            _ = await eventually { popup.itemArray.first !== before }
        }
        await announced()
        let alba = try #require(popup.itemArray.first { $0.representedObject as? String == "pocket:en:alba" })
        popup.select(alba)
        _ = popup.sendAction(popup.action, to: popup.target)
        // A reinstall: the pack is missing for a moment, and the menu shows Automatic meanwhile.
        installed = []
        await announced()
        #expect(popup.selectedItem?.representedObject == nil)
        installed = [.english]
        await announced()
        #expect(popup.selectedItem?.representedObject as? String == "pocket:en:alba")
    }

    @Test func noHelperFolderIsMadeOnceTheQuitHasBegun() throws {
        // Made before the quit: registered, so the quit removes it.
        let before = try NaturalVoiceHelpers.makeFolder { try NaturalHelperScratch.create() }
        NaturalVoiceHelpers.stopAll { _ in }
        defer { NaturalVoiceHelpers.stopAll(ending: false) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: before.path))
        // Asked for after it: nothing is made, so nothing (no reading text) can be left behind.
        let made = Mutex(false)
        #expect(throws: CancellationError.self) {
            _ = try NaturalVoiceHelpers.makeFolder {
                made.withLock { $0 = true }
                return try NaturalHelperScratch.create()
            }
        }
        #expect(!made.withLock { $0 })
    }

    @Test func aQuitDuringTheFolderWorkLeavesNoFolder() throws {
        defer { NaturalVoiceHelpers.stopAll(ending: false) { _ in } }
        let made = Mutex<URL?>(nil)
        // The quit comes while the folder is being made (it does not wait for it): the folder removes itself.
        #expect(throws: CancellationError.self) {
            _ = try NaturalVoiceHelpers.makeFolder {
                let folder = try NaturalHelperScratch.create()
                made.withLock { $0 = folder }
                NaturalVoiceHelpers.stopAll { _ in }
                return folder
            }
        }
        let folder = try #require(made.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aReadingThatSavedNoFallbackVoicePassesNone() async throws {
        let launches = Launches()
        let renderer = HelperNaturalRenderer(launch: { arguments, _, onExit in
            launches.arguments.withLock { $0.append(arguments) }
            try NaturalSpeechFile.write([Float](repeating: 0.1, count: 2_400), sampleRate: 24_000,
                                        to: URL(fileURLWithPath: arguments[8]))
            DispatchQueue.main.async { onExit(0) }
            return 4243
        }, installedPacks: { [.english] }, forceKill: { _ in }, gate: NaturalVoiceHelperGate())
        _ = try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil,
                                      savedSettings: ["check": "on"], to: try folder().appendingPathComponent("n.caf"))
        let arguments = launches.arguments.withLock { $0 }.first ?? []
        #expect(Array(arguments.suffix(4)) == ["--check", "on", "--fallback-voice", ""])
    }

    @Test func aNewPreviewClearsTheLastOnesFailure() async throws {
        let pane = ReadingPane(controller: ReadingController())
        pane.installedPacks = { [.english] }
        pane.preview.installedPacks = { [.english] }
        let popup = pane.voicePopup
        let before = popup.itemArray.first
        ReadingVoices.announceInstalled()
        #expect(await eventually { popup.itemArray.first !== before })
        let alba = try #require(popup.itemArray.first { $0.representedObject as? String == "pocket:en:alba" })
        popup.select(alba)
        _ = popup.sendAction(popup.action, to: popup.target)
        pane.preview.renderNatural = { _, _, _, _ in throw HolosError.io("The sample could not be made.") }
        pane.togglePreview()
        #expect(await eventually { pane.message?.contains("could not be made") == true })
        // The next Preview starts without the old failure on the card (nothing is played: it never finishes).
        pane.preview.renderNatural = { _, _, _, _ in
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        pane.togglePreview()
        #expect(pane.message == nil)
        pane.togglePreview()
    }

    @Test func quittingStopsTheToolAndRemovesItsFolder() async throws {
        let exit = Mutex<(@MainActor (Int32) -> Void)?>(nil)
        let textFile = Mutex<String?>(nil)
        let renderer = HelperNaturalRenderer(launch: { arguments, _, onExit in
            textFile.withLock { $0 = arguments[4] }
            exit.withLock { $0 = onExit }
            return 31_337
        }, installedPacks: { [.english] }, signal: { _ in }, forceKill: { _ in })
        let output = try folder().appendingPathComponent("p.caf")
        let task = Task { try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil, to: output) }
        #expect(await eventually { exit.withLock { $0 != nil } })
        let working = try #require(textFile.withLock { $0 }.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        #expect(FileManager.default.fileExists(atPath: working.path))
        // The quit: the tool is signalled and its folder removed at once, before the render has seen it end.
        var signalled: [Int32] = []
        let stopped = NaturalVoiceHelpers.stopAll(ending: false) { signalled.append($0) }
        #expect(stopped == [31_337])
        #expect(signalled == [31_337])
        #expect(!FileManager.default.fileExists(atPath: working.path))
        exit.withLock { $0 }?(143)
        await #expect(throws: HolosError.self) { _ = try await task.value }
        #expect(NaturalVoiceHelpers.stopAll(ending: false) { _ in }.isEmpty)
    }

    @Test func theMenusAreToldWhenPacksAreInstalledElsewhere() {
        var watch = NaturalVoicesWatch()
        let first = watch.observe([])
        #expect(!first)
        let same = watch.observe([])
        #expect(!same)
        // Installed from Terminal while the app was in the background.
        let installed = watch.observe([.english])
        #expect(installed)
        let again = watch.observe([.english])
        #expect(!again)
        let removed = watch.observe([])
        #expect(removed)
    }

    @Test func anInstallElsewhereIsFollowedUntilItEnds() async {
        // What a fake status source says at each look: installing for three looks, then installed.
        var looks = 0
        var watch = NaturalVoicesWatch()
        _ = watch.observe([])
        var announced = 0
        var pauses = 0
        await NaturalVoicesInstallPoll.run(
            inProgress: { looks < 3 },
            check: {
                looks += 1
                if watch.observe(looks >= 3 ? [.english] : []) { announced += 1 }
            },
            pause: { pauses += 1 })
        // The check after the install ended told the menus once, and the polling stopped there.
        #expect(announced == 1)
        #expect(looks == 3)
        #expect(pauses == 3)
        // Nothing being installed: no polling at all.
        var idleChecks = 0
        await NaturalVoicesInstallPoll.run(inProgress: { false }, check: { idleChecks += 1 }, pause: {})
        #expect(idleChecks == 0)
    }

    /// Fake helpers that run until told to exit; records the order they were launched in.
    @MainActor private final class FakeHelpers {
        var launched: [String] = []
        var exits: [String: @MainActor (Int32) -> Void] = [:]

        func renderer(_ name: String, gate: NaturalVoiceHelperGate) -> HelperNaturalRenderer {
            HelperNaturalRenderer(launch: { [self] _, _, onExit in
                launched.append(name)
                exits[name] = onExit
                return Int32(100 + launched.count)
            }, installedPacks: { [.english] }, signal: { _ in }, forceKill: { _ in }, gate: gate)
        }

        func exit(_ name: String, code: Int32 = 143) { exits.removeValue(forKey: name)?(code) }
    }

    private func render(_ renderer: HelperNaturalRenderer) throws -> Task<RenderedAudio, Error> {
        let output = try folder().appendingPathComponent("p.caf")
        return Task { try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil, to: output) }
    }

    @Test func oneHelperRunsAtATimeAndTheNextWaitsForItToExit() async throws {
        let gate = NaturalVoiceHelperGate()
        let helpers = FakeHelpers()
        // A reading's part is being rendered.
        let part = try render(helpers.renderer("part", gate: gate))
        #expect(await eventually { !helpers.launched.isEmpty })
        #expect(helpers.launched == ["part"])
        // A Preview asked for meanwhile waits: no second helper (and no second model) while the first runs.
        let preview = try render(helpers.renderer("preview", gate: gate))
        #expect(await eventually { gate.waitingCount == 1 })
        #expect(helpers.launched == ["part"])
        // Stopping the part signals its helper; the Preview still waits until that helper has exited.
        part.cancel()
        #expect(gate.waitingCount == 1)
        #expect(helpers.launched == ["part"])
        helpers.exit("part")
        #expect(await eventually { helpers.launched.count == 2 })
        #expect(helpers.launched == ["part", "preview"])
        helpers.exit("preview")
        _ = try? await part.value
        _ = try? await preview.value
        #expect(!gate.isBusy)
    }

    @Test func aWaitingRenderThatIsStoppedStartsNothing() async throws {
        let gate = NaturalVoiceHelperGate()
        let helpers = FakeHelpers()
        let first = try render(helpers.renderer("first", gate: gate))
        #expect(await eventually { !helpers.launched.isEmpty })
        let second = try render(helpers.renderer("second", gate: gate))
        #expect(await eventually { gate.waitingCount == 1 })
        second.cancel()
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        helpers.exit("first", code: 1)
        _ = try? await first.value
        #expect(helpers.launched == ["first"])
        #expect(!gate.isBusy)
    }

    private final class FakePlayback: PreviewPlayback {
        var stopped = false
        func stop() { stopped = true }
    }

    private func previewWithMadeSample() -> VoicePreview {
        let preview = VoicePreview()
        preview.installedPacks = { [.english] }
        preview.preferredLanguage = { "en-CA" }
        // The sample is written as the tool would; nothing is played (the playback is replaced below).
        preview.renderNatural = { _, _, _, output in
            try NaturalSpeechFile.write([Float](repeating: 0, count: 2_400), sampleRate: 24_000, to: output)
        }
        return preview
    }

    @Test func aSampleThatDoesNotStartPlayingIsAFailureNotAStop() async throws {
        let preview = previewWithMadeSample()
        preview.startPlayback = { _, _ in throw HolosError.io("The voice sample could not be played.") }
        let problem = Mutex<String?>(nil)
        preview.onError = { message in problem.withLock { $0 = message } }
        preview.speak(voiceIdentifier: "pocket:en:alba", speed: 1)
        #expect(preview.isSpeaking)
        #expect(await eventually { problem.withLock { $0 } != nil })
        #expect(problem.withLock { $0 }?.contains("could not be played") == true)
        #expect(!preview.isSpeaking)
    }

    @Test func aSampleThatStartsPlayingCanBeStopped() async throws {
        let preview = previewWithMadeSample()
        let playback = FakePlayback()
        let started = Mutex(false)
        preview.startPlayback = { _, _ in
            started.withLock { $0 = true }
            return playback
        }
        preview.speak(voiceIdentifier: "pocket:en:alba", speed: 1)
        #expect(await eventually { started.withLock { $0 } })
        #expect(preview.isSpeaking)
        preview.stop()
        #expect(playback.stopped)
        #expect(!preview.isSpeaking)
    }

    // MARK: Rendering through the tool

    private final class Launches: Sendable {
        let arguments = Mutex<[[String]]>([])
        let signals = Mutex<[Int32]>([])
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aPartIsRenderedByTheToolFromATextFile() async throws {
        let launches = Launches()
        let scratchWasMarked = Mutex(false)
        let renderer = HelperNaturalRenderer(launch: { arguments, _, onExit in
            launches.arguments.withLock { $0.append(arguments) }
            // What the tool would do: read the text file, write the part.
            let text = try String(contentsOfFile: arguments[4], encoding: .utf8)
            let marked = NaturalHelperScratch.isMade(URL(fileURLWithPath: arguments[6]), for: getpid())
            scratchWasMarked.withLock { $0 = marked }
            #expect(text == "First.\n\nSecond.")
            let output = URL(fileURLWithPath: arguments[8])
            try NaturalSpeechFile.write([Float](repeating: 0.1, count: 12_000), sampleRate: 24_000, to: output)
            DispatchQueue.main.async { onExit(0) }
            return 4242
        }, installedPacks: { [.english] }, signal: { pid in launches.signals.withLock { $0.append(pid) } })
        let output = try folder().appendingPathComponent("part0001.caf")
        let rate = ReadingSpeed.rate(for: 1.2)
        let result = try await renderer.render(text: "First.\n\nSecond.", voiceIdentifier: "pocket:en:alba",
                                               rate: rate, to: output)
        #expect(abs(result.duration - 0.5) < 0.001)
        #expect(result.url == output)
        let arguments = launches.arguments.withLock { $0 }.first ?? []
        #expect(Array(arguments.prefix(3)) == ["say", "--voice", "pocket:en:alba"])
        #expect(arguments[3] == "--text-file")
        // The tool's temporary files go in the folder this app tracks (and deletes on Stop or Quit): the text file's.
        #expect(arguments[5] == "--scratch-directory")
        #expect(arguments[6] == URL(fileURLWithPath: arguments[4]).deletingLastPathComponent().path)
        // Made and marked for this app, so the tool removes it if the app ends (and no other folder).
        #expect(scratchWasMarked.withLock { $0 })
        // The tool stops when this app ends, and waits for one an ended app left writing the same part.
        #expect(Array(arguments.suffix(6)) == ["--output", output.path, "--parent-pid", "\(getpid())", "--rate",
                                               "\(rate!)"])
        #expect(launches.signals.withLock { $0 }.isEmpty)
        // The text file is gone with its folder (removed off the main actor).
        #expect(await eventually { !FileManager.default.fileExists(atPath: arguments[6]) })
        #expect(!FileManager.default.fileExists(atPath: arguments[4]))
        #expect(!FileManager.default.fileExists(atPath: arguments[6]))
    }

    @Test func aPartIsRenderedWithTheSettingsItsReadingSaved() async throws {
        let launches = Launches()
        let renderer = HelperNaturalRenderer(launch: { arguments, _, onExit in
            launches.arguments.withLock { $0.append(arguments) }
            try NaturalSpeechFile.write([Float](repeating: 0.1, count: 2_400), sampleRate: 24_000,
                                        to: URL(fileURLWithPath: arguments[8]))
            DispatchQueue.main.async { onExit(0) }
            return 4242
        }, installedPacks: { [.english] }, gate: NaturalVoiceHelperGate(),
           currentSettings: { _ in NaturalRenderSettings(fallbackVoice: "today", checked: true) })
        // What a reading saves when it starts: the tool's settings now.
        #expect(renderer.renderSettings(for: "pocket:en:alba") == ["fallbackVoice": "today", "check": "on"])
        #expect(renderer.renderSettings(for: "ava") == nil)
        // Started with Ava as the fallback and the check off: each part is rendered so, whatever today's settings.
        _ = try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil,
                                      savedSettings: ["fallbackVoice": "ava", "check": "off"],
                                      to: try folder().appendingPathComponent("p.caf"))
        let arguments = launches.arguments.withLock { $0 }.first ?? []
        #expect(Array(arguments.suffix(4)) == ["--check", "off", "--fallback-voice", "ava"])
    }

    @Test func aFailedRenderSaysWhatTheToolSaid() async throws {
        let renderer = HelperNaturalRenderer(launch: { _, errors, onExit in
            try Data("Paragraph 2 is read by Ava: it was heard wrong.\nError: The voice broke.\n".utf8).write(to: errors)
            DispatchQueue.main.async { onExit(1) }
            return 7
        }, installedPacks: { [.english] })
        let error = await #expect(throws: HolosError.self) {
            _ = try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil,
                                          to: try folder().appendingPathComponent("p.caf"))
        }
        #expect(error?.localizedDescription.contains("The voice broke.") == true)
        await #expect(throws: HolosError.self) {
            _ = try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:fr:estelle", rate: nil,
                                          to: try folder().appendingPathComponent("q.caf"))
        }
    }

    @Test func aStopAfterTheToolExitedSignalsNoOne() async throws {
        let signals = Mutex<[Int32]>([])
        let exit = Mutex<(@MainActor (Int32) -> Void)?>(nil)
        let renderer = HelperNaturalRenderer(launch: { _, _, onExit in
            exit.withLock { $0 = onExit }
            return 4_321
        }, installedPacks: { [.english] }, signal: { pid in signals.withLock { $0.append(pid) } },
           forceKill: { _ in }, gate: NaturalVoiceHelperGate())
        let output = try folder().appendingPathComponent("p.caf")
        let task = Task { try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil, to: output) }
        #expect(await eventually { exit.withLock { $0 != nil } })
        // The tool exits (and is reaped); a Stop comes in the same turn, before the render has finished.
        exit.withLock { $0 }?(1)
        task.cancel()
        _ = try? await task.value
        // Its pid may belong to another process by now: nothing is signalled.
        #expect(signals.withLock { $0 }.isEmpty)
        #expect(NaturalVoiceHelpers.stopAll(ending: false) { _ in }.isEmpty)
    }

    @Test func aToolThatIgnoresTheStopIsKilled() async throws {
        let launches = Launches()
        let exit = Mutex<(@MainActor (Int32) -> Void)?>(nil)
        let killed = Mutex<[Int32]>([])
        let renderer = HelperNaturalRenderer(launch: { _, _, onExit in
            exit.withLock { $0 = onExit }
            return 77
        }, installedPacks: { [.english] }, signal: { pid in
            // SIGTERM: the tool is wedged and does not exit.
            launches.signals.withLock { $0.append(pid) }
        }, forceKill: { pid in
            killed.withLock { $0.append(pid) }
            DispatchQueue.main.async { MainActor.assumeIsolated { exit.withLock { $0 }?(137) } }
        }, killAfter: .milliseconds(20), gate: NaturalVoiceHelperGate())
        let output = try folder().appendingPathComponent("p.caf")
        let task = Task { try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil, to: output) }
        #expect(await eventually { exit.withLock { $0 != nil } })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(launches.signals.withLock { $0 } == [77])
        #expect(killed.withLock { $0 } == [77])
    }

    @Test func aStopSignalsTheTool() async throws {
        let launches = Launches()
        let exit = Mutex<(@MainActor (Int32) -> Void)?>(nil)
        let renderer = HelperNaturalRenderer(launch: { _, _, onExit in
            exit.withLock { $0 = onExit }
            return 99
        }, installedPacks: { [.english] }, signal: { pid in
            launches.signals.withLock { $0.append(pid) }
            // The tool ends on SIGTERM.
            DispatchQueue.main.async { MainActor.assumeIsolated { exit.withLock { $0 }?(143) } }
        }, forceKill: { _ in })
        let output = try folder().appendingPathComponent("p.caf")
        let task = Task { try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil, to: output) }
        #expect(await eventually { exit.withLock { $0 != nil } })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(launches.signals.withLock { $0 } == [99])
    }
}
