import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

@Test func normalizerPrefixesSortsAndCountsOverlap() {
    let output = DiarizerOutput(segments: [
        RawDiarizationSegment(speaker: "S2", start: 5, end: 9, quality: 0.8),
        RawDiarizationSegment(speaker: "S1", start: 0, end: 6),
    ], centroids: [:], windows: [], processingSeconds: 1)
    let track = DiarizationNormalizer.normalize(output, track: "system")
    #expect(track.track == "system")
    #expect(track.policy == .diarized)
    #expect(track.segments == [
        DiarizationSegment(track: "system", clusterID: "system:S1", start: 0, end: 6, overlapCount: 1),
        DiarizationSegment(track: "system", clusterID: "system:S2", start: 5, end: 9, overlapCount: 1, quality: 0.8),
    ])
    #expect(track.clusters == [
        ClusterSummary(clusterID: "system:S1", track: "system", speechSeconds: 6),
        ClusterSummary(clusterID: "system:S2", track: "system", speechSeconds: 4),
    ])
}

@Test func normalizerDropsTinySegments() {
    let output = DiarizerOutput(segments: [
        RawDiarizationSegment(speaker: "S1", start: 0, end: 0.03),
        RawDiarizationSegment(speaker: "S2", start: 1, end: 1.05),
        RawDiarizationSegment(speaker: "S3", start: 2, end: .nan),
    ], centroids: [:], windows: [], processingSeconds: 0)
    let track = DiarizationNormalizer.normalize(output, track: "mic")
    #expect(track.segments.map(\.clusterID) == ["mic:S2"])
    #expect(track.clusters.map(\.clusterID) == ["mic:S2"])
}

@Test func clusterSpeechIsUnionLengthAndOverlapCountsClusters() {
    let output = DiarizerOutput(segments: [
        RawDiarizationSegment(speaker: "S1", start: 0, end: 4),
        RawDiarizationSegment(speaker: "S1", start: 3, end: 6),     // overlaps its own cluster: counted once
        RawDiarizationSegment(speaker: "S2", start: 6, end: 8),     // touches S1: not an overlap
        RawDiarizationSegment(speaker: "S3", start: 1, end: 2),
        RawDiarizationSegment(speaker: "S2", start: 1.5, end: 2.5),
    ], centroids: [:], windows: [], processingSeconds: 0)
    let track = DiarizationNormalizer.normalize(output, track: "system")
    #expect(track.segments.map(\.clusterID) == ["system:S1", "system:S3", "system:S2", "system:S1", "system:S2"])
    #expect(track.segments.map(\.overlapCount) == [2, 2, 2, 0, 0])
    #expect(track.clusters == [
        ClusterSummary(clusterID: "system:S1", track: "system", speechSeconds: 6),
        ClusterSummary(clusterID: "system:S2", track: "system", speechSeconds: 3),
        ClusterSummary(clusterID: "system:S3", track: "system", speechSeconds: 1),
    ])
}
