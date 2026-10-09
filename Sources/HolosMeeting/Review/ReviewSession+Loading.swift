import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

extension ReviewSession {
    // MARK: - Loading (off the main actor)

    struct Loaded: Sendable {
        var snapshot: SpeakerSessionSnapshot
        var people: [SpeakerProfile]
        var profileNames: [String: String]
        var rememberVoices: Bool
        var calibration: (thresholds: RecognitionThresholds, model: EmbeddingModelID)?
        var editedExports: Set<String>
    }

    /// What one read of the people store gives the window.
    struct KnownPeople: Sendable {
        var people: [SpeakerProfile] = []
        var names: [String: String] = [:]
        var remember = false
        /// Calibrated recognition thresholds and the model they were measured on, when calibrated.
        var calibration: (thresholds: RecognitionThresholds, model: EmbeddingModelID)?
    }

    nonisolated static func load(session: URL, profiles: SpeakerProfileStore?) throws -> Loaded {
        let known = profiles.map { people(store: $0) } ?? KnownPeople()
        let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: known.names,
                                                       applyRecognition: recognitionAllowed(profiles))
        return Loaded(snapshot: snapshot, people: known.people, profileNames: known.names,
                      rememberVoices: known.remember, calibration: known.calibration,
                      editedExports: editedExports(session: session))
    }

    /// Whether the meeting's stored recognition result may be shown and exported, decided as every other reader of
    /// the labels decides it (`VoiceProfileService.recognitionAllowed`: Remember voices on and no forget still owed);
    /// without a people store (tests), as `SpeakerEditor` does, it is.
    nonisolated static func recognitionAllowed(_ profiles: SpeakerProfileStore?) -> Bool {
        profiles.map { VoiceProfileService.recognitionAllowed(store: $0) } ?? true
    }

    nonisolated static func people(store: SpeakerProfileStore) -> KnownPeople {
        people(loading: store.load)
    }

    /// The people offered, their names, Remember voices, and the calibration, all from one read of the store, so a
    /// rewrite of `profiles.json` in between cannot mix two versions. Nothing (and Remember voices off) when it cannot
    /// be read.
    nonisolated static func people(loading load: () throws -> SpeakerProfileDatabase) -> KnownPeople {
        do {
            let database = try load()
            let calibration = database.calibratedModel.flatMap { model in
                database.calibratedThresholds(for: model).map { (thresholds: $0, model: model) }
            }
            return KnownPeople(people: VoiceProfileService.knownPeople(in: database),
                               names: VoiceProfileService.profileNames(in: database),
                               remember: database.rememberVoices, calibration: calibration)
        } catch {
            log.error("Cannot read people: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return KnownPeople()
        }
    }

    /// Names of the hand-edited exports moved aside so far (`exports/edited-*`).
    nonisolated static func editedExports(session: URL) -> Set<String> {
        let folder = SessionPaths.exports(session)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return Set(names.filter { $0.hasPrefix("edited-") })
    }

    nonisolated static func segmentIndex(_ transcript: Transcript) -> [String: TranscriptSegment] {
        var index: [String: TranscriptSegment] = [:]
        for segment in transcript.segments where index[segment.id] == nil { index[segment.id] = segment }
        return index
    }

    /// The exports' text of `spans`, reading only the segments they name.
    nonisolated static func text(of spans: [WordSpan], segments: [String: TranscriptSegment],
                                         transcript: Transcript) -> String {
        var seen = Set<String>()
        let named = spans.compactMap { span -> TranscriptSegment? in
            guard seen.insert(span.segmentID).inserted else { return nil }
            return segments[span.segmentID]
        }
        let part = Transcript(id: transcript.id, createdAt: transcript.createdAt, source: transcript.source,
                              locale: transcript.locale, backend: transcript.backend, segments: named)
        return TranscriptExporter.text(of: spans, in: part)
    }

    nonisolated static func detached<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: body).value
    }

    /// `body` off the main actor, cancelled when the calling task is (a detached task does not inherit it).
    nonisolated static func cancellable<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated static func cancellableResult<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        do {
            return .success(try await cancellable(body))
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func detachedValue<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: body).value
    }

    nonisolated static func detachedResult<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        await Task.detached(priority: .userInitiated) { () -> Result<T, any Error> in
            do {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }.value
    }
}
