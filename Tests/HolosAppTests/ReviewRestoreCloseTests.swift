import AppKit
import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing
@testable import HolosApp

/// A Restore of deleted words is a word edit like any other for closing (docs/meeting/review-window.md §5.10, "Editing
/// words"): queued in the review at once and tracked by the window, so a close right after waits for it (by hand) or
/// closes the review with it queued (a quit), and a failure is reported. The text is made up.
@MainActor
struct ReviewRestoreCloseTests {
    /// A finished session with T1 (S1) "We will see." (segment A), T2 (S2) "Cheers." (segment D), and T3 (S1) "Right
    /// then." (segment E), D and E deleted whole in an earlier review; and its folder's parent, to remove.
    private func sessionWithDeletedWords() async throws -> (session: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-restore-\(UUID().uuidString)")
        func segment(_ id: String, _ words: [String], start: Double) -> TranscriptSegment {
            var text = ""
            var timed: [TimedWord] = []
            for (index, word) in words.enumerated() {
                if !text.isEmpty { text += " " }
                timed.append(TimedWord(text: word, start: start + Double(index), end: start + Double(index) + 0.8,
                                       utf16Offset: text.utf16.count, utf16Length: word.utf16.count))
                text += word
            }
            return TranscriptSegment(id: id, start: start, end: start + Double(words.count), text: text,
                                     words: timed, track: "system")
        }
        let transcript = Transcript(source: "fixture", locale: "en-CA", backend: .speech,
                                    segments: [segment("A", ["We", "will", "see."], start: 0),
                                               segment("D", ["Cheers."], start: 10),
                                               segment("E", ["Right", "then."], start: 20)])
        let archive = try SessionArchive.create(root: root, name: "Restore fixture", source: .system,
                                                locale: "en-CA", backend: .speech)
        try await archive.saveTranscript(transcript, writeLegacyExports: false)
        try await archive.finish(status: ArchiveStatus.complete)
        let session = archive.directory
        let manifest = try SessionArchive.readManifest(at: session)
        let speakers = ["system:S1", "system:S2"].enumerated().map {
            SessionSpeaker(id: $1, ordinal: $0 + 1, provenance: .diarizer, clusterIDs: [$1])
        }
        let turns = [("T1", "system:S1", "A", 0.0, 3.0, 3), ("T2", "system:S2", "D", 10.0, 11.0, 1),
                     ("T3", "system:S1", "E", 20.0, 22.0, 2)].map {
            SpeakerTurn(id: $0.0, track: "system", start: $0.3, end: $0.4, speakerID: $0.1, clusterID: $0.1,
                        spans: [WordSpan(segmentID: $0.2, first: 0, end: $0.5)], assignmentScore: 1,
                        timing: .measured)
        }
        let run = DiarizationRun(sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
                                 alignment: AlignmentInfo(version: 1, parameters: .v1),
                                 tracks: [TrackDiarization(track: "system", policy: .diarized, clusters: speakers.map {
                                     ClusterSummary(clusterID: $0.id, track: "system", speechSeconds: 2)
                                 })],
                                 speakers: speakers, turns: turns)
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.writeRun(run, session: session)
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
        }
        let first = try await ReviewSession(session: session, profiles: nil, maintenance: nil,
                                            exportDelay: .seconds(60))
        try await first.editWords(first.words(of: "T2").map(\.ref), to: "")
        try await first.editWords(first.words(of: "T3").map(\.ref), to: "")
        await first.close()
        return (session, root)
    }

    private func window(_ session: URL) async throws -> ReviewWindow {
        let review = try await ReviewSession(session: session, profiles: nil, maintenance: nil,
                                             exportDelay: .seconds(60))
        return ReviewWindow(sessionID: review.snapshot.manifest.id, review: review)
    }

    private func restored(_ session: URL) throws -> Bool {
        let current = try #require(try SessionFiles.currentTranscript(session: session))
        return current.segments.first { $0.id == "D" }?.text == "Cheers."
    }

    @Test(.timeLimit(.minutes(1))) func aRestoreRightBeforeAQuitLandsBeforeTheReviewCloses() async throws {
        let (session, root) = try await sessionWithDeletedWords()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = try await window(session)
        #expect(window.review.deletedWords().map(\.segmentID) == ["D", "E"])
        window.restoreDeleted("D")
        await window.closeAndWait()
        #expect(try restored(session))
        #expect(window.review.failedWordEditsAtClose.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aRestoreThatFailsAtAQuitIsReported() async throws {
        let (session, root) = try await sessionWithDeletedWords()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = try await window(session)
        // The labels change elsewhere just before the Restore saves: it is refused.
        window.review.beforeEdit = {
            try? SessionArchive.withSpeakerLock(at: session) {
                guard let head = try SessionSpeakerStore.readHead(session: session) else { return }
                var run = try SessionSpeakerStore.readRun(id: head.runID, session: session)
                run.id = UUID().uuidString
                try SessionSpeakerStore.writeRun(run, session: session)
                try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
            }
        }
        window.restoreDeleted("D")
        await window.closeAndWait()
        #expect(try !restored(session))
        let failed = window.review.failedWordEditsAtClose
        #expect(failed.count == 1)
        #expect(failed.first?.typed == ReviewSession.restoreDescription("D"))
        #expect(failed.first?.reason.isEmpty == false)
    }

    @Test(.timeLimit(.minutes(1))) func aCloseByHandRightAfterARestoreWaitsForIt() async throws {
        let (session, root) = try await sessionWithDeletedWords()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = try await window(session)
        let (gate, release) = AsyncStream<Void>.makeStream()
        window.review.beforeEdit = { for await _ in gate {} }
        window.restoreDeleted("D")
        // Still saving: the window does not close yet.
        #expect(!window.windowShouldClose(window.window))
        #expect(!window.isClosing)
        release.finish()
        // The close goes on once the Restore is saved (a poll budget, never a wall-clock bound).
        for _ in 0..<3_000 where !window.isClosing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.isClosing)
        await window.closeAndWait()
        #expect(try restored(session))
    }

    /// While a close by hand waits for an earlier save, no other Restore can be asked for (as no field opens): the
    /// menu offers none, and one asked for anyway is not queued, so nothing is left running after the window closes.
    @Test(.timeLimit(.minutes(1))) func noRestoreIsMadeWhileACloseWaitsForAnEarlierSave() async throws {
        let (session, root) = try await sessionWithDeletedWords()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = try await window(session)
        #expect(window.restorableDeletedWords.map(\.segmentID) == ["D", "E"])
        let (gate, release) = AsyncStream<Void>.makeStream()
        window.review.beforeEdit = { for await _ in gate {} }
        window.restoreDeleted("D")
        #expect(!window.windowShouldClose(window.window))
        // The close waits for D: E is neither offered nor made.
        #expect(window.restorableDeletedWords.isEmpty)
        let menuItem = NSMenuItem(title: ReviewWindow.restoreDeletedWordsTitle,
                                  action: #selector(ReviewWindow.restoreDeletedWords(_:)), keyEquivalent: "")
        #expect(!window.validateMenuItem(menuItem))
        let queued = window.review.queuedOperations
        window.restoreDeleted("E")
        #expect(window.review.queuedOperations == queued)
        release.finish()
        for _ in 0..<3_000 where !window.isClosing { try await Task.sleep(for: .milliseconds(10)) }
        await window.closeAndWait()
        let current = try #require(try SessionFiles.currentTranscript(session: session))
        #expect(current.segments.first { $0.id == "D" }?.removed == nil)
        #expect(current.segments.first { $0.id == "E" }?.removed != nil, "Never asked for while the close waited.")
    }

    /// A Restore saved whose speaker head then could not be published (the labels cannot be reread): the words are
    /// back, so it is no failure. A close by hand right after closes, and nothing is held as an edit not saved.
    @Test(.timeLimit(.minutes(1))) func aRestoreSavedBeforeItsRereadFailedIsNoFailure() async throws {
        let (session, root) = try await sessionWithDeletedWords()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = try await window(session)
        let (gate, release) = AsyncStream<Void>.makeStream()
        window.review.beforeEdit = { for await _ in gate {} }
        window.review.beforeHeadPublish = { throw HolosError.io("the speaker head is read-only") }
        window.restoreDeleted("D")
        #expect(!window.windowShouldClose(window.window))
        release.finish()
        for _ in 0..<3_000 where !window.isClosing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.isClosing, "Saved: the close goes on.")
        #expect(window.unsavedEditTexts.isEmpty)
        await window.closeAndWait()
        #expect(try restored(session))
        #expect(window.review.failedWordEditsAtClose.isEmpty)
    }
}
