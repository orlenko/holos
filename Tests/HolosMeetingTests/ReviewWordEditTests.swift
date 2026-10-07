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
                             apple: Bool = false, fixes: [TranscriptWordFix]? = nil) async throws -> URL {
    let segments = specs.enumerated().map { index, spec -> TranscriptSegment in
        var segment = SessionFixtures.segment(spec.words, track: "system", start: spec.start, wordSeconds: 1)
        // `fixes`: the first segment's marks.
        if index == 0 { segment.fixes = fixes }
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
/// (`CorrectionList.learnReplacingTaught`, written off the main actor inside the meeting's speaker lock), and what each
/// edit teaches: "heard" → "meant" as recorded, or with `contextual`, the app's rule with every word a dictionary word
/// (so a lone word is learned with its neighbour).
@MainActor
private final class WordEditLearner {
    private let stored: SharedValue<CorrectionList>
    private let failingNow = SharedValue(false)
    private let writes = SharedValue(0)
    let contextual: Bool
    private(set) var taughtBy: [ReviewWordEdit] = []

    var list: CorrectionList {
        get { stored.value }
        set { stored.set(newValue) }
    }
    /// While set, the list cannot be written.
    var failing: Bool {
        get { failingNow.value }
        set { failingNow.set(newValue) }
    }
    /// How many times a close tried to write the list.
    var lessons: Int { writes.value }

    init(_ list: CorrectionList = CorrectionList(), contextual: Bool = false) {
        stored = SharedValue(list)
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
        let stored = self.stored, failing = failingNow, writes = self.writes
        // As `CorrectionList.update`: read, changed, and saved only when it changed (`lessons` counts those saves).
        review.correctionsWriter = {
            { change in
                if failing.value {
                    writes.update { $0 += 1 }
                    throw HolosError.io("corrections.json cannot be written")
                }
                var list = stored.value
                try change(&list)
                guard list != stored.value else { return }
                writes.update { $0 += 1 }
                stored.set(list)
            }
        }
    }

    /// What the list makes of `heard`, nil when nothing.
    func value(_ heard: String) -> String? { list.entry(forKey: CorrectionList.key(heard))?.meant }

    /// What the meeting at `session` taught, as the list records it (`CorrectionList.reviewTaught`).
    func taught(_ session: URL) throws -> [Correction] {
        list.taught(byMeeting: try SessionArchive.readManifest(at: session).id)
    }
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
    #expect(edit == ReviewWordEdit(heard: "cloud", meant: "Claude", before: "ask", after: "now", typed: "Claude",
                                   typedHeard: "cloud"))
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
func wordsOfOverlappingTurnsAreNotEditedTogether() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSharedSession(in: temp, ["hello", "there", "yes", "now"],
                                                  times: [(0, 0.8), (1, 1.8), (2, 2.8), (3, 3.8)], split: 2)
    // Overlapping turns: T1 holds words 0–2, T2 words 1–3.
    let head = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    var run = try SessionSpeakerStore.readRun(id: head, session: session)
    let segmentID = try wordEditCurrent(session).segments[0].id
    run.turns[0].spans = [WordSpan(segmentID: segmentID, first: 0, end: 3)]
    run.turns[1].spans = [WordSpan(segmentID: segmentID, first: 1, end: 4)]
    run.id = UUID().uuidString
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let review = try await wordEditOpen(session)
    // "hello" is T1's alone, "there" both turns': edited together, the undo could not give each back its own turns.
    let hello = wordEditRefs(review, "T1", [0, 1])
    #expect(review.wordEditRefusal(hello) == TranscriptWordEdit.overlappingTurns.localizedDescription,
            "Known before a field opens.")
    let refusal = await #expect(throws: HolosError.self) { try await review.editWords(hello, to: "hi there") }
    #expect(refusal?.localizedDescription == TranscriptWordEdit.overlappingTurns.localizedDescription)
    // A word only one turn holds is edited, and undone, exactly.
    let spans = try wordEditHeadSpans(session)
    try await review.editWords(wordEditRefs(review, "T2", [2]), to: "today")
    #expect(try wordEditCurrent(session).segments[0].text == "hello there yes today")
    try await review.undo()
    #expect(try wordEditCurrent(session).segments[0].text == "hello there yes now")
    #expect(try wordEditHeadSpans(session) == spans)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func theOwnersCheckedBeforeAFieldOpensAreThoseOfEveryWordTheEditTakesIn() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSharedSession(in: temp, ["hello", "there", "yes", "now"],
                                                  times: [(0, 0.8), (1, 1.8), (2, 2.8), (3, 3.8)], split: 3)
    let review = try await wordEditOpen(session)
    // Words 0–1 edited together (one mark), while T1 held words 0–2.
    try await review.editWords(wordEditRefs(review, "T1", [0, 1]), to: "hi there")
    // Then labelled so that T2 holds words 1–3 as well: the mark's words belong to different turns.
    let head = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    var run = try SessionSpeakerStore.readRun(id: head, session: session)
    let segmentID = try wordEditCurrent(session).segments[0].id
    run.turns[1].spans = [WordSpan(segmentID: segmentID, first: 1, end: 4)]
    run.id = UUID().uuidString
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    await review.reload()
    // "hi" alone is T1's, but an edit of it takes in the whole mark ("hi there"): refused before a field opens.
    let hi = wordEditRefs(review, "T1", [0])
    #expect(review.wordEditRefusal(hi) == TranscriptWordEdit.overlappingTurns.localizedDescription)
    await #expect(throws: HolosError.self) { try await review.editWords(hi, to: "hey") }
    // Its Revert is not offered, and refused.
    #expect(review.words(of: "T1").first?.revertible == false)
    await #expect(throws: HolosError.self) { try await review.revertWordFix(hi[0]) }
    #expect(try wordEditCurrent(session).segments[0].text == "hi there yes now")
    await review.close()
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
    // The labels changed elsewhere: the rename's undo, made on the old labels, is gone, and so is the edit's (its own
    // head is no longer the current one: `Operation.overtaken`).
    #expect(!review.canUndo)
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
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
    // Claude" would teach one speaker's words with another's). The edit beside them, in one turn, is learned alone,
    // without them as context ("Claude" is part of an edit its turn holds only part of).
    #expect(learner.taughtBy == [ReviewWordEdit(heard: "now", meant: "today")])
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
func anEditIsNeverSavedOverAWordChangedElsewhereInItsPlace() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    // The field opens on "cloud"; meanwhile another process changes it to "crowd" (same segment, same place) and
    // relabels, and the window reads it.
    let seen = review.words(of: "T1")[1]
    var changed = try wordEditCurrent(session)
    changed.id = UUID().uuidString
    changed.segments[0].text = "ask crowd now"
    changed.segments[0].words[1].text = "crowd"
    try await SessionFixtures.saveTranscript(changed, in: session)
    var run = try SessionSpeakerStore.readRun(id: try #require(try SessionSpeakerStore.readHead(session: session)?.runID),
                                              session: session)
    run.id = UUID().uuidString
    run.transcriptID = changed.id
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    await review.reload()
    #expect(review.words(of: "T1")[1].text == "crowd" && review.canEditWords)
    // The field's edit, queued with the words as it showed them: refused, saying what was typed; nothing written.
    let refused = await #expect(throws: HolosError.self) {
        try await review.editWords([seen.ref], to: "Claude", seenMoves: review.wordMoves.count,
                                   expecting: [seen.shown])
    }
    #expect(refused?.localizedDescription.contains("what you typed: “Claude”") == true)
    #expect(try wordEditCurrent(session).segments[0].text == "ask crowd now")
    // The same when a maintenance pause takes the field's edit, and when the window's close does.
    let stale = ReviewSession.TypedEdit(words: [seen.ref], text: "Claude", seenMoves: review.wordMoves.count,
                                        expected: [seen.shown])
    let hold = ReviewMaintenance.Hold(.recover)
    let paused = await review.pause(hold, reason: "Voice is Local is recovering this meeting.", typed: stale)
    #expect(paused?.contains("“Claude”") == true)
    await review.resume(hold)
    #expect(try wordEditCurrent(session).segments[0].text == "ask crowd now")
    // Words as they are now are edited as usual.
    try await review.editWords([seen.ref], to: "Claude", expecting: ["crowd"])
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
    let closingStale = ReviewSession.TypedEdit(words: [review.words(of: "T1")[2].ref], text: "later",
                                               seenMoves: review.wordMoves.count, expected: ["then"])
    await review.close(typed: closingStale)
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now", "Not saved over “now”.")
}

