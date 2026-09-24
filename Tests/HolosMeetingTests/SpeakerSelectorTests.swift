import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import Testing

// SpeakerSelector (docs/meeting-design.md §5.7): speakers, turns, and times as typed in `holos speakers` commands.
// Pure projections built in memory; no files.

private let selectorDate = Date(timeIntervalSince1970: 1_000_000)

private struct SelectorTurn {
    var id: String
    var track: String
    var start: Double
    var end: Double
    var speaker: String?
}

/// A projection of hand-made turns, each one segment "seg-<id>" of two timed words splitting the turn in half.
/// `names` become rename edits.
private func selectorProjection(_ turns: [SelectorTurn], speakers: [SessionSpeaker],
                                names: [String: String] = [:]) -> SpeakerProjection {
    let segments = turns.map { turn -> TranscriptSegment in
        let middle = (turn.start + turn.end) / 2
        return TranscriptSegment(
            id: "seg-\(turn.id)", start: turn.start, end: turn.end, text: "one two",
            words: [TimedWord(text: "one", start: turn.start, end: middle, utf16Offset: 0, utf16Length: 3),
                    TimedWord(text: "two", start: middle, end: turn.end, utf16Offset: 4, utf16Length: 3)],
            track: turn.track)
    }
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: selectorDate, source: "fixture", locale: "en-CA",
                                backend: .speech, segments: segments)
    let run = DiarizationRun(
        id: "RUN", sessionID: "SESSION", createdAt: selectorDate, transcriptID: "TRANSCRIPT", engine: nil,
        alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: [], speakers: speakers,
        turns: turns.map { turn in
            SpeakerTurn(id: turn.id, track: turn.track, start: turn.start, end: turn.end, speakerID: turn.speaker,
                        clusterID: turn.speaker, spans: [WordSpan(segmentID: "seg-\(turn.id)", first: 0, end: 2)],
                        assignmentScore: 0.9, timing: .measured)
        })
    let edits = names.sorted { $0.key < $1.key }.enumerated().map { index, entry in
        SpeakerEdit(id: "EDIT-\(index)", baseRunID: "RUN", at: selectorDate, source: "cli",
                    action: .rename(speakerID: entry.key, name: entry.value))
    }
    return SpeakerProjection.make(run: run, transcript: transcript, edits: edits, recognition: nil, profileNames: [:])
}

private func selectorSpeaker(_ id: String, _ ordinal: Int) -> SessionSpeaker {
    id.hasSuffix(":me")
        ? SessionSpeaker(id: id, ordinal: ordinal, displayName: "Me", provenance: .channelAssumption)
        : SessionSpeaker(id: id, ordinal: ordinal, provenance: .diarizer, clusterIDs: [id])
}

/// Me (1) on the microphone; system:S1 (2) and system:S2 "Maria" (3) on system audio.
private let selectorMeeting = selectorProjection(
    [SelectorTurn(id: "T1", track: "mic", start: 0, end: 5, speaker: "mic:me"),
     SelectorTurn(id: "T2", track: "system", start: 5, end: 10, speaker: "system:S1"),
     SelectorTurn(id: "T3", track: "system", start: 10, end: 15, speaker: "system:S2")],
    speakers: [selectorSpeaker("mic:me", 1), selectorSpeaker("system:S1", 2), selectorSpeaker("system:S2", 3)],
    names: ["system:S2": "Maria"])

/// The message of the `invalidInput` error `body` throws.
private func selectorError(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) -> String {
    let error = #expect(throws: HolosError.self, sourceLocation: sourceLocation) { try body() }
    guard case .invalidInput(let message)? = error else {
        Issue.record("Expected invalidInput, got \(String(describing: error))", sourceLocation: sourceLocation)
        return ""
    }
    return message
}

@Test func selectorResolvesIDsLabelsOrdinalsNames() throws {
    for text in ["system:S2", "S2", "3", "Speaker 3", "maria", "  Maria ", "SYSTEM:s2", "s2", "speaker3"] {
        #expect(try SpeakerSelector.speaker(text, in: selectorMeeting) == .speaker("system:S2"), "\(text)")
    }
    #expect(try SpeakerSelector.speaker("me", in: selectorMeeting) == .speaker("mic:me"))
    #expect(try SpeakerSelector.speaker("1", in: selectorMeeting) == .speaker("mic:me"))
    #expect(try SpeakerSelector.speaker("Speaker 2", in: selectorMeeting) == .speaker("system:S1"))
    #expect(try SpeakerSelector.speaker("unknown", in: selectorMeeting) == .unknown)
    #expect(try SpeakerSelector.speaker("Unknown", in: selectorMeeting) == .unknown)

    let message = selectorError { _ = try SpeakerSelector.speaker("Jim", in: selectorMeeting) }
    #expect(message.contains("Jim"))
    for candidate in ["mic:me", "system:S1", "system:S2", "unknown"] {
        #expect(message.contains(candidate), "The error lists \(candidate).")
    }
    _ = selectorError { _ = try SpeakerSelector.speaker("9", in: selectorMeeting) }
    _ = selectorError { _ = try SpeakerSelector.speaker(" ", in: selectorMeeting) }
}

