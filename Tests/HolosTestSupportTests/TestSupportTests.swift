import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSessionTestSupport
import HolosStorage
import HolosTestSupport
import Testing

// The shared helpers check what the helpers they replaced checked: a session's meeting.json is its own, a removed
// entry is gone even as a symbolic link, and a fixture folder is not already private.

@Test func aSessionBuiltWithMeetingInfoReadsItBackUnderTheArchivesID() async throws {
    let temp = try TemporaryDirectory("support")
    defer { temp.remove() }
    let info = MeetingInfo(sessionID: "set-by-the-caller", mode: .call, othersInRoom: true,
                           createdAt: TranscriptFixtures.date)
    let made = try await SessionFixtureBuilder(name: "Support", source: .system, meetingInfo: info)
        .finished(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: made.session)
    #expect(manifest.id == made.id)
    var expected = info
    expected.sessionID = made.id
    #expect(try SessionFiles.meetingInfo(session: made.session, manifest: manifest) == expected)
}

@Test func aDanglingSymbolicLinkIsAnEntryThatLeadsNowhere() throws {
    let temp = try TemporaryDirectory("support")
    defer { temp.remove() }
    let link = temp.url.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temp.url.appendingPathComponent("gone"))
    #expect(FileInspection.entryExists(link), "A removal that leaves a dangling link has not removed it.")
    #expect(!FileInspection.exists(link))
    #expect(!FileInspection.entryExists(temp.url.appendingPathComponent("gone")))
}

@Test func aTemporaryDirectoryIsMadeAsAnyNewFolderIsUnlessAskedToBePrivate() throws {
    let plain = try TemporaryDirectory("support")
    defer { plain.remove() }
    let reference = plain.url.appendingPathComponent("reference", isDirectory: true)
    try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: false)
    #expect(FileInspection.mode(plain.url) == FileInspection.mode(reference))
    let privateFolder = try TemporaryDirectory("support", permissions: 0o700)
    defer { privateFolder.remove() }
    #expect(FileInspection.mode(privateFolder.url) == 0o700)
}