@Test(.timeLimit(.minutes(1)))
func aWordEditEventWithADamagedMoveIsDamagedNeverReadAnotherWay() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
    // An edit as written, one with no move (an older journal: mapped by time), and one whose move is damaged.
    try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
        "transcriptID": "T-good", "base": "B", "segment": "S1", "replaced": "1-2", "replacement": "1-3"])
    try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
        "transcriptID": "T-old", "base": "B"])
    try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
        "transcriptID": "T-bad", "base": "B", "segment": "S1", "replaced": "-1-2", "replacement": "1-3"])
    // An undo as written, and one whose "undo" is anything else.
    try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
        "transcriptID": "T-undo", "base": "B", "undo": "1", "segment": "S1", "replaced": "1-3", "replacement": "1-2"])
    try await archive.recordEvent(kind: MeetingEventKind.transcriptEdited, details: [
        "transcriptID": "T-odd", "base": "B", "undo": "yes", "segment": "S1", "replaced": "1-3",
        "replacement": "1-2"])
    await archive.releaseLock()
    let good = try #require(try SessionWordEdit.editedEvent(of: "T-good", session: session))
    #expect(good.base == "B" && good.move == ReviewWordMove(segmentID: "S1", replaced: 1..<2, replacement: 1..<3))
    #expect(!good.undo)
    #expect(try SessionWordEdit.editedEvent(of: "T-old", session: session)?.move == nil)
    #expect(throws: HolosError.self) { try SessionWordEdit.editedEvent(of: "T-bad", session: session) }
    #expect(try SessionWordEdit.editedEvent(of: "T-undo", session: session)?.undo == true)
    #expect(throws: HolosError.self) { try SessionWordEdit.editedEvent(of: "T-odd", session: session) }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aVoiceLearnedBeforeAWordEditIsTheLabellingsOwnNeverAnEarlierOnes() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let labelled = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
    let review = try await wordEditOpen(session)
    // Two word edits: each retargets the head to a new run of the same labelling.
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    try await review.editWords(wordEditRefs(review, "T1", [2]), to: "today")
    await review.close()
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let head = try #require(snapshot.run)
    #expect(head.id != labelled && head.labelling == labelled)
    // A voice learned from the run before the edits is the head's labelling's: recomputed or removed when the
    // speakers change, never kept as an earlier labelling's.
    let sample = VoiceprintSample(sessionID: snapshot.manifest.id, sessionName: "x", speakerIDs: ["system:S1"],
                                  speechSeconds: 30, embedding: FloatVector([1, 0]), condition: .room, weak: false,
                                  generation: "\(labelled):0")
    let database = SpeakerProfileDatabase(rememberVoices: true, profiles: [
        SpeakerProfile(id: "P1", displayName: "Jim", samples: [sample]),
    ])
    let earlier = try VoiceProfileService.earlierRunViews(database, snapshot: snapshot, headRunID: head.id)
    #expect(earlier.sameLabelling == [labelled])
    #expect(!VoiceProfileService.builtFromEarlierRun(sample, headRunID: head.id,
                                                     sameLabelling: earlier.sameLabelling))
    #expect(VoiceProfileService.builtFromEarlierRun(sample, headRunID: head.id), "Without it, as a relabel.")
}

/// A voice extractor that gives every turn the same embedding.
private struct WordEditVoice: VoiceSampleExtractor {
    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        turns.map { TurnEmbedding(turnID: $0.id, speechSeconds: $0.end - $0.start, vector: FloatVector([0.6, 0.8])) }
    }
}

