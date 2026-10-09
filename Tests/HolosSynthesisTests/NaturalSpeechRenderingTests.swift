import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

// Natural voices: how a part is rendered (plan, check, speed, writing, re-render, fallback).

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
    @Test func whatIsHeardMatchesIgnoringCasePunctuationAndHowNumbersAreWritten() {
        let text = "The garden had 1,500 flowers. Children walked out on Sundays!"
        for heard in ["the garden had 1500 flowers children walked out on sundays",
                      "the garden had one thousand five hundred flowers children walked out on sundays"] {
            #expect(SpeechChunkCheck.evaluate(expected: text, heard: heard, language: "en").passed, "\(heard)")
        }
        let digits = "the garden had 1500 flowers children walked out on sundays"
        #expect(SpeechChunkCheck.evaluate(expected: text, heard: digits, language: "en").wordErrorRate == 0)
        #expect(SpeechChunkCheck.evaluate(expected: "Café crème", heard: "cafe creme", language: "fr").wordErrorRate == 0)
    }

    @Test func garbledOrCutOffSpeechFails() {
        let text = "Each morning he carried buckets of rainwater up the rocky path, counting his steps out of habit."
        #expect(!SpeechChunkCheck.evaluate(expected: text, heard: "each morning he carried banana phone river tock",
                                           language: "en").passed)
        // A long paragraph cut off after nine words: few edits proportionally, but more than 8 words missing.
        let long = Array(repeating: text, count: 4).joined(separator: " ")
        let cut = long.split(separator: " ").dropLast(9).joined(separator: " ")
        let verdict = SpeechChunkCheck.evaluate(expected: long, heard: cut, language: "en")
        #expect(verdict.wordErrorRate < 0.15)
        #expect(!verdict.passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "Hello there.", heard: "", language: "en").passed)
    }

    @Test func shortTextsAllowTwoEditsButNeedAWordRight() {
        #expect(SpeechChunkCheck.evaluate(expected: "The Lighthouse Keeper's Garden",
                                          heard: "the lighthouse keepers garden", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "The Lighthouse Keeper's Garden", heard: "a light house",
                                           language: "en").passed)
        // Two edits allowed, but not every word wrong.
        #expect(SpeechChunkCheck.evaluate(expected: "A Heading", heard: "a heading", language: "en").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "A Heading", heard: "the heading", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "A Heading", heard: "banana phone", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "Garden", heard: "parrot", language: "en").passed)
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
    private(set) var voices: [String?] = []

    func defaultVoice(language: String) -> String? { "com.apple.voice.premium.en-US.Ava" }

    func samples(for text: String, voice: String?, language: String, sampleRate: Double) async throws
        -> (samples: [Float], voice: String) {
        texts.append(text)
        voices.append(voice)
        return ([Float](repeating: 0.5, count: 4_800), "Ava (Premium)")
    }
}

@MainActor @Suite final class NaturalSpeechRendererTests {
    private let folder: URL
    private let alba = "pocket:en:alba"
    private let text = "A Heading\n\nThe first paragraph has six words.\n\nThe second has four."

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-natural-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

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

@Suite struct SpeechChunkCheckNumberTests {
    @Test func numbersCompareHoweverTheRecognizerWritesThem() {
        let text = "In 2015 the tower was 3.05 metres tall and had 1,500 visitors."
        for heard in ["in 2015 the tower was 3.05 metres tall and had 1500 visitors",
                      "in two thousand fifteen the tower was three point zero five metres tall and had one thousand "
                          + "five hundred visitors"] {
            #expect(SpeechChunkCheck.evaluate(expected: text, heard: heard, language: "en").passed, "\(heard)")
        }
        #expect(!SpeechChunkCheck.evaluate(
            expected: text, heard: "in 2015 the parrot sang loudly beside the river of visitors", language: "en").passed)
        let french = "En 2015, la tour mesurait 3,5 mètres et accueillait 1 500 visiteurs."
        for heard in ["en 2015 la tour mesurait 3,5 mètres et accueillait 1500 visiteurs",
                      "en deux mille quinze la tour mesurait trois virgule cinq mètres et accueillait mille cinq cents "
                          + "visiteurs"] {
            #expect(SpeechChunkCheck.evaluate(expected: french, heard: heard, language: "fr").passed, "\(heard)")
        }
    }

    @Test func aParagraphOfNumbersAloneFailsOnOtherNumbersOrNothing() {
        #expect(SpeechChunkCheck.evaluate(expected: "2015.", heard: "2015", language: "en").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "2015.", heard: "two thousand and fifteen", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "twenty", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "garbage", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "2015", heard: "", language: "en").passed)
        #expect(!SpeechChunkCheck.evaluate(expected: "50 cents", heard: "5000", language: "en").passed)
        #expect(SpeechChunkCheck.evaluate(expected: "—", heard: "", language: "en").passed)
    }
}

