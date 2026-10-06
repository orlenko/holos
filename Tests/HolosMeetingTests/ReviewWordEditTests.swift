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
private func wordEditSession(in temp: TemporaryDirectory, _ specs: [WordEditTurn]) async throws -> URL {
    let segments = specs.map { SessionFixtures.segment($0.words, track: "system", start: $0.start, wordSeconds: 1) }
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

/// A corrections list in memory that the review keeps in step as the app does (`ReviewSession.syncCorrections`), and
/// what each edit teaches: "heard" → "meant", as recorded.
@MainActor
private final class WordEditLearner {
    var list: CorrectionList
    /// While set, writes fail (corrections.json cannot be saved).
    var failing = false
    private(set) var taughtBy: [ReviewWordEdit] = []

    init(_ list: CorrectionList = CorrectionList()) { self.list = list }

    func attach(to review: ReviewSession) {
        review.correctionsToLearn = { [self] edit in
            taughtBy.append(edit)
            return edit.heard == edit.meant ? [] : [Correction(heard: edit.heard, meant: edit.meant)]
        }
        review.syncCorrections = { [self] values, capture in
            guard !failing else { return nil }
            var before: [String: Correction?] = [:]
            for key in capture { before[key] = .some(list.entry(forKey: key)) }
            for (key, value) in values { list.set(value, forKey: key) }
            return before
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
    #expect(learner.taughtBy == [ReviewWordEdit(heard: "cloud", meant: "Claude", before: "ask", after: "now")])
    #expect(learner.value("cloud") == "Claude")
    let edited = try wordEditCurrent(session)
    #expect(edited.id != original.id)
    #expect(edited.segments.map(\.text) == ["ask Claude now", "we will see"])
    #expect(review.words(of: "T1").map(\.text) == ["ask", "Claude", "now"])
    #expect(review.words(of: "T1")[1].fix == TranscriptWordFix(first: 1, end: 2, heard: "cloud", kind: .reviewEdit))
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
    #expect(learner.value("cloud") == nil, "What the edit taught goes with it.")
    #expect(review.canUndo)
    try await review.undo()
    #expect(review.speaker("system:S1")?.name == "Speaker 1")
    #expect(!review.canUndo)
    await review.close()
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
func anEditWhoseLabelsCannotBeRereadCanStillBeUndoneAndItsUndoUnlearns() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["ask", "cloud", "now"]),
    ])
    let original = try wordEditCurrent(session)
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner()
    learner.attach(to: review)
    struct Unreadable: Error {}

    // Committed, then the labels cannot be reread: the edit is kept, and undoable once they are.
    review.beforeWordChangeReread = { throw Unreadable() }
    await #expect(throws: HolosError.self) { try await review.editWords(wordEditRefs(review, "T1", [1]), to: "Claude") }
    #expect(try wordEditCurrent(session).segments[0].text == "ask Claude now")
    #expect(review.reloadProblem != nil && review.canUndo)
    #expect(learner.value("cloud") == "Claude")
    review.beforeWordChangeReread = nil
    await review.reload()
    #expect(review.reloadProblem == nil && review.canUndo, "The reread knows the edit's run keeps the turns.")
    #expect(review.words(of: "T1").map(\.text) == ["ask", "Claude", "now"])

    // The undo is committed, then its reread fails: what the edit taught is taken back all the same.
    review.beforeWordChangeReread = { throw Unreadable() }
    await #expect(throws: HolosError.self) { try await review.undo() }
    #expect(learner.value("cloud") == nil)
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

// MARK: - Learning, worked out again from the window's edits

/// Three "cloud"s in one turn, between "x", "y", "z"; the list held "cloud → Cloudy" before the window.
@MainActor
private func wordEditOccurrences(_ temp: TemporaryDirectory) async throws
    -> (session: URL, review: ReviewSession, learner: WordEditLearner) {
    let session = try await wordEditSession(in: temp, [
        WordEditTurn(speaker: "system:S1", start: 0, words: ["cloud", "x", "cloud", "y", "cloud", "z"]),
    ])
    let review = try await wordEditOpen(session)
    let learner = WordEditLearner(CorrectionList(entries: [Correction(heard: "cloud", meant: "Cloudy")]))
    learner.attach(to: review)
    return (session, review, learner)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aChainOfEditsAndItsRevertLeaveTheListAsTheEditsInEffectSay() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let (session, review, learner) = try await wordEditOccurrences(temp)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claudia")
    #expect(learner.value("cloud") == "Claudia")
    try await review.revertWordFix(wordEditRefs(review, "T1", [0])[0])
    #expect(try wordEditCurrent(session).segments[0].text == "cloud x cloud y cloud z")
    #expect(learner.value("cloud") == "Cloudy", "Nothing the window taught is in effect: the list is as before.")
    try await review.undo()
    #expect(learner.value("cloud") == "Claudia")
    try await review.undo()
    #expect(learner.value("cloud") == "Claude")
    try await review.undo()
    #expect(learner.value("cloud") == "Cloudy")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func anotherOccurrencesNewerCorrectionWinsWhateverIsRevertedOrUndone() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let (_, review, learner) = try await wordEditOccurrences(temp)
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    try await review.editWords(wordEditRefs(review, "T1", [2]), to: "Klaud")
    #expect(learner.value("cloud") == "Klaud")
    // The first one reverted, then its Revert undone: the second, newer one is still what the list says.
    try await review.revertWordFix(wordEditRefs(review, "T1", [0])[0])
    #expect(learner.value("cloud") == "Klaud")
    try await review.undo()
    #expect(learner.value("cloud") == "Klaud")
    // An edit earlier in the turn moves the second occurrence; its Revert still finds what it taught.
    try await review.editWords(wordEditRefs(review, "T1", [1]), to: "x and")
    try await review.revertWordFix(wordEditRefs(review, "T1", [3])[0])
    #expect(learner.value("cloud") == "Claude")
    await review.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func aFailedCorrectionsWriteIsTriedAgainAndSaid() async throws {
    let temp = try TemporaryDirectory("review")
    defer { temp.remove() }
    let (_, review, learner) = try await wordEditOccurrences(temp)
    learner.failing = true
    try await review.editWords(wordEditRefs(review, "T1", [0]), to: "Claude")
    #expect(review.learningProblem != nil && learner.value("cloud") == "Cloudy")
    learner.failing = false
    try await review.editWords(wordEditRefs(review, "T1", [2]), to: "Klaud")
    #expect(review.learningProblem == nil && learner.value("cloud") == "Klaud")
    // An undo whose write fails: tried again when the window closes.
    learner.failing = true
    try await review.undo()
    #expect(review.learningProblem != nil && learner.value("cloud") == "Klaud")
    learner.failing = false
    await review.close()
    #expect(learner.value("cloud") == "Claude")
}

/// A small deterministic generator for the scenarios.
private struct WordEditRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor
func randomEditsRevertsAndUndosKeepTheListAsTheEditsInEffectSay() async throws {
    // A model of the rule: the most recent active edit of the window teaching "cloud", else the list's own value.
    struct Taught { var occurrence: Int; var value: String; var active = true; var undone = false }
    enum Step { case edit(Int, Int, String, Int), revert(Int, [Int], String, Int) }
    let spellings = ["Claude", "Klaud", "Claude Code"]
    for seed in [7, 21, 1984] as [UInt64] {
        let temp = try TemporaryDirectory("review")
        defer { temp.remove() }
        let (session, review, learner) = try await wordEditOccurrences(temp)
        var random = WordEditRandom(state: seed)
        var values = ["cloud", "cloud", "cloud"]
        var taught: [Taught] = []
        var steps: [Step] = []
        func start(_ occurrence: Int) -> Int {
            (0..<occurrence).reduce(0) { $0 + values[$1].split(separator: " ").count + 1 }
        }
        for _ in 0..<12 {
            let occurrence = random.next(3)
            let refs = wordEditRefs(review, "T1", Array(start(occurrence)..<(start(occurrence)
                + values[occurrence].split(separator: " ").count)))
            if !steps.isEmpty, random.next(4) == 0 {
                try await review.undo()
                switch steps.removeLast() {
                case .edit(let index, let edited, let before, _):
                    taught[index].undone = true
                    values[edited] = before
                case .revert(let edited, let deactivated, let before, _):
                    for index in deactivated { taught[index].active = true }
                    values[edited] = before
                }
            } else if values[occurrence] != "cloud", random.next(3) == 0 {
                try await review.revertWordFix(refs[0])
                let deactivated = taught.indices.filter {
                    taught[$0].occurrence == occurrence && taught[$0].active && !taught[$0].undone
                }
                for index in deactivated { taught[index].active = false }
                steps.append(.revert(occurrence, deactivated, values[occurrence], 0))
                values[occurrence] = "cloud"
            } else {
                let value = spellings.filter { $0 != values[occurrence] }[random.next(2)]
                try await review.editWords(refs, to: value)
                taught.append(Taught(occurrence: occurrence, value: value))
                steps.append(.edit(taught.count - 1, occurrence, values[occurrence], 0))
                values[occurrence] = value
            }
            let expected = taught.last { $0.active && !$0.undone }?.value ?? "Cloudy"
            #expect(learner.value("cloud") == expected, "seed \(seed), after \(steps.count) steps in effect")
            #expect(try wordEditCurrent(session).segments[0].text
                == "\(values[0]) x \(values[1]) y \(values[2]) z")
        }
        await review.close()
    }
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
    #expect(segment.fixes == [TranscriptWordFix(first: 3, end: 4, heard: "three", kind: .reviewEdit)])
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
