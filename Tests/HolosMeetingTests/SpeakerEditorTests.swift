import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// SpeakerEditor (docs/meeting-design.md §4.9, §5.7): compare-and-append edits, undo, and export regeneration.
// Fixture text is synthetic ("systemt1w1", …); failures print IDs and counts only.

private func editorJournal(_ session: URL) throws -> [SpeakerEdit] {
    try SessionSpeakerStore.readEdits(session: session).edits
}

private func editorExportsListing(_ session: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: SessionPaths.exports(session).path)) ?? []).sorted()
}

/// Checks that `body` throws the `HolosError` case `expected` names and returns its message.
private func editorRefusal(_ expected: String, _ body: () throws -> Void,
                           sourceLocation: SourceLocation = #_sourceLocation) -> String? {
    let error = #expect(throws: HolosError.self, sourceLocation: sourceLocation) { try body() }
    switch (expected, error) {
    case ("unavailable", .unavailable(let message)?), ("invalidInput", .invalidInput(let message)?):
        return message
    default:
        Issue.record("Expected \(expected), got \(String(describing: error))", sourceLocation: sourceLocation)
        return nil
    }
}

@Test func editJournalExportEndToEnd() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, run) = try await SessionFixtures.labelledSession(in: temp.url)
    let view = try SessionFixtures.view(session)
    let action = SpeakerEditAction.rename(speakerID: "system:S1", name: "Jim")

    let result = try SpeakerEditor.apply([action], view: view, session: session, source: "cli")

    let lines = try editorJournal(session)
    #expect(lines.count == 1)
    let line = try #require(lines.first)
    // §5.7 writes the prior value as `expected == ""`; the final fingerprint (§4.9) of an unnamed speaker is this.
    #expect(line.expected == "fp1:rename:speaker=9:system:S1=present;ordinal=1;name=none")
    #expect(line.expected == view.fingerprint(for: action))
    #expect(line.action == action)
    #expect(line.source == "cli")
    #expect(line.baseRunID == run.id)
    #expect(line.batchID != nil)
    #expect(!result.needsSampleRefresh)
    #expect(result.snapshot.projection?.speakers.first { $0.id == "system:S1" }?.label == "Jim")
    #expect(result.snapshot.projection?.appliedEditIDs == [line.id])

    let text = SessionPaths.export("txt", in: session)
    #expect(SessionFixtures.text(text).hasPrefix("Jim  00:0"))
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).contains("**Jim**"))
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: SessionPaths.export("json", in: session)))
    let speakers = (json as? [String: Any])?["speakers"] as? [[String: Any]] ?? []
    #expect(speakers.first { $0["id"] as? String == "system:S1" }?["name"] as? String == "Jim")
    #expect(SessionFixtures.mode(text) == 0o400)
}

@Test func missingTargetWritesNothing() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    let view = try SessionFixtures.view(session)

    let message = editorRefusal("invalidInput") {
        try SpeakerEditor.apply([.rename(speakerID: "system:S9", name: "Jim")], view: view, session: session,
                                source: "cli")
    }
    #expect(message?.contains("system:S9") == true)
    #expect(SessionFixtures.journalBytes(session) == nil)
    #expect(editorExportsListing(session).isEmpty, "A refused edit regenerates nothing.")

    // One bad action refuses the whole batch, including the valid actions before it.
    _ = editorRefusal("invalidInput") {
        try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "Jim"),
                                 .reassignTurns(turnIDs: ["T99"], to: "system:S1")],
                                view: view, session: session, source: "cli")
    }
    #expect(SessionFixtures.journalBytes(session) == nil)
}

@Test func editAgainstReplacedHeadIsRefused() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, transcript, runA) = try await SessionFixtures.labelledSession(in: temp.url)
    let viewA = try SessionFixtures.view(session)
    #expect(viewA.runID == runA.id)
    try SpeakerEditor.apply([.rename(speakerID: "system:S2", name: "Maria")], view: viewA, session: session,
                            source: "cli", regenerateExports: false)
    let viewWithEdit = try SessionFixtures.view(session)

    // A relabel publishes run B as the head.
    let runB = try SessionFixtures.writeHeadRun(session: session, transcript: transcript,
                                                outputs: ["system": SessionFixtures.alternatingOutput()])
    #expect(runB.id != runA.id)
    let before = SessionFixtures.journalBytes(session)

    let message = editorRefusal("unavailable") {
        try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "Jim")], view: viewA, session: session,
                                source: "cli")
    }
    #expect(message?.contains("changed since this view was loaded") == true)
    _ = editorRefusal("unavailable") {
        try SpeakerEditor.undoLast(view: viewWithEdit, session: session, source: "cli")
    }
    #expect(SessionFixtures.journalBytes(session) == before)
    #expect(editorExportsListing(session).isEmpty)
}

