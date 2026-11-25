import ArgumentParser
import Foundation
import HolosCore
import HolosDictation
import HolosDiarization
import HolosMeeting
import HolosPocket
import HolosStorage
import HolosWhisper

struct AccurateDictation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recognize a completed dictation using an installed local model.")
    @Argument(help: "Private 16 kHz mono dictation audio.") var audio: String
    @Option(help: "Private recognition settings file.") var request: String

    func run() async throws {
        let settings = try AtomicFile.readJSON(AccurateDictationCommand.Request.self, from: fileURL(request),
                                               maxBytes: 256 << 10)
        let filter = FluidAudioLogFilter.install(on: STDERR_FILENO)
        defer { filter?.finish() }
        do {
            try await recognize(settings)
        } catch let code as ExitCode {
            Console.error(AccurateDictationCommand.Failure.message(code: code.rawValue, model: settings.model))
            throw code
        } catch {
            Console.error(AccurateDictationCommand.Failure.message(code: 1, model: settings.model))
            throw ExitCode.failure
        }
    }

    private func recognize(_ settings: AccurateDictationCommand.Request) async throws {
        let engine: any DeepTranscriber
        let prompt: String
        switch settings.model {
        case .whisper:
            // The pinned WhisperKit retries a malformed local tokenizer against its Hub endpoint even with
            // model downloads disabled. Confine that fallback to an unreadable file URL in this helper process.
            guard setenv("HF_ENDPOINT", "file:///dev/null", 1) == 0,
                  ProcessInfo.processInfo.environment["HF_ENDPOINT"] == "file:///dev/null" else { throw ExitCode.failure }
            do { engine = try await WhisperKitTranscriber.load(decodeEntireRecording: true) }
            catch { throw ExitCode(AccurateDictationCommand.Failure.modelUnavailable.rawValue) }
            prompt = try await DeepTranscriptionPrompt.build(meetingName: nil,
                candidates: RecognizerVocabulary.merged([settings.vocabulary]), tokenCount: engine.promptTokenCount).text
        case .parakeet:
            guard ParakeetTranscriber.supports(locale: settings.locale) else {
                throw ExitCode(AccurateDictationCommand.Failure.unsupportedLanguage.rawValue)
            }
            do { engine = try ParakeetTranscriber.load() }
            catch { throw ExitCode(AccurateDictationCommand.Failure.modelUnavailable.rawValue) }
            prompt = ""
        }
        try Console.json(await AccurateDictationCommand.run(audio: fileURL(audio), request: settings,
                                                             transcriber: engine, prompt: prompt) { samples in
            DeepAudio.quietestCut(samples, searchFrom: samples.count - 3 * DeepAudio.sampleRate)
        })
    }
}
