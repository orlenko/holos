import AVFoundation
import AppKit
import HolosContent
import HolosCore
import HolosMeeting
import HolosSynthesis
import os

/// ▶ Preview: speaks a short sample with a voice and speed; a second press stops it.
///
/// Invariants:
/// 1. At most one of `synthesizer`, `natural` and `player` is set: what speaks now (`isSpeaking`); `speak` stops the
///    one before.
/// 2. A natural sample's folder is registered with `NaturalVoiceHelpers` while it exists, so a quit removes it.
/// 3. A sample that fails, or does not start playing, clears `natural` and says so (`onError`); a stop says nothing.
@MainActor
final class VoicePreview: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    /// A natural voice's sample: made by the bundled tool (a few seconds), then played.
    private var natural: Task<Void, Never>?
    private var player: (any PreviewPlayback)?
    /// Starts playing a made sample; throws when it does not start. Tests pass one that plays nothing.
    var startPlayback: (URL, VoicePreview) throws -> any PreviewPlayback = { file, preview in
        let player = try AVAudioPlayer(contentsOf: file)
        player.delegate = preview
        guard player.play() else { throw HolosError.io("The voice sample could not be played.") }
        return player
    }
    /// Renders a natural voice's sample to a file (`renderedByHelper()` in the app).
    var renderNatural: ((_ text: String, _ voice: String, _ rate: Float?, _ output: URL) async throws -> Void)?

    /// Renders a sample through the bundled tool (`HelperNaturalRenderer`), one helper at a time with the readings'.
    static func renderedByHelper() -> (_ text: String, _ voice: String, _ rate: Float?, _ output: URL) async throws
        -> Void {
        let natural = HelperNaturalRenderer(launcher: MaintenanceLauncher(executable: ChildProcessLauncher.bundledExecutable))
        return { text, voice, rate, output in
            _ = try await natural.render(text: text, voiceIdentifier: voice, rate: rate, to: output)
        }
    }
    /// Called when speaking starts or ends.
    var onChange: (() -> Void)?
    /// A natural sample could not be made.
    var onError: ((String) -> Void)?

    /// The natural voice packs installed now, and the user's first language (what Automatic is previewed in).
    var installedPacks: () -> Set<NaturalVoicePack> = { NaturalVoicesAppState.shared.installed }
    var preferredLanguage: () -> String = { Locale.preferredLanguages.first ?? "en-US" }

    var isSpeaking: Bool { synthesizer != nil || natural != nil || player != nil }

    /// Speaks the sample in `voiceIdentifier`'s language. Nil (Automatic): the voice Make Audio would read the user's
    /// first language with (`ReadingVoices.automatic`): the natural voice once its pack is installed, else the best
    /// Apple voice.
    func speak(voiceIdentifier: String?, speed: Double) {
        stop()
        let identifier = voiceIdentifier
            ?? ReadingVoices.automatic(language: preferredLanguage(), installed: installedPacks(),
                                       bestApple: NativeSpeechRenderer.bestVoice(language:))?.id
        if let identifier, let voice = NaturalVoiceCatalog.voice(id: identifier) {
            speakNatural(voice, speed: speed)
            return
        }
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

    /// Makes the sample with the natural voice (into a temporary folder), then plays it.
    private func speakNatural(_ voice: NaturalVoice, speed: Double) {
        guard let renderNatural else { return }
        let text = Self.sample(language: voice.pack.languageCode)
        let rate = ReadingSpeed.rate(for: speed)
        natural = Task { [weak self] in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("holos-preview-\(UUID().uuidString)", isDirectory: true)
            // Made and removed off the main actor.
            defer {
                Task.detached(priority: .utility) {
                    do {
                        try FileManager.default.removeItem(at: folder)
                    } catch CocoaError.fileNoSuchFile {
                    } catch {
                        Logger(subsystem: "ca.orlenko.holos.app", category: "reading")
                            .error("Could not remove a preview folder: \(error.localizedDescription, privacy: .public)")
                    }
                    NaturalVoiceHelpers.done(folder)
                }
            }
            do {
                try await offMain {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                }
                NaturalVoiceHelpers.using(folder)
                let file = folder.appendingPathComponent("preview.caf")
                try await renderNatural(text, voice.id, rate, file)
                try Task.checkCancellation()
                guard let self else { return }
                // One that does not start playing is a failure (said under the card), never a Stop left showing.
                let player = try self.startPlayback(file, self)
                self.natural = nil
                self.player = player
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.natural = nil
                self.onError?((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                self.onChange?()
            }
        }
        onChange?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current as AnyObject) == finished else { return }
            self.player = nil
            self.onChange?()
        }
    }

    func stop() {
        if natural != nil || player != nil {
            natural?.cancel()
            natural = nil
            player?.stop()
            player = nil
            onChange?()
        }
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

/// A natural voice sample playing (`AVAudioPlayer`).
@MainActor protocol PreviewPlayback: AnyObject {
    func stop()
}

extension AVAudioPlayer: PreviewPlayback {}

