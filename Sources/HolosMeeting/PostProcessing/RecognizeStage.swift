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

    /// Test hook: while set (a task-local value), called after the first read of the people and before the comparison
    /// that is saved.
    @TaskLocal static var beforeSaving: (@Sendable () throws -> Void)? = nil

    /// Test hook: while set (a task-local value), called with the speaker lock and `profiles.lock` held, after the
    /// people are read again and before the comparison is written.
    @TaskLocal static var whileSaving: (@Sendable () throws -> Void)? = nil

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
        guard run.engine != nil, voiceData != nil else {
            return .skipped(nothingToCompare)
        }
        let result: RecognitionResult
        do {
            try beforeSaving?()
            // The comparison that is saved is made again from the people as they are then (the recognizer is pure
            // and cheap), never from the earlier read, and it is written while the speaker lock and then
            // `profiles.lock` are held (the §1.7 order: speakers → profiles, as every other holder of both takes
            // them; a forget releases `profiles.lock` before it takes any speaker lock). Every change to the people
            // (`SpeakerProfileStore.update` takes `profiles.lock`) therefore lands either before the read, and is
            // reflected in what is written (a sample forgotten, refreshed, or learned, a person forgotten or merged,
            // suggestions or Remember voices turned off, a model change, a calibration saved or reset), or after
            // the write, as for a meeting processed earlier. A forget whose store update comes later cleans this
            // file afterwards (it takes the speaker lock per meeting after its store update).
            let written = try SessionArchive.withSpeakerLock(at: session) { () throws -> RecognitionResult? in
                try store.withLockedDatabase { current -> RecognitionResult? in
                    guard current.rememberVoices,
                          let fresh = SpeakerRecognizer.recognize(run: run, voiceData: voiceData,
                                                                  database: current) else {
                        return nil
                    }
                    try whileSaving?()
                    try SessionSpeakerStore.writeRecognition(fresh, session: session)
                    return fresh
                }
            }
            guard let written else { return .skipped(rememberOff) }
            result = written
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
