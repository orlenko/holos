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
