import AppKit
import Foundation
import HolosContent
import HolosCore
import HolosSynthesis
import Synchronization
import Testing
@testable import HolosApp

/// Settings › Reading's natural voice download (`NaturalVoiceDownload`), the voice a reading gets
/// (`ReadingVoices.choose`), and the renderer that runs `voiceislocal say` for a natural voice's part
/// (`HelperNaturalRenderer`), with a fake launcher: nothing is downloaded or spoken.
@MainActor @Suite struct NaturalVoicesAppTests {
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

    private func choose(fixed: String? = nil, language: String?, installed: Set<NaturalVoicePack>) throws
        -> VoiceDescriptor {
        let apple = [ava, amelie]
        return try ReadingVoices.choose(
            fixed: fixed, fixedName: nil, language: language, installed: installed, appleVoices: apple,
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
        let renderer = HelperNaturalRenderer(launch: { arguments, _, onExit in
            launches.arguments.withLock { $0.append(arguments) }
            // What the tool would do: read the text file, write the part.
            let text = try String(contentsOfFile: arguments[4], encoding: .utf8)
            #expect(text == "First.\n\nSecond.")
            let output = URL(fileURLWithPath: arguments[6])
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
        #expect(Array(arguments.suffix(4)) == ["--output", output.path, "--rate", "\(rate!)"])
        #expect(launches.signals.withLock { $0 }.isEmpty)
        // The text file is gone with its folder.
        #expect(!FileManager.default.fileExists(atPath: arguments[4]))
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
        })
        let output = try folder().appendingPathComponent("p.caf")
        let task = Task { try await renderer.render(text: "Hello.", voiceIdentifier: "pocket:en:alba", rate: nil, to: output) }
        while exit.withLock({ $0 == nil }) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(launches.signals.withLock { $0 } == [99])
    }
}
