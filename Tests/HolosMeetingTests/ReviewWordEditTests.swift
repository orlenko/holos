import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// Editing words through the review's model (docs/meeting-design.md §5.10, "Editing words"): `ReviewSession.editWords`
// on fixture sessions, with its undo, learning, speaker edits, and paragraphs. Helpers are prefixed `wordEdit`.

private struct WordEditTurn {
    var speaker: String
    var start: Double
    var words: [String]
    /// Word indices of the turn's segment not in the turn (hidden, as the echo mask hides words), dropped by the run.
    var hidden: Set<Int> = []
}

/// A finished call whose head run has one turn per spec (T1, T2, … in time order), each on a segment of its own whose
/// words start a second apart and last 0.8 s.
/// With `apple`, every word but a segment's first carries the space before it in its range and text (" cloud"), as
/// Apple's speech recognition reports words.
private func wordEditSession(in temp: TemporaryDirectory, _ specs: [WordEditTurn],
                             apple: Bool = false) async throws -> URL {
    let segments = specs.map { spec -> TranscriptSegment in
        var segment = SessionFixtures.segment(spec.words, track: "system", start: spec.start, wordSeconds: 1)
        if apple {
            segment.words = segment.words.enumerated().map { index, word in
                guard index > 0 else { return word }
                var spaced = word
                spaced.utf16Offset -= 1
                spaced.utf16Length += 1
                spaced.text = " " + word.text
                return spaced
            }
        }
        return segment
    }
    let transcript = SessionFixtures.transcript(segments)
    let total = (specs.map { $0.start + Double($0.words.count) }.max() ?? 0) + 1
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": total],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    var ordinals: [String: Int] = [:]
    for spec in specs where ordinals[spec.speaker] == nil { ordinals[spec.speaker] = ordinals.count + 1 }
    let speakers = ordinals.sorted { $0.value < $1.value }.map {
        SessionSpeaker(id: $0.key, ordinal: $0.value, provenance: .diarizer, clusterIDs: [$0.key])
    }
    var dropped: [WordSpan] = []
    let turns = zip(specs, segments).enumerated().map { index, pair in
        let (spec, segment) = pair
        var spans: [WordSpan] = []
        for word in spec.words.indices {
            if spec.hidden.contains(word) {
                dropped.append(WordSpan(segmentID: segment.id, first: word, end: word + 1))
            } else if let last = spans.last, last.end == word {
                spans[spans.count - 1].end = word + 1
            } else {
                spans.append(WordSpan(segmentID: segment.id, first: word, end: word + 1))
            }
        }
        return SpeakerTurn(id: "T\(index + 1)", track: "system", start: spec.start,
                           end: spec.start + Double(spec.words.count), speakerID: spec.speaker,
                           clusterID: spec.speaker, spans: spans, overlap: false, otherClusters: [],
                           assignmentScore: 1, timing: .measured)
    }
    let clusters = speakers.map { ClusterSummary(clusterID: $0.id, track: "system", speechSeconds: 10) }
    var run = DiarizationRun(sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
                             alignment: AlignmentInfo(version: 1, parameters: .v1),
                             tracks: [TrackDiarization(track: "system", policy: .diarized, clusters: clusters)],
                             speakers: speakers, turns: turns)
    if !dropped.isEmpty { run.droppedWords = [DroppedWords(spans: dropped, reason: "echo")] }
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    return session
}

@MainActor
private func wordEditOpen(_ session: URL) async throws -> ReviewSession {
    try await ReviewSession(session: session, profiles: nil, maintenance: nil, exportDelay: .seconds(60))
}

@MainActor
private func wordEditRefs(_ review: ReviewSession, _ turnID: String, _ indices: [Int]) -> [WordRef] {
    let words = review.words(of: turnID)
    return indices.map { words[$0].ref }
}

private func wordEditCurrent(_ session: URL) throws -> Transcript {
    try #require(try SessionFiles.currentTranscript(session: session))
}

/// A corrections list in memory that a review teaches when it closes, as the app's does
/// (`CorrectionList.learnKeepingExisting`), and what each edit teaches: "heard" → "meant" as recorded, or with
/// `contextual`, the app's rule with every word a dictionary word (so a lone word is learned with its neighbour).
@MainActor
private final class WordEditLearner {
    var list: CorrectionList
    /// While set, the list cannot be written.
    var failing = false
    let contextual: Bool
    private(set) var taughtBy: [ReviewWordEdit] = []
    private(set) var lessons = 0

    init(_ list: CorrectionList = CorrectionList(), contextual: Bool = false) {
        self.list = list
        self.contextual = contextual
    }

    func attach(to review: ReviewSession) {
        review.correctionsToLearn = { [self] edit in
            taughtBy.append(edit)
            guard contextual else { return [Correction(heard: edit.heard, meant: edit.meant)] }
            return TranscriptEditLearning.corrections(heard: edit.heard, meant: edit.meant, before: edit.before,
                                                      after: edit.after, heardBefore: edit.heardBefore,
                                                      heardAfter: edit.heardAfter, isDictionaryWord: { _ in true })
        }
        review.learnCorrections = { [self] learned, taught in
            lessons += 1
            guard !failing else { return nil }
            return list.learnReplacingTaught(learned, taught: taught)
        }
    }

