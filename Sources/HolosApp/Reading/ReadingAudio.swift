import AVFoundation
import AppKit
import HolosCore
import HolosSynthesis

/// ▶ Preview: speaks a short sample with a voice and speed; a second press stops it.
@MainActor
final class VoicePreview: NSObject, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    /// Called when speaking starts or ends.
    var onChange: (() -> Void)?

    var isSpeaking: Bool { synthesizer != nil }

    /// Speaks the sample in `voiceIdentifier`'s language (nil: the best voice for the user's first language).
    func speak(voiceIdentifier: String?, speed: Double) {
        stop()
        let identifier = voiceIdentifier
            ?? NativeSpeechRenderer.bestVoice(language: Locale.preferredLanguages.first ?? "en-US")?.id
        let voice = identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        let utterance = AVSpeechUtterance(string: Self.sample(language: voice?.language ?? "en"))
        utterance.voice = voice
        if let rate = ReadingSpeed.rate(for: speed) { utterance.rate = rate }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        synthesizer.speak(utterance)
        onChange?()
    }

    func stop() {
        guard let synthesizer else { return }
        self.synthesizer = nil
        // Kept until its didCancel (or didFinish) arrives: it is never freed while it may still call back.
        stopping[ObjectIdentifier(synthesizer)] = synthesizer
        synthesizer.stopSpeaking(at: .immediate)
        onChange?()
    }

    private var stopping: [ObjectIdentifier: AVSpeechSynthesizer] = [:]

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = ObjectIdentifier(synthesizer)
        Task { @MainActor in self.ended(finished) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let finished = ObjectIdentifier(synthesizer)
        Task { @MainActor in self.ended(finished) }
    }

    /// The synthesizer is kept until its own last callback; a newer preview is left alone.
    private func ended(_ finished: ObjectIdentifier) {
        stopping[finished] = nil
        guard let synthesizer, ObjectIdentifier(synthesizer) == finished else { return }
        self.synthesizer = nil
        onChange?()
    }

    /// A sentence in the voice's language (English for the others).
    static func sample(language: String) -> String {
        let samples = [
            "en": "This is how your reading will sound. Articles and documents become one audio file you can take anywhere.",
            "fr": "Voici comment votre lecture sonnera. Articles et documents deviennent un seul fichier audio à emporter partout.",
            "de": "So klingt Ihre Lesung. Artikel und Dokumente werden zu einer Audiodatei, die Sie überallhin mitnehmen können.",
            "es": "Así sonará tu lectura. Los artículos y documentos se convierten en un archivo de audio que puedes llevar a todas partes.",
            "it": "Ecco come suonerà la tua lettura. Articoli e documenti diventano un unico file audio da portare ovunque.",
            "pt": "É assim que a sua leitura vai soar. Artigos e documentos tornam-se um único arquivo de áudio para levar a qualquer lugar.",
            "nl": "Zo klinkt je voorleesbestand. Artikelen en documenten worden één audiobestand dat je overal mee naartoe neemt.",
        ]
        let code = Locale.Language(identifier: language).languageCode?.identifier.lowercased() ?? "en"
        return samples[code] ?? samples["en"]!
    }
}
