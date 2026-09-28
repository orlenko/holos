import Foundation
import Testing
import HolosAudio
import HolosCore
import HolosSpeech
import HolosStorage
import HolosSynthesis
@testable import HolosDictation

// Run Again on real speech (docs/design.md "Dictation audio and Run Again"): a sentence rendered by the system speech
// synthesizer (AVSpeechSynthesizer) goes through the dictation audio writer, as the microphone's frames do, and is then
// recognized again from the saved file and compared. Skipped, with a note, when the en-US speech model or an en-US
// voice is not installed; no microphone is used.

private let rerunLocale = ProcessInfo.processInfo.environment["HOLOS_RERUN_TEST_LOCALE"] ?? "en-US"
private let sentence = "I left my laptop on the kitchen table this morning."

@MainActor
private func synthesizedDictation(in folder: URL, store: DictationHistoryStore, id: UUID) async throws
    -> DictationHistoryStore.FinishedAudio? {
    guard let voice = NativeSpeechRenderer.systemVoiceIdentifier(language: rerunLocale) else { return nil }
    let rendered = folder.appendingPathComponent("sentence.caf")
    _ = try await NativeSpeechRenderer().render(text: sentence, voiceIdentifier: voice, to: rendered)
    let writer = DictationAudioWriter(store: store, id: id)
    for frame in try DictationAudioFile.frames(of: rendered) { writer.append(frame) }
    return writer.finish()
}

@Test(.timeLimit(.minutes(3))) @MainActor
func runAgainRecognizesASavedDictationAndNamesTheNewCorrection() async throws {
    let status: String
    do {
        status = try await AppleSpeechEngine.assetStatus(locale: rerunLocale, backend: .speech)
    } catch {
        status = "error: \(error.localizedDescription)"
    }
    guard status == "installed" else {
        print("Skipped: the \(rerunLocale) speech model is not installed (\(status); "
            + "voiceislocal setup --locale \(rerunLocale)).")
        return
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-rerun-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DictationHistoryStore(directory: root.appendingPathComponent("History"))
    let id = UUID()
    guard let finished = try await synthesizedDictation(in: root, store: store, id: id) else {
        print("Skipped: no \(rerunLocale) voice is installed.")
        return
    }
    #expect(finished.seconds > 1)

    // The recognizer hears the sentence in the saved audio.
    let heard = DictationTextPipeline.transcript(
        try await DictationRerun.recognize(finished.partial, locale: rerunLocale, vocabulary: []))
    #expect(WordDiff.changedWordCount(from: sentence, to: heard) <= 2, "Heard: \(heard)")

    // Kept in History as heard then, with a word misheard; a correction was learned since.
    let record = try store.append(
        DictationRecord(id: id, date: Date(), app: "Notes", language: rerunLocale,
                        text: "I left my lap top on the kitchen table this morning.",
                        heard: "I left my lap top on the kitchen table this morning.",
                        outcome: .init(kind: .inserted), seconds: finished.seconds),
        audio: finished)
    #expect(record.audio != nil)
    let corrections = CorrectionList(entries: [Correction(heard: "laptop", meant: "MacBook")])
    let (pipeline, note) = DictationRerun.pipeline(language: rerunLocale, removeFillers: true,
                                                   corrections: corrections, aiFix: false)
    #expect(note == nil)
    let report = try await DictationRerun.run(record, audio: store.audioURL(for: id), pipeline: pipeline)
    #expect(report.written.now.contains("MacBook"), "Written now: \(report.written.now)")
    #expect(report.changed)
    #expect(report.changedBy.contains(.recognizer))
    #expect(report.changedBy.contains(.corrections))
    #expect(report.steps.first { $0.step == .corrections }?.changes.contains { $0.to == "MacBook" } == true)
    #expect(report.steps.first { $0.step == .aiFix }?.enabled == false)

    // Update History keeps the new text and the audio.
    let updated = DictationRerun.updated(record, with: report)
    #expect(updated.text == report.written.now)
    #expect(updated.heard == report.heard.now)
    #expect(updated.audio == record.audio)
    #expect(updated.fixes.corrections == 1)
    #expect(updated.id == record.id && updated.date == record.date)
}

@Test func preferencesReadTheAppSettingsWithItsDefaults() throws {
    let suite = "holos-rerun-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DictationPreferences.saved(in: defaults) == .init(language: nil, removeFillers: true, aiFix: false))
    defaults.set("fr-CA", forKey: DictationPreferences.languageKey)
    defaults.set(false, forKey: DictationPreferences.removeFillersKey)
    defaults.set(true, forKey: DictationPreferences.aiFixKey)
    #expect(DictationPreferences.saved(in: defaults) == .init(language: "fr-CA", removeFillers: false, aiFix: true))
    #expect(DictationPreferences.saved(in: nil) == .init(language: nil, removeFillers: true, aiFix: false))
}