    /// What the list makes of `heard`, nil when nothing.
    func value(_ heard: String) -> String? { list.entry(forKey: CorrectionList.key(heard))?.meant }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditIsSavedLearnedAndUndoneExactlyWithSpeakerEditsAround() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
        WordEditTurn(speaker: "system:S2", start: 10, words: ["we", "will", "see"]),
    ])
    let original = try wordEditCurrent(session)
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner()
    learner.attach(to: review)
    try await review.apply([.rename(speakerID: "system:S1", name: "Alice")])
    let runBefore = review.projection.runID

    let edit = try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    #expect(edit == ReviewWordEdit(heard: "cloud", meant: "Claude", before: "ask", after: "now"))
    #expect(learner.taughtBy.isEmpty && learner.value("cloud") == nil, "Nothing is learned before the window closes.")
    let edited = try wordEditCurrent(session)
    #expect(edited.id != original.id)
    #expect(edited.segments.map(\.text) == ["ask Claude now", "we will see"])
    #expect(review.words(of: "T1").map(\.text) == ["ask", "Claude", "now"])
    #expect(review.words(of: "T1")[1].fix == TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit,
                                                                heardWords: 1))
    #expect(review.text(of: try #require(review.turn("T1"))) == "ask Claude now")
    #expect(review.projection.runID != runBefore && review.projection.turns.map(\.id) == ["T1", "T2"])
    #expect(review.speaker("system:S1")?.name == "Alice", "Speaker edits carry over to the edited words.")
    #expect(review.canUndo && review.exportsPending)
    #expect(try SessionArchive.readEvents(at: session).events.contains {
        $0.kind == MeetingEventKind.transcriptEdited && $0.details["transcriptID"] == edited.id
            && $0.details["base"] == original.id
    })

    // A speaker change after the edit, on the edited labels.
    try await review.assign(["T2"], to: .speaker("system:S1"))
    #expect(review.turn("T2")?.speakerID == "system:S1")

    // Undo takes back the reassignment, then the edit, then the rename.
    try await review.undo()
    #expect(review.turn("T2")?.speakerID == "system:S2")
    #expect(try wordEditCurrent(session).id == edited.id)
    try await review.undo()
    let restored = try wordEditCurrent(session)
    #expect(restored.id != original.id && restored.id != edited.id)
    #expect(restored.segments == original.segments, "Undo restores the words, their times, and their marks exactly.")
    #expect(review.words(of: "T1").map(\.text) == ["ask", "cloud", "now"])
    #expect(review.words(of: "T1").allSatisfy { $0.fix == nil })
    #expect(review.speaker("system:S1")?.name == "Alice")
    #expect(review.canUndo)
    try await review.undo()
    #expect(review.speaker("system:S1")?.name == "Speaker 1")
    #expect(!review.canUndo)
    await review.close()
    #expect(learner.lessons == 0 && learner.value("cloud") == nil, "The undone edit teaches nothing.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditInsideAParagraphKeepsItAndADeletionUndoes() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["first", "part"]),
        WordEditTurn(speaker: "system:S1", start: 3, words: ["I", "um", "think", "so"]),
        WordEditTurn(speaker: "system:S2", start: 10, words: ["other", "voice"]),
    ])
    let review = try await wordEditOpen(session)
    func paragraphs() -> [[String]] { ReviewParagraphs.group(review.projection.turns).map(\.turnIDs) }
    #expect(paragraphs() == [["T1", "T2"], ["T3"]])

    // "um" deleted: merged into "think", which keeps both times.
    let edit = try await review.editWords(wordEditRefs(review, "T2", [1]), to: "")
    #expect(edit?.deletion == true && edit?.heard == "um think" && edit?.meant == "think")
    #expect(review.words(of: "T2").map(\.text) == ["I", "think", "so"])
    #expect(review.words(of: "T2")[1].start == 4, "Playback from the merged word starts where the deleted one did.")
    #expect(paragraphs() == [["T1", "T2"], ["T3"]])
    try await review.undo()
    #expect(review.words(of: "T2").map(\.text) == ["I", "um", "think", "so"])
    #expect(paragraphs() == [["T1", "T2"], ["T3"]])

    // More words than there were.
    try await review.editWords(wordEditRefs(review, "T2", [2, 3]), to: "think it is so")
    #expect(review.words(of: "T2").map(\.text) == ["I", "um", "think", "it", "is", "so"])
    #expect(review.text(of: try #require(review.turn("T2"))) == "I um think it is so")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func editsInARowAreUndoneOneAfterAnother() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
        WordEditTurn(speaker: "system:S2", start: 10, words: ["we", "will", "see"]),
    ])
    let original = try wordEditCurrent(session)
    let review = try await wordEditOpen(session)
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    try await review.editWords(wordEditRefs(review, "T2", [1]), to: "")
    try await review.editWords(wordEditRefs(review, "T1", [0, 1]), to: "Ask Claude")
    #expect(try wordEditCurrent(session).segments.map(\.text) == ["Ask Claude now", "we see"])
    // Each undo makes a copy of the transcript the edit was made on current; the edit before it is undone from that.
    try await review.undo()
    #expect(try wordEditCurrent(session).segments.map(\.text) == ["ask Claude now", "we see"])
    try await review.undo()
    #expect(try wordEditCurrent(session).segments.map(\.text) == ["ask Claude now", "we will see"])
    try await review.undo()
    #expect(try wordEditCurrent(session).segments == original.segments)
    #expect(!review.canUndo)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditAskedForWhileAnEarlierOneOfItsSegmentSavesFollowsItsWords() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["I", "um", "think", "so"]),
    ])
    let review = try await wordEditOpen(session)
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    let words = review.words(of: "T1")
    // "um" deleted (merged into "think"), and before that is saved, "think" and then "so" edited: Tab moves on
    // before a save ends.
    let first = Task { try await review.editWords([words[1].ref], to: "") }
    #expect(await eventually { entered.value == 1 })
    let second = Task { try await review.editWords([words[2].ref], to: "believe") }
    let third = Task { try await review.editWords([words[3].ref], to: "so.") }
    #expect(await eventually { review.queuedOperations == 3 }, "Both later edits wait behind the first.")
    release.finish()
    _ = try await first.value
    _ = try await second.value
    _ = try await third.value
    #expect(try wordEditCurrent(session).segments[0].text == "I believe so.")
    #expect(review.words(of: "T1").map(\.text) == ["I", "believe", "so."])
    #expect(review.wordMoves.count == 3)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditQueuedBehindADeletionInAnAppleTranscriptFindsTheMergedWord() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["I", "um", "think", "so"]),
    ], apple: true)
    let review = try await wordEditOpen(session)
    #expect(review.words(of: "T1").map(\.text) == ["I", " um", " think", " so"])
    #expect(review.shownText(of: [review.words(of: "T1")[2].ref]) == "think")
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    let words = review.words(of: "T1")
    let first = Task { try await review.editWords([words[1].ref], to: "") }
    #expect(await eventually { entered.value == 1 })
    // "think", merged with the deleted "um", loses the space at the front of its range: still the same word shown.
    let second = Task { try await review.editWords([words[2].ref], to: "believe") }
    #expect(await eventually { review.queuedOperations == 2 })
    release.finish()
    _ = try await first.value
    _ = try await second.value
    #expect(try wordEditCurrent(session).segments[0].text == "I believe so")
    await review.close()
}

@Test(.timeLimit(.minutes(1)))
func aSaveThatFailsAfterTheTranscriptBecameCurrentIsAPublicationStillOwed() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let original = try wordEditCurrent(session)
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    struct DirectorySync: Error {}
    // The pointer was renamed into place, then syncing its folder failed.
    do {
        _ = try await TranscriptPointerSave.$afterSave.withValue({ throw DirectorySync() }) {
            try await SessionWordEdit.run(
                session: session,
                request: TranscriptWordEdit.Request(segmentID: original.segments[0].id, first: 1, end: 2,
                                                    text: "Claude"),
                expectedTranscriptID: original.id, expectedRunID: runID)
        }
        Issue.record("The save failure was not reported.")
    } catch let incomplete as SessionWordEdit.IncompletePublication {
        let outcome = try #require(incomplete.outcome, "What was published is kept: its undo and move are recorded.")
        #expect(try wordEditCurrent(session).id == outcome.transcriptID)
        #expect(try SessionSpeakerStore.readHead(session: session)?.runID == runID, "The head is still owed.")
    }
    try await SessionWordEdit.repairCurrentHead(session: session, expectedTranscriptID: original.id,
                                                expectedRunID: runID)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(!snapshot.transcriptChanged && snapshot.transcript.segments[0].text == "ask Claude now")
}

/// One segment shared by two speakers' turns: T1 (system:S1) has words `0..<split`, T2 (system:S2) the rest; `times`
/// are each word's start and end.
private func wordEditSharedSession(in temp: TemporaryDirectory, _ words: [String], times: [(Double, Double)],
                                   split: Int) async throws -> URL {
    var segment = SessionFixtures.segment(words, track: "system", start: 0, wordSeconds: 1)
    for (index, time) in times.enumerated() {
        segment.words[index].start = time.0
        segment.words[index].end = time.1
    }
    segment.start = times.first?.0 ?? 0
    segment.end = times.last?.1 ?? 0
    let transcript = SessionFixtures.transcript([segment])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 5],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let speakers = ["system:S1", "system:S2"].enumerated().map {
        SessionSpeaker(id: $1, ordinal: $0 + 1, provenance: .diarizer, clusterIDs: [$1])
    }
    func turn(_ id: String, _ speaker: String, _ words: Range<Int>) -> SpeakerTurn {
        SpeakerTurn(id: id, track: "system", start: times[words.lowerBound].0, end: times[words.upperBound - 1].1,
                    speakerID: speaker, clusterID: speaker,
                    spans: [WordSpan(segmentID: segment.id, first: words.lowerBound, end: words.upperBound)],
                    overlap: false, otherClusters: [], assignmentScore: 1, timing: .measured)
    }
    let run = DiarizationRun(sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
                             alignment: AlignmentInfo(version: 1, parameters: .v1),
                             tracks: [TrackDiarization(track: "system", policy: .diarized, clusters: speakers.map {
                                 ClusterSummary(clusterID: $0.id, track: "system", speechSeconds: 2)
                             })],
                             speakers: speakers,
                             turns: [turn("T1", "system:S1", 0..<split), turn("T2", "system:S2", split..<words.count)])
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    return session
}

