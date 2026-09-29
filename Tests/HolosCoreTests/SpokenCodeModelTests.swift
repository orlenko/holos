import Foundation
import FoundationModels
import Testing
@testable import HolosCore

/// Runs Apple's on-device model the way dictation does (`OnDeviceFix.spokenCode`) on the sentences that asked for
/// spoken code. Off by default: it needs Apple Intelligence and takes seconds. Run with
/// `HOLOS_AIFIX_MODEL_TESTS=1 swift test --filter SpokenCodeModelTests`; the probe prints each sentence's result.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_AIFIX_MODEL_TESTS"] == "1"), .serialized)
struct SpokenCodeModelTests {
    let formatter: SpokenCodeFormatter = {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return SpokenCodeFormatter(backticks: true, language: "en-US", timeout: .seconds(30)) { instructions, prompt in
            let session = LanguageModelSession(model: model, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content
        }
    }()

    @Test(arguments: [
        ("So in my dot ZHRC file, there's a command that exports the path variable and adds dot local slash bin into it.",
         "So in my `.zshrc` file, there's a command that exports the path variable and adds `.local/bin` into it."),
        ("I ran the script dot slash scripts slash restart dash app dot S. H.",
         "I ran the script `./scripts/restart-app.sh`"),
        ("Execute slash Q. C.", "Execute `/qc`"),
    ])
    func theUsersSentences(_ text: String, _ expected: String) async {
        #expect(SystemLanguageModel.default.availability == .available)
        let result = await formatter.format(text)
        // The model may keep or drop the letters' last period; nothing else may differ.
        #expect(result.text == expected || result.text == expected + ".", "\(result)")
    }

    @Test(arguments: [
        "We need to slash the price and dot every line before the dash to the finish.",
        "He made a dash for the door and said period, end of story.",
        "Let's slash the budget by half.",
    ])
    func proseStays(_ text: String) async {
        let result = await formatter.format(text)
        #expect(result.text == text, "\(result)")
    }

    /// Prints what the model and the verifier make of sentences with paths, commands, options, an address, and
    /// prose that uses "slash", "dot" and "dash" as words.
    @Test func probe() async {
        let sentences = [
            "So in my dot ZHRC file, there's a command that exports the path variable and adds dot local slash bin into it.",
            "I ran the script scripts slash restart dash app dot es aytch and it worked.",
            "When I say slash Q C, I mean the review command.",
            "Run the tests with dash dash no dash parallel so they finish.",
            "Send it to vlad at example dot com please.",
            "We need to slash the price and dot every line before the dash to the finish.",
            "Open the file source slash holos core slash transcript fixer dot swift.",
            "The config lives in tilde slash dot config slash ghostty slash config.",
            "Use git push dash U origin main.",
            "Set the variable H O L O S underscore A I F I X underscore MODEL underscore TESTS equals one.",
            "He made a dash for the door and said period, end of story.",
            "Check the README dot MD file in the docs folder.",
            "Edit package dot swift and then run swift build.",
            "The logs are in slash var slash log slash system dot log.",
            "Please don't slash the tires or dash my hopes.",
            "Type slash help to see the commands.",
        ]
        for sentence in sentences {
            let started = ContinuousClock.now
            let result = await formatter.format(sentence)
            print("PROBE IN : \(sentence)")
            print("PROBE OUT: \(result.text) [\(result.outcome.rawValue), \(result.spans) spans, \(started.duration(to: .now))]")
        }
    }
}