/// A voice learned, the audio deleted, then a word corrected in another speaker's turn and the samples synced: the
/// labels moved to a new run of the same labelling, but the audio the voice was learned from is the same, so it is
/// kept. A change that does move its audio (one of its turns given to someone else) still removes it; one that cannot
/// be shown either way (a sample with no input digest, as older builds saved) keeps it.
@Test(.timeLimit(.minutes(1))) @MainActor
func aWordEditAfterTheAudioIsDeletedKeepsTheVoicesItDidNotChange() async throws {
    for (reassign, undigested) in [(false, false), (true, false), (true, true)] {
        let temp = try TemporaryDirectory("review")
        defer { temp.remove() }
        let session = try await wordEditSession(in: temp, [
            WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
            WordEditTurn(speaker: "system:S2", start: 4, words: ["then", "we", "go"]),
            WordEditTurn(speaker: "system:S1", start: 8, words: ["and", "more", "here"]),
        ])
        let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("Support/Speakers"))
        try store.update { $0.rememberVoices = true }
        _ = try await VoiceProfileService.link(session: session, speakerID: "system:S1", to: .new(name: "Alice"),
                                               view: try SessionFixtures.view(session), learnVoice: true,
                                               extractor: WordEditVoice(), store: store)
        if undigested {
            try store.update { $0.profiles[0].samples[0].inputDigest = nil }
        }
        let learned = try #require(try store.load().profiles.first?.samples.first)
        #expect(learned.speakerIDs == ["system:S1"])
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        try SessionDeletion.deleteAudio(session: session, lease: lease)
        lease.release()

        let review = try await wordEditOpen(session)
        try await review.editWords(wordEditRefs(review, "T2", [1]), to: "they")
        if reassign { try await review.apply([.reassignTurns(turnIDs: ["T3"], to: "system:S2")]) }
        await review.close()
        let head = try #require(try SpeakerSessionSnapshot.load(session: session).run)
        #expect(head.labelling != nil && VoiceProfileService.sourceRunID(learned) != head.id)

        // The labelling timed each turn 3 s; its words end 0.2 s before. Turns whose words the edit left keep the
        // labelling's times: the audio a voice was learned from.
        #expect(head.turns.map(\.end) == [3, 7, 11])
        // The samples brought in step (naming the other speaker, say).
        try await VoiceProfileService.refreshSamples(session: session, extractor: WordEditVoice(), store: store)
        let alice = try #require(try store.load().profiles.first { $0.displayName == "Alice" })
        if reassign && !undigested {
            #expect(alice.samples.isEmpty, "Its audio changed, and it cannot be learned again without the audio.")
        } else {
            #expect(alice.samples == [learned], "undigested: \(undigested)")
        }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aDamagedWordMoveFromTheJournalIsRefusedNeverCounted() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let segment = try #require(snapshot.transcript.segments.first?.id)
    var edited = snapshot.transcript
    edited.id = UUID().uuidString
    // As an edit of "cloud" leaves it: its mark over the new word.
    edited.segments[0].fixes = [TranscriptWordFix(first: 1, end: 2, heard: "clod", kind: .reviewEdit, heardWords: 1)]
    // A decodable journal event whose move holds numbers past any word count (repairing a speaker head reads it).
    for move in [ReviewWordMove(segmentID: segment, replaced: 1..<2, replacement: 1..<Int.max),
                 ReviewWordMove(segmentID: segment, replaced: 1..<Int.max, replacement: 1..<2),
                 ReviewWordMove(segmentID: segment, replaced: 1..<2, replacement: 1..<9),
                 // Empty: no edit has one, and the word it would add has no owner.
                 ReviewWordMove(segmentID: segment, replaced: 1..<1, replacement: 1..<1)] {
        #expect(throws: HolosError.self, "\(move)") {
            try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: edited, move: move)
        }
    }
    // A sound one maps as before.
    #expect(try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: edited,
                                               move: ReviewWordMove(segmentID: segment, replaced: 1..<2,
                                                                    replacement: 1..<2)) != nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aWordMoveAcrossTwoTurnsIsRefusedWhereverItIsRead() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // One segment of four words, two turns of two words each.
    let segment = SessionFixtures.segment(["one", "two", "three", "four"], track: "system", start: 0, wordSeconds: 1,
                                          id: "S1")
    let transcript = SessionFixtures.transcript([segment])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 5],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let speakers = ["system:S1", "system:S2"].enumerated().map {
        SessionSpeaker(id: $1, ordinal: $0 + 1, provenance: .diarizer, clusterIDs: [$1])
    }
    func turn(_ id: String, _ speaker: String, _ words: Range<Int>) -> SpeakerTurn {
        SpeakerTurn(id: id, track: "system", start: Double(words.lowerBound), end: Double(words.upperBound),
                    speakerID: speaker, clusterID: speaker,
                    spans: [WordSpan(segmentID: "S1", first: words.lowerBound, end: words.upperBound)],
                    overlap: false, otherClusters: [], assignmentScore: 1, timing: .measured)
    }
    let run = DiarizationRun(sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
                             alignment: AlignmentInfo(version: 1, parameters: .v1),
                             tracks: [TrackDiarization(track: "system", policy: .diarized, clusters: speakers.map {
                                 ClusterSummary(clusterID: $0.id, track: "system", speechSeconds: 2)
                             })],
                             speakers: speakers,
                             turns: [turn("T1", "system:S1", 0..<2), turn("T2", "system:S2", 2..<4)])
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    var edited = snapshot.transcript
    edited.id = UUID().uuidString
    // Marked as an edit over "two three" would leave it: only the turns refuse the move below.
    edited.segments[0].fixes = [TranscriptWordFix(first: 1, end: 3, heard: "to tree", kind: .reviewEdit,
                                                  heardWords: 2)]
    // A move over "two three" (one word of each turn), as a damaged event-log entry could hold: refused, so the
    // recovered labels never give a word to a turn that did not hold it.
    #expect(throws: HolosError.self) {
        try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: edited,
                                           move: ReviewWordMove(segmentID: "S1", replaced: 1..<3, replacement: 1..<3))
    }
    // A move naming a segment the transcript does not have, with numbers past any count: refused, never walked.
    #expect(throws: HolosError.self) {
        try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: edited,
                                           move: ReviewWordMove(segmentID: "nowhere", replaced: 0..<Int.max,
                                                                replacement: 0..<Int.max))
    }
    // In range, but the words around it do not match: "two" became "TWO plus", the move says words 2–3.
    var changed = snapshot.transcript
    changed.id = UUID().uuidString
    changed.segments[0] = SessionFixtures.segment(["one", "TWO", "plus", "three", "four"], track: "system", start: 0,
                                                  wordSeconds: 1, id: "S1")
    changed.segments[0].fixes = [TranscriptWordFix(first: 1, end: 3, heard: "two", kind: .reviewEdit, heardWords: 1)]
    #expect(throws: HolosError.self) {
        try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: changed,
                                           move: ReviewWordMove(segmentID: "S1", replaced: 2..<3, replacement: 2..<4))
    }
    #expect(try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: changed,
                                               move: ReviewWordMove(segmentID: "S1", replaced: 1..<2,
                                                                    replacement: 1..<3)) != nil)
    // Within one turn, and marked as such an edit leaves it: mapped.
    var sound = snapshot.transcript
    sound.id = UUID().uuidString
    sound.segments[0].fixes = [TranscriptWordFix(first: 0, end: 2, heard: "won to", kind: .reviewEdit, heardWords: 2)]
    #expect(try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: sound,
                                               move: ReviewWordMove(segmentID: "S1", replaced: 0..<2,
                                                                    replacement: 0..<2)) != nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditMadeOnTheWordsShownBeforeARereadEditsTheWordShown() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["one", "go", "go"]),
    ])
    let review = try await wordEditOpen(session)
    let secondGo = wordEditRefs(review, "T1", [2])[0]
    // "one" becomes "one more"; after that saves and before the window rereads it, the second "go" (as shown, word 2)
    // is edited with the moves the shown words are after: it follows the new move to word 3, never the first "go".
    let edit = SharedValue<Task<Void, any Error>?>(nil)
    let seen = SharedValue<(shown: Int, all: Int)>((0, 0))
    review.beforeWordChangeReread = {
        review.beforeWordChangeReread = nil
        seen.set((review.shownWordMoves.count, review.wordMoves.count))
        let moves = review.shownWordMoves.count
        edit.set(Task { @MainActor in
            _ = try await review.editWords([secondGo], to: "stop", seenMoves: moves, expecting: ["go"])
        })
    }
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "one more")
    #expect(seen.value.shown == 0 && seen.value.all == 1, "The move saved is not among those shown yet.")
    try await #require(edit.value).value
    #expect(try wordEditCurrent(session).segments[0].text == "one more go stop")
    #expect(review.shownWordMoves.count == review.wordMoves.count, "Reread: all shown.")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aRevertAskedBeforeAnEditsRereadRevertsTheWordShown() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // "we met Claude", "Claude" an automatic fix of "cloud".
    let session = try await wordEditFixedCloudSession(temp, words: ["we", "met", "cloud"])
    let review = try await wordEditOpen(session)
    let claude = wordEditRefs(review, "T1", [2])[0]
    // "we" becomes "we all"; Revert is asked on "Claude" as still shown (word 2) after that edit saved, before the
    // window reread it: it follows the edit's move to word 3.
    let revert = SharedValue<Task<Void, any Error>?>(nil)
    review.beforeWordChangeReread = {
        review.beforeWordChangeReread = nil
        revert.set(Task { @MainActor in try await review.revertWordFix(claude) })
    }
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "we all")
    try await #require(revert.value).value
    #expect(try wordEditCurrent(session).segments[0].text == "we all met cloud")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aSplitChosenBeforeAWordEditSavedFollowsItsWord() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["one", "two", "three", "four"]),
    ])
    let review = try await wordEditOpen(session)
    // The Split Turn sheet opens; meanwhile "one" becomes "one and more", moving every later word by two.
    let seen = review.wordMoves.count
    let shown = review.words(of: "T1")
    try await review.editWords([shown[0].ref], to: "one and more")
    // Split before "four" as the sheet showed it: before "four", never before what is now its old index ("more").
    try await review.split(turnID: "T1", at: shown[3].ref, seenMoves: seen)
    let turns = review.projection.turns.sorted { $0.start < $1.start }
    #expect(turns.count == 2)
    #expect(review.words(of: turns[1]).map(\.text) == ["four"])
    // A word an edit replaced since: refused.
    let again = review.wordMoves.count
    let words = review.words(of: turns[0])
    try await review.editWords([words[3].ref], to: "TWO")
    await #expect(throws: HolosError.self) {
        try await review.split(turnID: turns[0].id, at: words[3].ref, seenMoves: again)
    }
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aLongSegmentsWordsAreReadInOnePass() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // 40,000 words in one segment and one turn, a hundredth of a second each: each word's shown text and fix are read
    // without walking the whole segment again (which made a long segment take hours).
    var text = ""
    var timed: [TimedWord] = []
    for index in 0..<40_000 {
        if !text.isEmpty { text += " " }
        let word = "w\(index)"
        timed.append(TimedWord(text: word, start: Double(index) / 100, end: Double(index) / 100 + 0.009,
                               utf16Offset: text.utf16.count, utf16Length: word.utf16.count))
        text += word
    }
    let segment = TranscriptSegment(id: "S1", start: 0, end: 400, text: text, words: timed, track: "system")
    let transcript = SessionFixtures.transcript([segment])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 401],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let speaker = SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"])
    let run = DiarizationRun(
        sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1),
        tracks: [TrackDiarization(track: "system", policy: .diarized,
                                  clusters: [ClusterSummary(clusterID: speaker.id, track: "system", speechSeconds: 400)])],
        speakers: [speaker],
        turns: [SpeakerTurn(id: "T1", track: "system", start: 0, end: 400, speakerID: speaker.id, clusterID: speaker.id,
                            spans: [WordSpan(segmentID: "S1", first: 0, end: 40_000)], overlap: false,
                            otherClusters: [], assignmentScore: 1, timing: .measured)])
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let review = try await wordEditOpen(session)
    let words = review.words(of: "T1")
    #expect(words.count == 40_000 && words.last?.shown == "w39999")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aWordMoveTooLargeForAnyEditIsRefusedNeverMapped() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // 1,001 words: a move whose every replacement word is owned by every replaced word would be over a million pairs.
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: Array(repeating: "word", count: 1_001)),
    ])
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    let segment = try #require(snapshot.transcript.segments.first?.id)
    var edited = snapshot.transcript
    edited.id = UUID().uuidString
    #expect(throws: HolosError.self) {
        try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: edited,
                                           move: ReviewWordMove(segmentID: segment, replaced: 0..<1_001,
                                                                replacement: 0..<1_001))
    }
    // One a real edit makes (and marks) maps.
    var marked = edited
    marked.segments[0].fixes = [TranscriptWordFix(first: 0, end: 500, heard: "words", kind: .reviewEdit,
                                                  heardWords: 1)]
    #expect(try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: marked,
                                               move: ReviewWordMove(segmentID: segment, replaced: 0..<500,
                                                                    replacement: 0..<500)) != nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func fixCountsThatAddUpButPutAFixElsewhereNeverMoveLabels() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // The unfixed revision "one two three four"; the fixed one "Alpha Beta" ("one two" and "three four").
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["one", "two", "three", "four"]),
    ])
    let base = try wordEditCurrent(session)
    let segmentID = base.segments[0].id
    for (counts, damaged) in [((2, 2), false), ((3, 1), true)] {
        var fixed = base
        fixed.id = UUID().uuidString
        fixed.fixedFrom = base.id
        fixed.segments[0] = SessionFixtures.segment(["Alpha", "Beta"], track: "system", start: 0, wordSeconds: 2,
                                                    id: segmentID)
        fixed.segments[0].fixes = [
            TranscriptWordFix(first: 0, end: 1, heard: "one two", kind: .correction, heardWords: counts.0),
            TranscriptWordFix(first: 1, end: 2, heard: "three four", kind: .correction, heardWords: counts.1),
        ]
        try await SessionFixtures.saveTranscript(fixed, in: session)
        var run = try SessionSpeakerStore.readRun(
            id: try #require(try SessionSpeakerStore.readHead(session: session)?.runID), session: session)
        run.id = UUID().uuidString
        run.transcriptID = fixed.id
        run.turns[0].spans = [WordSpan(segmentID: segmentID, first: 0, end: 2)]
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.writeRun(run, session: session)
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
        }
        let snapshot = try SpeakerSessionSnapshot.load(session: session)
        var next = fixed
        next.id = UUID().uuidString
        // The word-fix stage maps the labels by those counts (no word move): refused when they are wrong.
        if damaged {
            #expect(throws: HolosError.self) {
                try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: next)
            }
        } else {
            #expect(try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: next) != nil)
        }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aWordMoveIsWhereTheEditsMarkIsNeverOnRepeatedTextElsewhere() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // One segment "go go": the first spoken by S1, the second by S2.
    let segment = SessionFixtures.segment(["go", "go"], track: "system", start: 0, wordSeconds: 1, id: "S1")
    let transcript = SessionFixtures.transcript([segment])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 3],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let speakers = ["system:S1", "system:S2"].enumerated().map {
        SessionSpeaker(id: $1, ordinal: $0 + 1, provenance: .diarizer, clusterIDs: [$1])
    }
    func turn(_ id: String, _ speaker: String, _ word: Int) -> SpeakerTurn {
        SpeakerTurn(id: id, track: "system", start: Double(word), end: Double(word + 1), speakerID: speaker,
                    clusterID: speaker, spans: [WordSpan(segmentID: "S1", first: word, end: word + 1)],
                    overlap: false, otherClusters: [], assignmentScore: 1, timing: .measured)
    }
    let run = DiarizationRun(sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
                             alignment: AlignmentInfo(version: 1, parameters: .v1),
                             tracks: [TrackDiarization(track: "system", policy: .diarized, clusters: speakers.map {
                                 ClusterSummary(clusterID: $0.id, track: "system", speechSeconds: 1)
                             })],
                             speakers: speakers, turns: [turn("T1", "system:S1", 0), turn("T2", "system:S2", 1)])
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let snapshot = try SpeakerSessionSnapshot.load(session: session)
    // S1's "go" edited to "go go": "go go go", the edit's mark over words 0–2.
    var edited = snapshot.transcript
    edited.id = UUID().uuidString
    edited.segments[0] = SessionFixtures.segment(["go", "go", "go"], track: "system", start: 0, wordSeconds: 1,
                                                 id: "S1")
    edited.segments[0].fixes = [TranscriptWordFix(first: 0, end: 2, heard: "go", kind: .reviewEdit, heardWords: 1)]
    // A damaged log saying S2's "go" became two reads the same around it, and S2 holds it: the mark refuses it.
    #expect(throws: HolosError.self) {
        try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: edited,
                                           move: ReviewWordMove(segmentID: "S1", replaced: 1..<2, replacement: 1..<3))
    }
    // The move as written gives both new words to S1.
    let plan = try #require(try SpeakerTranscriptRetarget.plan(
        session: session, from: snapshot, to: edited,
        move: ReviewWordMove(segmentID: "S1", replaced: 0..<1, replacement: 0..<2)))
    let spans = Dictionary(uniqueKeysWithValues: plan.run.turns.map { ($0.id, $0.spans) })
    #expect(spans["T1"] == [WordSpan(segmentID: "S1", first: 0, end: 2)])
    #expect(spans["T2"] == [WordSpan(segmentID: "S1", first: 2, end: 3)])
    // Each direction on its own side: read as an undo, the same move needs its mark in the transcript it is made from
    // (an older mark there never stands in for an edit's, nor the reverse).
    #expect(throws: HolosError.self) {
        try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: edited,
                                           move: ReviewWordMove(segmentID: "S1", replaced: 0..<1, replacement: 0..<2),
                                           undo: true)
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func wordsChangedElsewhereAreCountedAndNeverFollowed() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["one", "go", "go"]),
    ])
    let review = try await wordEditOpen(session)
    // The window's own edit: no count (its word move says where words went).
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "One")
    #expect(review.wordsEpoch == 0)
    let epoch = review.wordsEpoch
    let shown = review.words(of: "T1")
    // Another process turns "One" into "One more" and labels again; the window reads it: counted.
    var changed = try wordEditCurrent(session)
    changed.id = UUID().uuidString
    changed.segments[0] = SessionFixtures.segment(["One", "more", "go", "go"], track: "system", start: 0,
                                                  wordSeconds: 1, id: changed.segments[0].id)
    try await SessionFixtures.saveTranscript(changed, in: session)
    var run = try SessionSpeakerStore.readRun(id: try #require(try SessionSpeakerStore.readHead(session: session)?.runID),
                                              session: session)
    run.id = UUID().uuidString
    run.transcriptID = changed.id
    run.turns[0].spans = [WordSpan(segmentID: changed.segments[0].id, first: 0, end: 4)]
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    await review.reload()
    #expect(review.wordsEpoch == epoch + 1)
    // An edit of the second "go" as it was chosen (word 2 then): refused, saying what was typed; nothing written.
    let refused = await #expect(throws: HolosError.self) {
        try await review.editWords([shown[2].ref], to: "stop", seenEpoch: epoch)
    }
    #expect(refused?.localizedDescription.contains("what you typed: “stop”") == true)
    #expect(try wordEditCurrent(session).segments[0].text == "One more go go")
    // A split chosen before (at the second "go", word 2 then) is refused, never made at what is word 2 now.
    await #expect(throws: HolosError.self) {
        try await review.split(turnID: "T1", at: shown[2].ref, seenMoves: review.shownWordMoves.count,
                               seenEpoch: epoch)
    }
    #expect(review.projection.turns.count == 1)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditIsNeverSavedOverAWordWhosePunctuationChangedElsewhere() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    let seen = review.words(of: "T1")[1]
    #expect(seen.text == "cloud" && seen.shown == "cloud")
    // Another process changes only the punctuation the recognizer did not time: "cloud" shows as "cloud?".
    var changed = try wordEditCurrent(session)
    changed.id = UUID().uuidString
    changed.segments[0].text = "ask cloud? now"
    changed.segments[0].words[2].utf16Offset = 11
    try await SessionFixtures.saveTranscript(changed, in: session)
    var run = try SessionSpeakerStore.readRun(id: try #require(try SessionSpeakerStore.readHead(session: session)?.runID),
                                              session: session)
    run.id = UUID().uuidString
    run.transcriptID = changed.id
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    await review.reload()
    #expect(review.words(of: "T1")[1].text == "cloud" && review.words(of: "T1")[1].shown == "cloud?")
    // Its timed text is the same, its shown text is not: refused, saying what was typed.
    let refused = await #expect(throws: HolosError.self) {
        try await review.editWords([seen.ref], to: "Claude", expecting: [seen.shown])
    }
    #expect(refused?.localizedDescription.contains("what you typed: “Claude”") == true)
    #expect(try wordEditCurrent(session).segments[0].text == "ask cloud? now")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditTakingInAnEarlierDeletionOffersNoHeardAs() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["um", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    // "um" deleted: it merges into "cloud", whose mark now holds "um cloud".
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "")
    #expect(review.words(of: "T1").map(\.text) == ["cloud", "now"])
    // Then "cloud" edited to "Clyde": what was heard there holds the deleted "um", so it is no "often heard as" (the
    // term itself may still be offered).
    var saved: [ReviewWordEdit] = []
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Clyde") { saved.append($0) }
    #expect(try wordEditCurrent(session).segments[0].text == "Clyde now")
    let edit = try #require(saved.first)
    #expect(edit.heard == "um cloud" && edit.typed == "Clyde" && edit.typedHeard == nil)
    // An edit holding no deletion keeps it.
    saved.removeAll()
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "later") { saved.append($0) }
    #expect(saved.first?.typedHeard == "now")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anUndoThatFailsAfterTheEditItWaitedForCanBeAskedAgain() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let original = try wordEditCurrent(session)
    let file = SessionPaths.transcript(original.id, in: session)
    let saved = try Data(contentsOf: file)
    let review = try await wordEditOpen(session)
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        let count = entered.update { value -> Int in
            value += 1
            return value
        }
        if count == 1 {
            for await _ in stream {}
        } else {
            // The undo, once the edit saved: the transcript it would restore cannot be read for a moment.
            try? Data("damaged".utf8).write(to: file)
        }
    }
    // The edit is saving when Undo is asked: the undo waits for it, on the labels before it.
    let edit = Task { try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude") }
    #expect(await eventually { entered.value == 1 })
    let undo = Task { try await review.undo() }
    #expect(await eventually { review.queuedOperations == 2 })
    // The edit saves (a new run, keeping the turns); the undo then fails before saving anything.
    release.finish()
    await #expect(throws: Never.self, "the edit") { _ = try await edit.value }
    await #expect(throws: (any Error).self) { try await undo.value }
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
    // Still undoable: the labels are this window's own (its edit retargeted them), not a new labelling.
    #expect(review.canUndo)
    review.beforeEdit = nil
    try saved.write(to: file)
    await #expect(throws: Never.self, "the second undo") { try await review.undo() }
    #expect(try wordEditCurrent(session).segments[0].text == "ask cloud now")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditsUndoThatCanNoLongerBeMadeNeverBlocksTheUndosBeforeIt() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // "ask more Claude now", "Claude" an automatic fix of "cloud". A rename, then "ask" edited to "Ask".
    let session = try await wordEditFixedCloudSession(temp)
    let review = try await wordEditOpen(session)
    try await review.apply([.rename(speakerID: "system:S1", name: "Ann")])
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Ask")
    // Reverting "Claude" while ⌘Z waits behind it: the revert makes another transcript current, so the edit's undo
    // (which needs its own) fails.
    let (stream, release) = AsyncStream<Void>.makeStream()
    let entered = SharedValue(0)
    review.beforeEdit = {
        entered.update { $0 += 1 }
        for await _ in stream {}
    }
    let revert = Task { try await review.revertWordFix(wordEditRefs(review, "T1", [2])[0]) }
    #expect(await eventually { entered.value == 1 })
    let undo = Task { try await review.undo() }
    #expect(await eventually { review.queuedOperations == 2 })
    review.beforeEdit = nil
    release.finish()
    try await revert.value
    await #expect(throws: (any Error).self) { try await undo.value }
    #expect(try wordEditCurrent(session).segments[0].text == "Ask more cloud now")
    // Not put back: the next ⌘Z takes back the rename, as it would have without the failed undo.
    #expect(review.canUndo)
    try await review.undo()
    #expect(review.speaker("system:S1")?.name != "Ann")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditWhoseHeadIsReplacedBeforeItsRereadGetsNoUndo() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    // Saved; then, before the window rereads the labels, another process replaces the head (a relabel elsewhere).
    review.beforeWordChangeReread = {
        review.beforeWordChangeReread = nil
        var run = try SessionSpeakerStore.readRun(
            id: try #require(try SessionSpeakerStore.readHead(session: session)?.runID), session: session)
        run.id = UUID().uuidString
        try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.writeRun(run, session: session)
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
        }
    }
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
    // The head it published is no longer current: its undo would act on another head, so there is none.
    #expect(!review.canUndo)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aFieldKeptWhenTheRereadFailedIsQueuedAndSavedAtTheReread() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    struct Unreadable: Error {}
    var failures = 1
    review.beforeWordChangeReread = {
        guard failures > 0 else { return }
        failures -= 1
        throw Unreadable()
    }
    // Tab: the first edit is saved, its labels cannot be reread; the review turns read-only with the next field open.
    let words = review.words(of: "T1")
    await #expect(throws: HolosError.self) { try await review.editWords([words[1].ref], to: "Claude") }
    #expect(review.reloadProblem != nil && !review.canEditWords)
    // A new edit is refused; the open field's, kept (`whileUnread`), waits, still queued, for the reread.
    await #expect(throws: HolosError.self) { try await review.editWords([words[2].ref], to: "later") }
    let kept = Task { try await review.editWords([words[2].ref], to: "today", seenMoves: 0, whileUnread: true) }
    #expect(await eventually { review.queuedOperations == 1 })
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
    await review.reload()
    _ = try await kept.value
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude today")
    #expect(review.reloadProblem == nil && review.queuedOperations == 0)
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
    let edits = ReviewLearning.edits(in: SessionFixtures.transcript([fixed, plain]),
                                     turns: [[WordSpan(segmentID: "S1", first: 0, end: 3)],
                                             [WordSpan(segmentID: "S2", first: 0, end: 3)]])
    #expect(edits == [
        ReviewWordEdit(heard: "as", meant: "ask", after: "Claude", heardAfter: "cloud"),
        ReviewWordEdit(heard: "new", meant: "knew", before: "we", after: "here"),
    ])
    // The heard side is the recognizer's text throughout, so the correction matches it: "as cloud" → "ask Claude".
    let learned = TranscriptEditLearning.corrections(heard: "as", meant: "ask", after: "Claude", heardAfter: "cloud",
                                                     isDictionaryWord: { _ in true })
    #expect(learned.map(\.heard) == ["as cloud"] && learned.map(\.meant) == ["ask Claude"])
}