/// The head run's word spans, by turn ID.
private func wordEditHeadSpans(_ session: URL) throws -> [String: [WordSpan]] {
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    let run = try SessionSpeakerStore.readRun(id: runID, session: session)
    return Dictionary(uniqueKeysWithValues: run.turns.map { ($0.id, $0.spans) })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditKeepsEveryWordsOwnerWhenRecognizerTimingsOverlapAcrossSpeakers() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // S1's "there" (0.6–1.2 s) overlaps S2's "yes" (1.1–1.7 s).
    let session = try await wordEditSharedSession(in: temp, ["hello", "there", "yes", "indeed"],
                                                  times: [(0, 0.6), (0.6, 1.2), (1.1, 1.7), (1.7, 2.3)], split: 2)
    let segmentID = try wordEditCurrent(session).segments[0].id
    func spans(_ t1: Range<Int>, _ t2: Range<Int>) -> [String: [WordSpan]] {
        ["T1": [WordSpan(segmentID: segmentID, first: t1.lowerBound, end: t1.upperBound)],
         "T2": [WordSpan(segmentID: segmentID, first: t2.lowerBound, end: t2.upperBound)]]
    }
    let review = try await wordEditOpen(session)
    func shown() -> [[String]] { ["T1", "T2"].map { review.words(of: $0).map(\.text) } }

    try await review.editWords(wordEditRefs(review, "T2", [0]), to: "yeah")
    #expect(shown() == [["hello", "there"], ["yeah", "indeed"]])
    #expect(try wordEditHeadSpans(session) == spans(0..<2, 2..<4))
    // More words: they all go to the turn of the word they replace; the words after keep theirs.
    try await review.editWords(wordEditRefs(review, "T2", [0]), to: "yeah right")
    #expect(shown() == [["hello", "there"], ["yeah", "right", "indeed"]])
    #expect(try wordEditHeadSpans(session) == spans(0..<2, 2..<5))
    // A deletion beside the other speaker's word merges into its own turn's neighbour.
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "")
    #expect(shown() == [["hello"], ["yeah", "right", "indeed"]])
    #expect(try wordEditHeadSpans(session) == spans(0..<1, 1..<4))

    // Each undo maps the words back the same way.
    try await review.undo()
    #expect(shown() == [["hello", "there"], ["yeah", "right", "indeed"]])
    #expect(try wordEditHeadSpans(session) == spans(0..<2, 2..<5))
    try await review.undo()
    try await review.undo()
    #expect(shown() == [["hello", "there"], ["yes", "indeed"]])
    #expect(try wordEditHeadSpans(session) == spans(0..<2, 2..<4))
    await review.close()

    // A head still owed after the transcript became current is repaired with the move the journal recorded.
    let original = try wordEditCurrent(session)
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    struct DirectorySync: Error {}
    await #expect(throws: SessionWordEdit.IncompletePublication.self) {
        _ = try await TranscriptPointerSave.$afterSave.withValue({ throw DirectorySync() }) {
            try await SessionWordEdit.run(
                session: session,
                request: TranscriptWordEdit.Request(segmentID: segmentID, first: 2, end: 3, text: "yeah"),
                expectedTranscriptID: original.id, expectedRunID: runID)
        }
    }
    try await SessionWordEdit.repairCurrentHead(session: session, expectedTranscriptID: original.id,
                                                expectedRunID: runID)
    #expect(try wordEditCurrent(session).segments[0].text == "hello there yeah indeed")
    #expect(try wordEditHeadSpans(session) == spans(0..<2, 2..<4))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aRelabelSavedBeforeAnEditsRereadIsAChangeMadeElsewhere() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    let original = try #require(review.snapshot.run?.id)
    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    // Another process relabels the edited transcript after the edit published its labels, before the window rereads.
    var relabelled: String?
    review.beforeWordChangeReread = {
        let head = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
        var run = try SessionSpeakerStore.readRun(id: head, session: session)
        run.id = UUID().uuidString
        relabelled = run.id
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.writeRun(run, session: session)
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
        }
    }
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    review.beforeWordChangeReread = nil
    let relabel = try #require(relabelled)
    #expect(review.snapshot.run?.id == relabel)
    #expect(!review.keepsTurns(of: original, in: relabel), "The relabel is not the edit's run.")
    // The labels changed elsewhere: the rename's undo, made on the old labels, is gone; the edit's own stays.
    try await review.undo()
    #expect(try wordEditCurrent(session).segments[0].text == "ask cloud now")
    #expect(!review.canUndo)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func wordsEditedTogetherThatARelabelPutInTwoTurnsAreNotRevertible() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "more", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner()
    learner.attach(to: review)
    try await review.editWords(wordEditRefs(review, "T1", [1, 2]), to: "much Claude")
    #expect(review.words(of: "T1").map(\.revertible) == [true, true, true, true])
    #expect(review.words(of: "T1")[1].fix?.kind == .reviewEdit)

    // A relabel (as Find More Speakers makes) puts a turn boundary inside the edited words.
    let head = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    var run = try SessionSpeakerStore.readRun(id: head, session: session)
    let segmentID = try #require(run.turns.first?.spans.first?.segmentID)
    var first = run.turns[0]
    var second = first
    first.spans = [WordSpan(segmentID: segmentID, first: 0, end: 2)]
    first.end = 2
    second.id = "T2"
    second.spans = [WordSpan(segmentID: segmentID, first: 2, end: 4)]
    second.start = 2
    run.turns = [first, second]
    run.id = UUID().uuidString
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    await review.reload()
    #expect(review.words(of: "T1").map(\.revertible) == [true, false])
    #expect(review.words(of: "T2").map(\.revertible) == [false, true])
    #expect(review.words(of: "T1")[1].fix?.kind == .reviewEdit, "Still shown as edited.")
    // Revert would be refused, as would an edit of them (it takes in the words edited together, in both turns); the
    // other words of each turn can still be edited.
    await #expect(throws: HolosError.self) { try await review.revertWordFix(wordEditRefs(review, "T1", [1])[0]) }
    await #expect(throws: HolosError.self) { try await review.editWords(wordEditRefs(review, "T2", [0]), to: "x") }
    try await review.editWords(wordEditRefs(review, "T2", [1]), to: "today")
    #expect(try wordEditCurrent(session).segments[0].text == "ask much Claude today")
    await review.close()
    // At close, the words edited together are not learned: they now mix two turns' words ("more cloud" → "much
    // Claude" would teach one speaker's words with another's). The edit beside them, in one turn, is learned alone.
    #expect(learner.taughtBy == [ReviewWordEdit(heard: "now", meant: "today", before: "Claude")])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aHeadThatCouldNotBePublishedHoldsTheReviewUntilAReloadRepairsIt() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let original = try wordEditCurrent(session)
    let review = try await wordEditOpen(session)
    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    let failing = SharedValue(true)
    review.beforeHeadPublish = { if failing.value { throw HolosError.io("the speaker head is read-only") } }

    // The edit's transcript is current; its head, and the repair right after, cannot be published.
    await #expect(throws: HolosError.self) {
        try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    }
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
    #expect(review.reloadProblem != nil && !review.canEditWords)

    // Reload: the repair fails again, so the labels made on the words as they were are not taken; still held.
    await review.reload()
    #expect(review.reloadProblem?.contains("could not be saved") == true)
    #expect(!review.canEditWords && !review.isEditable)
    #expect(review.snapshot.transcript.id == original.id, "Labels on the old transcript are not adopted.")

    // Reload once the head can be published: repaired, resumed, and the edit is still undoable.
    failing.set(false)
    await review.reload()
    #expect(review.reloadProblem == nil && review.canEditWords)
    #expect(!review.snapshot.transcriptChanged)
    #expect(review.words(of: "T1").map(\.text) == ["ask", "Claude", "now"])
    #expect(review.speaker("system:S1")?.name == "Ann", "The turn edits were carried over.")
    #expect(review.canUndo)
    try await review.undo()
    #expect(try wordEditCurrent(session).segments == original.segments)
    #expect(review.words(of: "T1").map(\.text) == ["ask", "cloud", "now"])
    #expect(review.speaker("system:S1")?.name == "Ann")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditSavedBeforeItsRereadFailedStillReachesTheCallerAndIsLearnedWithContextAtClose() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["I", "right", "now"]),
    ])
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner(contextual: true)
    learner.attach(to: review)
    struct Unreadable: Error {}
    review.beforeWordChangeReread = { throw Unreadable() }
    var committed: [ReviewWordEdit] = []
    await #expect(throws: HolosError.self) {
        try await review.editWords(wordEditRefs(review, "T1", [1]), to: "write") { committed.append($0) }
    }
    // Saved: what follows from it (⌥Return's word-list term) still has the edit.
    #expect(committed.map(\.meant) == ["write"])
    #expect(review.reloadProblem != nil)
    // Closed without a Reload: the labels are read again, so the lone dictionary word is learned with its neighbour.
    await review.close()
    #expect(learner.taughtBy == [ReviewWordEdit(heard: "right", meant: "write", before: "I", after: "now")])
    #expect(learner.list.entries.contains { $0.meant.contains("write") })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditsUndoGoesOnceAnotherProcessReplacedTheTranscriptAndUndoReachesTheChangeBefore() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    // Another process makes a new current transcript; the labels stay on the edit's.
    var replaced = try wordEditCurrent(session)
    replaced.id = UUID().uuidString
    try await SessionFixtures.saveTranscript(replaced, in: session)
    await review.reload()
    #expect(review.snapshot.transcriptChanged)
    // The edit's undo can never be made now: undo takes back the rename instead.
    #expect(review.canUndo)
    try await review.undo()
    #expect(review.speaker("system:S1")?.name != "Ann")
    #expect(try wordEditCurrent(session).id == replaced.id, "The words were not touched.")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditWhoseLabelsCannotBeRereadCanStillBeUndone() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let original = try wordEditCurrent(session)
    let review = try await wordEditOpen(session)
    struct Unreadable: Error {}

    // Committed, then the labels cannot be reread: the edit is kept, and undoable once they are.
    review.beforeWordChangeReread = { throw Unreadable() }
    await #expect(throws: HolosError.self) { try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude") }
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
    #expect(review.reloadProblem != nil && review.canUndo)
    review.beforeWordChangeReread = nil
    await review.reload()
    #expect(review.reloadProblem == nil && review.canUndo, "The reread knows the edit's run keeps the turns.")
    #expect(review.words(of: "T1").map(\.text) == ["ask", "Claude", "now"])

    // The undo is committed, then its reread fails: it is undone all the same.
    review.beforeWordChangeReread = { throw Unreadable() }
    await #expect(throws: HolosError.self) { try await review.undo() }
    #expect(try wordEditCurrent(session).segments == original.segments)
    review.beforeWordChangeReread = nil
    await review.reload()
    #expect(review.words(of: "T1").map(\.text) == ["ask", "cloud", "now"])
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aQueuedEditWaitsForTheRereadAnEarlierEditsFailureNeeds() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["I", "um", "think", "so"]),
    ])
    let review = try await wordEditOpen(session)
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    struct Unreadable: Error {}
    var failures = 1
    review.beforeWordChangeReread = {
        guard failures > 0 else { return }
        failures -= 1
        throw Unreadable()
    }
    let words = review.words(of: "T1")
    let first = Task { try await review.editWords([words[1].ref], to: "") }
    #expect(await eventually { entered.value == 1 })
    let second = Task { try await review.editWords([words[3].ref], to: "so.") }
    #expect(await eventually { review.queuedOperations == 2 })
    release.finish()
    // The first is saved, its labels cannot be reread: the second waits, still queued, rather than being refused.
    await #expect(throws: HolosError.self) { _ = try await first.value }
    #expect(review.reloadProblem != nil)
    #expect(review.queuedOperations == 1)
    await review.reload()
    _ = try await second.value
    #expect(try wordEditCurrent(session).segments[0].text == "I think so.")
    #expect(review.reloadProblem == nil && review.queuedOperations == 0)
    await review.close()
}

