import AppKit
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing
@testable import HolosApp

/// Joining rows through the review window itself (docs/meeting-design.md §5.10): a real `ReviewSession` over a
/// meeting written to a temporary folder (no audio), its window never shown. Each turn is a transcript segment of its
/// own; speakers are "S1", "S2" (nil: the unknown speaker). Made-up words only.
@MainActor
struct ReviewWindowJoinTests {
    private struct Spec {
        var speaker: String?
        var start: Double
        var words: [String]
        var track = "system"
    }

    /// A finished call whose head run has exactly the turns of `specs` (T1, T2, … in time order), each word half a
    /// second long, and its review window, laid out.
    private func open(_ specs: [Spec]) async throws -> (ReviewWindow, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-join-\(UUID().uuidString)", isDirectory: true)
        let segments = specs.map { spec in
            var text = ""
            var timed: [TimedWord] = []
            for (index, word) in spec.words.enumerated() {
                if !text.isEmpty { text += " " }
                let offset = text.utf16.count
                text += word
                let start = spec.start + Double(index) * 0.5
                timed.append(TimedWord(text: word, start: start, end: start + 0.4, utf16Offset: offset,
                                       utf16Length: word.utf16.count))
            }
            return TranscriptSegment(id: UUID().uuidString, start: spec.start,
                                     end: spec.start + Double(spec.words.count) * 0.5, text: text, words: timed,
                                     track: spec.track)
        }
        let transcript = Transcript(id: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                                    source: "fixture", locale: "en-CA", backend: .speech, segments: segments)
        let archive = try SessionArchive.create(root: root, name: "Join fixture", source: .system, locale: "en-CA",
                                                backend: .speech)
        try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: .call, othersInRoom: false),
                                 to: SessionPaths.meetingInfo(archive.directory))
        try await archive.saveTranscript(transcript, writeLegacyExports: false)
        try await archive.finish(status: ArchiveStatus.complete)
        let session = archive.directory
        let ids = Array(Set(specs.compactMap(\.speaker))).sorted()
        let speakers = ids.enumerated().map { index, id in
            SessionSpeaker(id: id, ordinal: index + 1, provenance: .diarizer, clusterIDs: [id])
        }
        let turns = zip(specs, segments).enumerated().map { index, pair in
            let (spec, segment) = pair
            return SpeakerTurn(id: "T\(index + 1)", track: spec.track, start: spec.start, end: segment.end,
                               speakerID: spec.speaker, clusterID: spec.speaker,
                               spans: [WordSpan(segmentID: segment.id, first: 0, end: spec.words.count)],
                               overlap: false, otherClusters: [], assignmentScore: 1, timing: .measured)
        }
        let tracks = Array(Set(specs.map(\.track))).sorted().map { track in
            TrackDiarization(track: track, policy: .diarized, clusters: speakers.map {
                ClusterSummary(clusterID: $0.id, track: track, speechSeconds: 10)
            })
        }
        let manifest = try SessionArchive.readManifest(at: session)
        let run = DiarizationRun(sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
                                 alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: tracks,
                                 speakers: speakers, turns: turns)
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.writeRun(run, session: session)
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
        }
        let review = try await ReviewSession(session: session, profiles: nil, maintenance: nil,
                                             exportDelay: .seconds(60))
        let window = ReviewWindow(sessionID: manifest.id, review: review)
        Self.retained.append(window)
        window.turnList.openSpeakerMenu = { _ in }
        window.window.contentView?.layoutSubtreeIfNeeded()
        return (window, session)
    }

    private static var retained: [ReviewWindow] = []

    /// Closes the window, then removes the temporary folder `open` made for its meeting.
    private func closeAndRemove(_ window: ReviewWindow, _ session: URL) async {
        await window.closeAndWait()
        try? FileManager.default.removeItem(at: session.deletingLastPathComponent())
    }

    /// Labels the meeting again elsewhere (a command): a new head run with the same turns, IDs and speakers.
    private func relabel(_ session: URL) throws {
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

    /// Counts calls from any thread (the review's save hook runs off the main actor).
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
        func peek() -> Int { lock.withLock { count } }
    }

    /// Polls (a budget of checks, never a clock) until `condition` holds.
    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<4000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func rows(_ window: ReviewWindow) -> [[String]] { window.turnList.paragraphs.map(\.turnIDs) }

    private func journal(_ session: URL) -> [SpeakerEditAction] {
        ((try? SessionSpeakerStore.readEdits(session: session).edits) ?? []).map(\.action)
    }

    private func speaker(_ window: ReviewWindow, _ turnID: String) -> String? {
        window.review.projection.turns.first { $0.id == turnID }?.speakerID
    }

    /// Opens the field over word `word` of `row` with the caret at `caret`, then sends `command` to it.
    private func press(_ window: ReviewWindow, row: Int, word: Int, caret: Int, _ command: Selector) {
        let list = window.turnList
        list.table.handleWordClick(row: row, word: word, through: word, extend: false)
        list.editField.currentEditor()?.selectedRange = NSRange(location: caret, length: 0)
        _ = list.control(list.editField, textView: NSTextView(), doCommandBy: command)
    }

    private func commandZ(_ window: ReviewWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: window.window.windowNumber, context: nil, characters: "z",
                                      charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
    }

    /// A key typed as the window receives it (`characters`, with `flags`).
    private func key(_ window: ReviewWindow, _ characters: String, code: UInt16,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// Backspace joins another speaker's row and the speaker change takes a while to save: the field is closed until
    /// it has, and what is typed meanwhile (K, Space and J, playback keys outside a field) goes into the field that
    /// opens again at the join, as typed there.
    @Test(.timeLimit(.minutes(1))) func typingWhileTheJoinSavesGoesIntoTheReopenedField() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        let (stream, release) = AsyncStream<Void>.makeStream()
        let calls = Calls()
        window.review.beforeEdit = {
            _ = calls.next()
            for await _ in stream {}
        }
        window.setEditMode(true)
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(await until { calls.peek() == 1 && rows(window) == [["T1", "T2"]] })
        #expect(window.turnList.wordEdit == nil, "Closed while the speaker change saves.")
        for (characters, code) in [("k", UInt16(40)), (" ", 49), ("j", 38)] {
            window.window.sendEvent(try key(window, characters, code: code))
        }
        release.finish()
        #expect(await until { journal(session).count == 1 && window.turnList.wordEdit != nil })
        #expect(window.turnList.editField.stringValue == "k jcedar")
        window.turnList.cancelWordEdit()
        await closeAndRemove(window, session)
    }

    /// Keys typed while the join saves, when the join is then dropped (its speaker change is refused: the labels were
    /// changed elsewhere meanwhile): no field opens, and what they typed at the join is kept as an edit not saved,
    /// which the footer offers to edit again.
    @Test(.timeLimit(.minutes(1))) func typingWhileAJoinThatFailsSavesIsKeptAsAnUnsavedEdit() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        let (stream, release) = AsyncStream<Void>.makeStream()
        let calls = Calls()
        window.review.beforeEdit = {
            _ = calls.next()
            for await _ in stream {}
        }
        // Elsewhere (a command): T2 goes to S1.
        let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
        _ = try SpeakerEditor.apply([.reassignTurns(turnIDs: ["T2"], to: "S1")], view: view, session: session,
                                    source: "cli", regenerateExports: false)
        window.setEditMode(true)
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(await until { calls.peek() == 1 && rows(window) == [["T1", "T2"]] })
        for (characters, code) in [("k", UInt16(40)), ("o", 31)] {
            window.window.sendEvent(try key(window, characters, code: code))
        }
        release.finish()
        #expect(await until { window.paragraphJoins.isEmpty && window.unsavedEditTexts == ["kocedar"] })
        #expect(window.turnList.wordEdit == nil)
        #expect(journal(session) == [.reassignTurns(turnIDs: ["T2"], to: "S1")], "Only the change made elsewhere.")
        await closeAndRemove(window, session)
    }

    /// Backspace joins another speaker's row while its speaker change is held in its save; Backspace opened the hold.
    private func joinWithHeldSave(_ window: ReviewWindow) async -> (release: AsyncStream<Void>.Continuation, Calls) {
        let (stream, release) = AsyncStream<Void>.makeStream()
        let calls = Calls()
        window.review.beforeEdit = {
            if calls.next() == 1 { for await _ in stream {} }
        }
        window.setEditMode(true)
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        _ = await until { calls.peek() == 1 }
        return (release, calls)
    }

    private func type(_ window: ReviewWindow, _ text: String) throws {
        for character in text { window.window.sendEvent(try key(window, String(character), code: 0)) }
    }

    /// Keys held while the join saves, then ⌘W: the close saves them as an edit of the word at the join (as it saves
    /// an open field's typing), waiting for it before the window closes.
    @Test(.timeLimit(.minutes(1))) func closingByHandWhileTypingIsHeldSavesIt() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        let (release, _) = await joinWithHeldSave(window)
        try type(window, "ko")
        #expect(!window.windowShouldClose(window.window), "It saves the held typing first.")
        release.finish()
        #expect(await until {
            window.review.turn("T2").map { window.review.text(of: $0).hasPrefix("kocedar") } ?? false
        })
        #expect(await until { window.isClosing }, "Closed once saved.")
        #expect(window.unsavedEditTexts.isEmpty)
        await closeAndRemove(window, session)
    }

    /// Keys held while the join saves, then the window closes without asking (quitting): the close saves them.
    @Test(.timeLimit(.minutes(1))) func closingWhileTypingIsHeldSavesIt() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        let (release, _) = await joinWithHeldSave(window)
        try type(window, "ko")
        window.startClosing()
        release.finish()
        await window.closeAndWait()
        let transcript = try SpeakerSessionSnapshot.load(session: session).transcript
        #expect(transcript.segments.contains { $0.text.hasPrefix("kocedar") })
        try? FileManager.default.removeItem(at: session.deletingLastPathComponent())
    }

    /// Join A's keys are held when join B starts (the person clicked the next row's first word and pressed Backspace):
    /// A's keys stay an edit of A's word, never typed at B's join.
    @Test(.timeLimit(.minutes(1))) func aSecondJoinNeverTakesTheFirstJoinsTyping() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"]),
                                                Spec(speaker: "S3", start: 4, words: ["elm", "fern"])])
        let (release, _) = await joinWithHeldSave(window)
        #expect(await until { rows(window) == [["T1", "T2"], ["T3"]] })
        try type(window, "k")
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(window.unsavedEditTexts == ["kcedar"], "A's typing, at A's word.")
        release.finish()
        #expect(await until { journal(session).count == 2 && window.turnList.wordEdit != nil })
        #expect(window.turnList.wordEdit?.words.map(\.text) == ["elm"])
        #expect(window.turnList.editField.stringValue == "elm")
        window.turnList.cancelWordEdit()
        await closeAndRemove(window, session)
    }

    /// Keys held while the join saves, then Undo from the Speakers menu (or ⌘Z handled by the window): the join goes,
    /// and what was typed stays in the footer as an edit not saved, which the undo's own start does not clear.
    @Test(.timeLimit(.minutes(1))) func undoWhileTypingIsHeldKeepsTheTyping() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        let (release, _) = await joinWithHeldSave(window)
        try type(window, "ko")
        #expect(window.handleKey(try commandZ(window)))
        #expect(window.unsavedEditTexts == ["kocedar"])
        release.finish()
        #expect(await until { window.review.snapshot.journal.edits.count == 2 && speaker(window, "T2") == "S2" })
        #expect(window.unsavedEditTexts == ["kocedar"])
        await closeAndRemove(window, session)
    }

    /// An undo saved elsewhere drops every join as the window refreshes, while the join's speaker change still waits:
    /// the hold ends then, so the keys typed after go where they always go.
    @Test(.timeLimit(.minutes(1))) func joinsDroppedByARefreshEndTheHold() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        try await window.review.apply([.rename(speakerID: "S1", name: "Ash")])
        window.refresh()
        // Undone elsewhere (a command), read by the review but not yet shown: the window refreshes at the join.
        let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
        _ = try SpeakerEditor.undoLast(view: view, session: session, source: "cli", regenerateExports: false)
        window.review.onChange = nil
        await window.review.reload()
        let (release, _) = await joinWithHeldSave(window)
        #expect(window.paragraphJoins.isEmpty, "The refresh at the join dropped it.")
        #expect(window.window.typingHold.current == nil, "No hold is left open.")
        release.finish()
        #expect(await until { window.review.snapshot.journal.edits.count == 3 })
        await closeAndRemove(window, session)
    }

    /// After Backspace joins another speaker's row, the field opens again at the join with nothing typed in it: ⌘Z
    /// there is the review's undo (the banner says so), which gives the row its speaker back, never the field's own
    /// typing undo. With something typed, ⌘Z undoes the typing.
    @Test(.timeLimit(.minutes(1))) func commandZInTheReopenedFieldUndoesTheJoinsSpeaker() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        #expect(rows(window) == [["T1"], ["T2"]])
        window.setEditMode(true)
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(await until { journal(session).count == 1 && window.turnList.wordEdit != nil })
        #expect(journal(session) == [.reassignTurns(turnIDs: ["T2"], to: "S1")])
        #expect(rows(window) == [["T1", "T2"]])
        #expect(window.turnList.wordEdit?.words.map(\.text) == ["cedar"])
        #expect(window.window.firstResponder === window.turnList.editField.currentEditor())
        #expect(window.handleKey(try commandZ(window)))
        #expect(await until { speaker(window, "T2") == "S2" && rows(window) == [["T1"], ["T2"]] })
        // With typing to undo in a text field, ⌘Z is the typing's; with none, or outside one, the review's.
        #expect(ReviewWindow.undoIsTyping(editingText: true, typingToUndo: true))
        #expect(!ReviewWindow.undoIsTyping(editingText: true, typingToUndo: false))
        #expect(!ReviewWindow.undoIsTyping(editingText: false, typingToUndo: true))
        await closeAndRemove(window, session)
    }

    /// Typing put back in the field without its undo (a ⇧-click widening the field, a failed save handing the text
    /// back): ⌘Z there never undoes the review's last change behind the user's text.
    @Test(.timeLimit(.minutes(1))) func commandZWithUnsavedTextAndNoUndoLeavesTheReviewAlone() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        window.setEditMode(true)
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(await until { journal(session).count == 1 && window.turnList.wordEdit != nil })
        // Text set as the field restores it: no undo registered for it.
        window.turnList.editField.stringValue = "Cedric"
        window.turnList.editField.currentEditor()?.undoManager?.removeAllActions()
        let joins = window.paragraphJoins
        #expect(!joins.isEmpty)
        #expect(window.handleKey(try commandZ(window)))
        // The review's undo would drop every join at once, before its revert is even queued.
        #expect(window.paragraphJoins == joins, "No review-level undo ran.")
        #expect(speaker(window, "T2") == "S1", "The join's speaker change stays.")
        #expect(journal(session).count == 1)
        #expect(ReviewWindow.undoIsTyping(editingText: true, typingToUndo: false, unsavedText: true))
        window.turnList.cancelWordEdit()
        await closeAndRemove(window, session)
    }

    /// "cedar" typed over with "dune", then everything selected and "cedar" typed again: the field reads as it opened,
    /// but it has typing to undo, so ⌘Z is the typing's. The review is not undone, and the join stays (a text undo is
    /// typing, not a review Undo).
    @Test(.timeLimit(.minutes(1))) func commandZWithTypingToUndoUndoesTheTypingAndKeepsTheJoins() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"])])
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(await until { journal(session).count == 1 && rows(window) == [["T1", "T2"]] })
        window.setEditMode(true)
        let list = window.turnList
        list.table.handleWordClick(row: 0, word: 2, through: 2, extend: false)
        let editor = try #require(list.editField.currentEditor() as? NSTextView)
        #expect(editor.undoManager?.canUndo != true, "Opened with no typing to undo.")
        editor.selectAll(nil)
        editor.insertText("dune", replacementRange: editor.selectedRange())
        editor.selectAll(nil)
        editor.insertText("cedar", replacementRange: editor.selectedRange())
        #expect(list.editField.stringValue == "cedar" && editor.undoManager?.canUndo == true)
        _ = window.handleKey(try commandZ(window))
        // Whatever ⌘Z queued runs before a change queued after it.
        for _ in 0..<10 { await Task.yield() }
        try await window.review.apply([.rename(speakerID: "S1", name: "Ash")])
        #expect(journal(session) == [.reassignTurns(turnIDs: ["T2"], to: "S1"), .rename(speakerID: "S1", name: "Ash")])
        #expect(window.paragraphJoins == ["T2"] && rows(window) == [["T1", "T2"]])
        list.cancelWordEdit()
        await closeAndRemove(window, session)
    }

    /// Closing by hand saves the field's typing first; that save fails (the transcript cannot be written): every join
    /// goes, as for any change that fails, and the window stays open with the field.
    @Test(.timeLimit(.minutes(1))) func aFailedSaveAtCloseDropsEveryJoin() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S1", start: 8, words: ["cedar", "dune"])])
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(window.paragraphJoins == ["T2"])
        window.setEditMode(true)
        let list = window.turnList
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = "Amber"
        let transcripts = SessionPaths.transcripts(session)
        window.review.beforeEdit = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: transcripts.path)
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcripts.path)
        }
        #expect(!window.windowShouldClose(window.window), "It saves the field first.")
        #expect(await until { window.paragraphJoins.isEmpty && rows(window) == [["T1"], ["T2"]] })
        window.review.beforeEdit = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcripts.path)
        #expect(journal(session).isEmpty)
        list.cancelWordEdit()
        await closeAndRemove(window, session)
    }

    /// Delete Audio starting while the field holds typing saves it first; when that save fails, every join is dropped,
    /// as for any failed save, though the labels run stays the same.
    @Test(.timeLimit(.minutes(1))) func aFailedSaveBeforeMaintenanceDropsEveryJoin() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S1", start: 8, words: ["cedar", "dune"])])
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(window.paragraphJoins == ["T2"])
        window.setEditMode(true)
        let list = window.turnList
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = "Amber"
        let transcripts = SessionPaths.transcripts(session)
        window.review.beforeEdit = {
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: transcripts.path)
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcripts.path)
        }
        let hold = ReviewMaintenance.Hold(.deleteAudio)
        await window.pauseForMaintenance(hold, banner: "Deleting this meeting's audio.")
        #expect(window.paragraphJoins.isEmpty)
        #expect(rows(window) == [["T1"], ["T2"]])
        window.review.beforeEdit = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcripts.path)
        await window.resumeAfterMaintenance(hold)
        await closeAndRemove(window, session)
    }

    /// A word edit saved before the join's speaker change ("amber" became "am ber", moving "birch" one on): forward
    /// Delete's field opens again at the end of "birch", where it is now, not on the word that took its old place.
    @Test(.timeLimit(.minutes(1))) func theFieldOpensWhereTheJoinsWordIsAfterAnEditSavedFirst() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 2, words: ["cedar", "dune"])])
        window.setEditMode(true)
        let list = window.turnList
        list.table.handleWordClick(row: 0, word: 0, through: 0, extend: false)
        list.editField.stringValue = "am ber"
        // Tab saves it (queued) and opens "birch", as shown before the edit saves.
        _ = list.control(list.editField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        #expect(list.wordEdit?.words.map(\.text) == ["birch"])
        list.editField.currentEditor()?.selectedRange = NSRange(location: 5, length: 0)
        _ = list.control(list.editField, textView: NSTextView(), doCommandBy: #selector(NSResponder.deleteForward(_:)))
        #expect(await until {
            journal(session).contains(.reassignTurns(turnIDs: ["T2"], to: "S1")) && list.wordEdit != nil
                && (window.review.turn("T1").map { window.review.text(of: $0).hasPrefix("am ber") } ?? false)
        })
        #expect(rows(window) == [["T1", "T2"]])
        #expect(list.wordEdit?.words.map(\.text) == ["birch"])
        #expect(list.wordEdit?.words.first?.ref.word == 2)
        #expect(list.editField.currentEditor()?.selectedRange == NSRange(location: 5, length: 0))
        list.cancelWordEdit()
        await closeAndRemove(window, session)
    }

    /// Return splits a turn and, while the split still saves (its second part has a temporary ID), Backspace joins
    /// the part back: the rows stay one once the split saves and the part takes its saved ID.
    @Test(.timeLimit(.minutes(1))) func aJoinMadeWhileItsSplitSavesStaysOnceItSaves() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch", "cedar"]),
                                                Spec(speaker: "S2", start: 3, words: ["dune", "elm"])])
        let (stream, release) = AsyncStream<Void>.makeStream()
        window.review.beforeEdit = { for await _ in stream {} }
        window.setEditMode(true)
        press(window, row: 0, word: 2, caret: 0, #selector(NSResponder.insertNewline(_:)))
        #expect(await until { rows(window).count == 3 })
        let part = try #require(rows(window)[1].first)
        #expect(part.hasPrefix("T1/") && journal(session).isEmpty, "Shown, not saved yet.")
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(rows(window) == [["T1", part], ["T2"]])
        release.finish()
        #expect(await until { journal(session).count == 1 && window.review.resolvedTurnID(part) != part })
        let saved = window.review.resolvedTurnID(part)
        #expect(await until { rows(window) == [["T1", saved], ["T2"]] })
        window.turnList.cancelWordEdit()
        await closeAndRemove(window, session)
    }

    /// A named speaker's row of a system-audio and a microphone turn, joined to the unknown speaker's row before it:
    /// the whole row joins, never parting by track once its turns are the unknown speaker's.
    @Test(.timeLimit(.minutes(1))) func aRowJoinedToTheUnknownSpeakerStaysWhole() async throws {
        let unknown = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
        let (window, session) = try await open([Spec(speaker: nil, start: 0, words: unknown),
                                                Spec(speaker: "S2", start: 4.5, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 6, words: ["cedar", "dune"], track: "mic")])
        #expect(rows(window) == [["T1"], ["T2", "T3"]])
        let offer = try #require(window.turnList.joinOffer(row: 1, index: 0))
        #expect(offer.refusal == nil)
        window.turnList.joinChosen(offer.choice)
        #expect(await until { journal(session) == [.reassignTurns(turnIDs: ["T2", "T3"], to: nil)] })
        #expect(await until { speaker(window, "T3") == nil && rows(window) == [["T1", "T2", "T3"]] })
        await closeAndRemove(window, session)
    }

    /// A change that fails drops every join, its own and any other: here the join's speaker change is refused (the
    /// labels were changed elsewhere meanwhile), and the earlier join of T3 to T2 goes too. Rows read as they group on
    /// their own again (T2 four seconds after T1, T3 six after T2: three rows).
    @Test(.timeLimit(.minutes(1))) func aFailedChangeDropsEveryJoin() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"]),
                                                Spec(speaker: "S2", start: 12, words: ["elm", "fern"])])
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 2, index: 0)).choice)
        #expect(rows(window) == [["T1"], ["T2", "T3"]] && window.paragraphJoins == ["T3"])
        // Elsewhere (a command): T2 goes to S1.
        let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
        _ = try SpeakerEditor.apply([.reassignTurns(turnIDs: ["T2"], to: "S1")], view: view, session: session,
                                    source: "cli", regenerateExports: false)
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(window.paragraphJoins == ["T2", "T3"], "Joined at once, while the speaker change saves.")
        #expect(await until {
            window.review.snapshot.journal.edits.count == 1 && window.paragraphJoins.isEmpty
                && rows(window) == [["T1"], ["T2"], ["T3"]]
        })
        #expect(journal(session) == [.reassignTurns(turnIDs: ["T2"], to: "S1")], "Only the change made elsewhere.")
        await closeAndRemove(window, session)
    }

    /// Any ⌘Z drops every join, whatever it undoes: here an unrelated rename made after the joins. The same speaker
    /// given to T2 again later (past the gap) leaves two rows, as any assignment would.
    @Test(.timeLimit(.minutes(1))) func anyUndoDropsEveryJoin() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"])])
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(await until { journal(session).count == 1 && rows(window) == [["T1", "T2"]] })
        try await window.review.apply([.rename(speakerID: "S1", name: "Ash")])
        #expect(window.paragraphJoins == ["T2"])
        window.window.makeFirstResponder(window.turnList.table)
        #expect(window.handleKey(try commandZ(window)))
        #expect(window.paragraphJoins.isEmpty, "At once, as ⌘Z is pressed.")
        #expect(await until { journal(session).count == 3 })
        // The join's own speaker change stays (only the rename was undone): T2 is S1's, past the gap, its own row.
        #expect(await until { speaker(window, "T2") == "S1" && rows(window) == [["T1"], ["T2"]] })
        await closeAndRemove(window, session)
    }

    /// ⌘Z before the join's speaker change was saved drops that change: the join goes with it.
    @Test(.timeLimit(.minutes(1))) func undoingAJoinBeforeItsSpeakerChangeSavesTakesTheJoinBack() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"])])
        // A change already saving holds the queue, so the join's speaker change waits behind it.
        let (stream, release) = AsyncStream<Void>.makeStream()
        window.review.beforeEdit = { for await _ in stream {} }
        let held = Task { try await window.review.setName("Ash", speakerID: "S1") }
        #expect(await until { window.review.canUndo })
        let offer = try #require(window.turnList.joinOffer(row: 1, index: 0))
        window.turnList.joinChosen(offer.choice)
        #expect(await until { speaker(window, "T2") == "S1" && window.paragraphJoins == ["T2"] })
        window.window.makeFirstResponder(window.turnList.table)
        #expect(window.handleKey(try commandZ(window)))
        release.finish()
        _ = try await held.value
        #expect(await until {
            speaker(window, "T2") == "S2" && window.paragraphJoins.isEmpty && rows(window) == [["T1"], ["T2"]]
        })
        #expect(!journal(session).contains(.reassignTurns(turnIDs: ["T2"], to: "S1")))
        await closeAndRemove(window, session)
    }

    /// The meeting labelled again (a new run, read by a reload): every join goes.
    @Test(.timeLimit(.minutes(1))) func aRelabelDropsEveryJoin() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S1", start: 8, words: ["cedar", "dune"])])
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(rows(window) == [["T1", "T2"]])
        let firstRun = window.review.snapshot.run?.id
        try relabel(session)
        await window.review.reload()
        #expect(await until {
            window.review.snapshot.run?.id != firstRun && window.paragraphJoins.isEmpty
                && rows(window) == [["T1"], ["T2"]]
        })
        await closeAndRemove(window, session)
    }

    /// Three speakers' rows, each past the gap: C joined to B, then B and C joined to A. Both saved, nothing undone:
    /// the three read as one row.
    @Test(.timeLimit(.minutes(1))) func twoJoinsInARowReadAsOneRow() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"]),
                                                Spec(speaker: "S3", start: 12, words: ["elm", "fern"])])
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 2, index: 0)).choice)
        #expect(await until { journal(session).count == 1 && rows(window) == [["T1"], ["T2", "T3"]] })
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(await until {
            // Read back by the review (not only on disk), so the window has settled with both saved.
            window.review.snapshot.journal.edits.count == 2 && speaker(window, "T3") == "S1"
        })
        window.refresh()
        #expect(rows(window) == [["T1", "T2", "T3"]])
        #expect(window.paragraphJoins == ["T2", "T3"])
        await closeAndRemove(window, session)
    }

    /// A row given to S2 (still saving), then joined back to the S1 row before it: the join follows its own
    /// assignment, never the speaker the labels had before; once both are saved the rows are one.
    @Test(.timeLimit(.minutes(1))) func aJoinFollowsItsOwnAssignmentNotTheSpeakerBeforeIt() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S1", start: 8, words: ["cedar", "dune"]),
                                                Spec(speaker: "S2", start: 20, words: ["elm", "fern"])])
        #expect(rows(window) == [["T1"], ["T2"], ["T3"]])
        let (stream, release) = AsyncStream<Void>.makeStream()
        window.review.beforeEdit = { for await _ in stream {} }
        let toS2 = Task { try await window.review.assign(["T2"], to: .speaker("S2")) }
        #expect(await until { speaker(window, "T2") == "S2" })
        window.refresh()
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(await until { speaker(window, "T2") == "S1" && rows(window) == [["T1", "T2"], ["T3"]] })
        release.finish()
        try await toS2.value
        #expect(await until {
            journal(session) == [.reassignTurns(turnIDs: ["T2"], to: "S2"), .reassignTurns(turnIDs: ["T2"], to: "S1")]
                && speaker(window, "T2") == "S1" && window.review.snapshot.journal.edits.count == 2
        })
        window.review.beforeEdit = nil
        window.refresh()
        #expect(rows(window) == [["T1", "T2"], ["T3"]])
        #expect(window.paragraphJoins == ["T2"])
        await closeAndRemove(window, session)
    }

    /// Return splits a named turn and, while the split saves, its first part goes to the unknown speaker and Backspace
    /// joins the second part back (to the unknown speaker too): the join waits for its own assignment, so the field
    /// opens again at the join, and ⌘Z later takes the join back with that assignment.
    @Test(.timeLimit(.minutes(1))) func aJoinOfASplitPartToTheUnknownSpeakerWaitsForItsOwnAssignment() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch", "cedar"]),
                                                Spec(speaker: "S2", start: 8, words: ["dune", "elm"])])
        let (stream, release) = AsyncStream<Void>.makeStream()
        window.review.beforeEdit = { for await _ in stream {} }
        window.setEditMode(true)
        press(window, row: 0, word: 2, caret: 0, #selector(NSResponder.insertNewline(_:)))
        #expect(await until { rows(window).count == 3 })
        let part = try #require(rows(window)[1].first)
        let toUnknown = Task { try await window.review.assign(["T1"], to: .unknown) }
        #expect(await until { speaker(window, "T1") == nil })
        window.refresh()
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(await until { speaker(window, part) == nil && rows(window) == [["T1", part], ["T2"]] })
        release.finish()
        try await toUnknown.value
        #expect(await until { journal(session).count == 3 && window.turnList.wordEdit != nil })
        let saved = window.review.resolvedTurnID(part)
        #expect(rows(window) == [["T1", saved], ["T2"]])
        #expect(window.turnList.wordEdit?.words.map(\.text) == ["cedar"])
        window.review.beforeEdit = nil
        window.turnList.cancelWordEdit()
        window.window.makeFirstResponder(window.turnList.table)
        #expect(window.handleKey(try commandZ(window)))
        #expect(await until {
            speaker(window, saved) == "S1" && window.paragraphJoins.isEmpty && rows(window) == [["T1"], [saved], ["T2"]]
        })
        await closeAndRemove(window, session)
    }

    /// A join resolved on rows the meeting was labelled again under before it was made (a reload adopted a relabel in
    /// between): refused, with nothing saved and no row joined, since its turn and speaker IDs may name others now.
    @Test(.timeLimit(.minutes(1))) func aJoinResolvedBeforeARelabelIsRefusedAfterIt() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"])])
        let request = try #require(window.turnList.joinRequest(row: 1))
        guard case .join(let join)? = window.turnList.resolveJoin?(request) else {
            Issue.record("Expected a join.")
            return
        }
        try relabel(session)
        await window.review.reload()
        #expect(await until { window.review.snapshot.run?.id != request.seen.runID })
        window.turnList.onJoin?(join, request)
        // Whatever the join queued runs before a change queued after it: let the window's task start, then wait for
        // one queued behind it.
        for _ in 0..<10 { await Task.yield() }
        try await window.review.apply([.rename(speakerID: "S1", name: "Ash")])
        #expect(journal(session) == [.rename(speakerID: "S1", name: "Ash")])
        #expect(window.paragraphJoins.isEmpty && rows(window) == [["T1"], ["T2"]])
        await closeAndRemove(window, session)
    }

    /// Backspace joins while another change saves, and ⌘Z drops the join's speaker change before it runs: the join
    /// is gone, the field does not open again saying "Joined" (whose ⌘Z hint would then undo the other change), and the
    /// other change stays.
    @Test(.timeLimit(.minutes(1))) func aJoinDroppedByUndoBeforeItRunsReopensNoField() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"])])
        let (stream, release) = AsyncStream<Void>.makeStream()
        window.review.beforeEdit = { for await _ in stream {} }
        let rename = Task { try await window.review.apply([.rename(speakerID: "S1", name: "Ash")]) }
        #expect(await until { window.review.canUndo })
        window.setEditMode(true)
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(await until { speaker(window, "T2") == "S1" && rows(window) == [["T1", "T2"]] })
        #expect(window.turnList.wordEdit == nil)
        window.window.makeFirstResponder(window.turnList.table)
        #expect(window.handleKey(try commandZ(window)))
        #expect(await until { speaker(window, "T2") == "S2" && window.paragraphJoins.isEmpty })
        release.finish()
        try await rename.value
        #expect(await until { window.review.snapshot.journal.edits.count == 1 })
        // Let the join's own task finish (it was waiting on the change Undo dropped), then look.
        for _ in 0..<10 { await Task.yield() }
        try await window.review.apply([.rename(speakerID: "S2", name: "Birch")])
        window.review.beforeEdit = nil
        #expect(window.turnList.wordEdit == nil, "No field opened for a join that was cancelled.")
        #expect(rows(window) == [["T1"], ["T2"]] && window.paragraphJoins.isEmpty)
        #expect(journal(session) == [.rename(speakerID: "S1", name: "Ash"), .rename(speakerID: "S2", name: "Birch")])
        await closeAndRemove(window, session)
    }

    /// C joined to B, then B and C joined to A; both speaker changes undone elsewhere (a command) before the window
    /// reads the labels again: every join goes, none is left behind on C, so C given B's speaker later stays apart
    /// (past the gap).
    @Test(.timeLimit(.minutes(1))) func joinsUndoneElsewhereLeaveNoMarkBehind() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"]),
                                                Spec(speaker: "S3", start: 12, words: ["elm", "fern"])])
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 2, index: 0)).choice)
        #expect(await until {
            window.review.snapshot.journal.edits.count == 1 && rows(window) == [["T1"], ["T2", "T3"]]
        })
        window.turnList.joinChosen(try #require(window.turnList.joinOffer(row: 1, index: 0)).choice)
        #expect(await until {
            window.review.snapshot.journal.edits.count == 2 && rows(window) == [["T1", "T2", "T3"]]
        })
        for _ in 0..<2 {
            let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
            _ = try SpeakerEditor.undoLast(view: view, session: session, source: "cli", regenerateExports: false)
        }
        await window.review.reload()
        #expect(await until {
            speaker(window, "T3") == "S3" && window.paragraphJoins.isEmpty && rows(window) == [["T1"], ["T2"], ["T3"]]
        })
        try await window.review.assign(["T3"], to: .speaker("S2"))
        #expect(await until { speaker(window, "T3") == "S2" })
        window.refresh()
        #expect(rows(window) == [["T1"], ["T2"], ["T3"]] && window.paragraphJoins.isEmpty)
        await closeAndRemove(window, session)
    }

    /// Backspace joins, and ⌘Z is pressed while the join's speaker change saves: once it saves, the field does not
    /// open again saying "Joined" (the person moved on); the revert then takes the join back.
    @Test(.timeLimit(.minutes(1))) func undoWhileTheJoinSavesOpensNoField() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"])])
        let (stream, release) = AsyncStream<Void>.makeStream()
        let calls = Calls()
        window.review.beforeEdit = { if calls.next() == 1 { for await _ in stream {} } }
        window.setEditMode(true)
        press(window, row: 1, word: 0, caret: 0, #selector(NSResponder.deleteBackward(_:)))
        #expect(await until { speaker(window, "T2") == "S1" && rows(window) == [["T1", "T2"]] })
        // Saving (held in the save): ⌘Z.
        #expect(await until { calls.peek() >= 1 })
        window.window.makeFirstResponder(window.turnList.table)
        #expect(window.handleKey(try commandZ(window)))
        release.finish()
        #expect(await until {
            window.review.snapshot.journal.edits.count == 2 && speaker(window, "T2") == "S2"
                && window.paragraphJoins.isEmpty && rows(window) == [["T1"], ["T2"]]
        })
        window.review.beforeEdit = nil
        #expect(window.turnList.wordEdit == nil, "No field opened for a join undone while it saved.")
        #expect(journal(session).first == .reassignTurns(turnIDs: ["T2"], to: "S1"))
        await closeAndRemove(window, session)
    }
}
