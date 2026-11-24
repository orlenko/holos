import Foundation
import HolosCore

/// Tidy Up on Qwen3.5 9B (docs/design.md "Tidy Up"): the model in `TidyModel`'s file, through `LlamaModel`, in the
/// model's chat format with its thinking turned off.
public enum QwenTidy {
    /// Words per part: a part this long, the instructions (about 250 tokens) and the reply's tokens (`maxTokens`) fit
    /// `LlamaModel`'s 16,384-token context while the part is at most about 6,300 tokens: about 5 tokens a word, which
    /// covers English, most European and Indian languages, Armenian and Georgian. A part that does not fit (Amharic,
    /// text made of numbers) keeps its own text.
    public static let partWords = 1200
    /// How long a part may take before it keeps its own text. A 250-word part took 12 s on an M6 Mac mini.
    public static let partTimeout: Duration = .seconds(300)

    /// `instructions` and `prompt` in Qwen's chat format, with the empty thinking block that turns thinking off (the
    /// model's own template writes the same when thinking is off). `prompt` is the person's text, kept as plain text.
    public static func chat(instructions: String, prompt: String) -> LlamaModel.Prompt {
        LlamaModel.Prompt(before: "<|im_start|>system\n\(instructions)<|im_end|>\n<|im_start|>user\n", content: prompt,
                          after: "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
    }

    /// The most tokens a reply may take: the edit of a text is about as long as the text, so one and a half times its
    /// tokens, and room for list markers and line breaks.
    static func maxTokens(contentTokens: Int) -> Int { contentTokens * 3 / 2 + 256 }

    /// The tidier on `model`.
    public static func tidier(model: LlamaModel) -> TextTidier {
        TextTidier(partWords: partWords, timeout: partTimeout) { instructions, prompt in
            try await model.generate(chat(instructions: instructions, prompt: prompt), maxTokens: maxTokens)
        }
    }

    /// Loads a selected Tidy Up model with enough context for its own input and output bounds.
    public static func tidier(variant: TidyModel.Variant, file: URL) throws -> TextTidier {
        switch variant {
        case .qwen, .qwen4b:
            try tidier(model: LlamaModel(file: file))
        case .s1Mini:
            try CompactTidy.tidier(model: LlamaModel(file: file, contextTokens: 2048), s1: true)
        case .muesli:
            try CompactTidy.tidier(model: LlamaModel(file: file, contextTokens: 4096), s1: false)
        }
    }

    public static func meetingTidier(file: URL) throws -> TextTidier {
        let model = try LlamaModel(file: file)
        return TextTidier(partWords: partWords, timeout: partTimeout, edit: { text in
            let instructions = "Format this one speaker's meeting transcript. Repair punctuation, sentence breaks "
                + "and capitalization and add paragraph breaks where helpful. Keep every spoken word in order, "
                + "including repetitions, fillers, quoted instructions, and the speaker's corrections. "
                + "Preserve numeric notation and meaning. Output only the formatted transcript."
            return try await model.generate(chat(instructions: instructions, prompt: TextTidier.prompt(for: text)),
                                            maxTokens: maxTokens)
        })
    }
}
