import Foundation
import HolosStorage
import HolosTestSupport
import Testing

@Test func anAudioDeletionIsUnfinishedWhileItsMarkerAndAudioFolderAreBothThere() throws {
    let temp = try TemporaryDirectory("audio-unfinished")
    defer { temp.remove() }
    let session = temp.url.appendingPathComponent("S.holos", isDirectory: true)
    let audio = session.appendingPathComponent("audio", isDirectory: true)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    #expect(!SessionDeletion.audioDeletionUnfinished(session: session), "No marker: not deleted at all.")
    try Data("{}".utf8).write(to: SessionPaths.audioDeleted(session))
    #expect(SessionDeletion.audioDeletionUnfinished(session: session))
    try FileManager.default.removeItem(at: audio)
    #expect(!SessionDeletion.audioDeletionUnfinished(session: session), "Marker and no audio: finished.")
    try Data().write(to: audio)
    #expect(!SessionDeletion.audioDeletionUnfinished(session: session), "A file in place of the folder is not it.")
}
