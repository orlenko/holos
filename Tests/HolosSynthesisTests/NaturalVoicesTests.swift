import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

@Suite struct NaturalVoiceCatalogTests {
    @Test func onlyVoicesThatAllowCommercialUseAreOffered() {
        let offered = NaturalVoiceCatalog.offered.map(\.id)
        #expect(!offered.contains("pocket:en:cosette"))
        #expect(!offered.contains("pocket:en:jean"))
        #expect(offered.contains("pocket:en:alba"))
        #expect(offered.contains("pocket:fr:estelle"))
        #expect(NaturalVoiceCatalog.offered.allSatisfy { $0.license != .ccByNC4 })
        #expect(NaturalVoiceCatalog.all.filter { $0.license == .ccByNC4 }.map(\.name).sorted() == ["cosette", "jean"])
        #expect(Set(NaturalVoiceCatalog.all.map(\.id)).count == NaturalVoiceCatalog.all.count)
        #expect(NaturalVoiceCatalog.voice(id: "pocket:en:cosette") == nil)
        #expect(NaturalVoiceCatalog.voice(id: "pocket:en:jean") == nil)
    }

    @Test func identifiersParseStrictly() {
        #expect(NaturalVoiceCatalog.parse("pocket:en:alba")?.pack == .english)
        #expect(NaturalVoiceCatalog.parse("pocket:fr:estelle")?.name == "estelle")
        #expect(NaturalVoiceCatalog.parse("pocket:en:peter_yearsley")?.name == "peter_yearsley")
        for bad in ["pocket:EN:alba", "pocket:de:juergen", "pocket:en:", "pocket:en:a:b", "apple:en:alba",
                    "pocket:en:al-ba", "pocket:en:Alba", "pocket::alba", "pocket", ""] {
            #expect(NaturalVoiceCatalog.parse(bad) == nil, "\(bad)")
        }
        #expect(NaturalVoiceCatalog.isNatural("pocket:anything"))
        #expect(!NaturalVoiceCatalog.isNatural("com.apple.voice.premium.en-US.Ava"))
    }

    @Test func labelsAndDescriptors() {
        let alba = NaturalVoiceCatalog.defaultVoice(for: .english)
        #expect(alba.id == "pocket:en:alba")
        #expect(alba.title == "Natural — Alba (English)")
        #expect(alba.descriptor == VoiceDescriptor(id: "pocket:en:alba", name: "Alba (Natural)", language: "en",
                                                   quality: "natural"))
        #expect(NaturalVoiceCatalog.defaultVoice(for: .french).title == "Natural — Estelle (French)")
    }

    @Test func voicesOfInstalledPacksDefaultFirst() {
        #expect(NaturalVoiceCatalog.voices(installed: []).isEmpty)
        let english = NaturalVoiceCatalog.voices(installed: [.english])
        #expect(english.first?.name == "alba")
        #expect(english.allSatisfy { $0.pack == .english })
        #expect(english.count == 19)
        #expect(Array(english.dropFirst().map(\.displayName)) == english.dropFirst().map(\.displayName).sorted())
        #expect(NaturalVoiceCatalog.voices(installed: [.french]).map(\.id) == ["pocket:fr:estelle"])
        #expect(NaturalVoiceCatalog.voices(installed: [.french, .english]).last?.id == "pocket:fr:estelle")
    }

    @Test func defaultsSwitchOnceAPackIsInstalled() {
        #expect(NaturalVoiceCatalog.defaultVoice(language: "en-US", installed: []) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: "en-GB", installed: [.english])?.id == "pocket:en:alba")
        #expect(NaturalVoiceCatalog.defaultVoice(language: "fr-CA", installed: [.english]) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: "fr-CA", installed: [.english, .french])?.id
            == "pocket:fr:estelle")
        #expect(NaturalVoiceCatalog.defaultVoice(language: "de", installed: [.english, .french]) == nil)
        #expect(NaturalVoiceCatalog.defaultVoice(language: nil, installed: [.english]) == nil)
    }

    @Test func queriesMatchOfferedVoicesOnly() {
        for query in ["Alba", "alba", "Alba (Natural)", "pocket:en:alba", "POCKET:EN:ALBA", "Natural — Alba (English)"] {
            #expect(NaturalVoiceCatalog.match(query)?.id == "pocket:en:alba", "\(query)")
        }
        #expect(NaturalVoiceCatalog.match("Peter Yearsley")?.id == "pocket:en:peter_yearsley")
        #expect(NaturalVoiceCatalog.match("cosette") == nil)
        #expect(NaturalVoiceCatalog.match("Ava") == nil)
        #expect(NaturalVoiceCatalog.match("  ") == nil)
    }

    @Test func packSizes() {
        #expect(NaturalVoicePack.english.downloadSize == "530 MB")
        #expect(NaturalVoicePack.french.downloadSize == "1.9 GB")
        #expect(NaturalVoicePack.forLanguage("fr-FR") == .french)
        #expect(NaturalVoicePack.forLanguage("it") == nil)
        #expect(NaturalVoicePack.english.fluidLanguage == "english")
        #expect(NaturalVoicePack.french.fluidLanguage == "french_24l")
    }
}