// MARK: - Learning, when a review closes, from every edited word

/// "cloud now and cloud later" in one turn.
private func wordEditCloudSession(_ temp: TemporaryDirectory) async throws -> URL {
    try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["cloud", "now", "and", "cloud", "later"]),
    ])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditStillThereWhenTheReviewClosesIsLearned() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner(CorrectionList(entries: [Correction(heard: "other", meant: "Other")]))
    learner.attach(to: review)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claudia")
    #expect(learner.value("cloud") == nil, "Nothing is learned while editing.")
    await review.close()
    // What the transcript holds: "cloud" → "Claudia", with its neighbour as context.
    #expect(learner.taughtBy == [ReviewWordEdit(heard: "cloud", meant: "Claudia", after: "now")])
    #expect(learner.value("cloud") == "Claudia" && learner.value("other") == "Other")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditUndoneOrRevertedBeforeCloseTeachesNothing() async throws {
    for revert in [false, true] {
        let temp = try TemporaryDirectory("review")
        defer { temp.remove() }
        let session = try await wordEditCloudSession(temp)
        let review = try await wordEditOpen(session)
        let learner = WordEditLearner()
        learner.attach(to: review)
        try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
        if revert {
            try await review.revertWordFix(wordEditRefs(review, "T1", [0])[0])
        } else {
            try await review.undo()
        }
        #expect(try wordEditCurrent(session).segments[0].text == "cloud now and cloud later")
        await review.close()
        #expect(learner.list.entries.isEmpty, revert ? "Reverted" : "Undone")
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func learningAgainAtTheNextCloseChangesNothingAndASecondOccurrenceIsAdded() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let learner = WordEditLearner(contextual: true)
    let first = try await wordEditOpen(session)
    learner.attach(to: first)
    try await first.editWords(wordEditRefs(first, "T1", [0]), to: "Claude")
    await first.close()
    #expect(learner.list.entries == [Correction(heard: "cloud now", meant: "Claude now")])
    // Reopened and closed: the meeting taught that already, so nothing is written.
    let again = try await wordEditOpen(session)
    learner.attach(to: again)
    await again.close()
    #expect(learner.list.entries == [Correction(heard: "cloud now", meant: "Claude now")] && learner.lessons == 1)
    // The second "cloud", spelled otherwise, has its own context: added beside the first.
    let third = try await wordEditOpen(session)
    learner.attach(to: third)
    try await third.editWords(wordEditRefs(third, "T1", [3]), to: "Klaud")
    await third.close()
    #expect(learner.list.entries == [Correction(heard: "cloud now", meant: "Claude now"),
                                     Correction(heard: "cloud later", meant: "Klaud later")])
}

