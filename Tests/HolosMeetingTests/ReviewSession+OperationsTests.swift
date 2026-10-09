import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing

/// The states a queued change of `ReviewSession` ends in (`ReviewSession.Operation`), for every way `adopt` and undo
/// mark them: whether it ran, was undone, was superseded (labels adopted while it ran), was overtaken (a head made
/// elsewhere adopted while it ran), finished, and saved lines it could not reread. Made-up speaker names only.
@MainActor
struct ReviewSessionOperationsTests {
    /// One change's states, as `"kind ran undone superseded overtaken finished unreread"` with `-` for each one off.
    private static func states(_ op: ReviewSession.Operation) -> String {
        let kind: String
        switch op.kind {
        case .edit: kind = "edit"
        case .undo: kind = "undo"
        case .reload: kind = "reload"
        case .exports: kind = "exports"
        default: kind = "other"
        }
        let flags = [(op.ran, "ran"), (op.undone, "undone"), (op.superseded, "superseded"),
                     (op.overtaken, "overtaken"), (op.isFinished, "finished"), (op.savedUnreloaded, "unreread")]
        return ([kind] + flags.map { $0.0 ? $0.1 : "-" }).joined(separator: " ")
    }

    enum Scenario: String, CaseIterable, Sendable {
        /// A change saved: its own labels are adopted while it runs.
        case saved
        /// Undo while it waits behind a change saving: dropped before it ran.
        case undoWhileQueued
        /// Undo while it saves: it is undone, saved, then reverted by the undo queued after it.
        case undoWhileSaving
        /// The undo of a change still saving fails: the change is not undone after all.
        case failedUndoWhileSaving
        /// A new labelling made elsewhere while a change saves: refused, and the labels read again have another head.
        case overtakenByAHeadElsewhere
        /// A change made elsewhere while one saves: that one is refused, and the one waiting behind it too (stale).
        case staleBehindAChangeElsewhere
        /// A change saved whose labels cannot be reread, then a reread that works.
        case savedButNotReread
    }

    /// For each scenario, every change in the order they finished: its states when it finished, then at the end.
    private static let expected: [Scenario: [(atFinish: String, atEnd: String)]] = [
        .saved: [
            ("edit ran - superseded - finished -", "edit ran - superseded - finished -"),
        ],
        .undoWhileQueued: [
            ("edit - undone - - finished -", "edit - undone - - finished -"),
            ("edit ran - superseded - finished -", "edit ran - superseded - finished -"),
        ],
        .undoWhileSaving: [
            ("edit ran undone superseded - finished -", "edit ran undone superseded - finished -"),
            ("undo ran - superseded - finished -", "undo ran - superseded - finished -"),
        ],
        .failedUndoWhileSaving: [
            ("edit ran undone superseded - finished -", "edit ran - superseded - finished -"),
            ("undo ran - superseded - finished -", "undo ran - superseded - finished -"),
        ],
        .overtakenByAHeadElsewhere: [
            ("edit ran - superseded overtaken finished -", "edit ran - superseded overtaken finished -"),
        ],
        .staleBehindAChangeElsewhere: [
            ("edit - - - - finished -", "edit - - - - finished -"),
            ("edit ran - superseded - finished -", "edit ran - superseded - finished -"),
        ],
        .savedButNotReread: [
            ("edit ran - - - finished unreread", "edit ran - - - finished -"),
            ("reload ran - - - finished -", "reload ran - - - finished -"),
            ("reload ran - superseded - finished -", "reload ran - superseded - finished -"),
        ],
    ]