@Test func concurrentReassignIsRefused() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3"],
                                                                     duration: 30)
    let viewV = try SessionFixtures.view(session)
    #expect(viewV.turns.first { $0.id == "T4" }?.speakerID == "system:S1")

    // Another window reassigns T4 to S2 first, on its own fresh view.
    try SpeakerEditor.apply([.reassignTurns(turnIDs: ["T4"], to: "system:S2")], view: try SessionFixtures.view(session),
                            session: session, source: "app", regenerateExports: false)
    let before = SessionFixtures.journalBytes(session)

    // V still shows T4 as S1: moving it to S3 would silently undo the other window's change.
    let message = editorRefusal("unavailable") {
        try SpeakerEditor.apply([.reassignTurns(turnIDs: ["T4"], to: "system:S3")], view: viewV, session: session,
                                source: "cli", regenerateExports: false)
    }
    #expect(message == SpeakerEditor.changedMessage)
    #expect(SessionFixtures.journalBytes(session) == before)
    #expect(try SessionFixtures.view(session).turns.first { $0.id == "T4" }?.speakerID == "system:S2")
}

@Test func unrelatedConcurrentEditStillApplies() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3"],
                                                                     duration: 30)
    let viewV = try SessionFixtures.view(session)
    try SpeakerEditor.apply([.rename(speakerID: "system:S3", name: "Maria")], view: try SessionFixtures.view(session),
                            session: session, source: "app", regenerateExports: false)

    let result = try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "Jim")], view: viewV,
                                         session: session, source: "cli", regenerateExports: false)

    let projection = try #require(result.snapshot.projection)
    #expect(projection.appliedEditIDs.count == 2)
    #expect(projection.staleEdits.isEmpty)
    #expect(projection.speakers.first { $0.id == "system:S1" }?.label == "Jim")
    #expect(projection.speakers.first { $0.id == "system:S3" }?.label == "Maria")
}

@Test func batchFingerprintsAreSequential() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    let view = try SessionFixtures.view(session)

    let result = try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "A"),
                                          .rename(speakerID: "system:S1", name: "B")],
                                         view: view, session: session, source: "cli", regenerateExports: false)

    let lines = try editorJournal(session)
    #expect(lines.count == 2)
    #expect(lines.first?.expected == "fp1:rename:speaker=9:system:S1=present;ordinal=1;name=none")
    #expect(lines.last?.expected == "fp1:rename:speaker=9:system:S1=present;ordinal=1;name=1:A",
            "The second line's prior name is the first line's.")
    #expect(lines.first?.batchID != nil)
    #expect(lines.first?.batchID == lines.last?.batchID)
    #expect(Set(lines.map(\.id)).count == 2)
    #expect(result.snapshot.projection?.staleEdits.isEmpty == true)
    #expect(result.snapshot.projection?.speakers.first { $0.id == "system:S1" }?.label == "B")
}

@Test func exportsRegenerateAfterLockRelease() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    try SessionExports.regenerate(session: session)
    let text = SessionPaths.export("txt", in: session)
    #expect(SessionFixtures.text(text).hasPrefix("Speaker 1  00:00"))

    // Regenerating inside the speaker lock would wait for the editor's own lock and time out after 2 s.
    let clock = ContinuousClock()
    let start = clock.now
    try SpeakerEditor.apply([.rename(speakerID: "system:S2", name: "Maria")], view: try SessionFixtures.view(session),
                            session: session, source: "cli", regenerateExports: true)
    #expect(clock.now - start < .seconds(2))

    #expect(SessionFixtures.text(text).contains("Maria  00:05"))
    #expect(SessionFixtures.text(SessionPaths.export("md", in: session)).contains("**Maria**"))
    #expect(SessionFixtures.mode(text) == 0o400)
    #expect(editorExportsListing(session).filter { $0.hasPrefix("edited-") }.isEmpty)
}