@Test func contextBesideAFixedWordIsWhatTheRecognizerWroteThere() {
    // "as cloud now": "cloud" fixed automatically to "Claude", then "as" edited to "ask". And "we new here", with
    // "new" edited to "knew" beside words no fix changed.
    var fixed = SessionFixtures.segment(["ask", "Claude", "now"], track: "system", start: 0, wordSeconds: 1, id: "S1")
    fixed.fixes = [TranscriptWordFix(first: 0, end: 1, heard: "as", kind: .reviewEdit, heardWords: 1),
                   TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .correction, heardWords: 1)]
    var plain = SessionFixtures.segment(["we", "knew", "here"], track: "system", start: 10, wordSeconds: 1, id: "S2")
    plain.fixes = [TranscriptWordFix(first: 1, end: 2, heard: "new", kind: .reviewEdit, heardWords: 1)]
    let edits = ReviewLearning.edits(in: SessionFixtures.transcript([fixed, plain]), sameTurn: { _, _, _ in true })
    #expect(edits == [
        ReviewWordEdit(heard: "as", meant: "ask", after: "Claude", heardAfter: "cloud"),
        ReviewWordEdit(heard: "new", meant: "knew", before: "we", after: "here"),
    ])
    // The heard side is the recognizer's text throughout, so the correction matches it: "as cloud" → "ask Claude".
    let learned = TranscriptEditLearning.corrections(heard: "as", meant: "ask", after: "Claude", heardAfter: "cloud",
                                                     isDictionaryWord: { _ in true })
    #expect(learned.map(\.heard) == ["as cloud"] && learned.map(\.meant) == ["ask Claude"])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aWordBesideAnAutomaticFixIsLearnedAgainstWhatTheRecognizerWrote() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditFixedCloudSession(temp, words: ["as", "cloud", "now"])
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner(contextual: true)
    learner.attach(to: review)
    #expect(review.words(of: "T1").map(\.text) == ["as", "Claude", "now"])
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "ask")
    await review.close()
    #expect(learner.value("as cloud") == "ask Claude", "Matches the recognizer's “as cloud” next time.")
    #expect(learner.value("as Claude") == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aRelabelWaitsBehindChangesQueuedBeforeItWhileTheLabelsAreUnread() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    // `voiceislocal session diarize` that notes whether the rename was saved when it ran, and changes nothing.
    let marker = temp.url.appendingPathComponent("rename-saved-first")
    let script = temp.url.appendingPathComponent("fake-holos.sh")
    try Data(("#!/bin/sh\ngrep -q 'Ann' '\(SessionPaths.edits(session).path)' && touch '\(marker.path)'\n"
        + "echo '{\"message\": \"Nothing could be done.\"}'\nexit 1\n").utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let review = try await ReviewSession(session: session, profiles: nil,
                                         maintenance: MaintenanceLauncher(executable: script),
                                         exportDelay: .seconds(60))
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    struct Unreadable: Error {}
    var failures = 1
    review.beforeWordChangeReread = {
        guard failures > 0 else { return }
        failures -= 1
        throw Unreadable()
    }
    // An edit (its reread will fail), then a rename, then Label Again, queued in that order.
    let edit = Task { try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude") }
    #expect(await eventually { entered.value == 1 })
    let rename = Task { try await review.apply([.rename(speakerID: "system:S1", name: "Ann")]) }
    let relabel = Task { try await review.labelAgain() }
    #expect(await eventually { review.queuedOperations == 3 })
    review.beforeEdit = nil
    release.finish()
    await #expect(throws: HolosError.self) { _ = try await edit.value }
    #expect(review.reloadProblem != nil)
    // The relabel does not run ahead of the rename held behind the failed reread.
    #expect(review.queuedOperations == 2)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    await review.reload()
    try await rename.value
    await #expect(throws: HolosError.self) { try await relabel.value }
    #expect(FileManager.default.fileExists(atPath: marker.path), "The rename was saved before the relabel ran.")
    #expect(review.speaker("system:S1")?.name == "Ann", "Carried forward.")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aMeetingsLaterEditReplacesWhatItTaughtButNeverAValueSetElsewhere() async throws {
    for external in [false, true] {
        let temp = try TemporaryDirectory("review")
        defer { temp.remove() }
        let session = try await wordEditCloudSession(temp)
        let learner = WordEditLearner()
        let first = try await wordEditOpen(session)
        learner.attach(to: first)
        try await first.editWords(wordEditRefs(first, "T1", [0]), to: "Claude")
        await first.close()
        #expect(learner.value("cloud") == "Claude")
        if external { learner.list.set(Correction(heard: "cloud", meant: "Cloud9"), forKey: "cloud") }
        // Reopened, the same word edited again.
        let second = try await wordEditOpen(session)
        learner.attach(to: second)
        try await second.editWords(wordEditRefs(second, "T1", [0]), to: "Claudia")
        await second.close()
        let taught = try ReviewLearning.taught(session: session)
        if external {
            #expect(learner.value("cloud") == "Cloud9", "A value set elsewhere is kept.")
            #expect(taught == [Correction(heard: "cloud", meant: "Claude")], "Claudia was not taught.")
        } else {
            #expect(learner.value("cloud") == "Claudia", "The meeting's own earlier lesson gives way.")
            #expect(taught == [Correction(heard: "cloud", meant: "Claudia")])
        }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func editsSideBySideAreLearnedAsOnePhraseFromWhatTheRecognizerWrote() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["we", "bull", "requested", "it"]),
        WordEditTurn(speaker: "system:S1", start: 10, words: ["ask", "cloud", "and", "cloud", "later"]),
    ])
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner()
    learner.attach(to: review)
    // "bull" → "pull", then (Tab) "requested" → "request": two edits side by side.
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "pull")
    try await review.editWords(wordEditRefs(review, "T1", [2]), to: "request")
    // One unedited word between two edits: each is learned on its own, beside the words as the recognizer wrote them.
    try await review.editWords(wordEditRefs(review, "T2", [1]), to: "Claude")
    try await review.editWords(wordEditRefs(review, "T2", [3]), to: "Claude")
    await review.close()
    #expect(learner.taughtBy == [
        ReviewWordEdit(heard: "bull requested", meant: "pull request", before: "we", after: "it"),
        ReviewWordEdit(heard: "cloud", meant: "Claude", before: "ask", after: "and"),
        ReviewWordEdit(heard: "cloud", meant: "Claude", before: "and", after: "later"),
    ])
    #expect(learner.value("bull requested") == "pull request")
    #expect(learner.value("pull requested") == nil && learner.value("bull request") == nil,
            "Never a phrase half corrected.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func learningTakesContextOnlyFromTheEditedWordsOwnTurnAsShown() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // One segment, two speakers: S1 says "say cloud", S2 "yes please"; then S1's "um cloud echo now", whose "echo"
    // is hidden.
    let segment = SessionFixtures.segment(["say", "cloud", "yes", "please"], track: "system", start: 0, wordSeconds: 1)
    let other = SessionFixtures.segment(["um", "cloud", "echo", "now"], track: "system", start: 10, wordSeconds: 1)
    let transcript = SessionFixtures.transcript([segment, other])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 15],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let speakers = ["system:S1", "system:S2"].enumerated().map {
        SessionSpeaker(id: $1, ordinal: $0 + 1, provenance: .diarizer, clusterIDs: [$1])
    }
    func turn(_ id: String, _ speaker: String, _ spans: [WordSpan], _ start: Double, _ end: Double) -> SpeakerTurn {
        SpeakerTurn(id: id, track: "system", start: start, end: end, speakerID: speaker, clusterID: speaker,
                    spans: spans, overlap: false, otherClusters: [], assignmentScore: 1, timing: .measured)
    }
    var run = DiarizationRun(sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
                             alignment: AlignmentInfo(version: 1, parameters: .v1),
                             tracks: [TrackDiarization(track: "system", policy: .diarized, clusters: speakers.map {
                                 ClusterSummary(clusterID: $0.id, track: "system", speechSeconds: 5)
                             })],
                             speakers: speakers,
                             turns: [turn("T1", "system:S1", [WordSpan(segmentID: segment.id, first: 0, end: 2)], 0, 2),
                                     turn("T2", "system:S2", [WordSpan(segmentID: segment.id, first: 2, end: 4)], 2, 4),
                                     turn("T3", "system:S1", [WordSpan(segmentID: other.id, first: 0, end: 2),
                                                              WordSpan(segmentID: other.id, first: 3, end: 4)],
                                          10, 14)])
    run.droppedWords = [DroppedWords(spans: [WordSpan(segmentID: other.id, first: 2, end: 3)], reason: "echo")]
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner(contextual: true)
    learner.attach(to: review)
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    try await review.editWords(wordEditRefs(review, "T3", [1]), to: "Klaud")
    await review.close()
    // Never "yes" (the next speaker's) nor "echo" (hidden): the word before, in the same turn.
    #expect(learner.taughtBy == [ReviewWordEdit(heard: "cloud", meant: "Claude", before: "say"),
                                 ReviewWordEdit(heard: "cloud", meant: "Klaud", before: "um")])
    #expect(learner.list.entries == [Correction(heard: "say cloud", meant: "say Claude"),
                                     Correction(heard: "um cloud", meant: "um Klaud")])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func whatTheOpenFieldHoldsAtCloseIsSavedAndLearned() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "more", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner()
    learner.attach(to: review)
    // The field opened on "cloud"; an edit before it in the segment saved since, moving it.
    let field = wordEditRefs(review, "T1", [2])
    let seen = review.wordMoves.count
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "a lot more")
    // The window closes with "Claude" typed in the field.
    await review.close(typed: (words: field, text: "Claude", seenMoves: seen))
    #expect(try wordEditCurrent(session).segments[0].text == "ask a lot more Claude now")
    #expect(learner.value("more cloud") == "a lot more Claude",
            "Learned at this close, with the edit beside it (one phrase).")
    #expect(learner.lessons == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func whatWasTypedIsKnownUntilTheEditOpenAtCloseIsSaved() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    #expect(review.unsavedEditAtClose == nil)
    let closing = Task { await review.close(typed: (words: wordEditRefs(review, "T1", [1]), text: "Claude",
                                                    seenMoves: review.wordMoves.count)) }
    // While the edit saves, quitting can still say what was typed (it logs it when it cannot wait).
    #expect(await eventually { entered.value == 1 })
    #expect(review.unsavedEditAtClose == "Claude")
    release.finish()
    await closing.value
    #expect(review.unsavedEditAtClose == nil)
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anExistingCorrectionIsKeptAndAFailedWriteIsMadeAtTheNextClose() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let learner = WordEditLearner()
    let review = try await wordEditOpen(session)
    learner.attach(to: review)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    try await review.editWords(wordEditRefs(review, "T1", [2]), to: "plus")
    // Set elsewhere while the window was open (in Corrections): kept.
    learner.list.set(Correction(heard: "cloud", meant: "Cloud9"), forKey: "cloud")
    // The list cannot be written now.
    learner.failing = true
    await review.close()
    #expect(learner.lessons == 1 && learner.value("and") == nil)
    learner.failing = false
    let reopened = try await wordEditOpen(session)
    learner.attach(to: reopened)
    await reopened.close()
    #expect(learner.value("and") == "plus", "The edits are still in the transcript: learned at the next close.")
    #expect(learner.value("cloud") == "Cloud9")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditBesideAnOlderUnspacedFixIsRefusedSayingWhy() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // "你好世界 再见", timed as "你好", "世界", "再见".
    var segment = SessionFixtures.segment(["你好", "世界", "再见"], track: "system", start: 0, wordSeconds: 1)
    segment.text = "你好世界 再见"
    segment.words[1].utf16Offset = 2
    segment.words[2].utf16Offset = 5
    let base = SessionFixtures.transcript([segment])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 4],
                                                        mode: .call, transcript: base)
    // A correction saved by an earlier version, without the count of words it replaced.
    var fixed = try await WordFixStage.fix(base, title: "",
                                           corrections: CorrectionList(entries: [Correction(heard: "你好世界",
                                                                                            meant: "你好地球")]),
                                           terms: CorrectionList(), dependencies: .none).transcript
    #expect(fixed.segments[0].text == "你好地球 再见")
    fixed.segments[0].fixes = [TranscriptWordFix(first: 0, end: 1, heard: "你好世界", kind: .correction)]
    try await SessionFixtures.saveTranscript(fixed, in: session)
    let manifest = try SessionArchive.readManifest(at: session)
    let speaker = SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"])
    let run = DiarizationRun(
        sessionID: manifest.id, transcriptID: fixed.id, engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1),
        tracks: [TrackDiarization(track: "system", policy: .diarized,
                                  clusters: [ClusterSummary(clusterID: speaker.id, track: "system", speechSeconds: 3)])],
        speakers: [speaker],
        turns: [SpeakerTurn(id: "T1", track: "system", start: 0, end: 3, speakerID: speaker.id, clusterID: speaker.id,
                            spans: [WordSpan(segmentID: segment.id, first: 0, end: 2)], overlap: false,
                            otherClusters: [], assignmentScore: 1, timing: .measured)])
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let review = try await wordEditOpen(session)
    #expect(review.words(of: "T1").map(\.text) == ["你好地球", "再见"])
    #expect(review.wordEditRefusal(wordEditRefs(review, "T1", [1])) == TranscriptWordEdit.olderFix.localizedDescription,
            "Known before a field opens.")
    // What the window's banner shows.
    let refusal = await #expect(throws: HolosError.self) {
        try await review.editWords(wordEditRefs(review, "T1", [1]), to: "拜拜")
    }
    #expect(refusal?.localizedDescription == TranscriptWordEdit.olderFix.localizedDescription)
    #expect(try wordEditCurrent(session).id == fixed.id, "Nothing was written.")
    #expect(review.reloadProblem == nil && review.canEditWords, "The review goes on.")
    await review.close()
}

