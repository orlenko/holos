import Foundation
import HolosCore
import HolosStorage
import Testing
@testable import HolosAudio

// docs/meeting-design.md §4.3: disk latency never reaches the capture path.

private let pumpRate = 16_000.0

private func pumpFrame(_ track: String, at start: Double, seconds: Double = 0.1) throws -> CapturedAudio {
    CapturedAudio(track: track, frame: try PCMFrame(
        samples: [Float](repeating: 0.1, count: Int((seconds * pumpRate).rounded())), sampleRate: pumpRate,
        channels: 1, startTime: start))
}

private func pumpArchive(_ source: AudioSource = .microphone) throws -> (SessionArchive, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-audio-\(UUID().uuidString)")
    return (try SessionArchive.create(root: root, name: "Pump", source: source, locale: "en-CA", backend: .speech), root)
}

/// Polls `condition` every 5 ms for up to `timeout`.
private func pumpEventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// The writer is stalled (its task has not started) while 20 s of frames arrive: nothing is dropped, and everything
/// is written once it runs.
@Test(.timeLimit(.minutes(1))) func pumpAbsorbsSlowWriter() async throws {
    let (archive, root) = try pumpArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = AudioChunkWriter(archive: archive)
    let pump = ChunkWriterPump(writer: writer)
    var accepted = 0
    var peak = 0.0
    for index in 0..<200 {
        if pump.push(try pumpFrame("mic", at: Double(index) / 10)) { accepted += 1 }
        peak = max(peak, pump.backlogSeconds()["mic"] ?? 0)
    }
    #expect(accepted == 200, "Nothing is dropped below the 60 s capacity.")
    #expect(peak >= 9)
    #expect(writer.bytesWritten() == 0, "The stalled writer has written nothing yet.")
    let run = Task { try await pump.run() }
    pump.finish()
    try await run.value
    #expect(pump.backlogSeconds().isEmpty)
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let manifest = try SessionArchive.readManifest(at: archive.directory)
    #expect(manifest.chunks.reduce(0) { $0 + $1.frameCount } == Int(20 * pumpRate))
    #expect(!(try SessionArchive.readEvents(at: archive.directory).events
        .contains { $0.kind == MeetingEventKind.audioDiscontinuity }))
}

/// The writer is stalled past the 60 s capacity: later frames are dropped, capture carries on, and each track gets
/// one `overflow` discontinuity where audio was lost.
@Test(.timeLimit(.minutes(1))) func pumpDropsBeyondCapacityAndMarksOverflow() async throws {
    let (archive, root) = try pumpArchive(.microphoneAndSystem)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = AudioChunkWriter(archive: archive)
    let pump = ChunkWriterPump(writer: writer, capacitySeconds: 60)
    var firstRefused: [String: Double] = [:]
    for index in 0..<700 {
        let start = Double(index) / 10
        for track in ["mic", "system"] where !pump.push(try pumpFrame(track, at: start)) {
            if firstRefused[track] == nil { firstRefused[track] = start }
        }
    }
    for track in ["mic", "system"] {
        let refused = try #require(firstRefused[track])
        #expect(abs(refused - 60) < 0.15, "\(track) pushes are refused once 60 s are queued (from \(refused) s).")
    }
    let run = Task { try await pump.run() }
    #expect(await pumpEventually { pump.backlogSeconds().isEmpty })
    // Capture never ended: frames after the stall are taken and written.
    for index in 700..<710 {
        for track in ["mic", "system"] { #expect(pump.push(try pumpFrame(track, at: Double(index) / 10))) }
    }
    pump.finish()
    try await run.value
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let events = try SessionArchive.readEvents(at: archive.directory).events
    for track in ["mic", "system"] {
        let gaps = events.filter { $0.kind == MeetingEventKind.audioDiscontinuity && $0.details["track"] == track }
        #expect(gaps.count == 1)
        #expect(gaps.first?.details["reason"] == GapReason.overflow.rawValue)
        #expect(gaps.first?.details["nextStart"] == "70.0")
    }
}

@Test func closeAllWaitsForTheFramesBeforeIt() async throws {
    let (archive, root) = try pumpArchive()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = AudioChunkWriter(archive: archive)
    let pump = ChunkWriterPump(writer: writer)
    for index in 0..<5 { #expect(pump.push(try pumpFrame("mic", at: Double(index) / 10))) }
    let run = Task { try await pump.run() }
    try await pump.closeAll(expectingGap: .paused)
    #expect(try SessionArchive.readManifest(at: archive.directory).chunks.count == 1,
            "The chunk holding the frames queued before the close is registered when it returns.")
    #expect(pump.push(try pumpFrame("mic", at: 3)))
    pump.finish()
    try await run.value
    try await writer.finish()
    try await archive.finish(status: ArchiveStatus.complete)
    let gap = try #require(try SessionArchive.readEvents(at: archive.directory).events
        .first { $0.kind == MeetingEventKind.audioDiscontinuity })
    #expect(gap.details["reason"] == GapReason.paused.rawValue)
}

/// A full meeting capture stream drops and counts buffers instead of failing (§4.3), and the next frame delivered
/// on that track says audio was dropped before it.
@Test @MainActor func captureOverflowDoesNotFail() async throws {
    let capture = AudioCapture(bufferCapacity: 2, overflow: .dropAndCount)
    for index in 0..<5 {
        capture.emitForTesting(track: "mic", frame: try PCMFrame(samples: [0.1], sampleRate: 48_000, channels: 1,
                                                                 startTime: Double(index)))
    }
    #expect(capture.droppedBuffers == 3)
    #expect(capture.droppedBuffers(track: "mic") == 3)
    #expect(capture.droppedBuffers(track: "system") == 0)
    var frames = capture.frames.makeAsyncIterator()
    let first = try await frames.next()
    #expect(first?.frame.startTime == 0)
    #expect(first?.followsDrop == false)
    #expect(try await frames.next()?.followsDrop == false, "Buffers queued before the drop are not marked.")
    // The stream is still open: a later buffer arrives, marked as following the dropped ones.
    capture.emitForTesting(track: "mic", frame: try PCMFrame(samples: [0.1], sampleRate: 48_000, channels: 1,
                                                             startTime: 9))
    capture.emitForTesting(track: "mic", frame: try PCMFrame(samples: [0.1], sampleRate: 48_000, channels: 1,
                                                             startTime: 10))
    let after = try await frames.next()
    #expect(after?.frame.startTime == 9)
    #expect(after?.followsDrop == true)
    #expect(try await frames.next()?.followsDrop == false, "Only the first frame after a drop is marked.")
    #expect(capture.droppedBuffers == 3)
}

/// Dictation keeps failing on overflow, so a stalled feed never inserts text with a silent hole.
@Test @MainActor func captureOverflowFailsByDefault() async throws {
    let capture = AudioCapture(bufferCapacity: 2)
    for index in 0..<3 {
        capture.emitForTesting(track: "mic", frame: try PCMFrame(samples: [0.1], sampleRate: 48_000, channels: 1,
                                                                 startTime: Double(index)))
    }
    var frames = capture.frames.makeAsyncIterator()
    #expect(try await frames.next()?.frame.startTime == 0)
    #expect(try await frames.next()?.frame.startTime == 1)
    do {
        _ = try await frames.next()
        Issue.record("The stream should end with the overflow error.")
    } catch {
        #expect(error is HolosError)
    }
}
