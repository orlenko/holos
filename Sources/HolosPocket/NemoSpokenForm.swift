import FluidAudio
import HolosSynthesis

/// `SpokenForm`'s second stage in the tool: NVIDIA NeMo's rule-based text normalizer (compiled grammars, no model),
/// bundled with FluidAudio. It writes numbers, dates, times, money and common units out in words, in English and
/// French; other languages, and text it declines, come back unchanged.
public struct NemoSpokenForm: SpokenFormNormalizer {
    public init() {}

    public func normalize(_ text: String, language: String) -> String {
        switch language.lowercased().prefix(2) {
        case "en": NemoTextNormalizer.normalize(text, language: .english)
        case "fr": NemoTextNormalizer.normalize(text, language: .french)
        default: text
        }
    }
}
