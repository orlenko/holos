import HolosCore
import HolosStorage
import HolosTestSupport
import Testing
@testable import HolosMeeting

@Test func progressFollowsTheRunningRecordAndDisappearsWhenItFinishes() async throws {
    let temp = try TemporaryDirectory("processing-progress")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Generated meeting", source: .system,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    let session = archive.directory
    #expect(MeetingProcessingProgress.read(session: session) == nil)
    let progress = PostProcessingProgress(stage: .deepTranscription, fraction: 0.4, message: "Processing")
    var record = PostProcessingRecord(sessionID: archive.id, state: .running, progress: progress,
                                      pid: 1, startedAt: .now, updatedAt: .now)
    try AtomicFile.writeJSON(record, to: SessionPaths.postprocess(session))
    #expect(MeetingProcessingProgress.read(session: session) == progress)
    record.state = .succeeded
    try AtomicFile.writeJSON(record, to: SessionPaths.postprocess(session))
    #expect(MeetingProcessingProgress.read(session: session) == nil)
}