/// "ask more cloud now" (or `words`), whose "cloud" the word-fix stage made "Claude"; the labels are on that revision.
private func wordEditFixedCloudSession(_ temp: TemporaryDirectory,
                                       words: [String] = ["ask", "more", "cloud", "now"]) async throws -> URL {
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: words),
    ])
    let base = try wordEditCurrent(session)
    let fixed = try await WordFixStage.fix(base, title: "",
                                           corrections: CorrectionList(entries: [Correction(heard: "cloud",
                                                                                            meant: "Claude")]),
                                           terms: CorrectionList(), dependencies: .none).transcript
    try await SessionFixtures.saveTranscript(fixed, in: session)
    var run = try SessionSpeakerStore.readRun(id: try #require(try SessionSpeakerStore.readHead(session: session)?.runID),
                                              session: session)
    run.id = UUID().uuidString
    run.transcriptID = fixed.id
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    return session
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aWordCorrectedWhileRecordingIsKnownNotEditableBeforeAFieldOpens() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    // "cloud" was corrected live, during the recording.
    var corrected = try wordEditCurrent(session)
    corrected.id = UUID().uuidString
    corrected.segments[0].fixes = [TranscriptWordFix(first: 1, end: 2, heard: "clod", kind: .liveCorrection,
                                                     heardWords: 1)]
    try await SessionFixtures.saveTranscript(corrected, in: session)
    var run = try SessionSpeakerStore.readRun(id: try #require(try SessionSpeakerStore.readHead(session: session)?.runID),
                                              session: session)
    run.id = UUID().uuidString
    run.transcriptID = corrected.id
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let review = try await wordEditOpen(session)
    #expect(review.wordEditRefusal(wordEditRefs(review, "T1", [1]))
        == TranscriptWordEdit.liveCorrected.localizedDescription)
    #expect(review.wordEditRefusal(wordEditRefs(review, "T1", [0])) == nil)
    let refusal = await #expect(throws: HolosError.self) {
        try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    }
    #expect(refusal?.localizedDescription == TranscriptWordEdit.liveCorrected.localizedDescription)
    #expect(try wordEditCurrent(session).id == corrected.id, "Nothing was written.")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditQueuedWhileARevertSavesFollowsItsWordsAndNeverLosesWhatWasTyped() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditFixedCloudSession(temp)
    let review = try await wordEditOpen(session)
    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    let words = review.words(of: "T1")
    #expect(words.map(\.text) == ["ask", "more", "Claude", "now"])
    // "Claude" is reverted; while that saves, "now" and "Claude" itself are edited.
    let revert = Task { try await review.revertWordFix(words[2].ref) }
    #expect(await eventually { entered.value == 1 })
    let after = Task { try await review.editWords([words[3].ref], to: "today") }
    let onIt = Task { try await review.editWords([words[2].ref], to: "Claudia") }
    #expect(await eventually { review.queuedOperations == 3 })
    review.beforeEdit = nil
    release.finish()
    try await revert.value
    // The window's own revert is not a change made elsewhere: the edit after it follows its words.
    _ = try await after.value
    #expect(try wordEditCurrent(session).segments[0].text == "ask more cloud today")
    // The reverted word itself changed: refused, saying what was typed.
    let refusal = await #expect(throws: HolosError.self) { _ = try await onIt.value }
    #expect(refusal?.localizedDescription.contains("Claudia") == true)
    #expect(review.speaker("system:S1")?.name == "Ann" && review.canUndo, "The speaker changes and undo stay.")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func wordsCannotBeEditedWhileSpeakerChangesCannotAllBeRead() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditFixedCloudSession(temp)
    // A damaged line in the speaker-change journal.
    let journal = SessionPaths.edits(session)
    let existing = (try? Data(contentsOf: journal)) ?? Data()
    try (existing + Data("{not a speaker change}\n".utf8)).write(to: journal)
    let review = try await wordEditOpen(session)
    #expect(!review.snapshot.journal.isComplete)
    #expect(!review.canEditWords)
    #expect(review.wordEditingBlocked == ReviewSession.speakerChangesUnreadable.localizedDescription,
            "The window says why before any field opens.")
    let words = review.words(of: "T1")
    let edit = await #expect(throws: HolosError.self) { try await review.editWords([words[1].ref], to: "less") }
    #expect(edit?.localizedDescription == ReviewSession.speakerChangesUnreadable.localizedDescription)
    await #expect(throws: HolosError.self) { try await review.revertWordFix(words[2].ref) }
    #expect(try wordEditCurrent(session).segments[0].text == "ask more Claude now", "Nothing was written.")
    await review.close()
}

