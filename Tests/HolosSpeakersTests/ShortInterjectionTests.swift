import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// Short interjections of the unknown speaker (docs/meeting-design.md §5.10): hidden or attached to a neighbour in
// `SpeakerProjection.shownTurns` and the exports, never in `turns`. Synthetic text only.

private let runID = "RUN-INTERJECTIONS"
private let fixedDate = Date(timeIntervalSince1970: 1_790_172_000)

/// One turn with its own segment "seg-<id>": the text split at spaces, word i at [start + i·0.4, start + i·0.4 + 0.4),
/// so a turn lasts 0.4 s per word.
private struct Line {
    var id: String
    var start: Double
    var speaker: String?
    var text: String
    var track = "system"
    var editedFirstWord = false
    /// Every character a timed word, as for a language written without spaces.
    var wordPerCharacter = false
}

private func line(_ id: String, _ start: Double, _ speaker: String?, _ text: String, track: String = "system",
                  edited: Bool = false) -> Line {
    Line(id: id, start: start, speaker: speaker, text: text, track: track, editedFirstWord: edited)
}

private let wordSeconds = 0.4

private func segment(_ line: Line) -> TranscriptSegment {
    var words: [TimedWord] = []
    let tokens: [Substring] = line.wordPerCharacter
        ? line.text.indices.map { line.text[$0...$0] } : line.text.split(separator: " ")
    for (index, token) in tokens.enumerated() {
        let start = line.start + Double(index) * wordSeconds
        words.append(TimedWord(text: String(token), start: start, end: start + wordSeconds,
                               utf16Offset: line.text.utf16.distance(from: line.text.startIndex, to: token.startIndex),
                               utf16Length: token.utf16.count))
    }
    let fixes = line.editedFirstWord
        ? [TranscriptWordFix(first: 0, end: 1, heard: "yes", kind: .reviewEdit)] : nil
    return TranscriptSegment(id: "seg-\(line.id)", start: line.start, end: words.last?.end ?? line.start,
                             text: line.text, words: words, track: line.track, fixes: fixes)
}

private func projection(_ lines: [Line], locale: String = "en-CA", languages: [String]? = nil,
                        actions: [SpeakerEditAction] = []) -> SpeakerProjection {
    let segments = lines.map(segment)
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: fixedDate, source: "mic+system", locale: locale,
                                backend: .speech, segments: segments, languages: languages)
    let turns = zip(lines, segments).map { line, segment in
        SpeakerTurn(id: line.id, track: line.track, start: segment.start, end: segment.end, speakerID: line.speaker,
                    clusterID: line.speaker, spans: [WordSpan(segmentID: segment.id, first: 0, end: segment.words.count)],
                    overlap: false, otherClusters: [], assignmentScore: line.speaker == nil ? 0 : 0.9,
                    timing: .measured)
    }
    let run = DiarizationRun(
        id: runID, sessionID: "SESSION", createdAt: fixedDate, transcriptID: "TRANSCRIPT", engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1, trackOffsets: ["system": 0]),
        tracks: [TrackDiarization(track: "system", policy: .diarized),
                 TrackDiarization(track: "mic", policy: .diarized)],
        speakers: [SessionSpeaker(id: "S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["S1"]),
                   SessionSpeaker(id: "S2", ordinal: 2, provenance: .diarizer, clusterIDs: ["S2"])],
        turns: turns)
    let named: [SpeakerEditAction] = [.rename(speakerID: "S1", name: "Avery"), .rename(speakerID: "S2", name: "Blake")]
    let edits = (named + actions).enumerated().map { index, action in
        SpeakerEdit(id: "E\(index)", baseRunID: runID, at: fixedDate, source: "cli", action: action)
    }
    return SpeakerProjection.make(run: run, transcript: transcript, edits: edits, recognition: nil, profileNames: [:])
}

/// The rows of the screenshot that asked for this, in synthetic words: a lone "an" between two turns of one speaker,
/// a few words that finish the previous speaker's sentence, standalone backchannels, and a longer unknown turn.
private let meeting: [Line] = [
    line("T1", 0, "S1", "Sure, that part is fine."),          // ends 2.0
    line("T2", 2.3, nil, "an"),                                // 2.3–2.7, a stretched "umm"
    line("T3", 3.0, "S1", "I think it makes sense."),         // ends 5.0
    line("T4", 5.5, "S2", "We asked them twice, but they"),    // ends 7.9, no full stop
    line("T5", 8.2, nil, "agreed to it. Yeah."),               // 8.2–9.8: finishes Blake's sentence
    line("T6", 10.5, "S1", "So a few things to do."),          // ends 12.9
    line("T7", 13.2, nil, "Yeah."),
    line("T8", 13.8, nil, "Yeah."),
    line("T9", 14.5, "S2", "There was a meeting about it."),   // ends 16.9
    line("T10", 17.5, nil, "we should check the numbers again"), // six words: kept
]