@Test func anEditIsLearnedOnlyWhenOneTurnHoldsItAllAndTakesContextFromThatTurn() {
    // Overlapping turns: A holds words 0–1, B holds 1–2, of each segment.
    var across = SessionFixtures.segment(["we", "much", "Claude", "now"], track: "system", start: 0, wordSeconds: 1,
                                         id: "S1")
    across.fixes = [TranscriptWordFix(first: 0, end: 3, heard: "we more cloud", kind: .reviewEdit, heardWords: 3)]
    var inside = SessionFixtures.segment(["ask", "Claude", "now", "please"], track: "system", start: 10, wordSeconds: 1,
                                         id: "S2")
    inside.fixes = [TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit, heardWords: 1)]
    let turns = ["S1", "S2"].flatMap { segment in
        [[WordSpan(segmentID: segment, first: 0, end: 2)], [WordSpan(segmentID: segment, first: 1, end: 3)]]
    }
    let edits = ReviewLearning.edits(in: SessionFixtures.transcript([across, inside]), turns: turns)
    // Words 0–2 are each in a turn, word by word, but no one turn holds them all: not learned. "cloud" is in both;
    // the first turn holding it (A) gives its context: "ask" before it, nothing after (B's "now" is not A's).
    #expect(edits == [ReviewWordEdit(heard: "cloud", meant: "Claude", before: "ask")])
}

