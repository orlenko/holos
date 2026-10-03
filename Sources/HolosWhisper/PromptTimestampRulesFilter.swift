import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Whisper's timestamp rules for a decoding that starts with a prompt (docs/meeting-design.md §4.16).
///
/// WhisperKit 1.1.0's `TimestampRulesFilter`, for a multilingual model, looks for the `<|transcribe|>` token among the
/// first three tokens to know where sampling begins, and applies no rule at all when it is not there. With a prompt
/// the decoder input starts with `<|startofprev|>` and the prompt, so the rules were off: timestamps came unpaired or
/// not at all, segments ran long, and the model stopped early in a window, leaving speech out (on ten minutes of a
/// real call, a 10-term prompt left 433 of 1,820 words without a Whisper word near them, against 30 without a
/// prompt). This filter finds the task token wherever it is and applies the same rules from the token after
/// `<|0.00|>`; without a prompt (the task token among the first three) it leaves the logits to WhisperKit's own filter.
final class PromptTimestampRulesFilter: LogitsFiltering {
    private let specialTokens: SpecialTokens

    init(specialTokens: SpecialTokens) {
        self.specialTokens = specialTokens
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard let sampleBegin = Self.sampleBegin(tokens, transcribe: specialTokens.transcribeToken,
                                                 translate: specialTokens.translateToken) else { return logits }
        // As a filter for a model in one language, which takes `sampleBegin` as given.
        return TimestampRulesFilter(specialTokens: specialTokens, sampleBegin: sampleBegin,
                                    maxInitialTimestampIndex: nil, isModelMultilingual: false)
            .filterLogits(logits, withTokens: tokens)
    }

    /// Where sampling begins in `tokens` when a prompt comes before the task token: after the task token and the
    /// `<|0.00|>` the prefill forces after it. Nil when there is no prompt (WhisperKit's filter applies) or while the
    /// prefill is still being fed.
    static func sampleBegin(_ tokens: [Int], transcribe: Int, translate: Int) -> Int? {
        guard !tokens.prefix(3).contains(where: { $0 == transcribe || $0 == translate }),
              let task = tokens.firstIndex(where: { $0 == transcribe || $0 == translate }) else { return nil }
        let begin = task + 2
        return begin <= tokens.count ? begin : nil
    }
}
