import FluidAudio
import Foundation
import HolosCore
import os

/// Engine settings Holos exposes for FluidAudio's offline diarizer (docs/meeting-design.md §4.8). Everything else
/// stays at `OfflineDiarizerConfig.default`, the best of every setting spike S1 tried.
public struct FluidDiarizerConfiguration: Sendable, Equatable {
    /// false keeps overlapping speech so alignment can mark overlap (FluidAudio default is true).
    public var exclusiveSegments: Bool
    /// nil uses FluidAudio's community-1 default (0.6, the best value S1 tried).
    public var clusteringThreshold: Double?

    public init(exclusiveSegments: Bool = false, clusteringThreshold: Double? = nil) {
        self.exclusiveSegments = exclusiveSegments; self.clusteringThreshold = clusteringThreshold
    }

    public static let `default` = FluidDiarizerConfiguration(exclusiveSegments: false, clusteringThreshold: nil)

    /// The keys `overridden(by:)` accepts.
    public static let overrideKeys = ["clusteringThreshold", "exclusiveSegments"]

    /// Applies `PostProcessingOptions.engineOverrides` ("exclusiveSegments", "clusteringThreshold").
    /// `exclusiveSegments` takes "true" or "false"; `clusteringThreshold` a number in (0, 2] (FluidAudio's range for
    /// its unit-norm Euclidean cut). Throws `invalidInput` for an unknown key or an invalid value.
    public func overridden(by overrides: [String: String]) throws -> FluidDiarizerConfiguration {
        var result = self
        for key in overrides.keys.sorted() {
            let value = (overrides[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "exclusiveSegments":
                switch value.lowercased() {
                case "true": result.exclusiveSegments = true
                case "false": result.exclusiveSegments = false
                default: throw HolosError.invalidInput("The engine setting exclusiveSegments must be true or false.")
                }
            case "clusteringThreshold":
                guard let threshold = Double(value), threshold.isFinite, threshold > 0, threshold <= 2 else {
                    throw HolosError.invalidInput(
                        "The engine setting clusteringThreshold must be a number greater than 0 and at most 2.")
                }
                result.clusteringThreshold = threshold
            default:
                throw HolosError.invalidInput(
                    "Unknown engine setting \"\(key)\"; the known settings are "
                        + Self.overrideKeys.joined(separator: " and ") + ".")
            }
        }
        return result
    }

    /// FluidAudio's configuration for one request: the default, chunk embeddings on, these settings, and the
    /// speaker-count hint as `resolved(_:)` gives it.
    func offlineConfig(speakers: SpeakerCountHint?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.exposeChunkEmbeddings = true
        config.postProcessing.exclusiveSegments = exclusiveSegments
        if let clusteringThreshold { config.clustering.threshold = clusteringThreshold }
        if let hint = Self.resolved(speakers) {
            if let exactly = hint.exactly {
                config = config.withSpeakers(exactly: exactly)
            } else {
                config = config.withSpeakers(min: hint.minimum, max: hint.maximum)
            }
        }
        return config
    }

    /// The speaker-count hint FluidAudio gets: values below 1 are dropped (a hint of n − 1 for one expected
    /// speaker means no minimum), `exactly` wins over `minimum`/`maximum`, and nothing left means no hint.
    /// FluidAudio itself clamps a minimum above the maximum down to the maximum.
    static func resolved(_ hint: SpeakerCountHint?) -> SpeakerCountHint? {
        guard let hint else { return nil }
        func positive(_ value: Int?) -> Int? { value.flatMap { $0 > 0 ? $0 : nil } }
        if let exactly = positive(hint.exactly) { return SpeakerCountHint(exactly: exactly) }
        let minimum = positive(hint.minimum)
        let maximum = positive(hint.maximum)
        guard minimum != nil || maximum != nil else { return nil }
        return SpeakerCountHint(minimum: minimum, maximum: maximum)
    }

    /// The effective engine settings, flattened for `DiarizationEngineInfo.configuration` (reproducibility only).
    var flattened: [String: String] {
        let config = offlineConfig(speakers: nil)
        return [
            "clusteringThreshold": String(describing: config.clustering.threshold),
            // FluidAudio 0.17.1 loads segmentation, embedding, and PLDA with `.all` and always keeps FBank on the CPU.
            "computeUnits": "all",
            "fbankComputeUnits": "cpuOnly",
            "embeddingExcludeOverlap": String(config.embedding.excludeOverlap),
            "exclusiveSegments": String(config.postProcessing.exclusiveSegments),
            "exposeChunkEmbeddings": String(config.exposeChunkEmbeddings),
            "minGapDurationSeconds": String(describing: config.postProcessing.minGapDurationSeconds),
            "minSegmentDurationSeconds": String(describing: config.embedding.minSegmentDurationSeconds),
            "segmentationStepRatio": String(describing: config.segmentation.stepRatio),
            "segmentationWindowSeconds": String(describing: config.segmentation.windowDurationSeconds),
            "vbxMaxIterations": String(config.vbx.maxIterations),
            "warmStartFa": String(describing: config.clustering.warmStartFa),
            "warmStartFb": String(describing: config.clustering.warmStartFb),
        ]
    }
}

/// `SpeakerDiarizer` over FluidAudio 0.17.1's `OfflineDiarizerManager` (pyannote Community-1 segmentation, WeSpeaker
/// embeddings, VBx clustering), fully offline (docs/meeting-design.md §4.8).
///
/// Every call first verifies the pinned model files (`FluidModels.status`) and refuses unverified ones. The actor
/// loads the models once (FluidAudio offline mode: a failed load never deletes or downloads anything, and
/// `prepareModels` is never used) and caches them; each `diarize` runs one pass over one rendered track in its own
/// `OfflineDiarizerManager`, off the actor. Callers diarize tracks one at a time, so peak memory is one track's
/// (S1: 1.8 GB peak RSS for 3 h). Voice vectors in the output stay in memory; this type persists nothing.
public actor FluidDiarizer: SpeakerDiarizer {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "diarization")

