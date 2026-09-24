import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// Multi-step writes whose retry must finish a failed attempt: every fsync, rename, and unlink step fails in turn
// (`AtomicFile.faultPlan`), a retry with the same inputs must succeed, and every entry the two attempts added,
// replaced, or removed must be covered by a later fsync of its folder.

private let retryDate = Date(timeIntervalSince1970: 1_790_000_000)

private func retryTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-retry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func retryNewSession(in root: URL) throws -> SessionArchive {
    try SessionArchive.create(root: root, name: "Retry", source: .microphoneAndSystem, locale: "en-CA",
                              backend: .speech)
}

/// Temporary files (".<UUID>.tmp") left in `folder`.
private func temporaryFiles(in folder: URL) throws -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasPrefix(".") && $0.hasSuffix(".tmp") }
}

enum RetryWrite: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// `saveTranscript` of a second revision (exports on), replacing the pointer to the first.
    case saveTranscript
    /// `writeRun` then `writeHead` on a session with no speakers/ folder yet.
    case runAndHead

    var testDescription: String { rawValue }
}

/// A fresh session ready for one write.
private final class RetryFixture {
    /// Performs the calls of the write that have not succeeded yet; throws the first failure.
    var perform: () async throws -> Void = {}
    /// Whether a call that returned normally still left work for a retry (a marker it could not remove).
    var needsRetry: () -> Bool = { false }
    /// Asserts the final state.
    var check: (Comment) throws -> Void = { _ in }
    /// Entries whose removal need not be durable.
    var ignoring: Set<String> = []
    /// Keeps the writer alive (and its lock held) for the whole test.
    var writer: SessionArchive?
}

/// Tracks which calls of a multi-call write succeeded, so a retry repeats only the failed one.
private final class CallProgress {
    var runWritten = false
}

private func makeFixture(_ write: RetryWrite, root: URL) async throws -> RetryFixture {
    let fixture = RetryFixture()
    switch write {
    case .saveTranscript:
        let writer = try retryNewSession(in: root)
        let directory = writer.directory
        fixture.writer = writer
        try await writer.saveTranscript(Transcript(createdAt: retryDate, source: "mic", locale: "en-CA",
                                                   backend: .speech,
                                                   segments: [.init(start: 0, end: 1, text: "First")]))
        let second = Transcript(createdAt: retryDate, source: "mic", locale: "en-CA", backend: .speech,
                                segments: [.init(start: 0, end: 1, text: "Second")])
        let pending = SessionPaths.pendingTranscript(directory)
        fixture.perform = { try await writer.saveTranscript(second) }
        fixture.needsRetry = { FileManager.default.fileExists(atPath: pending.path) }
        // A marker left after the pointer names the current revision; saving it again is harmless.
        fixture.ignoring = ["current.pending"]
        fixture.check = { (comment: Comment) throws in
            #expect(try SessionArchive.currentTranscriptID(at: directory) == second.id, comment)
            #expect(try Data(contentsOf: SessionPaths.transcript(second.id, in: directory)) ==
                    HolosJSON.encoder().encode(second), comment)
            #expect(!FileManager.default.fileExists(atPath: pending.path), comment)
            let text = try String(contentsOf: SessionPaths.export("txt", in: directory), encoding: .utf8)
            #expect(text == "Second\n", comment)
            let markdown = try String(contentsOf: SessionPaths.export("md", in: directory), encoding: .utf8)
            #expect(markdown.contains("Second") && !markdown.contains("First"), comment)
            #expect(try temporaryFiles(in: SessionPaths.transcripts(directory)) == [], comment)
            #expect(try temporaryFiles(in: SessionPaths.exports(directory)) == [], comment)
        }
    case .runAndHead:
        let archive = try retryNewSession(in: root)
        try await archive.finish(status: ArchiveStatus.complete)
        let session = archive.directory
        let run = DiarizationRun(sessionID: archive.id, createdAt: retryDate, transcriptID: UUID().uuidString,
                                 engine: nil, alignment: AlignmentInfo(version: 1, parameters: .v1),
                                 tracks: [], speakers: [], turns: [])
        let head = SpeakerHead(runID: run.id, updatedAt: retryDate)
        let progress = CallProgress()
        fixture.perform = {
            try SessionArchive.withSpeakerLock(at: session) {
                if !progress.runWritten {
                    try SessionSpeakerStore.writeRun(run, session: session)
                    progress.runWritten = true
                }
                try SessionSpeakerStore.writeHead(head, session: session)
            }
        }
        fixture.check = { (comment: Comment) throws in
            #expect(try SessionSpeakerStore.readRun(id: run.id, session: session) == run, comment)
            #expect(try SessionSpeakerStore.readHead(session: session) == head, comment)
            #expect(try SessionSpeakerStore.runIDs(session: session) == [run.id], comment)
            #expect(try temporaryFiles(in: SessionPaths.speakers(session)) == [], comment)
            #expect(try temporaryFiles(in: SessionPaths.runs(session)) == [], comment)
        }
    }
    return fixture
}

