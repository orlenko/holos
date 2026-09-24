import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

private func turn(_ id: String, _ start: Double, _ end: Double, cluster: String? = "system:S1",
                  overlap: Bool = false) -> SpeakerTurn {
    SpeakerTurn(id: id, track: "system", start: start, end: end, speakerID: cluster ?? "mic:me", clusterID: cluster,
                spans: [WordSpan(segmentID: "S", first: 0, end: 1)], overlap: overlap,
                otherClusters: overlap ? ["system:S2"] : [], assignmentScore: 1, timing: .measured)
}

private func window(_ start: Double, _ end: Double, _ values: [Float], cluster: String = "system:S1") -> EmbeddingWindow {
    EmbeddingWindow(speaker: cluster, start: start, end: end, vector: FloatVector(values))
}

@Test func turnEmbeddingWeightsWindows() throws {
    let embeddings = TurnEmbeddings.compute(
        turns: [turn("T1", 10, 14)],
        windowsByCluster: ["system:S1": [window(12, 20, [0, 1]), window(9, 12, [1, 0]), window(30, 40, [1, 0])]])
    let embedding = try #require(embeddings.first)
    #expect(embeddings.count == 1)
    #expect(embedding.turnID == "T1")
    #expect(embedding.speechSeconds == 4)
    #expect(embedding.vector.count == 2)
    #expect(abs(embedding.vector.values[0] - 0.70710677) < 1e-6)
    #expect(abs(embedding.vector.values[1] - 0.70710677) < 1e-6)
}

@Test func unequalOverlapShiftsTheMean() throws {
    // 3 s of [1, 0] and 1 s of [0, 1] → [0.75, 0.25] normalized.
    let embeddings = TurnEmbeddings.compute(
        turns: [turn("T1", 10, 14)],
        windowsByCluster: ["system:S1": [window(5, 13, [1, 0]), window(13, 20, [0, 1])]])
    let vector = try #require(embeddings.first?.vector.values)
    let norm = (0.75 * 0.75 + 0.25 * 0.25).squareRoot()
    #expect(abs(Double(vector[0]) - 0.75 / norm) < 1e-6)
    #expect(abs(Double(vector[1]) - 0.25 / norm) < 1e-6)
}

@Test func shortOrOverlappedTurnsGetNoEmbedding() {
    let windows = ["system:S1": [window(0, 100, [1, 0])]]
    #expect(TurnEmbeddings.compute(turns: [turn("T1", 10, 11.5)], windowsByCluster: windows).isEmpty)
    #expect(TurnEmbeddings.compute(turns: [turn("T2", 20, 25, overlap: true)], windowsByCluster: windows).isEmpty)
    #expect(TurnEmbeddings.compute(turns: [turn("T3", 30, 32)], windowsByCluster: windows).map(\.turnID) == ["T3"])
}

@Test func channelOrWindowlessTurnsGetNoEmbedding() {
    let windows = ["system:S1": [window(0, 10, [1, 0])], "system:S2": [window(0, 100, [0, 0])]]
    #expect(TurnEmbeddings.compute(turns: [turn("T1", 0, 5, cluster: nil)], windowsByCluster: windows).isEmpty)
    // No window of the cluster overlaps the turn.
    #expect(TurnEmbeddings.compute(turns: [turn("T2", 20, 25)], windowsByCluster: windows).isEmpty)
    // Zero-norm mean.
    #expect(TurnEmbeddings.compute(turns: [turn("T3", 20, 25, cluster: "system:S2")], windowsByCluster: windows).isEmpty)
    // Unknown cluster.
    #expect(TurnEmbeddings.compute(turns: [turn("T4", 0, 5, cluster: "system:S9")], windowsByCluster: windows).isEmpty)
}
