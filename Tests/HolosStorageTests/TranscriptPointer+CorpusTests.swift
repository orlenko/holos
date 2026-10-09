import Foundation
import Testing
import HolosCore
@testable import HolosStorage
import HolosTestSupport

/// transcripts/current.json and transcripts/current.pending: a missing file is nil; a newer `schemaVersion` is
/// `unavailable` whatever else the file holds; version 0, a file that does not decode (empty, cut short, not JSON,
/// no `schemaVersion`), an invalid transcript ID, and a file over 64 KiB are `invalidInput`, with the decoding
/// failure in parentheses. These messages are what callers and users see, so they stay as they are.
@Test(arguments: [("transcripts/current.json", "current.json"), ("transcripts/current.pending", "current.pending")])
func transcriptPointerRefusesNewerAndDamagedFilesWithStableMessages(name: String, fileName: String) throws {
    let temp = try TemporaryDirectory("pointer-corpus")
    defer { temp.remove() }
    let session = temp.url.appendingPathComponent("\(UUID().uuidString).holos", isDirectory: true)
    let url = session.appendingPathComponent("transcripts/\(fileName)", isDirectory: false)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    func read() throws -> TranscriptPointer? {
        fileName == "current.json" ? try TranscriptPointer.read(session: session)
            : try TranscriptPointer.readPending(session: session)
    }
    #expect(VersionedFileCorpus.outcome(read) == "nil")

    let valid = try HolosJSON.encoder().encode(TranscriptPointer(transcriptID: "T1",
                                                                  updatedAt: TranscriptFixtures.date))
    let damaged = "invalidInput: \(name) is damaged or was not written by Voice is Local ("
    let newer = "unavailable: \(name) was written by a newer version of Voice is Local; update Voice is Local to read it."
    let expected: [String: String] = [
        "valid": "value",
        "empty": damaged + "…",
        "truncated": damaged + "…",
        "garbled": damaged + "…",
        "newer": newer,
        "newerOnlyVersion": newer,
        "versionZero": "invalidInput: \(name) has an unsupported schema version 0.",
        "missingVersion": damaged + "schemaVersion: missing).",
        "textVersion": damaged + "schemaVersion: …",
    ]
    for (kind, data) in try VersionedFileCorpus.cases(valid: valid, newerVersion: 2) {
        try data.write(to: url)
        let outcome = VersionedFileCorpus.outcome(read)
        #expect(VersionedFileCorpus.matches(outcome, try #require(expected[kind])), "\(kind): \(outcome)")
    }

    let currentID = try HolosJSON.encoder().encode(TranscriptPointer(transcriptID: "CURRENT"))
    try currentID.write(to: url)
    #expect(VersionedFileCorpus.outcome(read) == "invalidInput: \(name) names an invalid transcript ID.")

    try VersionedFileCorpus.writeOversized(valid, to: url, maxBytes: 64 << 10)
    #expect(VersionedFileCorpus.outcome(read) == "invalidInput: \(fileName) is larger than Voice is Local expects.")
    try FileManager.default.removeItem(at: url)
    try VersionedFileCorpus.writeOversized(valid, to: url, maxBytes: (64 << 10) - 1)
    #expect(VersionedFileCorpus.matches(VersionedFileCorpus.outcome(read), damaged + "…"), "a full-size file is read")
}
