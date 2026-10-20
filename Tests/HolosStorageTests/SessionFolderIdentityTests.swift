import Foundation
import HolosCore
import HolosSessionTestSupport
import HolosStorage
import HolosTestSupport
import Testing

@Test func namingWritesPreserveMetadataAndCommitNameWithSource() async throws {
    let temp = try TemporaryDirectory("naming")
    defer { temp.remove() }
    let (session, id) = try await SessionFixtureBuilder().finished(in: temp.url)
    let meeting = MeetingInfo(sessionID: id, mode: .call, othersInRoom: true, nameSource: .default)
    var json = try #require(try JSONSerialization.jsonObject(with: HolosJSON.encoder().encode(meeting))
        as? [String: Any])
    json["extraField"] = "kept"
    try AtomicFile.write(try JSONSerialization.data(withJSONObject: json), to: SessionPaths.meetingInfo(session))
    let identity = try SessionFolderIdentity(at: session)
    try await SessionArchive.withVerifiedSpeakerLockAsync(at: session, matching: identity) {
        try SessionNamingStore.writeLocked(name: "Generated new name", source: .user, session: session,
                                           meeting: meeting, identity: identity)
    }
    let saved = try #require(try JSONSerialization.jsonObject(
        with: Data(contentsOf: SessionPaths.meetingInfo(session))) as? [String: Any])
    #expect(saved["name"] as? String == "Generated new name")
    #expect(saved["nameSource"] as? String == "user")
    #expect(saved["mode"] as? String == "call")
    #expect(saved["extraField"] as? String == "kept")
}

@Test func verifiedSpeakerLockRejectsAReplacementWithTheSameSessionID() async throws {
    let temp = try TemporaryDirectory("naming-identity")
    defer { temp.remove() }
    let session = try await SessionFixtureBuilder().finished(in: temp.url).session
    let identity = try SessionFolderIdentity(at: session)
    let moved = temp.url.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: session, to: moved)
    try FileManager.default.copyItem(at: moved, to: session)
    await #expect(throws: HolosError.self) {
        try await SessionArchive.withVerifiedSpeakerLockAsync(at: session, matching: identity) {
            Issue.record("A replacement folder must never reach the write body.")
        }
    }
}

@Test func verifiedSpeakerLockSharesTheExistingLockAndReleasesAfterFailure() async throws {
    let temp = try TemporaryDirectory("naming-lock")
    defer { temp.remove() }
    let session = try await SessionFixtureBuilder().finished(in: temp.url).session
    let identity = try SessionFolderIdentity(at: session)
    struct Stopped: Error {}
    await #expect(throws: Stopped.self) {
        try await SessionArchive.withVerifiedSpeakerLockAsync(at: session, matching: identity) {
            #expect(throws: HolosError.self) {
                try SessionArchive.withSpeakerLock(at: session, timeout: .zero) {}
            }
            throw Stopped()
        }
    }
    try SessionArchive.withSpeakerLock(at: session, timeout: .zero) {}
}