@Suite struct NaturalSpeechPlanTests {
    @Test func paragraphsGetPausesAndAHeadingALongerOne() {
        let blocks = NaturalSpeechPlan.blocks("A Heading\n\nFirst paragraph,\nwith a line break.\n\nSecond one.")
        #expect(blocks.map(\.text) == ["A Heading", "First paragraph, with a line break.", "Second one."])
        #expect(blocks.map(\.pauseAfter) == [0.9, 0.6, 0])
        #expect(blocks.map(\.isHeading) == [true, false, false])
    }

    @Test func aFirstSentenceIsNotAHeading() {
        let blocks = NaturalSpeechPlan.blocks("It begins here.\n\nThen goes on.")
        #expect(blocks.map(\.pauseAfter) == [0.6, 0])
        #expect(!blocks[0].isHeading)
        // A lone block (a title part) has no pause after it; the pipeline's gaps follow.
        #expect(NaturalSpeechPlan.blocks("Title Alone").map(\.pauseAfter) == [0])
        #expect(NaturalSpeechPlan.blocks(" \n\n \n").isEmpty)
        let long = String(repeating: "word ", count: 30)
        #expect(!NaturalSpeechPlan.blocks(long + "\n\nNext.")[0].isHeading)
    }
}

@Suite struct SpeechChunkCheckTests {
    @Test func whatIsHeardMatchesIgnoringCasePunctuationAndNumbers() {
        let verdict = SpeechChunkCheck.evaluate(
            expected: "The garden had 1,500 flowers. Children walked out on Sundays!",
            heard: "the garden had fifteen hundred flowers children walked out on sundays")
        // "fifteen hundred" are two extra words: within 15 % of 9 words (at least 2).
        #expect(verdict.passed)
        #expect(verdict.expectedWords == 9)
        #expect(SpeechChunkCheck.evaluate(expected: "Café crème", heard: "cafe creme").wordErrorRate == 0)
    }

    @Test func garbledOrCutOffSpeechFails() {
        let text = "Each morning he carried buckets of rainwater up the rocky path, counting his steps out of habit."
        #expect(!SpeechChunkCheck.evaluate(expected: text, heard: "each morning he carried banana phone river tock")
            .passed)
        // A long paragraph cut off after nine words: few edits proportionally, but more than 8 words missing.
        let long = Array(repeating: text, count: 4).joined(separator: " ")
        let cut = long.split(separator: " ").dropLast(9).joined(separator: " ")
        let verdict = SpeechChunkCheck.evaluate(expected: long, heard: cut)
        #expect(verdict.wordErrorRate < 0.15)
        #expect(!verdict.passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "Hello there.", heard: "").passed)
    }

    @Test func shortTextsAllowTwoEdits() {
        #expect(SpeechChunkCheck.evaluate(expected: "The Lighthouse Keeper's Garden",
                                          heard: "the lighthouse keepers garden").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "The Lighthouse Keeper's Garden", heard: "a light house").passed)
    }
}

