import Foundation
import FoundationModels
import HolosCore
import NaturalLanguage

/// Tidy Up on Apple's on-device model (docs/design.md "Tidy Up"): the model `OnDeviceFix` uses, a fresh session per
/// part, greedy sampling.
public enum OnDeviceTidy {
    /// Words per part. The model's context is 8,192 tokens on macOS 27; the instructions, a part this long and its edit
    /// take about half of it.
    public static let partWords = 600
    /// How long a part may take before it keeps its own text. Parts of 600 words took 5–10 s on an M-series Mac.
    public static let partTimeout: Duration = .seconds(60)

    /// Nil when Apple's model can tidy `text`; otherwise why not. Only English and French text, as for the fix
    /// (`OnDeviceFix.unavailableReason(language:)`).
    public static func unavailableReason(for text: String) -> String? {
        if let reason = OnDeviceFix.unavailableReason { return reason }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return OnDeviceFix.unavailableReason(language: language.rawValue)
    }

    /// The tidier on Apple's model.
    public static func tidier() -> TextTidier {
        TextTidier(partWords: partWords, timeout: partTimeout) { instructions, prompt in
            let session = LanguageModelSession(model: OnDeviceFix.model, instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(temperature: 0)).content
        }
    }
}