    @Test(.timeLimit(.minutes(1)), arguments: Scenario.allCases)
    func everyCombinationAdoptAndUndoMake(_ scenario: Scenario) async throws {
        let temp = try TemporaryDirectory("review-operations", permissions: 0o700)
        defer { temp.remove() }
        let fixture = try await SessionFixtures.labelledSession(in: temp.url)
        let session = fixture.session
        let review = try await ReviewSession(session: session, profiles: nil, maintenance: nil,
                                             exportDelay: .seconds(60))
        var finished: [(op: ReviewSession.Operation, atFinish: String)] = []
        review.operationFinished = { op in
            if case .exports = op.kind { return }
            finished.append((op, Self.states(op)))
        }
        let (stream, release) = AsyncStream<Void>.makeStream()
        let saves = SharedValue(0)
        /// Holds the first save back until `release`.
        let holdFirstSave: @Sendable () async -> Void = {
            if saves.update({ $0 += 1; return $0 }) == 1 { for await _ in stream {} }
        }
        let rename = { (speaker: String, name: String) in
            Task { @MainActor in try await review.apply([.rename(speakerID: speaker, name: name)]) }
        }
        switch scenario {
        case .saved:
            try await review.apply([.rename(speakerID: "system:S1", name: "Ash")])
        case .undoWhileQueued:
            review.beforeEdit = holdFirstSave
            let first = rename("system:S1", "Ash")
            #expect(await eventually { saves.value == 1 })
            let second = rename("system:S2", "Birch")
            #expect(await eventually { review.queuedOperations == 2 })
            try await review.undo()
            release.finish()
            try await first.value
            try await second.value
        case .undoWhileSaving:
            review.beforeEdit = holdFirstSave
            let first = rename("system:S1", "Ash")
            #expect(await eventually { saves.value == 1 })
            let undo = Task { @MainActor in try await review.undo() }
            #expect(await eventually { review.queuedOperations == 2 })
            release.finish()
            try await first.value
            try await undo.value
        case .failedUndoWhileSaving:
            let journal = SessionPaths.edits(session)
            review.beforeEdit = {
                let call = saves.update { $0 += 1; return $0 }
                if call == 1 { for await _ in stream {} }
                if call == 2 { Self.setWritable(journal, false) }
            }
            defer { Self.setWritable(journal, true) }
            let first = rename("system:S1", "Ash")
            #expect(await eventually { saves.value == 1 })
            let undo = Task { @MainActor in try await review.undo() }
            #expect(await eventually { review.queuedOperations == 2 })
            release.finish()
            try await first.value
            _ = try? await undo.value
        case .overtakenByAHeadElsewhere:
            review.beforeEdit = holdFirstSave
            let first = rename("system:S1", "Ash")
            #expect(await eventually { saves.value == 1 })
            try Self.relabel(session)
            release.finish()
            _ = try? await first.value
        case .staleBehindAChangeElsewhere:
            review.beforeEdit = holdFirstSave
            let first = rename("system:S1", "Ash")
            #expect(await eventually { saves.value == 1 })
            let second = rename("system:S2", "Birch")
            #expect(await eventually { review.queuedOperations == 2 })
            try SessionFixtures.appendEdits([.rename(speakerID: "system:S2", name: "Cedar")], session: session)
            release.finish()
            _ = try? await first.value
            _ = try? await second.value
        case .savedButNotReread:
            review.beforeEdit = { Self.blockRereads(session, true) }
            defer { Self.blockRereads(session, false) }
            _ = try? await review.apply([.rename(speakerID: "system:S1", name: "Ash")])
            review.beforeEdit = nil
            await review.reload()
            Self.blockRereads(session, false)
            await review.reload()
        }
        review.beforeEdit = nil
        let actual = finished.map { ($0.atFinish, Self.states($0.op)) }
        let wanted = Self.expected[scenario] ?? []
        #expect(actual.map(\.0) == wanted.map(\.atFinish), "\(scenario) at finish")
        #expect(actual.map(\.1) == wanted.map(\.atEnd), "\(scenario) at the end")
        await review.close()
    }

    private nonisolated static func setWritable(_ url: URL, _ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o600 : 0o400], ofItemAtPath: url.path)
    }

    /// Makes the session's event journal unreadable (read when labels are loaded, not when a change is saved), or
    /// readable again.
    private nonisolated static func blockRereads(_ session: URL, _ blocked: Bool) {
        let events = SessionPaths.events(session)
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: events.path, isDirectory: &isFolder)
        if blocked {
            if exists {
                try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: events.path)
            } else {
                try? FileManager.default.createDirectory(at: events, withIntermediateDirectories: false)
            }
        } else if exists {
            if isFolder.boolValue {
                try? FileManager.default.removeItem(at: events)
            } else {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: events.path)
            }
        }
    }

    /// Labels the meeting again elsewhere (a command): a new head run with the same turns.
    private static func relabel(_ session: URL) throws {
        let snapshot = try SpeakerSessionSnapshot.load(session: session)
        let old = try #require(snapshot.run)
        let run = DiarizationRun(sessionID: old.sessionID, transcriptID: old.transcriptID, engine: old.engine,
                                 alignment: old.alignment, tracks: old.tracks, speakers: old.speakers,
                                 turns: old.turns)
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.writeRun(run, session: session)
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
        }
    }
}