@Test func aSegmentThatCannotBeTrustedTeachesNothing() {
    // A damaged but decodable transcript beside a sound one. Each damaged segment holds a valid edit ("as" → "ask"):
    // a mark past its words, two marks over one word, and a word range that does not fit the text.
    var pastWords = SessionFixtures.segment(["ask", "now"], track: "system", start: 0, wordSeconds: 1, id: "S1")
    pastWords.fixes = [TranscriptWordFix(first: 0, end: 1, heard: "as", kind: .reviewEdit, heardWords: 1),
                       TranscriptWordFix(first: 1, end: 9, heard: "know", kind: .correction, heardWords: 1)]
    var overlapping = SessionFixtures.segment(["ask", "now"], track: "system", start: 10, wordSeconds: 1, id: "S2")
    overlapping.fixes = [TranscriptWordFix(first: 0, end: 2, heard: "as now", kind: .reviewEdit, heardWords: 2),
                         TranscriptWordFix(first: 1, end: 2, heard: "know", kind: .correction, heardWords: 1)]
    var outOfText = SessionFixtures.segment(["ask", "now"], track: "system", start: 20, wordSeconds: 1, id: "S3")
    outOfText.fixes = [TranscriptWordFix(first: 0, end: 1, heard: "as", kind: .reviewEdit, heardWords: 1)]
    outOfText.words[1].utf16Length = Int.max
    var sound = SessionFixtures.segment(["we", "knew", "here"], track: "system", start: 30, wordSeconds: 1, id: "S4")
    sound.fixes = [TranscriptWordFix(first: 1, end: 2, heard: "new", kind: .reviewEdit, heardWords: 1)]
    for segment in [pastWords, overlapping, outOfText] { #expect(TranscriptWordEdit.isDamaged(segment)) }
    let transcript = SessionFixtures.transcript([pastWords, overlapping, outOfText, sound])
    let turns = ["S1", "S2", "S3", "S4"].map { [WordSpan(segmentID: $0, first: 0, end: 9)] }
    // Only the sound segment's edit is learned; nothing is read past any word.
    #expect(ReviewLearning.edits(in: transcript, turns: turns)
        == [ReviewWordEdit(heard: "new", meant: "knew", before: "we", after: "here")])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aSegmentWithADamagedMarkIsRefusedBeforeAnyFieldOpens() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // A damaged but decodable transcript: a mark from word 0 to Int.max. Walking it (taking it in, listing its words)
    // would never end.
    let damaged = TranscriptWordFix(first: 0, end: Int.max, heard: "as", kind: .correction, heardWords: 1)
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
        WordEditTurn(speaker: "system:S2", start: 5, words: ["we", "knew", "here"]),
    ], fixes: [damaged])
    let review = try await wordEditOpen(session)
    // Its words are shown without marks (no Revert offered); every check refuses them up front, with the reason.
    let words = review.words(of: "T1")
    #expect(words.map(\.text) == ["ask", "cloud", "now"] && words.allSatisfy { $0.fix == nil })
    let reason = TranscriptWordEdit.damagedMarks.localizedDescription
    #expect(review.wordEditRefusal([words[1].ref]) == reason)
    #expect(review.wordEditRefusal(words.map(\.ref)) == reason)
    let edit = await #expect(throws: HolosError.self) { try await review.editWords([words[1].ref], to: "Claude") }
    #expect(edit?.localizedDescription == reason)
    let revert = await #expect(throws: HolosError.self) { try await review.revertWordFix(words[0].ref) }
    #expect(revert?.localizedDescription == reason)
    #expect(try wordEditCurrent(session).segments[0].text == "ask cloud now", "Nothing was written.")
    // Another segment's words are edited as usual.
    try await review.editWords([review.words(of: "T2")[1].ref], to: "new")
    #expect(try wordEditCurrent(session).segments[1].text == "we new here")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aSegmentWithOverlappingMarksIsRefusedBeforeAnyFieldOpens() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ], fixes: [TranscriptWordFix(first: 0, end: 2, heard: "as cloud", kind: .reviewEdit, heardWords: 2),
               TranscriptWordFix(first: 1, end: 3, heard: "cloud now", kind: .correction, heardWords: 2)])
    let review = try await wordEditOpen(session)
    let words = review.words(of: "T1")
    #expect(words.allSatisfy { $0.fix == nil }, "No mark is shown, so no Revert is offered.")
    let reason = TranscriptWordEdit.damagedMarks.localizedDescription
    #expect(review.wordEditRefusal([words[2].ref]) == reason && review.revertRefusal(words[1].ref) == reason)
    await #expect(throws: HolosError.self) { try await review.editWords([words[2].ref], to: "later") }
    await review.close()
}

@Test func aTranscriptWithASegmentIDUsedTwiceTeachesNothingAndIsNotEdited() throws {
    // A damaged transcript: two segments "S1", the second with a valid edit ("cloud" → "Claude").
    let first = SessionFixtures.segment(["hello", "there"], track: "system", start: 0, wordSeconds: 1, id: "S1")
    var second = SessionFixtures.segment(["ask", "Claude"], track: "system", start: 5, wordSeconds: 1, id: "S1")
    second.fixes = [TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit, heardWords: 1)]
    let transcript = SessionFixtures.transcript([first, second])
    #expect(TranscriptWordEdit.hasRepeatedSegmentIDs(transcript))
    // A turn of the first "S1" never vouches for words of the second.
    #expect(ReviewLearning.edits(in: transcript, turns: [[WordSpan(segmentID: "S1", first: 0, end: 2)]]).isEmpty)
    #expect(throws: HolosError.self) {
        try TranscriptWordEdit.editing(TranscriptWordEdit.Request(segmentID: "S1", first: 0, end: 1, text: "hi"),
                                       in: transcript, base: nil)
    }
    // An unfixed revision with "S1" twice gives no context: which one the recognizer's words are in cannot be told.
    var current = SessionFixtures.segment(["ask", "Claude"], track: "system", start: 0, wordSeconds: 1, id: "S1")
    current.fixes = [TranscriptWordFix(first: 0, end: 1, heard: "as", kind: .reviewEdit, heardWords: 1),
                     TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .correction, heardWords: 1)]
    var fixed = SessionFixtures.transcript([current])
    let base = SessionFixtures.transcript([
        SessionFixtures.segment(["ask", "cloud!"], track: "system", start: 0, wordSeconds: 1, id: "S1"),
        SessionFixtures.segment(["ask", "cloud."], track: "system", start: 5, wordSeconds: 1, id: "S1"),
    ])
    fixed.fixedFrom = base.id
    let edits = ReviewLearning.edits(in: fixed, turns: [[WordSpan(segmentID: "S1", first: 0, end: 2)]], base: base)
    #expect(edits.allSatisfy { $0.heardAfter != "cloud!" && $0.heardAfter != "cloud." })
}

