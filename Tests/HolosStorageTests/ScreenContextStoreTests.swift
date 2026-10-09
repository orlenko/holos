import Darwin
import Foundation
import HolosCore
import HolosStorage
import HolosTestSupport
import HolosSessionTestSupport
import Testing

private func screenStoreFixture() async throws -> (URL, SessionArchive) {
    let root = try TemporaryDirectory("screen-store").url
    let archive = try SessionFixtureBuilder(name: "Synthetic slides").create(in: root)
    try await archive.finish(status: ArchiveStatus.audioOnly)
    return (root, archive)
}

@Test func screenContextEvidenceIsTimedBoundedAndNeverAddsVocabulary() {
    let line = ScreenTextLine(text: "ExampleTool Cloud", x: 0, y: 0, width: 0.5, height: 0.1, confidence: 0.9)
    let frame = ScreenKeyframe(start: 10, end: 20, lines: [line])
    let record = ScreenContextRecord(sessionID: "id", frames: [frame])
    #expect(record.words(from: 12, to: 13) == ["ExampleTool Cloud"])
    #expect(record.words(from: 0, to: 9).isEmpty)
    #expect(record.words(from: 21, to: 25).isEmpty)
    #expect(record.words(from: .nan, to: 25).isEmpty)
    #expect(record.words(from: 12, to: 13, maximumCharacters: 4).isEmpty)
    #expect(record.candidates(excluding: ["cloud"], from: 12, to: 13) == ["ExampleTool"])
}

@Test func screenContextIsPrivateAndDeletedWithAudio() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let frame = ScreenKeyframe(start: 1, end: 2, lines: [])
    let record = ScreenContextRecord(sessionID: archive.id, frames: [frame])
    try ScreenContextStore.write(record, session: archive.directory)
    let image = try ScreenContextStore.image(frame.id, session: archive.directory)
    try AtomicFile.create(Data([1, 2]), at: image)
    #expect(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) == record)
    var info = stat()
    #expect(lstat(ScreenContextStore.directory(archive.directory).path, &info) == 0 && info.st_mode & 0o777 == 0o700)
    #expect(lstat(image.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    let lease = try SessionArchive.acquireProcessingLease(at: archive.directory)
    defer { lease.release() }
    try SessionDeletion.deleteAudio(session: archive.directory, lease: lease)
    #expect(!FileManager.default.fileExists(atPath: ScreenContextStore.directory(archive.directory).path))
    #expect(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) == nil)
    #expect(throws: (any Error).self) {
        try ScreenContextStore.update(session: archive.directory, sessionID: archive.id) { $0.frames = [frame] }
    }
    #expect(!FileManager.default.fileExists(atPath: ScreenContextStore.directory(archive.directory).path),
            "Late capture/OCR callbacks cannot recreate deleted screen evidence.")
}

@Test func screenContextRefusesWrongOwnerInvalidTimesAndPathTraversal() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try ScreenContextStore.write(ScreenContextRecord(sessionID: "other"), session: archive.directory)
    #expect(throws: (any Error).self) { try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) }
    try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id,
        frames: [ScreenKeyframe(start: 3, end: 2)]), session: archive.directory)
    #expect(throws: (any Error).self) { try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) }
    #expect(throws: (any Error).self) { try ScreenContextStore.image("../../outside", session: archive.directory) }
}

@Test func screenContextNeverFollowsPlantedDirectoryLink() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: ScreenContextStore.directory(archive.directory), withDestinationURL: outside)
    #expect(throws: (any Error).self) {
        try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id), session: archive.directory)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func screenContextReviewKeepsOCRWhenCandidateWordListCannotBeRead() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let line = ScreenTextLine(text: "ExampleTool", x: 0, y: 0, width: 0.5, height: 0.1, confidence: 0.9)
    let record = ScreenContextRecord(sessionID: archive.id, frames: [.init(start: 1, end: 2, lines: [line])])
    try ScreenContextStore.write(record, session: archive.directory)
    let result = try ScreenContextStore.readForReview(session: archive.directory, sessionID: archive.id) {
        throw HolosError.unavailable("Synthetic word list failure.")
    }
    #expect(result.record == record && result.known == nil)
}

