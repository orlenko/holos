import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Stage 7 of the post-processor (docs/meeting-design.md §4.7, §4.10): with "Remember voices" on and some person's
/// voice samples to compare, `SpeakerRecognizer` matches the new run's speakers using the run's in-memory voice data,
/// and only the distances are saved (`speakers/recognition/<runID>.json`). The voice data itself is never written
/// here; it is dropped when post-processing ends.
enum RecognizeStage {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "profiles")

    static let rememberOff = "Remember voices is off."
    static let noVoices = "No saved voices to compare."
    static let nothingToCompare = "No labelled speaker to compare."

    enum Outcome: Equatable {
        /// An expected skip: it never makes the record `partial`.
        case skipped(String)
        case recognized(RecognitionResult)
        case failed(String)
    }

    /// Runs the stage for the run stage 6 just published. Writes the recognition result under the speaker lock.
    static func run(_ run: DiarizationRun, voiceData: SessionVoiceData?, session: URL,
                    store: SpeakerProfileStore) -> Outcome {
        let database: SpeakerProfileDatabase
        do {
            database = try store.load()
        } catch {
            log.error("Cannot read the saved voices: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return .failed("Cannot read the saved voices: \(error.localizedDescription)")
        }
        guard database.rememberVoices else { return .skipped(rememberOff) }
        guard database.profiles.contains(where: { $0.recognitionEnabled && !$0.samples.isEmpty }) else {
            return .skipped(noVoices)
        }
        guard let result = SpeakerRecognizer.recognize(run: run, voiceData: voiceData, database: database) else {
            return .skipped(nothingToCompare)
        }
        do {
            try SessionArchive.withSpeakerLock(at: session) {
                try SessionSpeakerStore.writeRecognition(result, session: session)
            }
        } catch {
            log.error("Cannot save the voice comparison: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return .failed("Cannot save the voice comparison: \(error.localizedDescription)")
        }
        log.info("Run \(run.id, privacy: .public): \(result.matches.count, privacy: .public) voice suggestions, \(result.skippedProfiles.count, privacy: .public) people skipped (other model)")
        return .recognized(result)
    }

    /// "1 name suggested." / "3 names suggested." / "No voices matched."
    static func message(_ result: RecognitionResult) -> String {
        let count = result.matches.count
        guard count > 0 else { return "No voices matched." }
        let automatic = result.matches.filter { $0.tier == .likely }.count
        let suggested = count - automatic
        var parts: [String] = []
        if suggested > 0 { parts.append("\(suggested) \(suggested == 1 ? "name" : "names") suggested") }
        if automatic > 0 { parts.append("\(automatic) \(automatic == 1 ? "name" : "names") recognized") }
        return parts.joined(separator: ", ") + "."
    }
}