@Test(.timeLimit(.minutes(1))) func manySegmentsAndTurnsAreReadOnceToLearn() {
    // 60,000 one-word segments, each with its own turn, one edit among them: never every turn for every segment.
    let count = 60_000
    var segments = (0..<count).map { index in
        TranscriptSegment(id: "S\(index)", start: Double(index), end: Double(index) + 0.5, text: "word",
                          words: [TimedWord(text: "word", start: Double(index), end: Double(index) + 0.5,
                                            utf16Offset: 0, utf16Length: 4)], track: "system")
    }
    segments[count - 1].text = "Claude"
    segments[count - 1].words = [TimedWord(text: "Claude", start: Double(count - 1), end: Double(count) - 0.5,
                                           utf16Offset: 0, utf16Length: 6)]
    segments[count - 1].fixes = [TranscriptWordFix(first: 0, end: 1, heard: "cloud", kind: .reviewEdit, heardWords: 1)]
    let turns = (0..<count).map { [WordSpan(segmentID: "S\($0)", first: 0, end: 1)] }
    #expect(ReviewLearning.edits(in: SessionFixtures.transcript(segments), turns: turns)
        == [ReviewWordEdit(heard: "cloud", meant: "Claude")])
}

@Test(.timeLimit(.minutes(1))) func manyEditsSideBySideAreLearnedInOnePass() {
    // 60,000 words, each edited on its own and side by side, in one turn: one span, read without rechecking the span
    // as it grows (which took billions of checks).
    let count = 60_000
    var segment = SessionFixtures.segment(Array(repeating: "b", count: count), track: "system", start: 0,
                                          wordSeconds: 0.01, id: "S1")
    segment.fixes = (0..<count).map { TranscriptWordFix(first: $0, end: $0 + 1, heard: "a", kind: .reviewEdit,
                                                         heardWords: 1) }
    let edits = ReviewLearning.edits(in: SessionFixtures.transcript([segment]),
                                     turns: [[WordSpan(segmentID: "S1", first: 0, end: count)]])
    #expect(edits.count == 1)
    #expect(edits.first?.meant.split(separator: " ").count == count)
}

@Test func aFixTheTurnHoldsOnlyPartOfGivesNoContext() {
    // "as newark": "newark" fixed automatically to "New York", then "as" edited to "ask"; the labels split the fix,
    // "as New" in one turn and "York" in the next.
    var segment = SessionFixtures.segment(["ask", "New", "York"], track: "system", start: 0, wordSeconds: 1, id: "S1")
    segment.fixes = [TranscriptWordFix(first: 0, end: 1, heard: "as", kind: .reviewEdit, heardWords: 1),
                     TranscriptWordFix(first: 1, end: 3, heard: "newark", kind: .correction, heardWords: 1)]
    let edits = ReviewLearning.edits(in: SessionFixtures.transcript([segment]),
                                     turns: [[WordSpan(segmentID: "S1", first: 0, end: 2)],
                                             [WordSpan(segmentID: "S1", first: 2, end: 3)]])
    // No "as New" → "ask New", which would never match the recognizer's "as newark": no context on that side.
    #expect(edits == [ReviewWordEdit(heard: "as", meant: "ask")])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anEditOfPunctuationAloneKeepsItsMarkAndRevert() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // "Hello. there", timed as "Hello" and "there": the period is not timed.
    var segment = SessionFixtures.segment(["Hello", "there"], track: "system", start: 0, wordSeconds: 1)
    segment.text = "Hello. there"
    segment.words[1].utf16Offset = 7
    let transcript = SessionFixtures.transcript([segment])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .system, audioSeconds: ["system": 3],
                                                        mode: .call, transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let speaker = SessionSpeaker(id: "system:S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S1"])
    let run = DiarizationRun(
        sessionID: manifest.id, transcriptID: transcript.id, engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1),
        tracks: [TrackDiarization(track: "system", policy: .diarized,
                                  clusters: [ClusterSummary(clusterID: speaker.id, track: "system", speechSeconds: 2)])],
        speakers: [speaker],
        turns: [SpeakerTurn(id: "T1", track: "system", start: 0, end: 2, speakerID: speaker.id, clusterID: speaker.id,
                            spans: [WordSpan(segmentID: segment.id, first: 0, end: 2)], overlap: false,
                            otherClusters: [], assignmentScore: 1, timing: .measured)])
    try SessionArchive.withSpeakerLock(at: session) {
        try SessionSpeakerStore.writeRun(run, session: session)
        try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
    }
    let review = try await wordEditOpen(session)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Hello?")
    #expect(try wordEditCurrent(session).segments[0].text == "Hello? there")
    // The words are the same ("Hello"); the edit is not: it stays marked, with its Revert.
    let edited = try #require(review.words(of: "T1").first)
    #expect(edited.fix?.kind == .reviewEdit && edited.fix?.heard == "Hello." && edited.revertible)
    try await review.revertWordFix(edited.ref)
    #expect(try wordEditCurrent(session).segments[0].text == "Hello. there")
    #expect(review.words(of: "T1").first?.fix == nil, "Back to what the recognizer wrote: no longer a change.")
    await review.close()
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
        let taught = try learner.taught(session)
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
func anEditOfPartOfAFixSaysWhatWasTypedApartFromTheWordsItTookIn() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditFixedCloudSession(temp, words: ["we", "knew", "work", "here"],
                                                      correction: Correction(heard: "knew work", meant: "New York"))
    let review = try await wordEditOpen(session)
    #expect(review.words(of: "T1").map(\.text) == ["we", "New", "York", "here"])
    var committed: [ReviewWordEdit] = []
    try await review.editWords(wordEditRefs(review, "T1", [2]), to: "Yorkshire") { committed.append($0) }
    // The edit takes in the whole fix ("New Yorkshire", heard "knew work"); what was typed is "Yorkshire" alone, and
    // what the recognizer wrote for "York" alone is not known.
    #expect(committed.first?.meant == "New Yorkshire" && committed.first?.heard == "knew work")
    #expect(committed.first?.typed == "Yorkshire" && committed.first?.typedHeard == nil)
    // A whole word edited: what the recognizer wrote for it is known.
    try await review.editWords(wordEditRefs(review, "T1", [3]), to: "there") { committed.append($0) }
    #expect(committed.last?.typed == "there" && committed.last?.typedHeard == "here")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aDeletionTeachesNothingNorDoesAnEditTakingItIn() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    // "um cloud now please", whose "cloud" a correction made "Claude".
    let session = try await wordEditFixedCloudSession(temp, words: ["um", "cloud", "now", "please"])
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner()
    learner.attach(to: review)
    // "um" deleted: merged into "Claude", heard "um cloud". Then "now" edited beside it.
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "")
    #expect(try wordEditCurrent(session).segments[0].text == "Claude now please")
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "today")
    await review.close()
    // Never "um cloud" → "Claude" (dictation would drop "um" everywhere); the edit beside it is learned on its own,
    // without the deletion's words as context.
    #expect(learner.taughtBy == [ReviewWordEdit(heard: "now", meant: "today", after: "please")])
    #expect(learner.value("um cloud") == nil && learner.value("now") == "today")

    // Later, the merged word itself edited: it takes the deletion in, whose deleted words cannot be told apart from
    // the rest of what was heard there, so it teaches nothing either.
    let reopened = try await wordEditOpen(session)
    learner.attach(to: reopened)
    try await reopened.editWords(wordEditRefs(reopened, "T1", [0]), to: "Clyde")
    #expect(try wordEditCurrent(session).segments[0].text == "Clyde today please")
    await reopened.close()
    #expect(learner.value("um cloud") == nil && learner.value("cloud") == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aCorrectionTheListAlreadyHadIsNeverTheMeetingsToReplace() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    // The list already has "cloud" → "Claude" (set elsewhere); the meeting's edit teaches the same.
    let learner = WordEditLearner(CorrectionList(entries: [Correction(heard: "cloud", meant: "Claude")]))
    let first = try await wordEditOpen(session)
    learner.attach(to: first)
    try await first.editWords(wordEditRefs(first, "T1", [0]), to: "Claude")
    await first.close()
    #expect(try learner.taught(session).isEmpty, "Already there: not recorded as this meeting's.")
    // Reopened, the word edited again: the rule the meeting never created stays.
    let second = try await wordEditOpen(session)
    learner.attach(to: second)
    try await second.editWords(wordEditRefs(second, "T1", [0]), to: "Claudia")
    await second.close()
    #expect(learner.value("cloud") == "Claude")
    #expect(try learner.taught(session).isEmpty)
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
    await review.close(typed: .init(words: field, text: "Claude", seenMoves: seen))
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
    let closing = Task { await review.close(typed: .init(words: wordEditRefs(review, "T1", [1]), text: "Claude",
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
    // Its automatic fix's Revert is not offered either (it would fail once asked), and is refused if asked.
    let fixedWord = wordEditRefs(review, "T1", [0])[0]
    #expect(review.words(of: "T1")[0].fix?.kind == .correction)
    #expect(review.revertRefusal(fixedWord) == TranscriptWordEdit.olderFix.localizedDescription)
    let revert = await #expect(throws: HolosError.self) { try await review.revertWordFix(fixedWord) }
    #expect(revert?.localizedDescription == TranscriptWordEdit.olderFix.localizedDescription)
    #expect(review.queuedOperations == 0, "Refused before it was queued.")
    #expect(try wordEditCurrent(session).id == fixed.id, "Nothing was written.")
    #expect(review.reloadProblem == nil && review.canEditWords, "The review goes on.")
    await review.close()
}

/// "ask more cloud now" (or `words`), whose "cloud" the word-fix stage made "Claude"; the labels are on that revision.
private func wordEditFixedCloudSession(_ temp: TemporaryDirectory,
                                       words: [String] = ["ask", "more", "cloud", "now"],
                                       correction: Correction = Correction(heard: "cloud", meant: "Claude"))
    async throws -> URL {
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: words),
    ])
    let base = try wordEditCurrent(session)
    let fixed = try await WordFixStage.fix(base, title: "", corrections: CorrectionList(entries: [correction]),
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
func wordsAreReadOnlyWhileTheRevisionTheTranscriptWasFixedFromCannotBeRead() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditFixedCloudSession(temp)
    let fixed = try wordEditCurrent(session)
    let baseID = try #require(fixed.fixedFrom)
    let baseFile = SessionPaths.transcript(baseID, in: session)
    let kept = temp.url.appendingPathComponent("base.json")
    try FileManager.default.moveItem(at: baseFile, to: kept)
    let review = try await wordEditOpen(session)
    // Known before anything is typed: no field opens, no Revert is offered, and the banner says why.
    #expect(review.isEditable && !review.canEditWords)
    #expect(review.wordEditingBlocked == ReviewSession.baseUnreadable.localizedDescription)
    let edit = await #expect(throws: HolosError.self) {
        try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Ask")
    }
    #expect(edit?.localizedDescription == ReviewSession.baseUnreadable.localizedDescription)
    await #expect(throws: HolosError.self) { try await review.revertWordFix(wordEditRefs(review, "T1", [2])[0]) }
    #expect(try wordEditCurrent(session).id == fixed.id, "Nothing was written.")
    // Back, and the labels read again: words can be edited.
    try FileManager.default.moveItem(at: kept, to: baseFile)
    await review.reload()
    #expect(review.canEditWords)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Ask")
    #expect(try wordEditCurrent(session).segments[0].text == "Ask more Claude now")
    await review.close()
}