@Test(.timeLimit(.minutes(1)))
func aContextSavedBeforeDisplaysWereNamedReadsAsTheMainDisplay() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString
    let legacy = """
        {"schemaVersion":1,"sessionID":"\(archive.id)","imageBytes":12,
         "frames":[{"id":"\(id)","start":1,"end":4,"lines":[]}]}
        """
    try AtomicFile.ensurePrivateDirectory(ScreenContextStore.directory(archive.directory))
    try AtomicFile.create(Data(legacy.utf8), at: ScreenContextStore.manifest(archive.directory))
    let record = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    let frame = try #require(record.frames.first)
    #expect(frame.display == nil && frame.source.isMain && frame.source.number == 1)
    #expect(record.displays.count == 1 && record.displayLabel(frame) == nil, "one display: nothing extra in Review")
}

@Test(.timeLimit(.minutes(1)))
func displaysOverlapInTimeButEachDisplaysKeyframesFollowOneAnother() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let main = ScreenDisplay(id: 4, number: 1, isMain: true), side = ScreenDisplay(id: 7, number: 2, isMain: false)
    let overlapping = ScreenContextRecord(sessionID: archive.id, frames: [
        ScreenKeyframe(start: 1, end: 10, display: main), ScreenKeyframe(start: 2, end: 5, display: side),
        ScreenKeyframe(start: 6, end: 8, display: side), ScreenKeyframe(start: 10, end: 12, display: main),
    ])
    try ScreenContextStore.write(overlapping, session: archive.directory)
    let read = try #require(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id))
    #expect(read == overlapping)
    #expect(read.displays == [main, side])
    #expect(read.frames.map { read.displayLabel($0) } == ["Main display", "Display 2", "Display 2", "Main display"])
    #expect(read.frames.filter { $0.start <= 3 && $0.end >= 3 }.count == 2)
    #expect(read.insertionIndex(start: 6) == 3 && read.insertionIndex(start: 0) == 0 && read.insertionIndex(start: 99) == 4)

    // One display's own keyframes may not overlap, and a display number stays within bounds.
    for frames in [[ScreenKeyframe(start: 1, end: 5, display: side), ScreenKeyframe(start: 4, end: 6, display: side)],
                   [ScreenKeyframe(start: 1, end: 5, display: ScreenDisplay(id: 9, number: 0, isMain: false))],
                   [ScreenKeyframe(start: 1, end: 5, display: ScreenDisplay(id: 9, number: 65, isMain: false))]] {
        try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: frames), session: archive.directory)
        #expect(throws: (any Error).self) { try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) }
    }
}

@Test func reviewLabelsTellTwoMainDisplaysApart() {
    let first = ScreenDisplay(id: 1, number: 1, isMain: true), second = ScreenDisplay(id: 2, number: 2, isMain: true)
    let record = ScreenContextRecord(sessionID: "id", frames: [ScreenKeyframe(start: 0, end: 1, display: first),
                                                               ScreenKeyframe(start: 0, end: 1, display: second)])
    #expect(record.frames.map { record.displayLabel($0) } == ["Display 1, main", "Display 2, main"])
    #expect(record.displayLabels == ["Display 1, main", "Display 2, main"])
    let single = ScreenContextRecord(sessionID: "id", frames: [ScreenKeyframe(start: 0, end: 1, display: second),
                                                               ScreenKeyframe(start: 2, end: 3, display: second)])
    #expect(single.frames.map { single.displayLabel($0) } == [nil, nil] && single.displayLabels == [nil, nil])
}

@Test func aMainDisplayThatChangesAcrossAPauseIsLabelledApart() {
    // A main and B beside it; after a pause B is the main display.
    let aMain = ScreenDisplay(id: 1, number: 1, isMain: true), b = ScreenDisplay(id: 2, number: 2, isMain: false)
    let bMain = ScreenDisplay(id: 2, number: 2, isMain: true), aSide = ScreenDisplay(id: 1, number: 1, isMain: false)
    let record = ScreenContextRecord(sessionID: "id", frames: [
        ScreenKeyframe(start: 0, end: 5, display: aMain), ScreenKeyframe(start: 1, end: 5, display: b),
        ScreenKeyframe(start: 10, end: 15, display: aSide), ScreenKeyframe(start: 10, end: 15, display: bMain),
    ])
    let labels = ["Display 1, main", "Display 2", "Display 1", "Display 2, main"]
    #expect(record.frames.map { record.displayLabel($0) } == labels && record.displayLabels == labels)
}

