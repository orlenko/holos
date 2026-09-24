import Darwin
import Foundation
import HolosCore
import HolosDiarization
import HolosMeeting
import HolosStorage

/// The post-processor the CLI runs, after a recording and (from PR7b) for `holos session diarize`.
///
/// The diarizer is `makeDiarizer(engineOverrides: options.engineOverrides)`. The people store
/// (`SpeakerProfileStore()`) lets stage 7 suggest known people when "Remember voices" is on (PR10).
func makeMeetingPostProcessor(options: PostProcessingOptions = .init()) -> MeetingPostProcessor {
    MeetingPostProcessor(diarizer: makeDiarizer(engineOverrides: options.engineOverrides), options: options,
                         profiles: SpeakerProfileStore())
}

/// `FluidDiarizer` over the installed models with `engineOverrides` applied (`FluidDiarizer.forInstalledModels`):
/// nil only when the models are not installed (speaker-less exports and the setup hint). Damaged models give a
/// diarizer that fails with "missing or damaged", and invalid engine overrides one that fails with the reason, so
/// the diarize stage records the failure.
func makeDiarizer(engineOverrides: [String: String]) -> (any SpeakerDiarizer)? {
    do {
        let configuration = try FluidDiarizerConfiguration.default.overridden(by: engineOverrides)
        return FluidDiarizer.forInstalledModels(configuration: configuration)
    } catch {
        guard FluidModels.status() != .notInstalled else { return nil }
        return RejectedSettingsDiarizer(error: error as? HolosError ?? .invalidInput(error.localizedDescription))
    }
}

/// The CLI's voice sample extractor (docs/meeting-design.md §4.10): a fresh FluidAudio pass with chunk embeddings,
/// configured like the session's head run (its recorded `exclusiveSegments` and `clusteringThreshold`), through
/// `DiarizerVoiceSampleExtractor`. Nil when the speaker models are not verified.
func makeVoiceSampleExtractor(session: URL) -> (any VoiceSampleExtractor)? {
    var overrides: [String: String] = [:]
    if let head = try? SessionSpeakerStore.readHead(session: session),
       let run = try? SessionSpeakerStore.readRun(id: head.runID, session: session),
       let configuration = run.engine?.configuration {
        for key in FluidDiarizerConfiguration.overrideKeys { overrides[key] = configuration[key] }
    }
    return makeDiarizer(engineOverrides: overrides).map { DiarizerVoiceSampleExtractor(diarizer: $0) }
}

/// The hook `holos record start` runs under the processing lease after the archive is finished.
/// It never throws: an error becomes a `.failed` record with the error's message.
func makePostProcessHook(options: PostProcessingOptions) -> PostProcessHook {
    { session, lease, progress in
        let startedAt = Date()
        do {
            return try await makeMeetingPostProcessor(options: options).run(session: session, lease: lease,
                                                                           progress: progress)
        } catch {
            let message = error is CancellationError ? "Post-processing was cancelled." : error.localizedDescription
            let sessionID = (try? SessionArchive.readManifest(at: session).id)
                ?? session.deletingPathExtension().lastPathComponent
            return PostProcessingRecord(sessionID: sessionID, state: .failed, pid: getpid(), startedAt: startedAt,
                                        updatedAt: Date(), message: message)
        }
    }
}

/// A diarizer for engine settings that did not parse: every call fails with why, so the post-processor records the
/// diarize stage as failed instead of running with settings nobody asked for.
private struct RejectedSettingsDiarizer: SpeakerDiarizer {
    let error: HolosError

    func engineInfo() async throws -> DiarizationEngineInfo { throw error }

    func diarize(_ request: DiarizationRequest,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput {
        throw error
    }
}