/// Runs `write` on a fresh session with step `failAt` failing, retries with no fault when the attempt failed
/// (or left work behind), and checks the final state and that every change is covered by a folder fsync.
/// Returns the steps the first attempt took.
@discardableResult
private func runWithFault(_ write: RetryWrite, failAt: Int?, label: String = "") async throws -> [String] {
    let root = try retryTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await makeFixture(write, root: root)
    let plan = FaultPlan(failAt: failAt)
    var failure: (any Error)?
    do {
        try await AtomicFile.$faultPlan.withValue(plan) { try await fixture.perform() }
    } catch {
        failure = error
    }
    let steps = plan.steps
    let comment = Comment(rawValue: "\(write) \(label)")
    if failAt == nil { #expect(failure == nil, comment) }
    plan.disarm()
    if failure != nil || fixture.needsRetry() {
        do {
            try await AtomicFile.$faultPlan.withValue(plan) { try await fixture.perform() }
        } catch {
            Issue.record("\(write) \(label): the retry failed after \(String(describing: failure)): \(error)")
            return steps
        }
    }
    try fixture.check(comment)
    #expect(plan.unsyncedChanges(ignoring: fixture.ignoring) == [], comment)
    return steps
}

@Test(arguments: RetryWrite.allCases)
func aRetryAfterAnyFailedStepFinishesTheWriteDurably(_ write: RetryWrite) async throws {
    let steps = try await runWithFault(write, failAt: nil, label: "without a fault")
    // saveTranscript: marker, revision, two exports, pointer (fsync temp, rename, fsync folder each), then the
    // marker's unlink and folder fsync. writeRun + writeHead: speakers/ and runs/ (folder fsync each), the run,
    // and the head.
    #expect(steps.count == (write == .saveTranscript ? 17 : 8), "\(steps)")
    for index in steps.indices {
        try await runWithFault(write, failAt: index, label: "failing step \(index) (\(steps[index]))")
    }
}

@Test func saveTranscriptCanBeRetriedAfterThePointerFolderSyncFails() async throws {
    let steps = try await runWithFault(.saveTranscript, failAt: nil)
    let rename = try #require(steps.firstIndex(of: "rename current.json"))
    #expect(steps[rename + 1] == "fsync transcripts/")
    // The pointer already names the revision when its folder fsync fails; the retry publishes it again.
    try await runWithFault(.saveTranscript, failAt: rename + 1, label: "pointer folder fsync")
}

@Test func recoverRetryFsyncsTheSessionFolderAfterAFailedManifestSync() async throws {
    let root = try retryTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    func abandoned() async throws -> URL {
        let writer = try retryNewSession(in: root)
        try await writer.recordEvent(kind: "tick", details: [:])
        return writer.directory
    }
    let twin = FaultPlan()
    let twinDirectory = try await abandoned()
    _ = try await AtomicFile.$faultPlan.withValue(twin) { try await SessionArchive.recover(at: twinDirectory) }
    // The manifest is written last; fail the fsync of the session folder after its rename.
    #expect(Array(twin.steps.suffix(2)) == ["rename manifest.json", "fsync \(twinDirectory.lastPathComponent)/"])

    let directory = try await abandoned()
    let plan = FaultPlan(failAt: twin.steps.count - 1)
    await #expect(throws: HolosError.self) {
        _ = try await AtomicFile.$faultPlan.withValue(plan) { try await SessionArchive.recover(at: directory) }
    }
    plan.disarm()
    let report = try await AtomicFile.$faultPlan.withValue(plan) { try await SessionArchive.recover(at: directory) }
    #expect(report.manifest?.status == ArchiveStatus.interrupted)
    #expect(plan.unsyncedChanges() == [])
}

@Test func deleteVoiceDataRetryFsyncsTheFolderAfterAFailedSync() async throws {
    let root = try retryTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try retryNewSession(in: root)
    try await archive.finish(status: ArchiveStatus.complete)
    let session = archive.directory
    try AtomicFile.ensurePrivateDirectory(SessionPaths.voiceDirectory(session))
    try AtomicFile.write(Data("{}".utf8), to: SessionPaths.voiceDirectory(session).appendingPathComponent("r.json"))

    let plan = FaultPlan(failAt: 2)
    #expect(throws: HolosError.self) {
        try AtomicFile.$faultPlan.withValue(plan) { try SessionSpeakerStore.deleteVoiceData(session: session) }
    }
    #expect(plan.steps == ["unlink r.json", "unlink voice", "fsync speakers/"])
    plan.disarm()
    try AtomicFile.$faultPlan.withValue(plan) { try SessionSpeakerStore.deleteVoiceData(session: session) }
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.voiceDirectory(session).path))
    #expect(plan.unsyncedChanges() == [])
}