/// The field check and the Revert check are the save and the revert made as dry runs: for every refusal the save or
/// the revert makes, the check gives the same message before anything is typed or asked. "ask more Claude now", fixed
/// from "ask more cloud now"; each case changes the revisions as read from disk.
@Test(.timeLimit(.minutes(1))) @MainActor
func theChecksBeforeAnEditOrRevertRefuseWhatTheSaveRefuses() async throws {
    struct Case {
        var name: String
        var change: (inout Transcript, inout Transcript) -> Void
        /// The words the field opens over.
        var words: [Int]
    }
    let cases: [Case] = [
        // A modern fix whose count of recognizer words does not hold what it matched in the unfixed revision.
        Case(name: "wrong heardWords", change: { current, _ in current.segments[0].fixes?[0].heardWords = 2 },
             words: [0]),
        // A fix of a kind a newer version wrote.
        Case(name: "newer kind", change: { current, _ in
            current.segments[0].fixes?[0].kind = TranscriptWordFixKind("fromTheFuture")
        }, words: [2]),
        // A word corrected while recording.
        Case(name: "live correction", change: { current, _ in current.segments[0].fixes?[0].kind = .liveCorrection },
             words: [2]),
        // The unfixed revision repeats a segment ID, or its segment is damaged.
        Case(name: "repeated base ID", change: { _, base in base.segments.append(base.segments[0]) }, words: [0]),
        Case(name: "damaged base", change: { _, base in base.segments[0].words[3].utf16Offset = Int.max },
             words: [0]),
    ]
    for item in cases {
        let temp = try TemporaryDirectory("review")
        defer { temp.remove() }
        let session = try await wordEditFixedCloudSession(temp)
        var current = try wordEditCurrent(session)
        let baseID = try #require(current.fixedFrom)
        var base = try SessionFiles.transcript(id: baseID, session: session)
        item.change(&current, &base)
        try AtomicFile.writeJSON(current, to: SessionPaths.transcript(current.id, in: session))
        try AtomicFile.writeJSON(base, to: SessionPaths.transcript(baseID, in: session))
        let review = try await wordEditOpen(session)
        #expect(review.canEditWords, "\(item.name)")
        let refs = wordEditRefs(review, "T1", item.words)
        let check = try #require(review.wordEditRefusal(refs), "\(item.name): the field check refuses")
        let save = await #expect(throws: HolosError.self) { try await review.editWords(refs, to: "Something") }
        #expect(save?.localizedDescription == check, "\(item.name)")
        // The revert, made as the window makes it (no check before it).
        let fixed = wordEditRefs(review, "T1", [2])[0]
        let revertCheck = review.revertRefusal(fixed)
        let runID = try #require(try SessionSpeakerStore.readHead(session: session)?.runID)
        do {
            try await SessionWordFixRevert.run(session: session, word: fixed, expectedTranscriptID: current.id,
                                               expectedRunID: runID)
            Issue.record("\(item.name): the revert was made")
        } catch {
            #expect(revertCheck == error.localizedDescription, "\(item.name)")
        }
        #expect(try wordEditCurrent(session).id == current.id, "\(item.name): nothing was written")
        await review.close()
    }
}