/// A backend whose takes can be watched as they are asked for.
private actor WatchedBackend: NaturalSpeechBackend {
    private var count = 0
    private let watch: @Sendable (Int) -> Void

    init(watch: @escaping @Sendable (Int) -> Void) { self.watch = watch }

    func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float] {
        count += 1
        watch(count)
        return [Float](repeating: 0.25, count: 24_000)
    }
}

@MainActor private final class NoFallback: ParagraphFallback {
    func defaultVoice(language: String) -> String? { nil }

    func samples(for text: String, voice: String?, language: String, sampleRate: Double) async throws
        -> (samples: [Float], voice: String) {
        throw HolosError.io("not expected")
    }
}

@MainActor @Suite struct NaturalSpeechIncrementalWriteTests {
    @Test func paragraphsAreWrittenAsTheyAreMade() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sizes = Mutex<[Int: Int64]>([:])
        let backend = WatchedBackend { take in
            // Before each paragraph is made, what the temporary file beside the output already holds.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let size = names.filter { $0.hasPrefix(".holos-") }.compactMap { name -> Int64? in
                let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                return (attributes?[.size] as? NSNumber)?.int64Value
            }.reduce(0, +)
            sizes.withLock { $0[take] = size }
        }
        let renderer = NaturalSpeechRenderer(backend: backend, checker: nil, fallback: NoFallback(),
                                             installedPacks: { [.english] })
        let output = folder.appendingPathComponent("part.caf")
        let result = try await renderer.render(text: "One.\n\nTwo.\n\nThree.", voiceIdentifier: "pocket:en:alba",
                                               rate: nil, to: output)
        // 1 s per paragraph and two 0.6 s pauses.
        #expect(abs(result.duration - 4.2) < 0.001)
        let seen = sizes.withLock { $0 }
        // Before the third paragraph, the first two (2.6 s of 16-bit samples, about 125 KB) are already on disk.
        #expect((seen[3] ?? 0) > 120_000)
        #expect((seen[2] ?? 0) > 70_000)
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasPrefix(".holos-") })
    }
}

@Suite struct NaturalSpeechPlanLongParagraphTests {
    private let sentence = "The keeper carried rainwater up the rocky path every single morning, counting his steps."

    @Test func aLongParagraphIsFedInBoundedGroupsOfWholeSentences() {
        let paragraph = Array(repeating: sentence, count: 60).joined(separator: " ")
        let blocks = NaturalSpeechPlan.blocks("Heading\n\n" + paragraph + "\n\nLast one.")
        let groups = blocks.dropFirst().dropLast()
        #expect(groups.count >= 5)
        #expect(groups.allSatisfy { $0.text.count <= NaturalSpeechPlan.maximumBlockLength })
        #expect(groups.allSatisfy { $0.text.hasSuffix("steps.") && $0.text.hasPrefix("The keeper") })
        #expect(groups.map(\.text).joined(separator: " ") == paragraph)
        // The voice's own pauses between the groups; the paragraph's after the last.
        #expect(groups.dropLast().allSatisfy { $0.pauseAfter == 0 })
        #expect(groups.last?.pauseAfter == NaturalSpeechPlan.paragraphPause)
        #expect(blocks.first?.isHeading == true)
        #expect(blocks.dropFirst().allSatisfy { !$0.isHeading })
    }

    @Test func aLongSentenceIsSplitAtClausesThenWords() {
        let clauses = Array(repeating: "and then the gulls came back over the grey stone wall", count: 40)
            .joined(separator: ", ") + "."
        let byClause = NaturalSpeechPlan.split(clauses, maximumLength: 1_000)
        #expect(byClause.count > 1)
        #expect(byClause.allSatisfy { $0.count <= 1_000 && ($0.hasSuffix(",") || $0.hasSuffix(".")) })
        #expect(byClause.joined(separator: " ") == clauses)
        let words = Array(repeating: "marigold", count: 400).joined(separator: " ")
        let byWord = NaturalSpeechPlan.split(words, maximumLength: 1_000)
        #expect(byWord.allSatisfy { $0.count <= 1_000 })
        #expect(byWord.joined(separator: " ") == words)
        let unbroken = String(repeating: "x", count: 2_500)
        #expect(NaturalSpeechPlan.split(unbroken, maximumLength: 1_000).map(\.count) == [1_000, 1_000, 500])
    }
}

/// Counts the samples each take holds (0.1 s per word, as the renderer tests' fake).
private actor CountingBackend: NaturalSpeechBackend {
    private(set) var largest = 0
    private(set) var calls = 0

    func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float] {
        calls += 1
        let samples = [Float](repeating: 0.25, count: text.split(separator: " ").count * 2_400)
        largest = max(largest, samples.count)
        return samples
    }
}

