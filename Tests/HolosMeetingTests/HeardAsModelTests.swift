import Foundation
import FoundationModels
import HolosCore
@testable import HolosMeeting
import Testing

/// Runs the meeting word-fix stage's question (`HeardAsJudge`) with Apple's on-device model, as the command-line tool
/// gives it (`OnDeviceFix.answerer`: permissive guardrails, greedy, a fresh session per question), on an invented
/// meeting where "Claude" is sometimes meant and "cloud" sometimes is. Off by default: it needs Apple Intelligence
/// and takes seconds. Run with `HOLOS_AIFIX_MODEL_TESTS=1 swift test --filter HeardAsModelTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_AIFIX_MODEL_TESTS"] == "1"))
struct HeardAsModelTests {
    static let model: TranscriptFixer.Model = { instructions, prompt in
        let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                                           instructions: instructions)
        return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
    }

    @Test func theTermGoesWhereTheContextCallsForIt() async throws {
        #expect(SystemLanguageModel.default.availability == .available)
        let sentences = [
            "Yesterday I asked cloud to refactor the parser and it opened a pull request.",
            "We moved the nightly backups to the cloud instead of the office server.",
            "I let clot write the migration script, then I reviewed the diff.",
            "Our cloud provider raised its prices again this quarter.",
            "Then I told cloud the tests were flaky and it rewrote the waiter.",
            "It's a public cloud deployment, so the latency is fine.",
            // Harder ones, printed for the record: only the clear ones above are checked.
            "The cloud code session fixed the failing tests and wrote the commit message.",
            "Which cloud region are the servers in?",
            "Cloud wrote most of this function, I just fixed the edge cases.",
            "Let's ask cloud to summarize the incident report for us.",
        ]
        let segments = sentences.enumerated().map { index, text in
            SessionFixtures.segment(text.split(separator: " ").map(String.init), track: "mic",
                                    start: Double(index) * 10, wordSeconds: 0.4, id: "S\(index)")
        }
        let base = SessionFixtures.transcript(segments)
        let terms = CorrectionList(entries: ["cloud", "clot", "clod"].map { Correction(heard: $0, meant: "Claude") })
        let dependencies = WordFixDependencies(corrections: { CorrectionList() }, wordList: { WordList() },
                                               model: { _ in .available(Self.model) }, timeout: .seconds(30))
        let fixed = try await WordFixStage.fix(base, title: "Weekly engineering sync", corrections: CorrectionList(),
                                               terms: terms, dependencies: dependencies)
        for segment in fixed.transcript.segments { print("word fix:", segment.text) }
        #expect(fixed.asked == sentences.count)
        let texts = fixed.transcript.segments.map(\.text)
        // Never where the cloud is meant.
        for index in [1, 3, 5, 7] { #expect(texts[index] == sentences[index]) }
        // Where a coding assistant is talked to, at least most of the time.
        #expect([0, 2, 4].filter { texts[$0].contains("Claude") }.count >= 2)
    }
}