@Test func undoRevertsNewestBatch() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    try SpeakerEditor.apply([.linkProfile(speakerID: "system:S1", profileID: "PROFILE-JIM"),
                             .rename(speakerID: "system:S1", name: "Jim")],
                            view: try SessionFixtures.view(session), session: session, source: "cli",
                            regenerateExports: false)
    try SpeakerEditor.apply([.reassignTurns(turnIDs: ["T2"], to: "system:S1")], view: try SessionFixtures.view(session),
                            session: session, source: "cli", regenerateExports: false)
    let original = try editorJournal(session)
    #expect(original.count == 3)
    let batch = original[0..<2].map(\.id)
    let reassign = original[2].id

    // First undo: the reassign only.
    let first = try SpeakerEditor.undoLast(view: try SessionFixtures.view(session), session: session, source: "cli",
                                           regenerateExports: false)
    var lines = try editorJournal(session)
    #expect(lines.count == 4)
    #expect(lines[3].action == .revert(editID: reassign))
    #expect(lines[3].expected == nil)
    #expect(lines[3].batchID != nil && !original.map(\.batchID).contains(lines[3].batchID))
    let afterFirst = try #require(first.snapshot.projection)
    #expect(afterFirst.revertedEditIDs == [reassign])
    #expect(afterFirst.turns.first { $0.id == "T2" }?.speakerID == "system:S2")
    #expect(afterFirst.speakers.first { $0.id == "system:S1" }?.label == "Jim")
    #expect(afterFirst.lastUndoableBatchID == original[0].batchID)

    // Second undo: both lines of the first batch, as one batch.
    let second = try SpeakerEditor.undoLast(view: afterFirst, session: session, source: "cli",
                                            regenerateExports: false)
    lines = try editorJournal(session)
    #expect(lines.count == 6)
    #expect(lines[4...].map(\.action) == batch.map { SpeakerEditAction.revert(editID: $0) })
    #expect(lines[4].batchID != nil && lines[4].batchID == lines[5].batchID)
    let afterSecond = try #require(second.snapshot.projection)
    #expect(Set(afterSecond.revertedEditIDs) == Set(batch + [reassign]))
    #expect(afterSecond.appliedEditIDs.isEmpty)
    let speaker = try #require(afterSecond.speakers.first { $0.id == "system:S1" })
    #expect(speaker.label == "Speaker 1" && speaker.profileID == nil)
    #expect(afterSecond.lastUndoableBatchID == nil)

    // Nothing left: undo refuses and writes nothing.
    let message = editorRefusal("invalidInput") {
        try SpeakerEditor.undoLast(view: afterSecond, session: session, source: "cli", regenerateExports: false)
    }
    #expect(message?.contains("no speaker change to undo") == true)
    #expect(try editorJournal(session).count == 6)
}

@Test func undoFromAnOutdatedViewIsRefused() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "Jim")], view: try SessionFixtures.view(session),
                            session: session, source: "cli", regenerateExports: false)
    let outdated = try SessionFixtures.view(session)

    // Someone else undoes the rename first; undoing again from the outdated view must not revert anything else.
    try SpeakerEditor.undoLast(view: try SessionFixtures.view(session), session: session, source: "app",
                               regenerateExports: false)
    var before = SessionFixtures.journalBytes(session)
    _ = editorRefusal("unavailable") {
        try SpeakerEditor.undoLast(view: outdated, session: session, source: "cli", regenerateExports: false)
    }
    #expect(SessionFixtures.journalBytes(session) == before)

    // A newer change made elsewhere is not undone from a view that has not seen it.
    try SpeakerEditor.apply([.rename(speakerID: "system:S2", name: "Maria")], view: try SessionFixtures.view(session),
                            session: session, source: "app", regenerateExports: false)
    let beforeNewer = try SessionFixtures.view(session)
    try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "Sam")], view: try SessionFixtures.view(session),
                            session: session, source: "app", regenerateExports: false)
    before = SessionFixtures.journalBytes(session)
    _ = editorRefusal("unavailable") {
        try SpeakerEditor.undoLast(view: beforeNewer, session: session, source: "cli", regenerateExports: false)
    }
    #expect(SessionFixtures.journalBytes(session) == before)
}

