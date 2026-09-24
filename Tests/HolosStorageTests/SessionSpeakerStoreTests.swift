import Foundation
import Testing
import HolosCore
@testable import HolosStorage

private let storeDate = Date(timeIntervalSince1970: 1_790_000_000)

private func storeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-speakers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A finished session and its ID.
private func storeMakeSession(in root: URL) async throws -> (session: URL, id: String) {
    let archive = try SessionArchive.create(root: root, name: "Speakers", source: .microphoneAndSystem,
                                            locale: "en-CA", backend: .speech)
    try await archive.finish(status: ArchiveStatus.complete)
    return (archive.directory, archive.id)
}

private func storeRun(sessionID: String, id: String = UUID().uuidString) -> DiarizationRun {
    DiarizationRun(
        id: id, sessionID: sessionID, createdAt: storeDate, transcriptID: UUID().uuidString, engine: nil,
        alignment: AlignmentInfo(version: 1, parameters: .v1, trackOffsets: ["system": 0.06]),
        tracks: [
            TrackDiarization(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
            TrackDiarization(track: "system", policy: .diarized,
                             segments: [DiarizationSegment(track: "system", clusterID: "system:S1", start: 1, end: 4)],
                             clusters: [ClusterSummary(clusterID: "system:S1", track: "system", speechSeconds: 3)]),
        ],
        speakers: [
            SessionSpeaker(id: "mic:me", ordinal: 1, displayName: "Me", provenance: .channelAssumption),
            SessionSpeaker(id: "system:S1", ordinal: 2, provenance: .diarizer, clusterIDs: ["system:S1"]),
        ],
        turns: [
            SpeakerTurn(id: "T1", track: "system", start: 1, end: 4, speakerID: "system:S1", clusterID: "system:S1",
                        spans: [WordSpan(segmentID: "SEG-1", first: 0, end: 5)], assignmentScore: 0.9,
                        timing: .measured),
        ])
}

private func storeEdit(runID: String, name: String) -> SpeakerEdit {
    SpeakerEdit(baseRunID: runID, at: storeDate, source: "cli",
                action: .rename(speakerID: "system:S1", name: name), expected: "")
}

private func storeMode(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
}

private func storeAppendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

private func isInvalidInput(_ error: HolosError?) -> Bool {
    if case .invalidInput? = error { return true }
    return false
}

@Test func runRoundTripsAndRefusesOverwrite() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, sessionID) = try await storeMakeSession(in: root)
    #expect(try SessionSpeakerStore.runIDs(session: session) == [])
    let run = storeRun(sessionID: sessionID)
    try SessionArchive.withSpeakerLock(at: session) { try SessionSpeakerStore.writeRun(run, session: session) }
    #expect(try SessionSpeakerStore.readRun(id: run.id, session: session) == run)

    let error = #expect(throws: HolosError.self) {
        try SessionArchive.withSpeakerLock(at: session) { try SessionSpeakerStore.writeRun(run, session: session) }
    }
    #expect(isInvalidInput(error))
    #expect(try storeMode(SessionPaths.run(run.id, in: session)) == 0o600)
    #expect(try storeMode(SessionPaths.runs(session)) == 0o700)
    #expect(try storeMode(session.appendingPathComponent("speakers")) == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: SessionPaths.runs(session).path) == ["\(run.id).json"])

    let second = storeRun(sessionID: sessionID, id: "0-second-run")
    try SessionSpeakerStore.writeRun(second, session: session)
    #expect(try SessionSpeakerStore.runIDs(session: session) == ["0-second-run", run.id].sorted())

    let foreign = storeRun(sessionID: UUID().uuidString)
    #expect(isInvalidInput(#expect(throws: HolosError.self) { try SessionSpeakerStore.writeRun(foreign, session: session) }))
    let traversal = storeRun(sessionID: sessionID, id: "../escape")
    #expect(isInvalidInput(#expect(throws: HolosError.self) { try SessionSpeakerStore.writeRun(traversal, session: session) }))
    #expect(throws: HolosError.self) { try SessionSpeakerStore.readRun(id: "../escape", session: session) }
    #expect(throws: HolosError.self) { try SessionSpeakerStore.readRun(id: UUID().uuidString, session: session) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.json").path))
}