@Test(.timeLimit(.minutes(1)))
func aRevertWhoseSaveFailsAfterItBecameCurrentIsAPublicationStillOwed() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditFixedCloudSession(temp)
    let fixed = try wordEditCurrent(session)
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    struct DirectorySync: Error {}
    // The pointer was renamed into place, then syncing its folder failed.
    do {
        _ = try await TranscriptPointerSave.$afterSave.withValue({ throw DirectorySync() }) {
            try await SessionWordFixRevert.run(session: session,
                                               word: WordRef(segmentID: fixed.segments[0].id, word: 2),
                                               expectedTranscriptID: fixed.id, expectedRunID: runID)
        }
        Issue.record("The save failure was not reported.")
    } catch let incomplete as SessionWordFixRevert.IncompletePublication {
        let outcome = try #require(incomplete.outcome, "What was published is kept: its word move is recorded.")
        #expect(outcome.move == ReviewWordMove(segmentID: fixed.segments[0].id, replaced: 2..<3, replacement: 2..<3))
        #expect(try wordEditCurrent(session).segments[0].text == "ask more cloud now")
        #expect(try SessionSpeakerStore.readHead(session: session)?.runID == runID, "The head is still owed.")
    }
    try await SessionWordFixRevert.repairCurrentHead(session: session, expectedTranscriptID: fixed.id,
                                                     expectedRunID: runID)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    #expect(!snapshot.transcriptChanged && snapshot.transcript.segments[0].text == "ask more cloud now")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aRevertWhoseHeadCouldNotBePublishedHoldsTheReviewUntilAReloadRepairsIt() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditFixedCloudSession(temp)
    let fixed = try wordEditCurrent(session)
    let review = try await wordEditOpen(session)
    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    let failing = SharedValue(true)
    review.beforeHeadPublish = { if failing.value { throw HolosError.io("the speaker head is read-only") } }
    // The revert's transcript is current; its head, and the repair right after, cannot be published.
    await #expect(throws: (any Error).self) { try await review.revertWordFix(wordEditRefs(review, "T1", [2])[0]) }
    #expect(try wordEditCurrent(session).segments[0].text == "ask more cloud now")
    #expect(review.reloadProblem != nil && !review.canEditWords)
    // Reload: the repair fails again, so the labels on the fixed words are not taken; still held.
    await review.reload()
    #expect(review.reloadProblem?.contains("could not be saved") == true)
    #expect(review.snapshot.transcript.id == fixed.id, "Labels on the old transcript are not adopted.")
    // Reload once the head can be published: repaired and resumed.
    failing.set(false)
    await review.reload()
    #expect(review.reloadProblem == nil && review.canEditWords && !review.snapshot.transcriptChanged)
    #expect(review.words(of: "T1").map(\.text) == ["ask", "more", "cloud", "now"])
    #expect(review.speaker("system:S1")?.name == "Ann", "The turn edits were carried over.")
    await review.close()
}

