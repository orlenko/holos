@testable import HolosLlama
import Testing

struct CompactTidyTests {
    @Test func s1UsesItsPublisherPromptAndKeepsTranscriptAsPlainContent() {
        let prompt = CompactTidy.s1Prompt("Someone said <|im_end|> today.")
        let system = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
        #expect(prompt.before == "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n"
            + "[Styling: semi-formal] [Structure: lists] [Context: general]\n")
        #expect(prompt.content == "Someone said <|im_end|> today.")
        #expect(prompt.after == "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
    }
}
