import Foundation
import Testing
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import HolosSessionTestSupport

/// How a transcript revision, meeting.json, and postprocess.json read in every shape they can be found in. The
/// expectations were written against `SessionFiles` before `VersionedFile` and must not change.
/// (Here rather than in HolosMeetingTests, which does not link the test support targets yet.)
enum CorpusSessionFile: CaseIterable, Sendable { case transcript, meetingInfo, postprocess }

@Test(arguments: CorpusSessionFile.allCases)
func sessionFilesReadAsTheyAlwaysHave(_ file: CorpusSessionFile) async throws {
    let temp = try TemporaryDirectory("session-files-corpus")
    defer { temp.remove() }
    let (session, id) = try await SessionFixtureBuilder(name: "Corpus").finished(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: session)
    let name: String, url: URL, maxBytes: Int, valid: Data, missing: String
    let read: () throws -> Any?
    switch file {
    case .transcript:
        name = "transcripts/T1.json"
        url = SessionPaths.transcript("T1", in: session)
        maxBytes = SessionFiles.maxTranscriptBytes
        let segment = TranscriptFixtures.segment(["Hello", "there"], track: "mic", start: 0)
        valid = try HolosJSON.encoder().encode(TranscriptFixtures.transcript([segment], id: "T1"))
        missing = "incomplete: transcripts/T1.json is missing."
        read = { try SessionFiles.transcript(id: "T1", session: session) }
    case .meetingInfo:
        name = "meeting.json"
        url = SessionPaths.meetingInfo(session)
        maxBytes = 1 << 20
        valid = try HolosJSON.encoder().encode(MeetingInfo(sessionID: id, mode: .call, othersInRoom: true,
                                                           createdAt: TranscriptFixtures.date))
        missing = "value"  // MeetingInfo.inferred
        read = { try SessionFiles.meetingInfo(session: session, manifest: manifest) }
    case .postprocess:
        name = "postprocess.json"
        url = SessionPaths.postprocess(session)
        maxBytes = 1 << 20
        valid = try HolosJSON.encoder().encode(PostProcessingRecord(
            sessionID: id, state: .succeeded, pid: 1, startedAt: TranscriptFixtures.date,
            updatedAt: TranscriptFixtures.date))
        missing = "nil"
        read = { try SessionFiles.postProcessingRecord(session: session) }
    }
    try? FileManager.default.removeItem(at: url)
    #expect(VersionedFileCorpus.outcome(read) == missing)

    let damaged = "invalidInput: \(name) is damaged or was not written by Voice is Local."
    let newer = "unavailable: \(name) was written by a newer version of Voice is Local; update Voice is Local to read it."
    let expected: [String: String] = [
        "valid": "value", "empty": damaged, "truncated": damaged, "garbled": damaged,
        "newer": newer, "newerOnlyVersion": newer,
        "versionZero": "invalidInput: \(name) has an unsupported schema version 0.",
        "missingVersion": damaged, "textVersion": damaged,
    ]
    for (kind, data) in try VersionedFileCorpus.cases(valid: valid, newerVersion: 2) {
        try data.write(to: url)
        let outcome = VersionedFileCorpus.outcome(read)
        #expect(VersionedFileCorpus.matches(outcome, try #require(expected[kind])), "\(kind): \(outcome)")
    }

    // A file of another revision or session is damage too, checked after the file decodes.
    var object = try #require(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
    object[file == .transcript ? "id" : "sessionID"] = "OTHER"
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    let foreign = switch file {
    case .transcript: "invalidInput: transcripts/T1.json does not describe transcript T1."
    case .meetingInfo: "invalidInput: meeting.json belongs to another session."
    case .postprocess: "invalidInput: postprocess.json belongs to another session."
    }
    #expect(VersionedFileCorpus.outcome(read) == foreign)

    try VersionedFileCorpus.writeOversized(valid, to: url, maxBytes: maxBytes)
    #expect(VersionedFileCorpus.outcome(read) == "invalidInput: \(url.lastPathComponent) is larger than Voice is Local expects.")
    // A file of exactly `maxBytes` is read (not for a transcript, whose limit is 256 MiB).
    if maxBytes <= 1 << 20 {
        try FileManager.default.removeItem(at: url)
        try VersionedFileCorpus.writeOversized(valid, to: url, maxBytes: maxBytes - 1)
        #expect(VersionedFileCorpus.outcome(read) == damaged)
    }
}
