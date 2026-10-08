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
        // Typing in a word's field, or any other text field: ⌘Z is the typing's.
        #expect(ReviewWindow.undoIsTyping(editingText: true, inUnchangedWordField: false))
        #expect(!ReviewWindow.undoIsTyping(editingText: true, inUnchangedWordField: true))
        #expect(!ReviewWindow.undoIsTyping(editingText: false, inUnchangedWordField: false))
        await window.closeAndWait()
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
        await window.closeAndWait()
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
        await window.closeAndWait()
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
        await window.closeAndWait()
    }

    /// The join's speaker change refused (the labels were changed elsewhere meanwhile): the rows part again, and
    /// nothing is left to join them later unasked. Here the change made elsewhere gave the turn that very speaker, four
    /// seconds after the row before: past the gap, they stay two rows.
    @Test(.timeLimit(.minutes(1))) func aRefusedJoinLeavesNothingToJoinTheRowsLater() async throws {
        let (window, session) = try await open([Spec(speaker: "S1", start: 0, words: ["amber", "birch"]),
                                                Spec(speaker: "S2", start: 5, words: ["cedar", "dune"])])
        // Elsewhere (a command): T2 goes to S1.
        let view = try #require(try SpeakerSessionSnapshot.load(session: session).projection)
        _ = try SpeakerEditor.apply([.reassignTurns(turnIDs: ["T2"], to: "S1")], view: view, session: session,
                                    source: "cli", regenerateExports: false)
        let offer = try #require(window.turnList.joinOffer(row: 1, index: 0))
        window.turnList.joinChosen(offer.choice)
        #expect(window.paragraphJoins == ["T2"], "Joined at once, while the speaker change saves.")
        // Refused: the labels are read again (T2 is S1's from elsewhere), and the join is taken back.
        #expect(await until {
            window.review.snapshot.journal.edits.count == 1 && speaker(window, "T2") == "S1"
                && window.paragraphJoins.isEmpty
        })
        #expect(await until { rows(window) == [["T1"], ["T2"]] })
        #expect(journal(session) == [.reassignTurns(turnIDs: ["T2"], to: "S1")], "Only the change made elsewhere.")
        await window.closeAndWait()
    }
}