@Test func headRefusesUnknownRun() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, sessionID) = try await storeMakeSession(in: root)
    #expect(try SessionSpeakerStore.readHead(session: session) == nil)
    let missing = SpeakerHead(runID: UUID().uuidString, updatedAt: storeDate)
    let error = #expect(throws: HolosError.self) { try SessionSpeakerStore.writeHead(missing, session: session) }
    #expect(isInvalidInput(error))
    #expect(try SessionSpeakerStore.readHead(session: session) == nil)

    let run = storeRun(sessionID: sessionID)
    let head = SpeakerHead(runID: run.id, updatedAt: storeDate)
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(head, session: session)
    }
    #expect(try SessionSpeakerStore.readHead(session: session) == head)
    #expect(try storeMode(SessionPaths.head(session)) == 0o600)
}

@Test func editsAppendAndReadInOrder() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, _) = try await storeMakeSession(in: root)
    #expect(try SessionSpeakerStore.readEdits(session: session) == EditJournal())
    let runID = UUID().uuidString
    let e1 = storeEdit(runID: runID, name: "Maria")
    let batch = UUID().uuidString
    var e2 = storeEdit(runID: runID, name: "Jim")
    e2.batchID = batch
    var e3 = SpeakerEdit(baseRunID: runID, at: storeDate, source: "app",
                         action: .splitTurn(turnID: "T1", at: WordRef(segmentID: "SEG-1", word: 2)))
    e3.batchID = batch
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.appendEdits([e1], session: session)
        try SessionSpeakerStore.appendEdits([e2, e3], session: session)
        try SessionSpeakerStore.appendEdits([], session: session)
    }
    let journal = try SessionSpeakerStore.readEdits(session: session)
    #expect(journal.edits == [e1, e2, e3])
    #expect(!journal.tornTail)
    #expect(journal.unreadableLines == 0)
    #expect(try storeMode(SessionPaths.edits(session)) == 0o600)
    let lines = try String(contentsOf: SessionPaths.edits(session), encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 3)

    var invalid = storeEdit(runID: runID, name: "X")
    invalid.id = "not/valid"
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionSpeakerStore.appendEdits([e1, invalid], session: session)
    }))
    #expect(try SessionSpeakerStore.readEdits(session: session).edits == [e1, e2, e3])
}

@Test func tornTailIsReportedThenRepairedOnAppend() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, _) = try await storeMakeSession(in: root)
    let runID = UUID().uuidString
    let e1 = storeEdit(runID: runID, name: "One")
    let e2 = storeEdit(runID: runID, name: "Two")
    try SessionSpeakerStore.appendEdits([e1, e2], session: session)
    let journalURL = SessionPaths.edits(session)
    try storeAppendRaw(#"{"action":{"rename":{"na"#, to: journalURL)
    let torn = try Data(contentsOf: journalURL)

    let read = try SessionSpeakerStore.readEdits(session: session)
    #expect(read.edits == [e1, e2])
    #expect(read.tornTail)
    #expect(read.unreadableLines == 0)
    #expect(try Data(contentsOf: journalURL) == torn)

    let e4 = storeEdit(runID: runID, name: "Four")
    try SessionArchive.withSpeakerLock(at: session) { try SessionSpeakerStore.appendEdits([e4], session: session) }
    let speakers = session.appendingPathComponent("speakers")
    let backups = try FileManager.default.contentsOfDirectory(atPath: speakers.path)
        .filter { $0.hasPrefix("edits.torn-") && $0.hasSuffix(".jsonl") }
    #expect(backups.count == 1)
    if let backup = backups.first {
        #expect(try Data(contentsOf: speakers.appendingPathComponent(backup)) == torn)
        #expect(try storeMode(speakers.appendingPathComponent(backup)) == 0o600)
    }
    let repaired = try SessionSpeakerStore.readEdits(session: session)
    #expect(repaired.edits == [e1, e2, e4])
    #expect(!repaired.tornTail)
    #expect(repaired.unreadableLines == 0)
}

@Test func newerSchemaLineIsSkippedAndCounted() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, _) = try await storeMakeSession(in: root)
    let runID = UUID().uuidString
    let e1 = storeEdit(runID: runID, name: "One")
    try SessionSpeakerStore.appendEdits([e1], session: session)
    var newer = storeEdit(runID: runID, name: "From the future")
    newer.schemaVersion = 2
    try storeAppendRaw(String(decoding: try HolosJSON.line(newer), as: UTF8.self), to: SessionPaths.edits(session))
    let e3 = storeEdit(runID: runID, name: "Three")
    try SessionSpeakerStore.appendEdits([e3], session: session)

    let journal = try SessionSpeakerStore.readEdits(session: session)
    #expect(journal.edits == [e1, e3])
    #expect(journal.unreadableLines == 1)
    #expect(!journal.tornTail)

    try storeAppendRaw("not json\n", to: SessionPaths.edits(session))
    #expect(try SessionSpeakerStore.readEdits(session: session).unreadableLines == 2)
    // This build writes only version 1.
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionSpeakerStore.appendEdits([newer], session: session)
    }))
}

