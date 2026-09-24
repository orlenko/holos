import AVFoundation
import Foundation
import HolosCore
import HolosStorage
import Testing
@testable import HolosAudio

// docs/meeting-design.md §2.3: within an epoch, jitter under 50 ms is contiguous, a later frame is a gap, and an
// earlier one loses its overlapping samples.

private struct ContinuityFixture {
    let root: URL
    let archive: SessionArchive
    let writer: AudioChunkWriter

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-audio-\(UUID().uuidString)")
        archive = try SessionArchive.create(root: root, name: "Continuity", source: .microphone, locale: "en-CA",
                                            backend: .speech)
        writer = AudioChunkWriter(archive: archive)
    }

    /// Appends `seconds` of 48 kHz mono audio starting at `start`.
    func append(_ start: Double, _ seconds: Double, value: Float = 0.25) async throws {
        let count = Int((seconds * 48_000).rounded())
        try await writer.append(CapturedAudio(track: "mic", frame: try PCMFrame(
            samples: [Float](repeating: value, count: count), sampleRate: 48_000, channels: 1, startTime: start)))
    }

    func finish() async throws -> (chunks: [AudioChunkRecord], events: [ArchiveEvent]) {
        try await writer.finish()
        try await archive.finish(status: ArchiveStatus.complete)
        let chunks = try SessionArchive.readManifest(at: archive.directory).chunks.sorted { $0.start < $1.start }
        return (chunks, try SessionArchive.readEvents(at: archive.directory).events)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func classifyAppliesTheFiftyMillisecondRule() {
    typealias Decision = FrameContinuity.Decision
    #expect(FrameContinuity.classify(frameStart: 5, frameCount: 10, sampleRate: 100, expected: nil)
            == .contiguous(driftSeconds: 0))
    #expect(FrameContinuity.classify(frameStart: 1.03, frameCount: 10, sampleRate: 100, expected: 1)
            == .contiguous(driftSeconds: 1.03 - 1))
    #expect(FrameContinuity.classify(frameStart: 0.96, frameCount: 10, sampleRate: 100, expected: 1)
            == .contiguous(driftSeconds: 0.96 - 1))
    #expect(FrameContinuity.classify(frameStart: 1.05, frameCount: 10, sampleRate: 100, expected: 1)
            == .gap(seconds: 1.05 - 1))
    #expect(FrameContinuity.classify(frameStart: 0.8, frameCount: 50, sampleRate: 100, expected: 1)
            == .overlap(dropFrames: 20))
    #expect(FrameContinuity.classify(frameStart: 0.5, frameCount: 10, sampleRate: 100, expected: 1)
            == .overlap(dropFrames: 50), "A frame entirely before the end is dropped whole.")
}

@Test func smallJitterIsContiguous() async throws {
    let fixture = try ContinuityFixture()
    defer { fixture.remove() }
    try await fixture.append(0, 0.1)
    try await fixture.append(0.13, 0.1)
    let (chunks, events) = try await fixture.finish()
    #expect(chunks.count == 1)
    #expect(chunks.first?.frameCount == 9_600)
    #expect(abs((chunks.first?.end ?? 0) - 0.2) < 1e-9, "The samples follow directly; the frame's own time is ignored.")
    #expect(!events.contains { $0.kind == MeetingEventKind.audioDiscontinuity })
}

@Test func gapClosesChunk() async throws {
    let fixture = try ContinuityFixture()
    defer { fixture.remove() }
    try await fixture.append(0, 0.1)
    try await fixture.append(0.2, 0.1)
    let (chunks, events) = try await fixture.finish()
    #expect(chunks.count == 2)
    #expect(chunks.map(\.start) == [0, 0.2])
    let gap = try #require(events.first { $0.kind == MeetingEventKind.audioDiscontinuity })
    #expect(gap.details["reason"] == "timestampGap")
    #expect(gap.details["previousEnd"] == "0.1")
    #expect(gap.details["nextStart"] == "0.2")
}

@Test func overlapIsTrimmedAndRecorded() async throws {
    let fixture = try ContinuityFixture()
    defer { fixture.remove() }
    try await fixture.append(0, 1.0, value: 0.25)
    try await fixture.append(0.8, 0.5, value: -0.5)
    let (chunks, events) = try await fixture.finish()
    let overlap = try #require(events.first { $0.kind == MeetingEventKind.timestampOverlap })
    #expect(overlap.details["track"] == "mic")
    #expect(overlap.details["previousEnd"] == "1.0")
    #expect(overlap.details["nextStart"] == "0.8")
    #expect(abs((overlap.details["droppedSeconds"].flatMap(Double.init) ?? 0) - 0.2) < 1e-9)
    #expect(chunks.count == 1)
    #expect(chunks.first?.frameCount == 62_400, "1.0 s plus the 0.3 s that did not overlap.")
    #expect(abs((chunks.first?.end ?? 0) - 1.3) < 1e-9)
    for (previous, next) in zip(chunks, chunks.dropFirst()) {
        #expect(next.start >= previous.end, "No chunk starts before the previous one ends.")
    }
    // Only the non-overlapping 0.3 s of the second frame was written, after the first frame's samples.
    let file = try AVAudioFile(forReading: fixture.archive.directory.appendingPathComponent(chunks[0].relativePath))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 62_400))
    try file.read(into: buffer)
    let samples = try PCMConversion.copy(buffer, startTime: 0).samples
    #expect(samples[47_999] == 0.25)
    #expect(samples[48_000] == -0.5)
}

@Test func closeAllStartsTheNextFrameAtItsOwnTimeWithTheReason() async throws {
    let fixture = try ContinuityFixture()
    defer { fixture.remove() }
    try await fixture.append(0, 0.1)
    try await fixture.writer.closeAll(expectingGap: .deviceChanged)
    // The next epoch starts 10 ms after the last frame: close enough to be contiguous, but it is a new epoch.
    try await fixture.append(0.11, 0.1)
    let (chunks, events) = try await fixture.finish()
    #expect(chunks.map(\.start) == [0, 0.11])
    let gap = try #require(events.first { $0.kind == MeetingEventKind.audioDiscontinuity })
    #expect(gap.details["reason"] == GapReason.deviceChanged.rawValue)
}