@Test func theScreenshotsUnknownFragmentsAreHiddenOrAttached() throws {
    let view = projection(meeting)
    #expect(view.interjections == [
        "T2": .hidden, "T5": .attached(speakerID: "S2"), "T7": .hidden, "T8": .hidden,
    ])
    // Shown: no lone "an", no standalone "Yeah.", Blake's sentence whole, the longer unknown turn kept.
    #expect(view.shownTurns.map(\.id) == ["T1", "T3", "T4", "T5", "T6", "T9", "T10"])
    let attached = try #require(view.shownTurns.first { $0.id == "T5" })
    #expect(attached.speakerID == "S2")
    #expect(attached.interjection == .attached(speakerID: "S2"))
    #expect(!attached.uncertain)
    let kept = try #require(view.shownTurns.first { $0.id == "T10" })
    #expect(kept.speakerID == nil && kept.uncertain && kept.interjection == nil)
    // With hidden ones: every turn, the hidden ones as they are (unknown, uncertain).
    let all = view.shownTurns(includingHidden: true)
    #expect(all.map(\.id) == view.turns.map(\.id))
    #expect(all.filter { $0.interjection == .hidden }.map(\.id) == ["T2", "T7", "T8"])
    #expect(all.filter { $0.interjection == .hidden }.allSatisfy { $0.speakerID == nil && $0.uncertain })
    // Presentation only: the projection's turns and speakers are as without the rule.
    #expect(view.turns.count == meeting.count)
    #expect(view.turns.first { $0.id == "T5" }?.speakerID == nil)
    #expect(view.turns.allSatisfy { $0.interjection == nil })
    #expect(view.speakers.first { $0.id == "S2" }?.turnCount == 2)
}

@Test func theExportsLeaveHiddenInterjectionsOutAndJoinAttachedOnes() throws {
    let view = projection(meeting)
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: fixedDate, source: "mic+system", locale: "en-CA",
                                backend: .speech, segments: meeting.map(segment))
    let metadata = ExportMetadata(sessionID: "SESSION", name: "Sync", createdAt: fixedDate, durationSeconds: 30,
                                  source: .microphoneAndSystem, locale: "en-CA", backend: .speech, timeZone: .gmt)
    let document = ExportDocument(metadata: metadata, transcript: transcript, projection: view)
    let blocks = TranscriptExporter.blocks(document)
    #expect(blocks.map(\.speakerLabel) == ["Avery", "Blake", "Avery", "Blake", "Unknown speaker"])
    #expect(blocks[0].text == "Sure, that part is fine. I think it makes sense.")
    #expect(blocks[1].text == "We asked them twice, but they agreed to it. Yeah.")
    #expect(blocks[1].turnIDs == ["T4", "T5"])
    #expect(blocks[2].text == "So a few things to do.")
    let text = String(decoding: try TranscriptExporter.render(document, format: .txt), as: UTF8.self)
    let lines = text.components(separatedBy: "\n")
    #expect(!lines.contains("an") && !lines.contains("Yeah."))
    #expect(lines.filter { $0.hasPrefix("Unknown speaker") }.count == 1)
    let json = try #require(try JSONSerialization.jsonObject(
        with: TranscriptExporter.render(document, format: .json)) as? [String: Any])
    let turns = try #require(json["turns"] as? [[String: Any]])
    #expect(turns.map { $0["id"] as? String } == ["T1", "T3", "T4", "T5", "T6", "T9", "T10"])
    #expect(turns.first { $0["id"] as? String == "T5" }?["interjection"] as? String == "attached")
    #expect(turns.first { $0["id"] as? String == "T5" }?["speakerID"] as? String == "S2")
    #expect(turns.filter { $0["interjection"] != nil }.count == 1)
}