@Test func ambiguousSelectorListsCandidates() throws {
    let projection = selectorProjection(
        [SelectorTurn(id: "T1", track: "mic", start: 0, end: 5, speaker: "mic:S1"),
         SelectorTurn(id: "T2", track: "system", start: 0, end: 5, speaker: "system:S1")],
        speakers: [selectorSpeaker("mic:S1", 1), selectorSpeaker("system:S1", 2)],
        names: ["mic:S1": "Sam", "system:S1": "sam"])

    let label = selectorError { _ = try SpeakerSelector.speaker("S1", in: projection) }
    #expect(label.contains("mic:S1") && label.contains("system:S1"))
    let name = selectorError { _ = try SpeakerSelector.speaker("Sam", in: projection) }
    #expect(name.contains("mic:S1") && name.contains("system:S1"))
    // The full IDs and the ordinals still pick one each.
    #expect(try SpeakerSelector.speaker("mic:S1", in: projection) == .speaker("mic:S1"))
    #expect(try SpeakerSelector.speaker("2", in: projection) == .speaker("system:S1"))
}

@Test func timeSelectorFindsTurn() throws {
    // T1…T14 on system audio: Tk from k minutes 3 s to k minutes 40 s, so T12 is 00:12:03–00:12:40.
    var turns: [SelectorTurn] = []
    for k in 1...14 {
        let minute = Double(60 * k)
        let speaker = k.isMultiple(of: 2) ? "system:S2" : "system:S1"
        turns.append(SelectorTurn(id: "T\(k)", track: "system", start: minute + 3, end: minute + 40,
                                  speaker: speaker))
    }
    let projection = selectorProjection(turns, speakers: [selectorSpeaker("system:S1", 1),
                                                          selectorSpeaker("system:S2", 2)])

    #expect(try SpeakerSelector.turn("00:12:05", track: "system", in: projection) == "T12")
    #expect(try SpeakerSelector.turn("00:12:05", track: nil, in: projection) == "T12")
    #expect(try SpeakerSelector.turn("12:03", track: nil, in: projection) == "T12")
    #expect(try SpeakerSelector.turn("759.5", track: nil, in: projection) == "T12")
    #expect(try SpeakerSelector.turn("T12", track: nil, in: projection) == "T12")
    #expect(try SpeakerSelector.turn("t12", track: "system", in: projection) == "T12")

    let gap = selectorError { _ = try SpeakerSelector.turn("00:12:50", track: nil, in: projection) }
    #expect(gap.contains("T12"), "A time between turns names the nearest one.")
    _ = selectorError { _ = try SpeakerSelector.turn("00:12:05", track: "mic", in: projection) }
    _ = selectorError { _ = try SpeakerSelector.turn("T12", track: "mic", in: projection) }
    _ = selectorError { _ = try SpeakerSelector.turn("T99", track: nil, in: projection) }
    _ = selectorError { _ = try SpeakerSelector.turn("00:12:05", track: "speakers", in: projection) }
    _ = selectorError { _ = try SpeakerSelector.turn("soon", track: nil, in: projection) }
}

@Test func timeSelectorNeedsTrackWhenBothTracksHaveATurn() throws {
    let projection = selectorProjection(
        [SelectorTurn(id: "T1", track: "mic", start: 0, end: 10, speaker: "mic:me"),
         SelectorTurn(id: "T2", track: "system", start: 2, end: 12, speaker: "system:S1"),
         SelectorTurn(id: "T3", track: "system", start: 12, end: 20, speaker: "system:S1")],
        speakers: [selectorSpeaker("mic:me", 1), selectorSpeaker("system:S1", 2)])

    let both = selectorError { _ = try SpeakerSelector.turn("00:00:05", track: nil, in: projection) }
    #expect(both.contains("T1") && both.contains("T2") && both.contains("--track"))
    #expect(try SpeakerSelector.turn("00:00:05", track: "mic", in: projection) == "T1")
    #expect(try SpeakerSelector.turn("00:00:05", track: "system", in: projection) == "T2")
    #expect(try SpeakerSelector.turn("1", track: nil, in: projection) == "T1", "Only the microphone speaks at 1 s.")
    #expect(try SpeakerSelector.turn("12", track: "system", in: projection) == "T3",
            "A boundary belongs to the turn that starts there.")
    #expect(try SpeakerSelector.turn("20", track: nil, in: projection) == "T3",
            "The end of the last turn still finds it.")
}

@Test func splitPartsAreSelectedByTheirFullID() throws {
    var projection = selectorMeeting
    projection = projection.applying(.splitTurn(turnID: "T2", at: WordRef(segmentID: "seg-T2", word: 1)),
                                     editID: "SPLIT")
    #expect(projection.turns.contains { $0.id == "T2/SPLIT" })
    #expect(try SpeakerSelector.turn("T2/SPLIT", track: nil, in: projection) == "T2/SPLIT")
    #expect(try SpeakerSelector.turn("T2", track: nil, in: projection) == "T2")
    #expect(try SpeakerSelector.turn("8", track: "system", in: projection) == "T2/SPLIT")
}

@Test func timesParseInEveryLayout() throws {
    let cases: [(String, Double)] = [
        ("01:12:03", 4_323), ("1:12:03", 4_323), ("12:03.5", 723.5), ("723.5", 723.5), ("723", 723),
        ("0:00", 0), (".5", 0.5), ("100:00:00", 360_000), ("90:00", 5_400), ("00:12:05", 725),
    ]
    for (text, seconds) in cases {
        #expect(try SpeakerSelector.time(text) == seconds, "\(text)")
    }
    for text in ["", ":", "1:60", "1:60:00", "-5", "1e3", "inf", "nan", "1:2:3:4", "12:03.5.1", "1.5:00", "abc",
                 "12 03", "0x10", "٣"] {
        _ = selectorError { _ = try SpeakerSelector.time(text) }
    }
}