@MainActor @Suite struct NaturalSpeechLongTextTests {
    @Test func aTextWithoutBlankLinesNeverHoldsMoreThanABlocksSamples() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-long-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sentence = "The keeper carried rainwater up the rocky path every single morning, counting his steps."
        // About 20,000 characters, 3,000 words, in one paragraph.
        let text = Array(repeating: sentence, count: 220).joined(separator: " ")
        let backend = CountingBackend()
        let renderer = NaturalSpeechRenderer(backend: backend, checker: nil, fallback: NoFallback(),
                                             installedPacks: { [.english] })
        let result = try await renderer.render(text: text, voiceIdentifier: "pocket:en:alba", rate: nil,
                                               to: folder.appendingPathComponent("long.caf"))
        let words = text.split(separator: " ").count
        #expect(abs(result.duration - Double(words) * 0.1) < 0.01)
        #expect(await backend.calls >= 20)
        // No take holds more than one block: at most 1,000 characters, under 200 words.
        #expect(await backend.largest <= 200 * 2_400)
    }
}

@Suite struct NaturalVoiceTemporariesTests {
    @Test func staleFoldersOfNaturalVoicesAreSweptAndNothingElse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let old = now.addingTimeInterval(-2 * 24 * 60 * 60)
        func make(_ name: String, changed: Date, file: Bool = false) throws {
            let url = folder.appendingPathComponent(name)
            if file {
                try Data("x".utf8).write(to: url)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url.appendingPathComponent("paragraph.caf"))
            }
            try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: url.path)
        }
        try make("holos-check-A", changed: old)
        try make("holos-fallback-B", changed: old)
        try make("holos-natural-C", changed: old)
        try make("holos-preview-D", changed: old)
        try make("holos-check-recent", changed: now)
        try make("holos-say-E", changed: old)
        try make("holos-check-file", changed: old, file: true)
        let removed = NaturalVoiceTemporaries.sweep(in: folder, now: now)
        #expect(removed == ["holos-check-A", "holos-fallback-B", "holos-natural-C", "holos-preview-D"])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["holos-check-file", "holos-check-recent", "holos-say-E"])
    }
}

@Suite struct NaturalSpeechPlanCodexTests {
    @Test func blankLinesWithSpacesOrTabsSeparateParagraphs() {
        let blocks = NaturalSpeechPlan.blocks("First one.\n  \nSecond one.\n\t\nThird one.\r\n \r\nFourth.")
        #expect(blocks.map(\.text) == ["First one.", "Second one.", "Third one.", "Fourth."])
        #expect(blocks.map(\.pauseAfter) == [0.6, 0.6, 0.6, 0])
        // A single line break inside a paragraph is still a space.
        #expect(NaturalSpeechPlan.blocks("One line\nand the next.").map(\.text) == ["One line and the next."])
    }

    @Test func aLongUnbrokenTokenIsCutInOnePass() {
        let token = String(repeating: "ab", count: 100_000)
        let cuts = NaturalSpeechPlan.split(token, maximumLength: 1_000)
        #expect(cuts.count == 200)
        #expect(cuts.allSatisfy { $0.count == 1_000 })
        #expect(cuts.joined() == token)
    }
}

@MainActor @Suite struct NaturalSpeechUncheckableTests {
    /// Says no recognizer is installed, counting how often it is asked.
    private final class NoRecognizer: SpeechChunkChecker, Sendable {
        let asked = Mutex(0)
        func transcript(of samples: [Float], sampleRate: Double, language: String) async throws -> String? {
            asked.withLock { $0 += 1 }
            return nil
        }
    }

    @Test func aMissingRecognizerIsFoundAndSaidOnceForAllParts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let checker = NoRecognizer()
        let renderer = NaturalSpeechRenderer(backend: CountingBackend(), checker: checker, fallback: NoFallback(),
                                             installedPacks: { [.english] })
        var events: [NaturalSpeechEvent] = []
        renderer.onEvent = { events.append($0) }
        // A reading's parts, one renderer (as `voiceislocal read` renders them).
        for part in 1...5 {
            _ = try await renderer.render(text: "Part \(part).\n\nMore words here.", voiceIdentifier: "pocket:en:alba",
                                          rate: nil, to: folder.appendingPathComponent("part\(part).caf"))
        }
        #expect(checker.asked.withLock { $0 } == 1)
        #expect(events == [.checkUnavailable(language: "en")])
    }
}