@Test func whatAMeetingTaughtIsMergedSoTwoClosesKeepBothEntries() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let cloud = Correction(heard: "cloud", meant: "Claude")
    let plus = Correction(heard: "and", meant: "plus")
    // Two closes, each with what it read before: neither loses the other's entry.
    try ReviewLearning.recordTaught(adding: [cloud], session: session)
    try ReviewLearning.recordTaught(adding: [plus, cloud], session: session)
    #expect(try ReviewLearning.taught(session: session) == [cloud, plus])
    #expect(ReviewLearning.untaught([cloud, Correction(heard: "Cloud", meant: "Claude"), plus,
                                     Correction(heard: "cloud", meant: "Cloud9")],
                                    taught: [cloud, plus]) == [Correction(heard: "cloud", meant: "Cloud9")])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aCorrectionDeletedInCorrectionsIsNotTaughtAgainByTheMeeting() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let learner = WordEditLearner()
    let review = try await wordEditOpen(session)
    learner.attach(to: review)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    await review.close()
    #expect(learner.value("cloud") == "Claude")
    // Deleted in Corrections; the meeting is reviewed again and an edit made.
    learner.list = CorrectionList()
    let reopened = try await wordEditOpen(session)
    learner.attach(to: reopened)
    try await reopened.editWords(wordEditRefs(reopened, "T1", [2]), to: "plus")
    await reopened.close()
    #expect(learner.value("cloud") == nil, "What the meeting taught before is not taught again.")
    #expect(learner.value("and") == "plus", "A new edit is.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nothingIsLearnedOnLabelsNotOnTheCurrentTranscriptUntilALaterClose() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let original = try wordEditCurrent(session)
    let learner = WordEditLearner()
    let review = try await wordEditOpen(session)
    learner.attach(to: review)
    let runID = try #require(review.snapshot.run?.id)
    // The edit's head cannot be published, nor repaired: the labels stay on the transcript as it was.
    review.beforeHeadPublish = { throw HolosError.io("the speaker head is read-only") }
    await #expect(throws: HolosError.self) {
        try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    }
    await review.close()
    #expect(learner.lessons == 0, "No context could be taken: nothing learned now.")
    // Once the head is published, the next close learns it.
    try await SessionWordEdit.repairCurrentHead(session: session, expectedTranscriptID: original.id,
                                                expectedRunID: runID)
    let reopened = try await wordEditOpen(session)
    learner.attach(to: reopened)
    await reopened.close()
    #expect(learner.value("cloud") == "Claude")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aQueuedRevertOfAnAutomaticFixFollowsAnEditBeforeIt() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "more", "cloud", "now"]),
    ])
    // The word-fix stage made "cloud" "Claude"; the labels are on that revision.
    let base = try wordEditCurrent(session)
    let fixed = try await WordFixStage.fix(base, title: "",
                                           corrections: CorrectionList(entries: [Correction(heard: "cloud",
                                                                                            meant: "Claude")]),
                                           terms: CorrectionList(), dependencies: .none).transcript
    try await SessionFixtures.saveTranscript(fixed, in: session)
    var run = try SessionSpeakerStore.readRun(id: try #require(try SessionSpeakerStore.readHead(session: session)?.runID),
                                              session: session)
    run.id = UUID().uuidString
    run.transcriptID = fixed.id
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let review = try await wordEditOpen(session)
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    let words = review.words(of: "T1")
    #expect(words.map(\.text) == ["ask", "more", "Claude", "now"])
    // "more" becomes "a lot more" while "Claude" is reverted from its old place.
    let edit = Task { try await review.editWords([words[1].ref], to: "a lot more") }
    #expect(await eventually { entered.value == 1 })
    let revert = Task { try await review.revertWordFix(words[2].ref) }
    #expect(await eventually { review.queuedOperations == 2 })
    release.finish()
    _ = try await edit.value
    try await revert.value
    #expect(try wordEditCurrent(session).segments[0].text == "ask a lot more cloud now")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func wordsCannotBeEditedOnceTheTranscriptChangedAfterLabelling() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    // A new revision the speakers were not labelled on.
    var changed = try wordEditCurrent(session)
    changed.id = UUID().uuidString
    try await SessionFixtures.saveTranscript(changed, in: session)
    let review = try await wordEditOpen(session)
    #expect(review.snapshot.transcriptChanged)
    #expect(review.isEditable && !review.canEditWords)
    #expect(review.wordEditingBlocked?.contains("Label Again") == true)
    await #expect(throws: HolosError.self) { try await review.editWords(wordEditRefs(review, "T1", [1]), to: "x") }
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aSpeakerChangeQueuedBehindAnEditWhoseRereadFailedWaitsForTheReread() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    struct Unreadable: Error {}
    var failures = 1
    review.beforeWordChangeReread = {
        guard failures > 0 else { return }
        failures -= 1
        throw Unreadable()
    }
    let edit = Task { try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude") }
    #expect(await eventually { entered.value == 1 })
    let rename = Task { try await review.apply([.rename(speakerID: "system:S1", name: "Ann")]) }
    #expect(await eventually { review.queuedOperations == 2 })
    release.finish()
    await #expect(throws: HolosError.self) { _ = try await edit.value }
    #expect(review.reloadProblem != nil && review.queuedOperations == 1, "The rename waits, still queued.")
    await review.reload()
    try await rename.value
    #expect(review.speaker("system:S1")?.name == "Ann")
    #expect(try SessionSpeakerStore.readEdits(session: session).edits.contains {
        $0.action == .rename(speakerID: "system:S1", name: "Ann")
    })
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditAndItsUndoKeepTheTurnsForParagraphBreaks() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["first", "part"]),
        WordEditTurn(speaker: "system:S1", start: 3, words: ["second", "part"]),
    ])
    let review = try await wordEditOpen(session)
    var breaks = ReviewParagraphBreaks()
    let second = try #require(review.turn("T2"))
    breaks.insert(before: second, runID: review.projection.runID)
    let original = review.projection.runID
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "bit")
    try await review.undo()
    let now = review.projection.runID
    #expect(now != original && review.keepsTurns(of: original, in: now))
    #expect(breaks.active(in: review.projection.turns, runID: now,
                          keepsTurnsOf: { review.keepsTurns(of: $0, in: now) }) == ["T2"],
            "A break made before the edit stays after its undo.")
    #expect(!review.keepsTurns(of: now, in: original))
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func wordsEditedTogetherAreNeverSplitApart() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["we", "knew", "work", "here"]),
    ])
    let review = try await wordEditOpen(session)
    try await review.editWords(wordEditRefs(review, "T1", [1, 2]), to: "New York")
    let words = review.words(of: "T1")
    // Inside "New York": refused, so its Revert always has one turn to edit.
    await #expect(throws: HolosError.self) { try await review.split(turnID: "T1", at: words[2].ref) }
    try await review.split(turnID: "T1", at: words[1].ref)
    #expect(review.projection.turns.count == 2)
    try await review.revertWordFix(words[1].ref)
    #expect(try wordEditCurrent(session).segments[0].text == "we knew work here")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func postProcessingFinishesAnEditWhoseSpeakerHeadWasNeverPublished() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now", "please"]),
        WordEditTurn(speaker: "system:S2", start: 10, words: ["we", "will", "see"]),
    ])
    let original = try wordEditCurrent(session)
    try SessionFixtures.appendEdits([.reassignTurns(turnIDs: ["T2"], to: "system:S1")], session: session)
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    let segment = try #require(original.segments.first { $0.text.hasPrefix("ask") })
    // The app quits between the transcript and the speaker head.
    await #expect(throws: SessionWordEdit.IncompletePublication.self) {
        try await SpeakerTranscriptRetarget.$beforePublishHead.withValue({ throw HolosError.io("quit") }) {
            _ = try await SessionWordEdit.run(
                session: session,
                request: TranscriptWordEdit.Request(segmentID: segment.id, first: 1, end: 2, text: "Claude"),
                expectedTranscriptID: original.id, expectedRunID: runID)
        }
    }
    #expect(try SpeakerSessionSnapshot.load(session: session).transcriptChanged)

    // Post-processing (a relabel would carry the names only) publishes the edit's head first.
    _ = try await MeetingPostProcessor(voiceSamples: .none,
                                       diarizer: FakeDiarizer(outputs: ["system": SessionFixtures.alternatingOutput()]),
                                       freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let current = try wordEditCurrent(session)
    #expect(current.segments.contains { $0.text == "ask Claude now please" })
    #expect(!snapshot.transcriptChanged && snapshot.transcript.id == current.id)
    #expect(snapshot.projection?.turns.first { $0.id == "T2" }?.speakerID == "system:S1",
            "The reassignment made before the edit is kept.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func postProcessingPublishesTheHeadARevertStillOwes() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditFixedCloudSession(temp)
    let fixed = try wordEditCurrent(session)
    try SessionFixtures.appendEdits([.rename(speakerID: "system:S1", name: "Ann")], session: session)
    let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    // The app quits between the reverted transcript and its speaker head.
    await #expect(throws: SessionWordFixRevert.IncompletePublication.self) {
        try await SpeakerTranscriptRetarget.$beforePublishHead.withValue({ throw HolosError.io("quit") }) {
            _ = try await SessionWordFixRevert.run(session: session,
                                                   word: WordRef(segmentID: fixed.segments[0].id, word: 2),
                                                   expectedTranscriptID: fixed.id, expectedRunID: runID)
        }
    }
    #expect(try SpeakerSessionSnapshot.load(session: session).transcriptChanged)

    // Post-processing publishes the revert's head first, from the old one, rather than relabel over it.
    _ = try await MeetingPostProcessor(voiceSamples: .none,
                                       diarizer: FakeDiarizer(outputs: ["system": SessionFixtures.alternatingOutput()]),
                                       freeSpace: FixedFreeSpace(.max)).run(session: session, lease: nil)
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let current = try wordEditCurrent(session)
    #expect(current.segments[0].text == "ask more cloud now")
    #expect(!snapshot.transcriptChanged && snapshot.transcript.id == current.id)
    #expect(snapshot.projection?.speakers.first { $0.id == "system:S1" }?.name == "Ann",
            "The speaker edit made before the revert is kept.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func editsAcrossTurnsSegmentsOrHiddenWordsAreRefused() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["one", "two", "echo", "three"], hidden: [2]),
        WordEditTurn(speaker: "system:S2", start: 10, words: ["four", "five"]),
    ])
    let review = try await wordEditOpen(session)
    let shown = review.words(of: "T1")
    #expect(shown.map(\.text) == ["one", "two", "three"])
    #expect(shown.map(\.ref.word) == [0, 1, 3], "Shown words name their stored indices.")
    // "two three": the hidden word lies between.
    await #expect(throws: HolosError.self) { try await review.editWords([shown[1].ref, shown[2].ref], to: "x") }
    // Two segments (and two turns).
    await #expect(throws: HolosError.self) {
        try await review.editWords([shown[2].ref, review.words(of: "T2")[0].ref], to: "x")
    }
    // The hidden word itself.
    await #expect(throws: HolosError.self) {
        try await review.editWords([WordRef(segmentID: shown[0].ref.segmentID, word: 2)], to: "x")
    }
    // A word after the hidden one is edited at its stored index.
    try await review.editWords([shown[2].ref], to: "drei")
    let segment = try wordEditCurrent(session).segments[0]
    #expect(segment.text == "one two echo drei")
    #expect(segment.fixes == [TranscriptWordFix(first: 3, end: 4, heard: "three", kind: .reviewEdit, heardWords: 1)])
    #expect(review.words(of: "T1").map(\.text) == ["one", "two", "drei"])
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func wordFixesMadeAgainKeepAnEdit() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now", "please"]),
    ])
    let review = try await wordEditOpen(session)
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claudia")
    await review.close()

    let corrections = CorrectionList(entries: [Correction(heard: "cloud", meant: "Claude"),
                                               Correction(heard: "please", meant: "pls")])
    let dependencies = WordFixDependencies(corrections: { corrections }, wordList: { WordList() },
                                           model: { _ in .unavailable("unused") })
    _ = try await MeetingPostProcessor(voiceSamples: .none, diarizer: nil, freeSpace: FixedFreeSpace(.max),
                                       wordFixes: dependencies).run(session: session, lease: nil)
    let current = try wordEditCurrent(session)
    #expect(current.segments[0].text == "ask Claudia now pls",
            "The edit is in the unfixed base: fixing words again keeps it and fixes the rest.")
    #expect(current.segments[0].fixes?.contains { $0.kind == .reviewEdit && $0.heard == "cloud" } == true)
    #expect(TranscriptWordEdit.hasReviewEdits(current))
}
