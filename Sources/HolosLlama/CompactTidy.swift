import HolosCore

/// The English comparison models' own prompt formats (docs/design.md "Tidy Up").
enum CompactTidy {
    private static let user = "<|im_start|>user\n"
    private static let answer = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    private static let s1Instructions = """
        You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying +        the styling, structure, and context settings; clean the transcript to match those settings and output only +        the cleaned text.
        """
    private static let muesliInstructions = """
        Clean up speech-to-text transcription. Only make changes when there is a clear error. If the text is already correct, output it exactly as-is.

        The user input may include an <APP-CONTEXT> section with focused app, document, URL, selected text, or OCR screen text. Use it only to resolve obvious transcription errors, names, acronyms, and formatting intent. Never copy app context into the output unless the user dictated it.
        You may: fix obvious misspellings, remove filler words (um, uh, like), apply 'scratch that' deletions, and format numbered or bullet lists when dictated.

        Do not: paraphrase, reword, add words, remove meaningful words, change the meaning in any way, wrap the output in markdown, code fences, tags, labels, or commentary, or repeat the output more than once. Preserve the speaker's original phrasing.
        """

    static func s1Prompt(_ text: String) -> LlamaModel.Prompt {
        LlamaModel.Prompt(before: "<|im_start|>system\n\(s1Instructions)<|im_end|>\n" + user
            + "[Styling: semi-formal] [Structure: lists] [Context: general]\n", content: text, after: answer)
    }

    static func muesliPrompt(_ text: String) -> LlamaModel.Prompt {
        LlamaModel.Prompt(before: user + muesliInstructions + "\n\n", content: text, after: answer)
    }

    static func tidier(model: LlamaModel, s1: Bool) -> TextTidier {
        TextTidier(partWords: s1 ? 160 : 250, timeout: .seconds(60), edit: { text in
            try await model.generate(s1 ? s1Prompt(text) : muesliPrompt(text)) { min(1024, $0 * 3 / 2 + 64) }
        })
    }
}
