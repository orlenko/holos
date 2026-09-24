import Foundation
import Synchronization
import Testing
import HolosCore
@testable import HolosSpeakers

private final class ProgressLog: Sendable {
    let values = Mutex<[Double]>([])
    func append(_ value: Double) { values.withLock { $0.append(value) } }
    var all: [Double] { values.withLock { $0 } }
}

@Test func fakeAlternatingOutput() {
    let output = FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds: 5, duration: 20)
    #expect(output.segments == [
        RawDiarizationSegment(speaker: "S1", start: 0, end: 5),
        RawDiarizationSegment(speaker: "S2", start: 5, end: 10),
        RawDiarizationSegment(speaker: "S1", start: 10, end: 15),
        RawDiarizationSegment(speaker: "S2", start: 15, end: 20),
    ])
    #expect(output.centroids.count == 2)
    let s1 = output.centroids["S1"]?.values ?? []
    let s2 = output.centroids["S2"]?.values ?? []
    #expect(s1.count == 8)
    #expect(s2.count == 8)
    #expect(abs(VectorMath.cosineDistance(s1, s2) - 1) < 1e-12)
    #expect(VectorMath.norm(s1) == 1)
    #expect(VectorMath.norm(s2) == 1)
    #expect(output.windows.map(\.speaker) == ["S1", "S2", "S1", "S2"])
    #expect(output.windows.allSatisfy { $0.vector == output.centroids[$0.speaker] })
    #expect(output.windows.map(\.start) == [0, 5, 10, 15])
}

@Test func fakeAlternatingOutputClipsTheLastTurn() {
    let output = FakeDiarizer.alternating(speakers: ["S1", "S2", "S3"], turnSeconds: 4, duration: 10, dimension: 3)
    #expect(output.segments.map(\.speaker) == ["S1", "S2", "S3"])
    #expect(output.segments.last?.end == 10)
    #expect(output.centroids["S3"] == FloatVector([0, 0, 1]))
    #expect(FakeDiarizer.alternating(speakers: [], turnSeconds: 5, duration: 20).segments.isEmpty)
}

@Test func fakeAlternatingOutputHasNoSliverTurn() {
    // 3 × 0.7 is 2.0999999999999996 in binary floating point, just under 2.1.
    let output = FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds: 0.7, duration: 2.1)
    #expect(output.segments.map(\.speaker) == ["S1", "S2", "S1"])
    #expect(output.segments.last?.end == 2.1)
    #expect(output.windows.count == 3)
}

@Test func fakeDiarizerReturnsTrackOutputAndReportsProgress() async throws {
    let system = FakeDiarizer.alternating(speakers: ["S1"], turnSeconds: 5, duration: 5)
    let diarizer = FakeDiarizer(outputs: ["system": system])
    let log = ProgressLog()
    let result = try await diarizer.diarize(DiarizationRequest(audio: URL(fileURLWithPath: "/nonexistent.caf"),
                                                               track: "system"),
                                            progress: { log.append($0) })
    #expect(result == system)
    #expect(log.all == [0, 1])

    let mic = try await diarizer.diarize(DiarizationRequest(audio: URL(fileURLWithPath: "/nonexistent.caf"),
                                                            track: "mic"), progress: { _ in })
    #expect(mic == DiarizerOutput(segments: [], centroids: [:], windows: [], processingSeconds: 0))
    #expect(try await diarizer.engineInfo() == .fake)
}

@Test func fakeDiarizerThrowsConfiguredError() async {
    let diarizer = FakeDiarizer(outputs: [:], error: .unavailable("Speaker models are missing."))
    await #expect(throws: HolosError.self) {
        _ = try await diarizer.engineInfo()
    }
    let log = ProgressLog()
    await #expect(throws: HolosError.self) {
        _ = try await diarizer.diarize(DiarizationRequest(audio: URL(fileURLWithPath: "/nonexistent.caf"),
                                                          track: "system"),
                                       progress: { log.append($0) })
    }
    #expect(log.all.isEmpty)
}

@Test func fakeEngineInfoDescribesTheFake() {
    let info = DiarizationEngineInfo.fake
    #expect(info.engine == "Fake")
    #expect(info.engineVersion == "1")
    #expect(info.models.isEmpty)
    #expect(info.embeddingModel == EmbeddingModelID(id: "fake", revision: "1"))
    #expect(info.embeddingDimension == 8)
}