    public static let engineName = "FluidAudio.OfflineDiarizerManager"
    public static let engineVersion = "0.17.1"
    public static let embeddingDimension = 256
    public static let embeddingModel = EmbeddingModelID(
        id: "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc", revision: FluidModels.revision)

    private let modelsDirectory: URL
    private let configuration: FluidDiarizerConfiguration
    private let pinned: [PinnedFile]
    private var models: OfflineDiarizerModels?
    private var loading: Task<OfflineDiarizerModels, any Error>?

    /// Turns FluidAudio's offline mode on for this process: nothing in it downloads from here on.
    public init(modelsDirectory: URL = FluidModels.defaultDirectory,
                configuration: FluidDiarizerConfiguration = .default) {
        self.init(modelsDirectory: modelsDirectory, configuration: configuration, pinned: PinnedModels.files)
    }

    init(modelsDirectory: URL, configuration: FluidDiarizerConfiguration, pinned: [PinnedFile]) {
        ModelHub.offlineMode = true
        self.modelsDirectory = modelsDirectory
        self.configuration = configuration
        self.pinned = pinned
    }

    /// Engine and model provenance: one `ModelDescriptor` for the repo whose `sha256` is the `ModelTreeDigest` of the
    /// verified files. Throws `HolosError.unavailable` when the models are missing or fail verification.
    public func engineInfo() async throws -> DiarizationEngineInfo {
        try verifyModels()
        return DiarizationEngineInfo(
            engine: Self.engineName, engineVersion: Self.engineVersion,
            models: [ModelDescriptor(id: FluidModels.repository, revision: FluidModels.revision,
                                     sha256: ModelTreeDigest.digest(of: pinned))],
            embeddingModel: Self.embeddingModel, embeddingDimension: Self.embeddingDimension,
            configuration: configuration.flattened)
    }