@Suite struct NaturalSpeechSpeedTests {
    @Test func theSlidersSpeedsMapToThemselves() {
        #expect(NaturalSpeechSpeed.factor(rate: nil) == 1)
        for speed in stride(from: 0.8, through: 1.4, by: 0.1) {
            let factor = NaturalSpeechSpeed.factor(rate: ReadingSpeed.rate(for: speed))
            #expect(abs(factor - ReadingSpeed.clamped(speed)) < 0.001, "\(speed)")
        }
        #expect(NaturalSpeechSpeed.factor(rate: 0) == 0.5)
        #expect(NaturalSpeechSpeed.factor(rate: 1) == 2)
        #expect(NaturalSpeechSpeed.factor(rate: .nan) == 1)
    }

    @Test func timeStretchChangesTheLength() throws {
        let second = (0..<24_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 24_000)) * 0.3 }
        #expect(try TimeStretch.apply(second, sampleRate: 24_000, rate: 1) == second)
        let faster = try TimeStretch.apply(second, sampleRate: 24_000, rate: 2)
        #expect(abs(faster.count - 12_000) < 200)
        #expect(faster.contains { abs($0) > 0.1 })
        let slower = try TimeStretch.apply(second, sampleRate: 24_000, rate: 0.8)
        #expect(abs(slower.count - 30_000) < 200)
    }
}

// MARK: - Renderer

/// A fake Pocket TTS: 0.1 s of a tone per word, louder for each seed so takes can be told apart.
private actor FakeBackend: NaturalSpeechBackend {
    struct Call: Equatable { let text: String; let voice: String; let seed: UInt64 }
    private(set) var calls: [Call] = []
    var failures: Set<Int> = []

    func failing(_ calls: Set<Int>) { failures = calls }

    func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float] {
        calls.append(Call(text: text, voice: voice.id, seed: seed))
        if failures.contains(calls.count) { throw HolosError.io("GPU busy") }
        let words = text.split(separator: " ").count
        return [Float](repeating: 0.25, count: words * 2_400)
    }
}

/// Hears what it is told for each call in turn (then the last answer again); nil answers mean "no recognizer".
private final class FakeChecker: SpeechChunkChecker, Sendable {
    private let count = Mutex(0)
    let heard: @Sendable (Int) -> String?

    init(_ heard: @escaping @Sendable (Int) -> String?) {
        self.heard = heard
    }

    var calls: Int { count.withLock { $0 } }

    func transcript(of samples: [Float], sampleRate: Double, language: String) async throws -> String? {
        let call = count.withLock { value -> Int in
            value += 1
            return value
        }
        return heard(call)
    }
}

@MainActor private final class FakeFallback: ParagraphFallback {
    private(set) var texts: [String] = []

    func samples(for text: String, language: String, sampleRate: Double) async throws -> (samples: [Float], voice: String) {
        texts.append(text)
        return ([Float](repeating: 0.5, count: 4_800), "Ava (Premium)")
    }
}

@MainActor @Suite struct NaturalSpeechRendererTests {
    private let folder: URL
    private let alba = "pocket:en:alba"
    private let text = "A Heading\n\nThe first paragraph has six words.\n\nThe second has four."

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-natural-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func renderer(_ backend: FakeBackend, checker: FakeChecker? = nil, fallback: FakeFallback = FakeFallback(),
                          installed: Set<NaturalVoicePack> = [.english]) -> NaturalSpeechRenderer {
        NaturalSpeechRenderer(backend: backend, checker: checker, fallback: fallback, installedPacks: { installed })
    }

