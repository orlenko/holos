import Foundation
import HolosCore
import HolosStorage
import HolosTestSupport
import Testing
@testable import HolosMeeting

@Test func aSavedMeetingWithoutJournalEventsShowsTheCurrentTranscriptAndFollowsNewRevisions() async throws {
    let temp = try TemporaryDirectory("saved-meeting-text")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Generated meeting", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    func transcript(_ text: String) -> Transcript {
        Transcript(source: "fixture", locale: "en-CA", backend: .speech,
                   segments: [.init(start: 0, end: 1, text: text, track: "mic")])
    }
    try await archive.saveTranscript(transcript("Generated first revision."), writeLegacyExports: false)
    var reader = LiveTranscriptReader(session: archive.directory)
    reader.read(includeVolatile: false, preferSaved: true)
    #expect(reader.finals.map(\.text) == ["Generated first revision."])
    try await archive.saveTranscript(transcript("Generated second revision."), writeLegacyExports: false)
    reader.read(includeVolatile: false, preferSaved: true)
    #expect(reader.finals.map(\.text) == ["Generated second revision."])
    reader.read(includeVolatile: false)
    #expect(reader.finals.isEmpty)
    try await archive.finish(status: ArchiveStatus.complete)
}

@Test func anUnreadableSavedReplacementKeepsTheLastSnapshotWithoutMixingJournalWords() async throws {
    let temp = try TemporaryDirectory("saved-meeting-unreadable")
    defer { temp.remove() }
    let archive = try SessionArchive.create(root: temp.url, name: "Generated meeting", source: .microphone,
                                            locale: "en-CA", backend: .speech)
    try await archive.recordEvent(kind: MeetingEventKind.transcriptFinalized,
                                  details: ["text": "Generated journal words.", "track": "mic"])
    let first = Transcript(source: "fixture", locale: "en-CA", backend: .speech,
                           segments: [.init(start: 0, end: 1, text: "Generated saved words.", track: "mic")])
    try await archive.saveTranscript(first, writeLegacyExports: false)
    var reader = LiveTranscriptReader(session: archive.directory)
    reader.read(includeVolatile: false, preferSaved: true)
    let revision = reader.revision
    let replacement = Transcript(source: "fixture", locale: "en-CA", backend: .speech,
                                 segments: [.init(start: 0, end: 1, text: "Generated replacement.", track: "mic")])
    try await archive.saveTranscript(replacement, writeLegacyExports: false)
    let path = SessionPaths.transcript(replacement.id, in: archive.directory)
    let original = try Data(contentsOf: path)
    try AtomicFile.write(Data("invalid".utf8), to: path)
    for _ in 0..<2 { reader.read(includeVolatile: false, preferSaved: true) }
    #expect(reader.finals == first.segments)
    #expect(reader.revision == revision)
    try AtomicFile.write(original, to: path)
    reader.read(includeVolatile: false, preferSaved: true)
    #expect(reader.finals == replacement.segments)
    reader.read(includeVolatile: false)
    #expect(reader.finals.map(\.text) == ["Generated journal words."])
    try await archive.finish(status: ArchiveStatus.complete)
}
