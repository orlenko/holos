import Foundation
import FoundationModels
import Testing
@testable import HolosCore

/// Runs Apple's on-device model the way dictation does (`DictationFixPipeline.make`), on sentences where it once
/// swapped a taught spelling into unrelated words. Off by default: it needs Apple Intelligence and takes seconds.
/// Run with `HOLOS_AIFIX_MODEL_TESTS=1 swift test --filter AIFixModelTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_AIFIX_MODEL_TESTS"] == "1"))
struct AIFixModelTests {
    let fixer: TranscriptFixer = {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return TranscriptFixer(corrections: CorrectionList(entries: taughtList), referenceBudget: model.contextSize / 4,
                               timeout: .seconds(30)) { instructions, prompt in
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
        }
    }()

    @Test(arguments: [
        "Let's develop it on a Windows machine first.",
        "I tested this on Windows and then pushed it to the develop branch.",
        "We should develop a plan for the windows laptop.",
    ])
    func unrelatedWordsStay(_ text: String) async {
        #expect(SystemLanguageModel.default.availability == .available)
        let result = await fixer.fix(text, isFinal: true)
        #expect(result.outcome != .failed)
        #expect(!result.text.localizedCaseInsensitiveContains("ubuntu"), "\(result)")
    }

    @Test func aTaughtMishearingIsFixed() async {
        let result = await fixer.fix("The build runs Onobunto.", isFinal: true)
        #expect(result == .init(text: "The build runs on Ubuntu.", outcome: .fixed))
    }
}