@Test func undoNeverRevivesARefusedEdit() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, run) = try await SessionFixtures.labelledSession(in: temp.url)
    let unnamed = try SessionFixtures.view(session)
    try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "A")], view: unnamed, session: session,
                            source: "cli", regenerateExports: false)
    // A line written by something other than the editor, made on the unnamed view: stale behind the rename.
    let stale = SpeakerEditAction.rename(speakerID: "system:S1", name: "X")
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.appendEdits([SpeakerEdit(baseRunID: run.id, source: "cli", action: stale,
                                                         expected: unnamed.fingerprint(for: stale))],
                                            session: session)
    }
    let view = try SessionFixtures.view(session)
    #expect(view.staleEdits.count == 1)
    let before = SessionFixtures.journalBytes(session)

    let message = editorRefusal("invalidInput") {
        try SpeakerEditor.undoLast(view: view, session: session, source: "cli", regenerateExports: false)
    }
    #expect(message?.contains("bring back") == true)
    #expect(SessionFixtures.journalBytes(session) == before)
}

@Test func concurrentEditorsSerialize() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)

    /// Twenty renames, each on a freshly loaded view, on a thread of its own (the lock waits block).
    @Sendable func renames(_ speakerID: String, prefix: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    for index in 0..<20 {
                        let view = try SessionFixtures.view(session)
                        try SpeakerEditor.apply([.rename(speakerID: speakerID, name: "\(prefix)\(index)")],
                                                view: view, session: session, source: "cli",
                                                regenerateExports: false)
                    }
                })
            }
        }
    }
    async let first: Void = renames("system:S1", prefix: "A")
    async let second: Void = renames("system:S2", prefix: "B")
    _ = try await (first, second)

    let journal = try SessionSpeakerStore.readEdits(session: session)
    #expect(journal.edits.count == 40)
    #expect(!journal.tornTail)
    #expect(journal.unreadableLines == 0)
    #expect(Set(journal.edits.map(\.id)).count == 40)
    let projection = try SessionFixtures.view(session)
    #expect(projection.appliedEditIDs.count == 40)
    #expect(projection.staleEdits.isEmpty)
    #expect(projection.speakers.first { $0.id == "system:S1" }?.label == "A19")
    #expect(projection.speakers.first { $0.id == "system:S2" }?.label == "B19")
}

@Test func exportFormatsRenderWithoutWriting() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    try SessionExports.regenerate(session: session)
    try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "Jim")], view: try SessionFixtures.view(session),
                            session: session, source: "cli", regenerateExports: false)
    let before = SessionFixtures.files(in: SessionPaths.exports(session))

    let text = String(decoding: try SessionExports.render(.txt, session: session), as: UTF8.self)
    #expect(text.hasPrefix("Jim  00:00\n"))
    let markdown = String(decoding: try SessionExports.render(.md, session: session), as: UTF8.self)
    #expect(markdown.contains("**Jim**"))
    let json = try JSONSerialization.jsonObject(with: try SessionExports.render(.json, session: session))
    #expect((json as? [String: Any])?["format"] as? String == "holos-transcript")

    #expect(SessionFixtures.files(in: SessionPaths.exports(session)) == before)
    #expect(!SessionFixtures.text(SessionPaths.export("txt", in: session)).contains("Jim"))
}

@Test func invalidActionsAreRefusedBeforeWriting() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    let view = try SessionFixtures.view(session)
    let turn = try #require(view.turns.first { $0.id == "T1" })
    let firstWord = WordRef(segmentID: turn.spans[0].segmentID, word: turn.spans[0].first)

    _ = editorRefusal("invalidInput") {
        try SpeakerEditor.apply([], view: view, session: session, source: "cli")
    }
    _ = editorRefusal("invalidInput") {
        try SpeakerEditor.apply([.splitTurn(turnID: "T1", at: firstWord)], view: view, session: session,
                                source: "cli")
    }
    _ = editorRefusal("invalidInput") {
        try SpeakerEditor.apply([.merge(from: "system:S1", into: "system:S1")], view: view, session: session,
                                source: "cli")
    }
    _ = editorRefusal("invalidInput") {
        try SpeakerEditor.apply([.newSpeaker(speakerID: "system:S1", name: "Jim", turnIDs: ["T1"])], view: view,
                                session: session, source: "cli")
    }
    _ = editorRefusal("invalidInput") {
        try SpeakerEditor.apply([.revert(editID: "NO-SUCH-EDIT")], view: view, session: session, source: "cli")
    }
    _ = editorRefusal("invalidInput") {
        try SpeakerEditor.apply([.rename(speakerID: "system:S1", name: "Jim")], view: view, session: session,
                                source: " ")
    }
    #expect(SessionFixtures.journalBytes(session) == nil)
}

