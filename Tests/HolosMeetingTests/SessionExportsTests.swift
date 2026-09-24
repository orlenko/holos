import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// SessionExports (docs/meeting-design.md §4.11): generated, read-only exports; hand edits moved aside.

private func exportsSession(in root: URL, legacyExports: Bool = false, headRun: Bool = true) async throws -> URL {
    let transcript = SessionFixtures.transcript(SessionFixtures.alternatingSegments(track: "mic"))
    let session = try await SessionFixtures.makeSession(in: root, mode: .inPerson, transcript: transcript,
                                                        legacyExports: legacyExports)
    if headRun {
        try SessionFixtures.writeHeadRun(session: session, transcript: transcript,
                                         outputs: ["mic": SessionFixtures.alternatingOutput()])
    }
    return session
}

/// Names in exports/, sorted.
private func exportsListing(_ session: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: SessionPaths.exports(session).path)) ?? []).sorted()
}

private func exportsMakeWritableAndAppend(_ text: String, to url: URL) throws {
    #expect(chmod(url.path, 0o600) == 0)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

@Test func regenerateMovesHandEditedExportAside() async throws {
    let temp = try TemporaryDirectory("exports")
    defer { temp.remove() }
    let session = try await exportsSession(in: temp.url)
    let first = try SessionExports.regenerate(session: session)
    #expect(first.written.map(\.lastPathComponent) == ["transcript.md", "transcript.json", "transcript.txt"])
    #expect(first.movedAside.isEmpty)

    let markdown = SessionPaths.export("md", in: session)
    try exportsMakeWritableAndAppend("My own note.\n", to: markdown)
    let edited = try Data(contentsOf: markdown)
    let result = try SessionExports.regenerate(session: session)
    #expect(result.movedAside.count == 1)
    let aside = try #require(result.movedAside.first)
    #expect(aside.lastPathComponent.range(of: #"^edited-\d{8}-\d{6}\.md$"#, options: .regularExpression) != nil)
    #expect(try Data(contentsOf: aside) == edited)
    #expect(SessionFixtures.mode(aside) == 0o600)
    #expect(SessionFixtures.mode(markdown) == 0o400)
    #expect(!SessionFixtures.text(markdown).contains("My own note."))

    // Nothing else was edited: a further regeneration moves nothing.
    #expect(try SessionExports.regenerate(session: session).movedAside.isEmpty)

    // Two edits within one second get distinct names.
    try exportsMakeWritableAndAppend("Second.\n", to: markdown)
    let again = try SessionExports.regenerate(session: session)
    #expect(again.movedAside.count == 1)
    #expect(Set(exportsListing(session).filter { $0.hasPrefix("edited-") }).count == 2)
}

@Test func regenerateLockedRunsInsideTheLock() async throws {
    let temp = try TemporaryDirectory("exports")
    defer { temp.remove() }
    let session = try await exportsSession(in: temp.url)
    let result = try SessionArchive.withSpeakerLock(at: session) {
        try SessionExports.regenerateLocked(session: session)
    }
    #expect(result.written.count == 3)
    #expect(SessionFixtures.text(SessionPaths.export("txt", in: session)).hasPrefix("Speaker 1  00:00\n"))
}

@Test func legacyExportsAreReplacedWithoutMovingThemAside() async throws {
    let temp = try TemporaryDirectory("exports")
    defer { temp.remove() }
    let session = try await exportsSession(in: temp.url, legacyExports: true)
    #expect(exportsListing(session) == ["transcript.md", "transcript.txt"])
    let result = try SessionExports.regenerate(session: session)
    #expect(result.movedAside.isEmpty, "The speaker-less exports saveTranscript wrote are generated files.")
    #expect(exportsListing(session) == [".generated.json", "transcript.json", "transcript.md", "transcript.txt"])
    #expect(SessionFixtures.mode(SessionPaths.export("txt", in: session)) == 0o400)
}

@Test func unknownExportsAreMovedAsideBeforeTheFirstGeneration() async throws {
    let temp = try TemporaryDirectory("exports")
    defer { temp.remove() }
    let session = try await exportsSession(in: temp.url, legacyExports: true)
    try exportsMakeWritableAndAppend("Fixed a name by hand.\n", to: SessionPaths.export("txt", in: session))
    let result = try SessionExports.regenerate(session: session)
    #expect(result.movedAside.map(\.pathExtension) == ["txt"])
    #expect(SessionFixtures.text(try #require(result.movedAside.first)).contains("Fixed a name by hand."))
}

@Test func aFileWrittenBeforeACrashStillCountsAsGenerated() async throws {
    let temp = try TemporaryDirectory("exports")
    defer { temp.remove() }
    let session = try await exportsSession(in: temp.url)
    try SessionExports.regenerate(session: session)
    // A regeneration recorded its pending digests and replaced transcript.txt, then stopped.
    let text = SessionPaths.export("txt", in: session)
    let written = Data("Speaker 1  00:00\nnewer words\n\n".utf8)
    try AtomicFile.write(written, to: text, permissions: 0o400)
    var record = try AtomicFile.readJSON(SessionExports.GeneratedRecord.self,
                                         from: SessionPaths.generatedExports(session))
    record.pending = ["transcript.txt": SessionExports.sha256(written)]
    try AtomicFile.writeJSON(record, to: SessionPaths.generatedExports(session))
    #expect(try SessionExports.regenerate(session: session).movedAside.isEmpty)
}

@Test func generatedRecordFromANewerHolosIsRefused() async throws {
    let temp = try TemporaryDirectory("exports")
    defer { temp.remove() }
    let session = try await exportsSession(in: temp.url)
    try SessionExports.regenerate(session: session)
    var record = try AtomicFile.readJSON(SessionExports.GeneratedRecord.self,
                                         from: SessionPaths.generatedExports(session))
    record.schemaVersion = 2
    try AtomicFile.writeJSON(record, to: SessionPaths.generatedExports(session))
    let before = SessionFixtures.files(in: SessionPaths.exports(session))
    #expect(throws: HolosError.self) { try SessionExports.regenerate(session: session) }
    #expect(SessionFixtures.files(in: SessionPaths.exports(session)) == before)
}

@Test func renderReturnsOneFormatWithoutWriting() async throws {
    let temp = try TemporaryDirectory("exports")
    defer { temp.remove() }
    let session = try await exportsSession(in: temp.url)
    let data = try SessionExports.render(.txt, session: session)
    #expect(String(decoding: data, as: UTF8.self).hasPrefix("Speaker 1  00:00\n"))
    #expect(exportsListing(session).isEmpty)
    let json = try JSONSerialization.jsonObject(with: try SessionExports.render(.json, session: session))
    #expect((json as? [String: Any])?["format"] as? String == "holos-transcript")
}