@Test func voiceDataIsPrivateAndNotBackedUp() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, sessionID) = try await storeMakeSession(in: root)
    let runID = UUID().uuidString
    #expect(try SessionSpeakerStore.readVoiceData(runID: runID, session: session) == nil)
    let voice = SessionVoiceData(
        runID: runID, sessionID: sessionID, createdAt: storeDate,
        embeddingModel: EmbeddingModelID(id: "model", revision: "rev"),
        centroids: ["system:S1": FloatVector([0.25, -1, 3.5])],
        turnEmbeddings: [TurnEmbedding(turnID: "T1", speechSeconds: 3, vector: FloatVector([1, 0, -0.5]))])
    try SessionArchive.withSpeakerLock(at: session) { try SessionSpeakerStore.writeVoiceData(voice, session: session) }
    #expect(try SessionSpeakerStore.readVoiceData(runID: runID, session: session) == voice)

    let folder = SessionPaths.voiceDirectory(session)
    #expect(try storeMode(SessionPaths.voiceData(runID, in: session)) == 0o600)
    #expect(try storeMode(folder) == 0o700)
    let values = try URL(fileURLWithPath: folder.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)

    let foreign = SessionVoiceData(runID: runID, sessionID: UUID().uuidString, createdAt: storeDate,
                                   embeddingModel: voice.embeddingModel, centroids: [:], turnEmbeddings: [])
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionSpeakerStore.writeVoiceData(foreign, session: session)
    }))

    try SessionArchive.withSpeakerLock(at: session) { try SessionSpeakerStore.deleteVoiceData(session: session) }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try SessionSpeakerStore.readVoiceData(runID: runID, session: session) == nil)
    try SessionSpeakerStore.deleteVoiceData(session: session)
}

@Test func recognitionIsReplacedAndReadBack() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, _) = try await storeMakeSession(in: root)
    let runID = UUID().uuidString
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session) == nil)
    let thresholds = RecognitionThresholds(likelyMaxDistance: 0, likelyMinMargin: 0.1, possibleMaxDistance: 0.4,
                                           minSampleSeconds: 20)
    var result = RecognitionResult(runID: runID, createdAt: storeDate,
                                   embeddingModel: EmbeddingModelID(id: "model", revision: "rev"),
                                   thresholds: thresholds,
                                   matches: [SpeakerMatch(speakerID: "system:S1", profileID: "P1", profileName: "Jim",
                                                          distance: 0.2, tier: .possible)])
    try SessionSpeakerStore.writeRecognition(result, session: session)
    result.matches = []
    try SessionSpeakerStore.writeRecognition(result, session: session)
    #expect(try SessionSpeakerStore.readRecognition(runID: runID, session: session) == result)
    #expect(try storeMode(SessionPaths.recognition(runID, in: session)) == 0o600)
}

@Test func runFromANewerHolosIsRefused() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, sessionID) = try await storeMakeSession(in: root)
    var run = storeRun(sessionID: sessionID)
    run.schemaVersion = 2
    #expect(isInvalidInput(#expect(throws: HolosError.self) { try SessionSpeakerStore.writeRun(run, session: session) }))
    try AtomicFile.ensurePrivateDirectory(session.appendingPathComponent("speakers"))
    try AtomicFile.ensurePrivateDirectory(SessionPaths.runs(session))
    try AtomicFile.writeJSON(run, to: SessionPaths.run(run.id, in: session))
    let error = #expect(throws: HolosError.self) { try SessionSpeakerStore.readRun(id: run.id, session: session) }
    guard case .unavailable? = error else { Issue.record("Expected unavailable, got \(String(describing: error))"); return }
}

private func isUnavailable(_ error: HolosError?) -> Bool {
    if case .unavailable? = error { return true }
    return false
}

/// Encodes `value`, lets `change` edit the JSON object, and writes the result to `url`.
private func storeWriteEdited<T: Encodable>(_ value: T, to url: URL,
                                            _ change: (inout [String: Any]) -> Void) throws {
    var object = try #require(try JSONSerialization.jsonObject(with: HolosJSON.encoder().encode(value)) as? [String: Any])
    change(&object)
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
}