@Test func turnsTheUserWorkedOnAreNeverTouched() {
    // Edited in Review (a word fix of kind reviewEdit): kept as it is.
    let edited = projection([
        line("T1", 0, "S1", "That is all."),
        line("T2", 1.5, nil, "Yeah.", edited: true),
        line("T3", 3, "S2", "Okay then, next."),
    ])
    #expect(edited.interjections.isEmpty)
    #expect(edited.shownTurns.map(\.id) == ["T1", "T2", "T3"])
    // Assigned to the unknown speaker by the user: kept.
    let assigned = projection([
        line("T1", 0, "S1", "That is all."),
        line("T2", 1.5, "S2", "Yeah."),
        line("T3", 3, "S2", "Okay then, next."),
    ], actions: [.reassignTurns(turnIDs: ["T2"], to: nil)])
    #expect(assigned.turns.first { $0.id == "T2" }?.speakerID == nil)
    #expect(assigned.interjections.isEmpty)
    // Split by the user: both parts kept, the unknown one included.
    let split = projection([
        line("T1", 0, "S1", "That is all."),
        line("T2", 1.5, nil, "Yeah. Okay."),
        line("T3", 3, "S2", "Okay then, next."),
    ], actions: [.splitTurn(turnID: "T2", at: WordRef(segmentID: "seg-T2", word: 1))])
    #expect(split.turns.filter { $0.speakerID == nil }.count == 2)
    #expect(split.interjections.isEmpty)
    // Named speakers' turns are never hidden, however short.
    let named = projection([line("T1", 0, "S1", "Yeah."), line("T2", 1, "S2", "Um.")])
    #expect(named.interjections.isEmpty)
}

@Test func choosingUnknownForAnAttachedTurnKeepsItUnknownUntilUndone() throws {
    let lines = [
        line("T1", 0, "S2", "We asked them, but they"),
        line("T2", 2.2, nil, "agreed to it."),
    ]
    #expect(projection(lines).interjections == ["T2": .attached(speakerID: "S2")])
    // The stored speaker does not change (it was unknown), but the choice stands: shown as unknown.
    let chosen = projection(lines, actions: [.reassignTurns(turnIDs: ["T2"], to: nil)])
    #expect(chosen.interjections.isEmpty)
    #expect(try #require(chosen.shownTurns.last).speakerID == nil)
    #expect(chosen.turns == projection(lines).turns)
    // Undone: attached again.
    let undone = projection(lines, actions: [.reassignTurns(turnIDs: ["T2"], to: nil), .revert(editID: "E2")])
    #expect(undone.interjections == ["T2": .attached(speakerID: "S2")])
    // The same holds for a hidden filler given Unknown while hidden ones are shown: it stays listed.
    let filler = [line("T1", 0, "S1", "That is all."), line("T2", 1.5, nil, "Yeah.")]
    #expect(projection(filler).interjections == ["T2": .hidden])
    #expect(projection(filler, actions: [.reassignTurns(turnIDs: ["T2"], to: nil)]).interjections.isEmpty)
}

@Test func aFewWordsInsideOneSpeakersSpeechJoinIt() {
    // Between two turns of Avery, the first ending its sentence: joins Avery when both gaps are short.
    let inside = projection([
        line("T1", 0, "S1", "We tried it."),         // ends 1.2
        line("T2", 1.5, nil, "the new one"),          // 1.5–2.7
        line("T3", 3.5, "S1", "It worked well."),
    ])
    #expect(inside.interjections == ["T2": .attached(speakerID: "S1")])
    // A gap longer than 1.5 s on one side: shown as it is.
    let apart = projection([
        line("T1", 0, "S1", "We tried it."),
        line("T2", 1.5, nil, "the new one"),
        line("T3", 4.5, "S1", "It worked well."),
    ])
    #expect(apart.interjections.isEmpty)
    // Different speakers on each side, the first ending its sentence: shown as it is.
    let between = projection([
        line("T1", 0, "S1", "We tried it."),
        line("T2", 1.5, nil, "the new one"),
        line("T3", 3.0, "S2", "It worked well."),
    ])
    #expect(between.interjections.isEmpty)
}

