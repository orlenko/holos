import Foundation
import HolosCore

/// Tidy Up on Qwen3.5 9B (docs/design.md "Tidy Up"): the model in `TidyModel`'s file, through `LlamaModel`, in the
/// model's chat format with its thinking turned off.
public enum QwenTidy {
    /// Words per part: a part this long, its edit, and the instructions fit the 8,192-token context with room to spare.
    public static let partWords = 1200
    /// How long a part may take before it keeps its own text. A 250-word part took 12 s on an M6 Mac mini.
    public static let partTimeout: Duration = .seconds(300)

    /// `instructions` and `prompt` in Qwen's chat format, with the empty thinking block that turns thinking off (the
    /// model's own template writes the same when thinking is off).
    public static func chat(instructions: String, prompt: String) -> String {
        "<|im_start|>system\n\(instructions)<|im_end|>\n<|im_start|>user\n\(prompt)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// The most tokens a reply to `prompt` may take: twice the prompt's own words in tokens, and some room.
    static func maxTokens(for prompt: String) -> Int {
        let words = prompt.split(whereSeparator: \.isWhitespace).count
        return words * 3 + 256
    }

    /// The tidier on `model`.
    public static func tidier(model: LlamaModel) -> TextTidier {
        TextTidier(partWords: partWords, timeout: partTimeout) { instructions, prompt in
            try await model.generate(prompt: chat(instructions: instructions, prompt: prompt),
                                     maxTokens: maxTokens(for: prompt))
        }
    }
}
