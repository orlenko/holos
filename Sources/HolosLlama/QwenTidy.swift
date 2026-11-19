import Foundation
import HolosCore

/// Tidy Up on Qwen3.5 9B (docs/design.md "Tidy Up"): the model in `TidyModel`'s file, through `LlamaModel`, in the
/// model's chat format with its thinking turned off.
public enum QwenTidy {
    /// Words per part: a part this long, the instructions and the reply's tokens (`maxTokens`) fit the 8,192-token
    /// context, for English, other languages written with spaces, and text full of numbers.
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
}
