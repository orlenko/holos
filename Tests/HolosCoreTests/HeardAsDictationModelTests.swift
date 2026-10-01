import Foundation
import FoundationModels
import Testing
@testable import HolosCore

/// Dictation's fix with the word list's "often heard as" pairs, with Apple's on-device model as dictation runs it
/// (`OnDeviceFix.fixer`). Off by default: it needs Apple Intelligence and takes seconds. Run with
/// `HOLOS_AIFIX_MODEL_TESTS=1 swift test --filter HeardAsDictationModelTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_AIFIX_MODEL_TESTS"] == "1"))
struct HeardAsDictationModelTests {
    let fixer: TranscriptFixer = {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return TranscriptFixer(corrections: CorrectionList(), wordList: ["Claude"],
                               heardAs: ["cloud", "clot"].map { Correction(heard: $0, meant: "Claude") },
                               referenceBudget: model.contextSize / 4, timeout: .seconds(30)) { instructions, prompt in
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
        }
    }()

    @Test(arguments: [
        "We moved the nightly backups to the cloud instead of the office server.",
        "Our cloud provider raised its prices again this quarter.",
        "It's a public cloud deployment, so the latency is fine.",
    ])
    func theCloudStays(_ text: String) async {
        let result = await fixer.fix(text, isFinal: true)
        print("dictation fix:", result.outcome.rawValue, result.text)
        #expect(!result.text.contains("Claude"), "\(result)")
    }

    @Test(arguments: [
        "Yesterday I asked cloud to refactor the parser and it opened a pull request.",
        "Then I told cloud the tests were flaky and it rewrote the waiter.",
    ])
    func theTermMayStand(_ text: String) async {
        let result = await fixer.fix(text, isFinal: true)
        print("dictation fix:", result.outcome.rawValue, result.text)
        #expect(result.outcome != .failed)
    }
}