@Test func aContinuationNeedsAnOpenSentenceAndAShortGap() {
    // The previous turn ends without a full stop, but 2 s of silence passed: shown as it is.
    let late = projection([
        line("T1", 0, "S2", "We asked them, but they"),   // ends 2.0
        line("T2", 4.0, nil, "agreed to it."),
    ])
    #expect(late.interjections.isEmpty)
    // The previous turn ended its sentence: not a continuation.
    let closed = projection([
        line("T1", 0, "S2", "We asked them twice?"),
        line("T2", 1.8, nil, "agreed to it."),
    ])
    #expect(closed.interjections.isEmpty)
    // The previous turn is the unknown speaker's: nothing to join.
    let unknown = projection([
        line("T1", 0, nil, "we asked them all about it, but they"),
        line("T2", 3.4, nil, "agreed to it."),
    ])
    #expect(unknown.interjections.isEmpty)
    // Only the turns of its own track are its neighbours.
    let otherTrack = projection([
        line("T1", 0, "S2", "We asked them, but they"),
        line("T2", 2.2, nil, "agreed to it.", track: "mic"),
    ])
    #expect(otherTrack.interjections.isEmpty)
    // Five words: too long to be touched, filler or not.
    let long = projection([
        line("T1", 0, "S2", "We asked them, but they"),
        line("T2", 2.2, nil, "agreed to it right away."),
    ])
    #expect(long.interjections.isEmpty)
    // Without spaces the recognizer's words count: ten timed words are not short, three are.
    var unspaced = line("T2", 2.2, nil, "他们后来都同意了这个")
    unspaced.wordPerCharacter = true
    let opening = line("T1", 0, "S2", "We asked them, but they")
    #expect(projection([opening, unspaced]).interjections.isEmpty)
    unspaced.text = "同意了"
    #expect(projection([opening, unspaced]).interjections == ["T2": .attached(speakerID: "S2")])
}

@Test func fillersFollowTheMeetingsLanguages() {
    let lines = [
        line("T1", 0, "S1", "Voilà."),
        line("T2", 2, nil, "Ouais."),
        line("T3", 4, "S2", "Bon."),
        line("T4", 6, nil, "euh"),
        line("T5", 8, "S1", "Alors."),
        line("T6", 10, nil, "Yeah."),
        line("T7", 12, "S2", "Fin."),
        line("T8", 14, nil, "a"),
        line("T9", 16, "S1", "Bon."),
        line("T10", 18, nil, "Mm-hmm."),
    ]
    // French: its fillers and the sounds of every language; English words and a lone "a" stay.
    let french = projection(lines, locale: "fr-CA")
    #expect(french.interjections == ["T2": .hidden, "T4": .hidden, "T10": .hidden])
    // English: "Yeah." and a lone "a" go; French words stay.
    let english = projection(lines, locale: "en-CA")
    #expect(english.interjections == ["T6": .hidden, "T8": .hidden, "T10": .hidden])
    // A meeting in both: every list applies.
    let both = projection(lines, locale: "fr-CA", languages: ["fr-CA", "en-CA"])
    #expect(Set(both.interjections.keys) == ["T2", "T4", "T6", "T8", "T10"])
}

@Test func fillerWordsAreComparedAsSpokenNotAsWritten() {
    let fillers = ShortInterjections.Fillers(languages: ["en-US"])
    #expect(fillers.isFillerOnly(ShortInterjections.tokens("Ummm.")))
    #expect(fillers.isFillerOnly(ShortInterjections.tokens("Hmmm, okay.")))
    #expect(fillers.isFillerOnly(ShortInterjections.tokens("Uh-huh. Yeah, yeah.")))
    #expect(fillers.isFillerOnly(ShortInterjections.tokens("An")))
    // An article is a filler only alone, and a name that looks like one is not one.
    #expect(!fillers.isFillerOnly(ShortInterjections.tokens("an idea")))
    #expect(!fillers.isFillerOnly(ShortInterjections.tokens("Ann.")))
    #expect(!fillers.isFillerOnly(ShortInterjections.tokens("Yeah, sure.")))
    #expect(!fillers.isFillerOnly(ShortInterjections.tokens("— …")))
    #expect(ShortInterjections.tokens("D’accord !") == ["d'accord"])
    #expect(ShortInterjections.Fillers(languages: ["fr"]).isFillerOnly(ShortInterjections.tokens("D’accord !")))
    #expect(ShortInterjections.endsSentence("It works."))
    #expect(ShortInterjections.endsSentence("Does it?\u{201D}"))
    #expect(ShortInterjections.endsSentence("Well…"))
    #expect(!ShortInterjections.endsSentence("but they"))
    #expect(!ShortInterjections.endsSentence("they said,"))
    #expect(!ShortInterjections.endsSentence(""))
}

@Test func withoutShortUnknownTurnsTheShownTurnsAreTheTurns() {
    let view = projection([line("T1", 0, "S1", "Hello there."), line("T2", 2, "S2", "Hi.")])
    #expect(view.interjections.isEmpty)
    #expect(view.shownTurns == view.turns)
    #expect(view.shownTurns(includingHidden: true) == view.turns)
}