@Test func splitNewSpeakerAndMergeApplyInOneBatch() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2", "S3"],
                                                                     duration: 30)
    let view = try SessionFixtures.view(session)
    let turn = try #require(view.turns.first { $0.id == "T1" })
    let span = turn.spans[0]
    let split = SpeakerEditAction.splitTurn(turnID: "T1", at: WordRef(segmentID: span.segmentID, word: span.first + 3))
    let newSpeaker = "user:\(UUID().uuidString)"

    let result = try SpeakerEditor.apply([split,
                                          .newSpeaker(speakerID: newSpeaker, name: "Guest", turnIDs: ["T2"]),
                                          .merge(from: "system:S3", into: "system:S2"),
                                          .excludeFromEnrollment(turnIDs: ["T1"])],
                                         view: view, session: session, source: "cli", regenerateExports: false)

    let lines = try editorJournal(session)
    #expect(lines.count == 4)
    #expect(Set(lines.map(\.batchID)).count == 1)
    let projection = try #require(result.snapshot.projection)
    #expect(projection.staleEdits.isEmpty)
    #expect(projection.appliedEditIDs == lines.map(\.id))
    let part = try #require(projection.turns.first { $0.id == "T1/\(lines[0].id)" })
    #expect(part.modified && part.speakerID == "system:S1")
    #expect(projection.turns.first { $0.id == "T1" }?.excludedFromEnrollment == true)
    #expect(projection.turns.first { $0.id == "T2" }?.speakerID == newSpeaker)
    #expect(projection.speakers.first { $0.id == newSpeaker }?.label == "Guest")
    #expect(!projection.speakers.contains { $0.id == "system:S3" })
    #expect(projection.turns.filter { $0.speakerID == "system:S2" }.map(\.id) == ["T3", "T5", "T6"])
}

// MARK: - SessionLocator

@Test func sessionLocatorResolvesPathsAndIDs() async throws {
    let temp = try TemporaryDirectory("editor")
    defer { temp.remove() }
    let (session, _, _) = try await SessionFixtures.labelledSession(in: temp.url)
    let manifest = try SessionArchive.readManifest(at: session)
    let expected = session.standardizedFileURL.path

    #expect(try SessionLocator.resolve(session.path, root: temp.url).path == expected)
    #expect(try SessionLocator.resolve(session.path + "/", root: temp.url).path == expected)
    #expect(try SessionLocator.resolve(manifest.id, root: temp.url).path == expected)
    #expect(try SessionLocator.resolve(manifest.id.lowercased(), root: temp.url).path == expected)
    #expect(try SessionLocator.resolve("  \(manifest.id) ", root: temp.url).path == expected)

    let other = UUID().uuidString
    let missing = editorRefusal("invalidInput") { _ = try SessionLocator.resolve(other, root: temp.url) }
    #expect(missing?.contains(other) == true)
    _ = editorRefusal("invalidInput") { _ = try SessionLocator.resolve("", root: temp.url) }
    _ = editorRefusal("invalidInput") {
        _ = try SessionLocator.resolve(temp.url.appendingPathComponent("nope.holos").path, root: temp.url)
    }
    _ = editorRefusal("invalidInput") { _ = try SessionLocator.resolve(temp.url.path, root: temp.url) }

    // A symbolic link in place of the session folder is refused, as every session operation refuses it.
    let link = temp.url.appendingPathComponent("\(UUID().uuidString).holos")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: session)
    _ = editorRefusal("invalidInput") { _ = try SessionLocator.resolve(link.path, root: temp.url) }
}