    @Test func feedsOneParagraphAtATimeWithPausesAndTheFixedSeed() async throws {
        let backend = FakeBackend()
        let renderer = renderer(backend)
        let output = folder.appendingPathComponent("part.caf")
        let result = try await renderer.render(text: text, voiceIdentifier: alba, rate: nil, to: output)
        let calls = await backend.calls
        #expect(calls.map(\.text) == ["A Heading", "The first paragraph has six words.", "The second has four."])
        #expect(calls.allSatisfy { $0.seed == NaturalSpeechRenderer.seed && $0.voice == alba })
        // 2 + 6 + 4 words at 0.1 s, a heading pause and a paragraph pause.
        #expect(abs(result.duration - (1.2 + 0.9 + 0.6)) < 0.01)
        #expect(result.sampleRate == 24_000)
        let samples = try AudioSamples.mono(from: output, sampleRate: 24_000)
        #expect(abs(samples.count - Int(2.7 * 24_000)) < 10)
        #expect(renderer.lastStats.paragraphs == 3)
        // Rendered again (a resume), the same seeds are asked for.
        _ = try await renderer.render(text: text, voiceIdentifier: alba, rate: nil,
                                      to: folder.appendingPathComponent("again.caf"))
        #expect(await backend.calls.dropFirst(3).map(\.seed) == calls.map(\.seed))
    }

    @Test func speedShortensTheSpeechButNotThePauses() async throws {
        let backend = FakeBackend()
        let fast = try await renderer(backend).render(
            text: text, voiceIdentifier: alba, rate: ReadingSpeed.rate(for: 1.2),
            to: folder.appendingPathComponent("fast.caf"))
        #expect(abs(fast.duration - (1.2 / 1.2 + 1.5)) < 0.03)
    }

