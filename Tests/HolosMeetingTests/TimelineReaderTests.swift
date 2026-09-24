import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import Testing

// SessionTimelineReader (docs/meeting-design.md §5.5 PR7b): gaps and markers for exports from events.jsonl.

private func timelineSession(in root: URL, _ events: [(kind: String, details: [String: String])]) async throws -> URL {
    let archive = try SessionArchive.create(root: root, name: "Timeline", source: .microphoneAndSystem,
                                            locale: "en-CA", backend: .speech)
    for event in events { try await archive.recordEvent(kind: event.kind, details: event.details) }
    try await archive.finish(status: ArchiveStatus.complete)
    return archive.directory
}

private func timelineGap(_ track: String, _ start: Double, _ end: Double,
                         _ reason: String) -> (kind: String, details: [String: String]) {
    (MeetingEventKind.audioDiscontinuity,
     ["track": track, "previousEnd": String(start), "nextStart": String(end), "reason": reason])
}

@Test func timelineReaderMapsEveryReason() async throws {
    let temp = try TemporaryDirectory("timeline")
    defer { temp.remove() }
    let session = try await timelineSession(in: temp.url, [
        timelineGap("mic", 10.0, 20.0, "paused"),
        timelineGap("system", 10.02, 20.01, "paused"),
        (MeetingEventKind.marker, ["at": "15.0", "requestID": UUID().uuidString, "label": "Budget vote"]),
        timelineGap("mic", 30, 40, "sleep"),
        timelineGap("mic", 50, 51, "deviceChanged"),
        (MeetingEventKind.marker, ["at": "55.0", "requestID": UUID().uuidString]),
        timelineGap("mic", 60, 60.5, "captureRestarted"),
        timelineGap("system", 70, 80, "audioUnavailable"),
        timelineGap("mic", 90, 92, "overflow"),
        timelineGap("mic", 100, 100.4, "timestampGap"),
        timelineGap("mic", 110, 112, "timestampGap"),
        timelineGap("mic", 120, 123, "somethingNew"),
        timelineGap("mic", 124, 124.5, "somethingNew"),
        timelineGap("mic", 130, 135, "formatChanged"),
        timelineGap("mic", 140, 140.03, "paused"),
    ])
    // A torn or corrupt line is skipped.
    let journal = SessionPaths.events(session)
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("not json\n{\"sequence\":".utf8))
    try handle.close()

    let (gaps, markers) = try SessionTimelineReader.read(session: session)
    #expect(gaps == [
        TimelineGap(track: nil, start: 10.0, end: 20.01, reason: .paused),
        TimelineGap(track: "mic", start: 30, end: 40, reason: .sleep),
        TimelineGap(track: "mic", start: 50, end: 51, reason: .deviceChanged),
        TimelineGap(track: "mic", start: 60, end: 60.5, reason: .captureRestarted),
        TimelineGap(track: "system", start: 70, end: 80, reason: .audioUnavailable),
        TimelineGap(track: "mic", start: 90, end: 92, reason: .overflow),
        TimelineGap(track: "mic", start: 110, end: 112, reason: .audioGap),
        TimelineGap(track: "mic", start: 120, end: 123, reason: .audioGap),
    ])
    #expect(markers == [TimelineMarker(at: 15, label: "Budget vote"), TimelineMarker(at: 55, label: nil)])
}

@Test func timelineReaderSplitsGapAtPauseEvents() async throws {
    let temp = try TemporaryDirectory("timeline")
    defer { temp.remove() }
    let session = try await timelineSession(in: temp.url, [
        (MeetingEventKind.paused, ["at": "120.0"]),
        (MeetingEventKind.resumed, ["at": "180.0", "epoch": "2"]),
        timelineGap("mic", 100, 200, "audioUnavailable"),
        (MeetingEventKind.systemWillSleep, ["at": "300.0", "phaseBeforeSleep": "recording"]),
        (MeetingEventKind.didWake, ["at": "400.0", "sleptSeconds": "100.0", "action": "resume"]),
        timelineGap("mic", 290, 410, "captureRestarted"),
        // Sleep while paused stays a pause.
        (MeetingEventKind.paused, ["at": "500.0"]),
        (MeetingEventKind.systemWillSleep, ["at": "510.0", "phaseBeforeSleep": "paused"]),
        (MeetingEventKind.didWake, ["at": "560.0", "sleptSeconds": "50.0", "action": "resume"]),
        (MeetingEventKind.resumed, ["at": "600.0", "epoch": "4"]),
        timelineGap("mic", 500, 600, "paused"),
    ])
    let (gaps, markers) = try SessionTimelineReader.read(session: session)
    #expect(gaps == [
        TimelineGap(track: "mic", start: 100, end: 120, reason: .audioUnavailable),
        TimelineGap(track: "mic", start: 120, end: 180, reason: .paused),
        TimelineGap(track: "mic", start: 180, end: 200, reason: .audioUnavailable),
        TimelineGap(track: "mic", start: 290, end: 300, reason: .captureRestarted),
        TimelineGap(track: "mic", start: 300, end: 400, reason: .sleep),
        TimelineGap(track: "mic", start: 400, end: 410, reason: .captureRestarted),
        TimelineGap(track: "mic", start: 500, end: 600, reason: .paused),
    ])
    #expect(markers.isEmpty)
}

@Test func timelineReaderHandlesAnEmptyJournal() async throws {
    let temp = try TemporaryDirectory("timeline")
    defer { temp.remove() }
    let session = try await timelineSession(in: temp.url, [])
    let (gaps, markers) = try SessionTimelineReader.read(session: session)
    #expect(gaps.isEmpty && markers.isEmpty)
}
