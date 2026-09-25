import Foundation
import Testing
import HolosCore
@testable import HolosMeeting

// `voiceislocal record start --vocabulary-file` (docs/meeting-design.md §4.12): the file is deleted once read, but only
// after it was opened and verified as a regular file; any other path is refused and left untouched.

private func expectVocabularyInvalidInput(_ body: () throws -> Void) {
    let error = #expect(throws: HolosError.self) { try body() }
    guard case .invalidInput? = error else { Issue.record("Expected invalidInput, got \(String(describing: error))"); return }
}

private func vocabularyEntries(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

@Test func vocabularyFileIsReadThenDeleted() throws {
    let temp = try TemporaryDirectory("vocabulary")
    defer { temp.remove() }
    let url = temp.url.appendingPathComponent("holos-vocabulary.json")
    try HolosJSON.encoder().encode(MeetingVocabulary(strings: ["Maria Chen"])).write(to: url)
    #expect(try VocabularyFile.consume(url) == ["Maria Chen"])
    #expect(vocabularyEntries(temp.url).isEmpty)
    expectVocabularyInvalidInput { _ = try VocabularyFile.consume(url) }
}

@Test func vocabularyFileThatIsNotAVocabularyIsStillDeleted() throws {
    let temp = try TemporaryDirectory("vocabulary")
    defer { temp.remove() }
    let url = temp.url.appendingPathComponent("holos-vocabulary.json")
    try Data("{\"schemaVersion\": 2, \"strings\": []}".utf8).write(to: url)
    expectVocabularyInvalidInput { _ = try VocabularyFile.consume(url) }
    #expect(vocabularyEntries(temp.url).isEmpty)
}

@Test func vocabularyFileOptionNamingAFolderLeavesItAndItsFilesAlone() throws {
    let temp = try TemporaryDirectory("vocabulary")
    defer { temp.remove() }
    let documents = temp.url.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
    let kept = documents.appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: kept)
    expectVocabularyInvalidInput { _ = try VocabularyFile.consume(documents) }
    #expect(vocabularyEntries(temp.url) == ["Documents"])
    #expect(try Data(contentsOf: kept) == Data("keep".utf8))
}

@Test func vocabularyFileOptionNamingALinkLeavesTheLinkAndTargetAlone() throws {
    let temp = try TemporaryDirectory("vocabulary")
    defer { temp.remove() }
    let target = temp.url.appendingPathComponent("target.json")
    try HolosJSON.encoder().encode(MeetingVocabulary(strings: ["Maria Chen"])).write(to: target)
    let link = temp.url.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    expectVocabularyInvalidInput { _ = try VocabularyFile.consume(link) }
    #expect(vocabularyEntries(temp.url) == ["link.json", "target.json"])
}