@Test func newerRunWithAnUnknownCaseIsRefusedAsNewer() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, sessionID) = try await storeMakeSession(in: root)
    let run = storeRun(sessionID: sessionID)
    try AtomicFile.ensurePrivateDirectory(session.appendingPathComponent("speakers"))
    try AtomicFile.ensurePrivateDirectory(SessionPaths.runs(session))
    let url = SessionPaths.run(run.id, in: session)
    func withUnknownProvenance(version: Int) -> (inout [String: Any]) -> Void {
        { object in
            object["schemaVersion"] = version
            var speakers = object["speakers"] as? [[String: Any]] ?? []
            speakers[0]["provenance"] = ["importedFromOtter": [String: Any]()]
            object["speakers"] = speakers
        }
    }

    // A version 2 run may use enum cases this build does not know: that means "update Holos".
    try storeWriteEdited(run, to: url, withUnknownProvenance(version: 2))
    #expect(isUnavailable(#expect(throws: HolosError.self) {
        try SessionSpeakerStore.readRun(id: run.id, session: session)
    }))
    // The same content claiming version 1 is damaged.
    try storeWriteEdited(run, to: url, withUnknownProvenance(version: 1))
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionSpeakerStore.readRun(id: run.id, session: session)
    }))
}

@Test func newerRecognitionHeadAndVoiceDataAreRefusedAsNewer() async throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (session, sessionID) = try await storeMakeSession(in: root)
    let runID = UUID().uuidString
    let thresholds = RecognitionThresholds(likelyMaxDistance: 0, likelyMinMargin: 0.1, possibleMaxDistance: 0.4,
                                           minSampleSeconds: 20)
    let result = RecognitionResult(runID: runID, createdAt: storeDate,
                                   embeddingModel: EmbeddingModelID(id: "model", revision: "rev"),
                                   thresholds: thresholds,
                                   matches: [SpeakerMatch(speakerID: "system:S1", profileID: "P1", profileName: "Jim",
                                                          distance: 0.2, tier: .possible)])
    try SessionSpeakerStore.writeRecognition(result, session: session)
    try storeWriteEdited(result, to: SessionPaths.recognition(runID, in: session)) { object in
        object["schemaVersion"] = 2
        var matches = object["matches"] as? [[String: Any]] ?? []
        matches[0]["tier"] = "certain"
        object["matches"] = matches
    }
    #expect(isUnavailable(#expect(throws: HolosError.self) {
        try SessionSpeakerStore.readRecognition(runID: runID, session: session)
    }))

    // A version 2 head that renamed a field this build requires.
    try AtomicFile.ensurePrivateDirectory(SessionPaths.speakers(session))
    try storeWriteEdited(SpeakerHead(runID: runID, updatedAt: storeDate), to: SessionPaths.head(session)) { object in
        object["schemaVersion"] = 2
        object["currentRun"] = object.removeValue(forKey: "runID")
    }
    #expect(isUnavailable(#expect(throws: HolosError.self) { try SessionSpeakerStore.readHead(session: session) }))

    let voice = SessionVoiceData(runID: runID, sessionID: sessionID, createdAt: storeDate,
                                 embeddingModel: EmbeddingModelID(id: "model", revision: "rev"),
                                 centroids: [:], turnEmbeddings: [])
    try SessionSpeakerStore.writeVoiceData(voice, session: session)
    try storeWriteEdited(voice, to: SessionPaths.voiceData(runID, in: session)) { object in
        object["schemaVersion"] = 3
        object["centroids"] = "moved elsewhere"
    }
    #expect(isUnavailable(#expect(throws: HolosError.self) {
        try SessionSpeakerStore.readVoiceData(runID: runID, session: session)
    }))

    // A file with no readable schemaVersion is damaged, not newer.
    try Data("{}".utf8).write(to: SessionPaths.head(session))
    #expect(isInvalidInput(#expect(throws: HolosError.self) { try SessionSpeakerStore.readHead(session: session) }))
}

@Test func speakerLockRefusesAFolderThatIsNotASession() throws {
    let root = try storeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(isInvalidInput(#expect(throws: HolosError.self) { try SessionArchive.withSpeakerLock(at: root) {} }))
    #expect(isInvalidInput(#expect(throws: HolosError.self) {
        try SessionArchive.acquireProcessingLease(at: root, retry: .zero)
    }))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}