    @Test func aParagraphThatFailsItsCheckIsRenderedAgainWithTheNextSeed() async throws {
        let backend = FakeBackend()
        // The second paragraph's first take is heard garbled; its second take is right.
        let checker = FakeChecker { call in
            switch call {
            case 1: "a heading"
            case 2: "banana phone river"
            case 3: "the first paragraph has six words"
            default: "the second has four"
            }
        }
        let renderer = renderer(backend, checker: checker)
        var events: [NaturalSpeechEvent] = []
        renderer.onEvent = { events.append($0) }
        _ = try await renderer.render(text: text, voiceIdentifier: alba, rate: nil,
                                      to: folder.appendingPathComponent("retry.caf"))
        let calls = await backend.calls
        #expect(calls.map(\.seed) == [NaturalSpeechRenderer.seed, NaturalSpeechRenderer.seed,
                                      NaturalSpeechRenderer.seed &+ 1, NaturalSpeechRenderer.seed])
        #expect(calls[1].text == calls[2].text)
        let checked = events.compactMap { event -> (Int, Int, Bool)? in
            if case .checked(let paragraph, let take, let verdict, _) = event { return (paragraph, take, verdict.passed) }
            return nil
        }
        #expect(checked.map(\.0) == [1, 2, 2, 3])
        #expect(checked.map(\.1) == [1, 1, 2, 1])
        #expect(checked.map(\.2) == [true, false, true, true])
        #expect(renderer.lastStats.rerenders == 1)
        #expect(renderer.lastStats.fallbacks == 0)
    }

    @Test func aParagraphThatFailsTwiceIsReadByTheSystemVoice() async throws {
        let backend = FakeBackend()
        let fallback = FakeFallback()
        // The first answer is right; then two wrong takes of the second paragraph.
        let answers = FakeChecker { call in
            switch call {
            case 1: "a heading"
            case 2, 3: "nothing like it at all"
            default: "the second has four"
            }
        }
        let renderer = renderer(backend, checker: answers, fallback: fallback)
        var events: [NaturalSpeechEvent] = []
        renderer.onEvent = { events.append($0) }
        let result = try await renderer.render(text: text, voiceIdentifier: alba, rate: nil,
                                               to: folder.appendingPathComponent("fallback.caf"))
        #expect(fallback.texts == ["The first paragraph has six words."])
        #expect(events.contains { event in
            if case .fellBack(2, "Ava (Premium)", _) = event { return true }
            return false
        })
        #expect(renderer.lastStats.fallbacks == 1)
        // 0.2 s heading, 0.2 s of system voice, 0.4 s second paragraph, and the pauses.
        #expect(abs(result.duration - (0.2 + 0.2 + 0.4 + 1.5)) < 0.01)
    }

    @Test func aVoiceThatFailsIsRetriedThenReplaced() async throws {
        let backend = FakeBackend()
        await backend.failing([1, 2])
        let fallback = FakeFallback()
        _ = try await renderer(backend, fallback: fallback).render(
            text: "Only paragraph here.", voiceIdentifier: alba, rate: nil, to: folder.appendingPathComponent("f.caf"))
        #expect(await backend.calls.map(\.seed) == [NaturalSpeechRenderer.seed, NaturalSpeechRenderer.seed &+ 1])
        #expect(fallback.texts == ["Only paragraph here."])
    }

    @Test func withoutARecognizerParagraphsAreNotChecked() async throws {
        let backend = FakeBackend()
        let checker = FakeChecker { _ in nil }
        let renderer = renderer(backend, checker: checker)
        var events: [NaturalSpeechEvent] = []
        renderer.onEvent = { events.append($0) }
        _ = try await renderer.render(text: text, voiceIdentifier: alba, rate: nil,
                                      to: folder.appendingPathComponent("unchecked.caf"))
        #expect(checker.calls == 1)
        #expect(events == [.checkUnavailable(language: "en")])
        #expect(await backend.calls.count == 3)
    }

    @Test func voicesMustBeOfferedAndInstalled() async throws {
        let renderer = renderer(FakeBackend(), installed: [.english])
        try renderer.checkVoice(alba)
        #expect(throws: HolosError.self) { try renderer.checkVoice("pocket:fr:estelle") }
        #expect(throws: HolosError.self) { try renderer.checkVoice("pocket:en:cosette") }
        #expect(throws: HolosError.self) { try renderer.checkVoice("com.apple.voice.premium.en-US.Ava") }
        let existing = folder.appendingPathComponent("taken.caf")
        try Data("x".utf8).write(to: existing)
        await #expect(throws: HolosError.self) {
            _ = try await renderer.render(text: "Hello.", voiceIdentifier: alba, rate: nil, to: existing)
        }
        await #expect(throws: HolosError.self) {
            _ = try await renderer.render(text: "Hello.", voiceIdentifier: alba, rate: nil,
                                          to: folder.appendingPathComponent("speech.mp3"))
        }
        #expect(try Data(contentsOf: existing) == Data("x".utf8))
    }
}

// MARK: - Install