@Test(.timeLimit(.minutes(1)))
func keyframeSizesAreBoundedOnRead() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let display = ScreenDisplay(id: 1, number: 1, isMain: true)
    for (bytes, valid) in [(512, true), (ScreenContextStore.maximumImageBytes + 1, false), (-1, false)] {
        let frame = ScreenKeyframe(start: 1, end: 2, display: display, bytes: bytes)
        try ScreenContextStore.write(ScreenContextRecord(sessionID: archive.id, frames: [frame]), session: archive.directory)
        let read = try? ScreenContextStore.read(session: archive.directory, sessionID: archive.id)
        #expect((read?.frames.first?.bytes == bytes) == valid)
    }
}

/// A record whose keyframes name their display or size is written as version 2, which a build from before displays
/// were named refuses (and leaves alone) rather than rewriting it without those fields; one without them stays 1.
@Test(.timeLimit(.minutes(1)))
func recordsThatNameDisplaysAreWrittenAsVersionTwo() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    func written() throws -> Int? {
        let data = try #require(try AtomicFile.readIfPresent(ScreenContextStore.manifest(archive.directory), maxBytes: 1 << 20))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
    }
    let legacy = ScreenContextRecord(sessionID: archive.id, frames: [ScreenKeyframe(start: 1, end: 2, lines: [])])
    try ScreenContextStore.write(legacy, session: archive.directory)
    #expect(try written() == 1)
    #expect(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) == legacy)
    // `--screen main` after the main display changed: two displays that never overlap.
    let named = ScreenContextRecord(sessionID: archive.id, frames: [
        ScreenKeyframe(start: 1, end: 2, display: ScreenDisplay(id: 4, number: 1, isMain: true), bytes: 10),
        ScreenKeyframe(start: 3, end: 4, display: ScreenDisplay(id: 7, number: 2, isMain: true), bytes: 10),
    ])
    try ScreenContextStore.write(named, session: archive.directory)
    #expect(try written() == 2)
    #expect(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) == named)
    // A version this build does not know is refused, not read as damaged or rewritten.
    let newer = Data("{\"schemaVersion\":3,\"sessionID\":\"\(archive.id)\",\"frames\":[]}".utf8)
    try FileManager.default.removeItem(at: ScreenContextStore.manifest(archive.directory))
    try AtomicFile.create(newer, at: ScreenContextStore.manifest(archive.directory))
    #expect(throws: (any Error).self) { try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) }
    #expect(throws: (any Error).self) {
        try ScreenContextStore.update(session: archive.directory, sessionID: archive.id) { $0.ocrID = "x" }
    }
    #expect(try AtomicFile.readIfPresent(ScreenContextStore.manifest(archive.directory), maxBytes: 1 << 20) == newer)
}

@Test(.timeLimit(.minutes(1)))
func aContextWithoutAReadableVersionIsRefused() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try AtomicFile.ensurePrivateDirectory(ScreenContextStore.directory(archive.directory))
    for version in ["", "\"schemaVersion\":\"2\",", "\"schemaVersion\":0,"] {
        let json = "{\(version)\"sessionID\":\"\(archive.id)\",\"frames\":[]}"
        try? FileManager.default.removeItem(at: ScreenContextStore.manifest(archive.directory))
        try AtomicFile.create(Data(json.utf8), at: ScreenContextStore.manifest(archive.directory))
        #expect(throws: (any Error).self, "\(version)") {
            try ScreenContextStore.read(session: archive.directory, sessionID: archive.id)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func keyframesOfAllDisplaysAreListedInStartOrder() async throws {
    let (root, archive) = try await screenStoreFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = ScreenDisplay(id: 4, number: 1, isMain: true), b = ScreenDisplay(id: 7, number: 2, isMain: false)
    let backwards = ScreenContextRecord(sessionID: archive.id, frames: [
        ScreenKeyframe(start: 10, end: 12, display: a), ScreenKeyframe(start: 1, end: 3, display: b),
    ])
    try ScreenContextStore.write(backwards, session: archive.directory)
    #expect(throws: (any Error).self, "B at 1 s listed after A at 10 s") {
        try ScreenContextStore.read(session: archive.directory, sessionID: archive.id)
    }
    // Overlapping intervals of different displays stay fine while their starts are in order.
    let ordered = ScreenContextRecord(sessionID: archive.id, frames: [
        ScreenKeyframe(start: 1, end: 12, display: a), ScreenKeyframe(start: 1, end: 3, display: b),
        ScreenKeyframe(start: 4, end: 9, display: b),
    ])
    try ScreenContextStore.write(ordered, session: archive.directory)
    #expect(try ScreenContextStore.read(session: archive.directory, sessionID: archive.id) == ordered)
}
