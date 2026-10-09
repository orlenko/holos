import AppKit
import Foundation
@testable import HolosContent
import HolosCore
import HolosSynthesis
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosApp

/// The renderer that runs `voiceislocal say` for a natural voice's part (`HelperNaturalRenderer`), the
/// helper gate, and the helpers' folders (`NaturalVoiceHelpers`), with a fake launcher: nothing is spoken.
/// Serialized: the tests share `NaturalVoiceHelpers`' process-wide record of helpers and folders.
@MainActor @Suite(.serialized) struct NaturalVoiceRenderingTests {
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