@Suite struct NaturalVoiceModelsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pocket-\(UUID().uuidString)")

    private final class Calls: Sendable {
        let downloads = Mutex(0)
        let warmUps = Mutex(0)
    }

    private func download(_ calls: Calls, failing: (any Error)? = nil) -> NaturalVoiceModels.Download {
        { _, base, progress in
            calls.downloads.withLock { $0 += 1 }
            try FileManager.default.createDirectory(at: base.appendingPathComponent("Models"),
                                                    withIntermediateDirectories: true)
            progress(0.5)
            if let failing { throw failing }
            progress(1)
        }
    }

    private func warmUp(_ calls: Calls, failing: Bool = false) -> NaturalVoiceModels.WarmUp {
        { _, base in
            calls.warmUps.withLock { $0 += 1 }
            #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Models").path))
            if failing { throw HolosError.io("did not load") }
        }
    }

    @Test func installsDownloadsThenWarmsUpInPlaceAndMarksLast() async throws {
        let calls = Calls()
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
        let progress = Mutex<[Double]>([])
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(calls),
                                           warmUp: warmUp(calls), notice: { _ in },
                                           progress: { value in progress.withLock { $0.append(value) } })
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
        #expect(NaturalVoiceModels.installedPacks(root: root) == [.english])
        #expect(progress.withLock { $0.last } == 1)
        #expect(!FileManager.default.fileExists(atPath: NaturalVoiceModels.stagingFolder(root: root, pack: .english).path))
        // Installed: nothing is downloaded again.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(calls),
                                           warmUp: warmUp(calls), notice: { _ in }, progress: { _ in })
        #expect(calls.downloads.withLock { $0 } == 1)
        #expect(calls.warmUps.withLock { $0 } == 1)
        try NaturalVoiceModels.remove(root: root, pack: .english)
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
    }

    @Test func aFailedDownloadKeepsWhatItGotAndInstallsNothing() async throws {
        let calls = Calls()
        await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false,
                                               download: download(calls, failing: URLError(.notConnectedToInternet)),
                                               warmUp: warmUp(calls), notice: { _ in }, progress: { _ in })
        }
        #expect(NaturalVoiceModels.status(root: root, pack: .french) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: NaturalVoiceModels.stagingFolder(root: root, pack: .french).path))
        #expect(calls.warmUps.withLock { $0 } == 0)
        // The next try resumes (the staging folder is kept) and installs.
        let lines = Mutex<[String]>([])
        try await NaturalVoiceModels.setUp(root: root, pack: .french, force: false, download: download(calls),
                                           warmUp: warmUp(calls), notice: { line in lines.withLock { $0.append(line) } },
                                           progress: { _ in })
        let notices = lines.withLock { $0 }
        #expect(notices.first?.hasPrefix("Resuming") == true)
        #expect(NaturalVoiceModels.status(root: root, pack: .french) == .installed)
    }

    @Test func aCancelledDownloadIsACancellation() async throws {
        let calls = Calls()
        await #expect(throws: CancellationError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false,
                                               download: download(calls, failing: CancellationError()),
                                               warmUp: warmUp(calls), notice: { _ in }, progress: { _ in })
        }
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
    }

    @Test func aWarmUpCutOffIsRetriedInPlaceAndOneThatFailsThereDownloadsAgain() async throws {
        let calls = Calls()
        // Downloaded, but the warm-up fails: in place, not installed.
        await #expect(throws: HolosError.self) {
            try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(calls),
                                               warmUp: warmUp(calls, failing: true), notice: { _ in },
                                               progress: { _ in })
        }
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: NaturalVoiceModels.directory(root: root, pack: .english).path))
        // The next setup finds its files are the pinned commit's and warms it up where it is, without a download.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: false, download: download(calls),
                                           warmUp: warmUp(calls), verify: { _, _ in true }, notice: { _ in },
                                           progress: { _ in })
        #expect(calls.downloads.withLock { $0 } == 1)
        #expect(NaturalVoiceModels.status(root: root, pack: .english) == .installed)
        // Forced: downloaded again.
        try await NaturalVoiceModels.setUp(root: root, pack: .english, force: true, download: download(calls),
                                           warmUp: warmUp(calls), notice: { _ in }, progress: { _ in })
        #expect(calls.downloads.withLock { $0 } == 2)
    }

    @Test func theRootFollowsTheEnvironment() {
        #expect(NaturalVoiceModels.root(environment: ["HOLOS_POCKET_MODELS_DIR": "/tmp/pocket"]).path == "/tmp/pocket")
        #expect(NaturalVoiceModels.root(environment: ["HOLOS_SUPPORT_DIR": "/tmp/support"]).path
            == "/tmp/support/Models/pocket-tts")
    }
}