@MainActor @Suite final class NaturalSpeechPublicationTests {
    /// Every folder a test makes is in here, removed after the test.
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-publish-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    private func folder() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aStopDuringTheCopyIntoPlaceLeavesNoOutput() async throws {
        let folder = try folder()
        let render = Mutex<Task<RenderedAudio, Error>?>(nil)
        // A volume that cannot rename exclusively (the file is copied into place), and a Stop as the copy begins.
        let renderer = NaturalSpeechRenderer(backend: CountingBackend(), checker: nil, fallback: NoFallback(),
                                             installedPacks: { [.english] }, exclusiveRename: { _, _ in
            render.withLock { $0 }?.cancel()
            errno = ENOTSUP
            return -1
        })
        let output = folder.appendingPathComponent("part.caf")
        let task = Task {
            try await renderer.render(text: "One two three.", voiceIdentifier: "pocket:en:alba", rate: nil, to: output)
        }
        render.withLock { $0 = task }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func theGroupsOfALongParagraphAreNamedByItsNumber() async throws {
        let folder = try folder()
        let sentence = "The keeper carried rainwater up the rocky path every single morning, counting his steps."
        let long = Array(repeating: sentence, count: 60).joined(separator: " ")
        let groups = NaturalSpeechPlan.blocks(long).count
        #expect(groups > 1)
        // Every take is heard wrong, so every block is read by the system voice and named in an event.
        let fallback = FakeFallback()
        let renderer = NaturalSpeechRenderer(backend: CountingBackend(), checker: FakeChecker { _ in "nothing alike" },
                                             fallback: fallback, installedPacks: { [.english] })
        var named: [Int] = []
        renderer.onEvent = { event in
            if case .fellBack(let paragraph, _, _) = event { named.append(paragraph) }
        }
        _ = try await renderer.render(text: "This opening paragraph has several plain words in it.\n\n" + long
                                          + "\n\nThis closing paragraph ends the part quite plainly.",
                                      voiceIdentifier: "pocket:en:alba", rate: nil,
                                      to: folder.appendingPathComponent("part.caf"))
        #expect(named == [1] + Array(repeating: 2, count: groups) + [3], "\(named) groups \(groups)")
        #expect(renderer.lastStats.paragraphs == 3)
    }
}

@MainActor @Suite final class NaturalRenderSettingsTests {
    /// Every folder a test makes is in here, removed after the test.
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-settings-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    private func folder() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aReadingsSavedSettingsAreUsedNotTodays() async throws {
        let fallback = FakeFallback()
        let checker = FakeChecker { _ in "nothing alike at all" }
        let renderer = NaturalSpeechRenderer(backend: CountingBackend(), checker: checker, fallback: fallback,
                                             installedPacks: { [.english] })
        #expect(renderer.settings(for: "pocket:en:alba")
            == NaturalRenderSettings(fallbackVoice: "com.apple.voice.premium.en-US.Ava", checked: true))
        // Saved when the reading started: another system voice than today's best.
        let saved = NaturalRenderSettings(fallbackVoice: "com.apple.voice.enhanced.en-GB.Daniel", checked: true)
        #expect(NaturalRenderSettings(values: saved.values) == saved)
        _ = try await renderer.render(text: "This paragraph has plenty of words in it.", voiceIdentifier: "pocket:en:alba",
                                      rate: nil, settings: saved, to: try folder().appendingPathComponent("a.caf"))
        #expect(fallback.voices == ["com.apple.voice.enhanced.en-GB.Daniel"])
        // Saved with the check off: no paragraph is heard back, whatever the renderer would do today.
        let unchecked = NaturalRenderSettings(fallbackVoice: nil, checked: false)
        #expect(NaturalRenderSettings(values: unchecked.values) == unchecked)
        _ = try await renderer.render(text: "Another paragraph with words.", voiceIdentifier: "pocket:en:alba",
                                      rate: nil, settings: unchecked, to: try folder().appendingPathComponent("b.caf"))
        #expect(checker.calls == 2)
        #expect(fallback.texts.count == 1)
    }

    @Test func aReadingThatSavedTheCheckOnIsCheckedWhenTodaysDefaultIsOff() async throws {
        let checker = FakeChecker { _ in "a paragraph of a reading begun before" }
        // HOLOS_NATURAL_CHECK=0 today: a new rendering is not checked.
        let renderer = NaturalSpeechRenderer(backend: CountingBackend(), checker: checker, checksByDefault: false,
                                             fallback: FakeFallback(), installedPacks: { [.english] })
        #expect(renderer.settings(for: "pocket:en:alba")?.checked == false)
        _ = try await renderer.render(text: "A paragraph rendered today.", voiceIdentifier: "pocket:en:alba", rate: nil,
                                      to: try folder().appendingPathComponent("a.caf"))
        #expect(checker.calls == 0)
        // A reading that started with the check on keeps it.
        _ = try await renderer.render(text: "A paragraph of a reading begun before.", voiceIdentifier: "pocket:en:alba",
                                      rate: nil, settings: NaturalRenderSettings(fallbackVoice: nil, checked: true),
                                      to: try folder().appendingPathComponent("b.caf"))
        #expect(checker.calls == 1)
    }
}
