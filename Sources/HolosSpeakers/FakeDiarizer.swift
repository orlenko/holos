import Foundation
import HolosCore

/// A `SpeakerDiarizer` that returns prepared outputs, for tests of code that diarizes (docs/meeting-design.md §4.8).
/// It never loads a model or reads audio.
public struct FakeDiarizer: SpeakerDiarizer {
    /// Output by track ("mic", "system").
    public var outputs: [String: DiarizerOutput]
    public var info: DiarizationEngineInfo
    public var error: HolosError?

    public init(outputs: [String: DiarizerOutput], info: DiarizationEngineInfo = .fake, error: HolosError? = nil) {
        self.outputs = outputs; self.info = info; self.error = error
    }

    /// Throws `error` if set.
    public func engineInfo() async throws -> DiarizationEngineInfo {
        if let error { throw error }
        return info
    }

    /// Calls progress(0) then progress(1); returns outputs[request.track] or an empty output; throws `error` if set.
    /// Throws `CancellationError` when the task is cancelled.
    public func diarize(_ request: DiarizationRequest,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput {
        try Task.checkCancellation()
        if let error { throw error }
        progress(0)
        progress(1)
        return outputs[request.track]
            ?? DiarizerOutput(segments: [], centroids: [:], windows: [], processingSeconds: 0)
    }

    /// Speakers take turns of `turnSeconds` over [0, duration) in order; centroids are orthogonal
    /// unit vectors of `dimension`; one EmbeddingWindow per turn equal to its speaker's centroid.
    /// Speaker k's centroid is the unit vector along axis `k % dimension`, so centroids are orthogonal only
    /// while there are at most `dimension` speakers. Empty speakers, a non-positive turn length or dimension,
    /// or a non-positive duration give an empty output.
    public static func alternating(speakers: [String], turnSeconds: Double, duration: Double,
                                   dimension: Int = 8) -> DiarizerOutput {
        var output = DiarizerOutput(segments: [], centroids: [:], windows: [], processingSeconds: 0)
        guard !speakers.isEmpty, dimension > 0, turnSeconds.isFinite, turnSeconds > 0,
              duration.isFinite, duration > 0 else { return output }
        for (index, speaker) in speakers.enumerated() where output.centroids[speaker] == nil {
            var axis = [Float](repeating: 0, count: dimension)
            axis[index % dimension] = 1
            output.centroids[speaker] = FloatVector(axis)
        }
        // The turn count comes from one division with a tolerance, so a duration that is a multiple of
        // `turnSeconds` in decimal (2.1 / 0.7) gets no extra sliver turn from floating-point sums. The last
        // turn ends at `duration`.
        let count = max(1, (duration / turnSeconds - 1e-9).rounded(.up))
        var turn = 0
        while Double(turn) < count {
            let speaker = speakers[turn % speakers.count]
            let start = Double(turn) * turnSeconds
            let end = Double(turn + 1) < count ? Double(turn + 1) * turnSeconds : duration
            output.segments.append(RawDiarizationSegment(speaker: speaker, start: start, end: end))
            if let centroid = output.centroids[speaker] {
                output.windows.append(EmbeddingWindow(speaker: speaker, start: start, end: end, vector: centroid))
            }
            turn += 1
        }
        return output
    }
}

extension DiarizationEngineInfo {
    /// engine "Fake", version "1", no models, embeddingModel ("fake", "1"), dimension 8.
    public static let fake = DiarizationEngineInfo(
        engine: "Fake", engineVersion: "1", models: [],
        embeddingModel: EmbeddingModelID(id: "fake", revision: "1"), embeddingDimension: 8, configuration: [:])
}