    /// Diarizes one rendered track (`Int16CAFSampleSource`: 16 kHz mono Int16 CAF). Times are seconds of that file.
    /// Audio without speech gives an empty output. `progress` receives 0...1 from any thread. Throws
    /// `unavailable` when the models are not verified or fail, `invalidInput` for audio in another format, and
    /// `CancellationError` when cancelled (nothing partial is returned).
    public func diarize(_ request: DiarizationRequest,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput {
        try Task.checkCancellation()
        try verifyModels()
        let source = try Int16CAFSampleSource(url: request.audio)
        // Timed from here, so only the call that loads (or waits for) the models counts the load.
        let started = ContinuousClock.now
        let models = try await loadedModels()
        try Task.checkCancellation()
        let config = configuration.offlineConfig(speakers: request.speakers)
        progress(0)
        let output = try await Self.process(source: source, models: models, config: config, started: started,
                                            progress: progress)
        try Task.checkCancellation()
        Self.log.info("""
            Diarized track \(request.track, privacy: .public): \(source.sampleCount / 16_000, privacy: .public) s of \
            audio, \(output.segments.count, privacy: .public) segments, \(output.centroids.count, privacy: .public) \
            clusters in \(output.processingSeconds, privacy: .public) s
            """)
        progress(1)
        return output
    }

    // MARK: - Private

    private func verifyModels() throws {
        let status = FluidModels.status(directory: modelsDirectory, pinned: pinned)
        guard status == .verified else {
            Self.log.error("Speaker models not verified: \(status.doctorValue, privacy: .public)")
            throw HolosError.unavailable(FluidModels.missingModelsMessage)
        }
    }

    /// The cached models, loading them once; concurrent callers share one load, and a failed load is retried by the
    /// next call.
    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let models { return models }
        if let loading { return try await loading.value }
        let directory = modelsDirectory
        let task = Task { try await Self.load(from: directory) }
        loading = task
        do {
            let loaded = try await task.value
            models = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    /// Loads under the offline mode `init` turned on: a failed load throws instead of deleting and downloading.
    @concurrent
    private static func load(from directory: URL) async throws -> OfflineDiarizerModels {
        do {
            return try await OfflineDiarizerModels.load(from: directory, configuration: nil)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            log.error("Speaker models failed to load: \(String(describing: type(of: error)), privacy: .public)")
            throw HolosError.unavailable(
                "The speaker models could not be loaded (\(error.localizedDescription)). "
                    + "Reinstall them from Setup, or run holos setup --speakers.")
        }
    }

    /// One pass over one track in a local, non-Sendable `OfflineDiarizerManager` that never leaves this function.
    @concurrent
    private static func process(source: Int16CAFSampleSource, models: OfflineDiarizerModels,
                                config: OfflineDiarizerConfig, started: ContinuousClock.Instant,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput {
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result: DiarizationResult
        do {
            // Segmentation reports (windows done, total) per 10 s window; the rest (embeddings finishing,
            // clustering) takes the last 5 %.
            result = try await manager.process(audioSource: source, audioLoadingSeconds: 0) { done, total in
                guard total > 0 else { return }
                progress(min(0.95, 0.95 * Double(done) / Double(total)))
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            return DiarizerOutput(segments: [], centroids: [:], windows: [],
                                  processingSeconds: seconds(since: started))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            log.error("Diarization failed: \(String(describing: type(of: error)), privacy: .public)")
            throw HolosError.unavailable(
                "Speaker labelling failed (\(error.localizedDescription)). Try again; if it keeps failing, "
                    + "reinstall the speaker models with holos setup --speakers.")
        }
        return output(from: result, processingSeconds: seconds(since: started))
    }

    /// FluidAudio's result as the engine-neutral output: segments with their quality, centroids from the speaker
    /// database (raw WeSpeaker space), one window per chunk embedding, and `processingSeconds`.
    ///
    /// `processingSeconds` is the wall time `diarize` measured, including the model load only on the call that
    /// loaded them. FluidAudio's `PipelineTimings.totalProcessingSeconds` (the §4.8 mapping) is not used: it adds
    /// `OfflineDiarizerModels.compilationDuration` on every call, so cached models counted their one-time load on
    /// every track.
    static func output(from result: DiarizationResult, processingSeconds: Double) -> DiarizerOutput {
        let segments = result.segments.map { segment in
            let quality = Double(segment.qualityScore)
            return RawDiarizationSegment(speaker: segment.speakerId, start: Double(segment.startTimeSeconds),
                                         end: Double(segment.endTimeSeconds), quality: quality.isFinite ? quality : nil)
        }
        let centroids = (result.speakerDatabase ?? [:]).mapValues { FloatVector($0) }
        let windows = (result.chunkEmbeddings ?? []).filter { !$0.embedding256.isEmpty }.map { chunk in
            EmbeddingWindow(speaker: chunk.speakerId, start: chunk.startTimeSeconds, end: chunk.endTimeSeconds,
                            vector: FloatVector(chunk.embedding256))
        }
        return DiarizerOutput(segments: segments, centroids: centroids, windows: windows,
                              processingSeconds: processingSeconds)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