/// The unfixed revision reads but cannot be trusted (a segment ID used twice; its segment damaged): known before a
/// field opens or Revert is offered, by the same check the edit and the revert make, never after the person typed.
@Test(.timeLimit(.minutes(1))) @MainActor
func anUntrustworthyUnfixedRevisionIsRefusedBeforeAFieldOpens() async throws {
    for repeated in [true, false] {
        let temp = try TemporaryDirectory("review")
        defer { temp.remove() }
        let session = try await wordEditFixedCloudSession(temp)
        let fixed = try wordEditCurrent(session)
        let baseID = try #require(fixed.fixedFrom)
        var base = try SessionFiles.transcript(id: baseID, session: session)
        if repeated {
            base.segments.append(base.segments[0])
        } else {
            base.segments[0].words[3].utf16Offset = Int.max
        }
        try AtomicFile.writeJSON(base, to: SessionPaths.transcript(baseID, in: session))
        let review = try await wordEditOpen(session)
        #expect(review.canEditWords, "The transcript shown is sound: only its fixed segment is refused.")
        let refs = wordEditRefs(review, "T1", [0])
        let fixedWord = wordEditRefs(review, "T1", [2])[0]
        let damaged = TranscriptWordEdit.damagedMarks.localizedDescription
        #expect(review.wordEditRefusal(refs) == damaged, "repeated: \(repeated)")
        #expect(review.revertRefusal(fixedWord) == damaged, "repeated: \(repeated)")
        // What the edit and the revert refuse.
        let edit = await #expect(throws: HolosError.self) { try await review.editWords(refs, to: "Ask") }
        #expect(edit?.localizedDescription == damaged)
        await #expect(throws: HolosError.self) { try await review.revertWordFix(fixedWord) }
        #expect(try wordEditCurrent(session).id == fixed.id, "Nothing was written.")
        await review.close()
    }
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
func aRevertWhoseHeadWasWrittenThenFailedStaysTheWindowsOwnChange() async throws {
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
    // head.json names the revert's run, then syncing its folder fails (once).
    let failures = SharedValue(1)
    review.afterHeadWritten = {
        if failures.update({ count in defer { count -= 1 }; return count > 0 }) {
            throw HolosError.io("the folder could not be synced")
        }
    }
    let revert = Task { try await review.revertWordFix(wordEditRefs(review, "T1", [2])[0]) }
    #expect(await eventually { entered.value == 1 })
    // Queued while the revert saves.
    let rename = Task { try await review.apply([.rename(speakerID: "system:S1", name: "Bo")]) }
    #expect(await eventually { review.queuedOperations == 2 })
    review.beforeEdit = nil
    release.finish()
    try await revert.value
    // The revert's own head is not a relabel made elsewhere: the queued rename is not refused, the undo stays.
    try await rename.value
    #expect(try wordEditCurrent(session).segments[0].text == "ask more cloud now")
    #expect(review.speaker("system:S1")?.name == "Bo")
    #expect(review.reloadProblem == nil && review.canUndo)
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aTranscriptReplacedWhileLearningTeachesNothingAtThisClose() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner()
    learner.attach(to: review)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    // Another process replaces the current transcript after the close read it, before the corrections are written.
    let teach = try #require(review.correctionsToLearn)
    review.correctionsToLearn = { edit in
        if var other = try? wordEditCurrent(session) {
            other.id = UUID().uuidString
            try? AtomicFile.writeJSON(other, to: SessionPaths.transcript(other.id, in: session))
            try? AtomicFile.writeJSON(TranscriptPointer(transcriptID: other.id),
                                      to: SessionPaths.transcriptPointer(session))
        }
        return teach(edit)
    }
    await review.close()
    #expect(learner.lessons == 0 && learner.list.entries.isEmpty, "Nothing taught from a transcript no longer current.")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aRelabelSavedWhileLearningTeachesNothingAtThisClose() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner()
    learner.attach(to: review)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    // Another process labels the speakers again on the same transcript after the close read the labels, giving the
    // words after "Claude" to a turn of their own: the edit's context ("now") is no longer its turn's.
    let teach = try #require(review.correctionsToLearn)
    review.correctionsToLearn = { edit in
        if let head = try? SessionSpeakerStore.readHead(session: session)?.runID,
           var run = try? SessionSpeakerStore.readRun(id: head, session: session),
           let segmentID = run.turns.first?.spans.first?.segmentID {
            run.id = UUID().uuidString
            var rest = run.turns[0]
            rest.id = "T2"
            rest.spans = [WordSpan(segmentID: segmentID, first: 1, end: 5)]
            run.turns[0].spans = [WordSpan(segmentID: segmentID, first: 0, end: 1)]
            run.turns.append(rest)
            try? SessionArchive.withSpeakerLock(at: session) {
                try SessionSpeakerStore.writeRun(run, session: session)
                try SessionSpeakerStore.writeHead(SpeakerHead(runID: run.id), session: session)
            }
        }
        return teach(edit)
    }
    await review.close()
    #expect(learner.lessons == 0 && learner.list.entries.isEmpty, "Nothing taught on labels no longer current.")
    #expect(try learner.taught(session).isEmpty)
    // The next close, on the labels as they are then, learns it.
    let reopened = try await wordEditOpen(session)
    learner.attach(to: reopened)
    await reopened.close()
    #expect(learner.value("cloud") == "Claude")
    #expect(try learner.taught(session) == [Correction(heard: "cloud", meant: "Claude")])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aSpeakerChangeSavedWhileLearningTeachesNothingAtThisClose() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner(contextual: true)
    learner.attach(to: review)
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude")
    let segmentID = try wordEditCurrent(session).segments[0].id
    // After the close read the labels, another process splits the turn before "now" (same transcript, same head run):
    // "now" is no longer the edit's turn's, so the context learned from the labels read first is not theirs now.
    let teach = try #require(review.correctionsToLearn)
    var split = false
    review.correctionsToLearn = { edit in
        if !split {
            split = true
            try? SessionFixtures.appendEdits([.splitTurn(turnID: "T1", at: WordRef(segmentID: segmentID, word: 2))],
                                             session: session)
        }
        return teach(edit)
    }
    await review.close()
    #expect(learner.lessons == 0 && learner.list.entries.isEmpty, "Nothing taught from labels no longer current.")
    // The next close learns from the labels as they are: "cloud" with "ask" before it, nothing after.
    let reopened = try await wordEditOpen(session)
    learner.attach(to: reopened)
    await reopened.close()
    #expect(learner.value("ask cloud") == "ask Claude" && learner.value("cloud now") == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aRuleTheMeetingTaughtThenDeletedInCorrectionsIsNeverTaughtAgain() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditCloudSession(temp)
    let claude = Correction(heard: "cloud", meant: "Claude")
    let review = try await wordEditOpen(session)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    let learner = WordEditLearner()
    learner.attach(to: review)
    await review.close()
    // Taught, and recorded as the meeting's in the same list (one save).
    #expect(learner.value("cloud") == "Claude" && learner.lessons == 1)
    #expect(try learner.taught(session) == [claude])
    // Deleted in Corrections: the rule goes, what the meeting taught stays.
    learner.list.remove(claude)
    #expect(try learner.value("cloud") == nil && learner.taught(session) == [claude])
    // The next close, with the same edit still in the transcript, does not add it back.
    let reopened = try await wordEditOpen(session)
    learner.attach(to: reopened)
    await reopened.close()
    #expect(try learner.value("cloud") == nil && learner.taught(session) == [claude])
}

@Test func whatAMeetingTaughtTravelsWithTheRulesAndOlderFilesReadAsBefore() throws {
    // One value, saved and read back whole: the rules and what each meeting taught.
    var list = CorrectionList(entries: [Correction(heard: "um", meant: "uh")])
    #expect(list.learnFromReview([Correction(heard: "cloud", meant: "Claude")], meeting: "M1")
        == [Correction(heard: "cloud", meant: "Claude")])
    let decoded = try JSONDecoder().decode(CorrectionList.self, from: JSONEncoder().encode(list))
    #expect(decoded == list && decoded.taught(byMeeting: "M1") == [Correction(heard: "cloud", meant: "Claude")])
    // A file from before (no `reviewTaught`) reads as before, and one with no lesson writes none.
    let older = try JSONDecoder().decode(CorrectionList.self,
                                         from: Data(#"{"entries":[{"heard":"um","meant":"uh"}]}"#.utf8))
    #expect(older.entries == [Correction(heard: "um", meant: "uh")] && older.reviewTaught == nil)
    let written = String(decoding: try JSONEncoder().encode(older), as: UTF8.self)
    #expect(!written.contains("reviewTaught"))
    // The same lesson again teaches nothing; another meeting's is its own.
    #expect(list.learnFromReview([Correction(heard: "cloud", meant: "Claude")], meeting: "M1").isEmpty)
    list.remove(Correction(heard: "cloud", meant: "Claude"))
    #expect(list.learnFromReview([Correction(heard: "cloud", meant: "Claude")], meeting: "M1").isEmpty)
    #expect(list.learnFromReview([Correction(heard: "cloud", meant: "Claude")], meeting: "M2")
        == [Correction(heard: "cloud", meant: "Claude")], "Another meeting teaches it as its own.")
    // Phrase and value are compared apart: text holding a separator never makes two lessons one.
    var separated = CorrectionList()
    #expect(separated.learnFromReview([Correction(heard: "a", meant: "b\u{1f}c")], meeting: "M1").count == 1)
    #expect(separated.learnFromReview([Correction(heard: "a\u{1f}b", meant: "c")], meeting: "M1").count == 1)
}

@Test func contextBesideAFixedWordCoversTheSameCharactersOnBothSides() {
    // "as cloud." with "cloud" fixed to "Claude" (the period is not timed), then "as" edited to "ask". The unfixed
    // revision holds the edit too, as an edit is made in both.
    let baseText = "ask cloud."
    let baseSegment = TranscriptSegment(id: "S1", start: 0, end: 2, text: baseText, words: [
        TimedWord(text: "ask", start: 0, end: 0.8, utf16Offset: 0, utf16Length: 3),
        TimedWord(text: "cloud", start: 1, end: 1.8, utf16Offset: 4, utf16Length: 5),
    ], track: "system", fixes: [TranscriptWordFix(first: 0, end: 1, heard: "as", kind: .reviewEdit, heardWords: 1)])
    let base = SessionFixtures.transcript([baseSegment])
    let fixedSegment = TranscriptSegment(id: "S1", start: 0, end: 2, text: "ask Claude.", words: [
        TimedWord(text: "ask", start: 0, end: 0.8, utf16Offset: 0, utf16Length: 3),
        TimedWord(text: "Claude", start: 1, end: 1.8, utf16Offset: 4, utf16Length: 6),
    ], track: "system", fixes: [TranscriptWordFix(first: 0, end: 1, heard: "as", kind: .reviewEdit, heardWords: 1),
                                TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .correction, heardWords: 1)])
    var fixed = SessionFixtures.transcript([fixedSegment])
    fixed.fixedFrom = base.id
    let turns = [[WordSpan(segmentID: "S1", first: 0, end: 2)]]
    // From the unfixed revision: "cloud." beside "Claude.", the same characters.
    #expect(ReviewLearning.edits(in: fixed, turns: turns, base: base)
        == [ReviewWordEdit(heard: "as", meant: "ask", after: "Claude.", heardAfter: "cloud.")])
    // Learned with the period on neither side (the rule leaves sentence punctuation out of both alike): never one
    // inserting it ("as cloud" → "ask Claude.").
    let learned = TranscriptEditLearning.corrections(heard: "as", meant: "ask", after: "Claude.",
                                                     heardAfter: "cloud.", isDictionaryWord: { _ in true })
    #expect(learned == [Correction(heard: "as cloud", meant: "ask Claude")])
    // Without it, the heard side cannot cover the period: no context on that side, never one mismatched.
    #expect(ReviewLearning.edits(in: fixed, turns: turns) == [ReviewWordEdit(heard: "as", meant: "ask")])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func pausingForACommandSavesWhatTheOpenFieldHolds() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
        WordEditTurn(speaker: "system:S2", start: 10, words: ["we", "will", "see"]),
    ])
    let review = try await wordEditOpen(session)
    // A command makes the review read-only while "Claude" is typed in the field: saved before the command starts.
    let hold = ReviewMaintenance.Hold(.recover)
    let unsaved = await review.pause(hold, reason: "Voice is Local is recovering this meeting.",
                                     typed: .init(words: wordEditRefs(review, "T1", [1]), text: "Claude",
                                             seenMoves: review.wordMoves.count))
    #expect(unsaved == nil)
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
    #expect(review.pauseReason != nil && !review.isEditable)
    await review.resume(hold)
    // One that is refused says what was typed.
    let other = ReviewMaintenance.Hold(.recover)
    let refused = await review.pause(other, reason: "again",
                                     typed: .init(words: [wordEditRefs(review, "T1", [2])[0],
                                                     wordEditRefs(review, "T2", [0])[0]],
                                             text: "today we", seenMoves: review.wordMoves.count))
    #expect(refused?.contains("What you typed: “today we”") == true)
    #expect(try wordEditCurrent(session).segments.map(\.text) == ["ask Claude now", "we will see"])
    await review.resume(other)
    await review.close()
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

@Test func whatAMeetingTaughtIsMergedSoTwoClosesKeepBothEntries() throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let url = temp.url.appendingPathComponent("corrections.json")
    let cloud = Correction(heard: "cloud", meant: "Claude")
    let plus = Correction(heard: "and", meant: "plus")
    // Two closes, each a read, change and save under the list's lock: neither loses the other's entry.
    _ = try CorrectionList.update(at: url) { $0.learnFromReview([cloud], meeting: "M1") }
    _ = try CorrectionList.update(at: url) { $0.learnFromReview([plus, cloud], meeting: "M1") }
    let list = try CorrectionList.load(from: url)
    #expect(list.taught(byMeeting: "M1") == [cloud, plus] && list.entries == [cloud, plus])
    // Taught already, in any case: nothing new. Another value for the phrase replaces the meeting's own (the list still
    // holds the value it taught).
    var next = list
    #expect(next.learnFromReview([Correction(heard: "Cloud", meant: "Claude")], meeting: "M1").isEmpty)
    #expect(next.learnFromReview([Correction(heard: "cloud", meant: "Cloud9")], meeting: "M1")
        == [Correction(heard: "cloud", meant: "Cloud9")])
    #expect(next.taught(byMeeting: "M1") == [plus, Correction(heard: "cloud", meant: "Cloud9")])
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
    learner.list.remove(Correction(heard: "cloud", meant: "Claude"))
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
