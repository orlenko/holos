import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// Microphone echo of system audio in calls (docs/meeting-design.md §5.11, PR11).

/// A segment on `track` with measured words, word i at `start + i × wordSeconds`, each lasting `wordSeconds`.
private func echoSegment(_ id: String, _ words: [String], track: String, start: Double,
                         wordSeconds: Double = 0.3) -> TranscriptSegment {
    var text = ""
    var timed: [TimedWord] = []
    for (index, word) in words.enumerated() {
        if !text.isEmpty { text += " " }
        let wordStart = start + Double(index) * wordSeconds
        timed.append(TimedWord(text: word, start: wordStart, end: wordStart + wordSeconds,
                               utf16Offset: text.utf16.count, utf16Length: word.utf16.count))
        text += word
    }
    return TranscriptSegment(id: id, start: start, end: start + Double(words.count) * wordSeconds, text: text,
                             words: timed, track: track)
}

private func echoTranscript(_ segments: [TranscriptSegment]) -> Transcript {
    Transcript(id: "TRANSCRIPT", createdAt: Date(timeIntervalSince1970: 1_790_000_000), source: "mic+system",
               locale: "en-CA", backend: .speech, segments: segments)
}

/// The call settings post-processing uses: v1 with a 1 s echo window.
private let callParameters: AlignmentParameters = {
    var parameters = AlignmentParameters.v1
    parameters.echoWindowSeconds = 1.0
    return parameters
}()

private func echoSpans(_ segments: [TranscriptSegment],
                       parameters: AlignmentParameters = callParameters) -> [WordSpan] {
    EchoFilter.echoSpans(transcript: echoTranscript(segments), parameters: parameters)
}

private func echoOutput(_ segments: (String, Double, Double)...) -> DiarizerOutput {
    DiarizerOutput(segments: segments.map { RawDiarizationSegment(speaker: $0.0, start: $0.1, end: $0.2) },
                   centroids: [:], windows: [], processingSeconds: 0)
}

private let echoMe = TrackPolicy.channel(speakerID: "mic:me", displayName: "Me")

/// Every word position the run's turns cover.
private func wordsInTurns(_ run: DiarizationRun) -> Set<WordRef> {
    EchoFilter.words(in: run.turns.flatMap(\.spans))
}

// MARK: - Finding echo

@Test func threeWordEchoRunIsDropped() {
    let spans = echoSpans([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "should", "vote", "now"], track: "mic", start: 10.3),
    ])
    #expect(spans == [WordSpan(segmentID: "MIC", first: 0, end: 4)])
}

@Test func singleMatchingWordIsKept() {
    #expect(echoSpans([
        echoSegment("SYS", ["yes"], track: "system", start: 5.0),
        echoSegment("MIC", ["yes"], track: "mic", start: 5.2),
    ]).isEmpty)
}

/// R34: runs shorter than `echoMinRunWords` (3) are kept, so "thank you" and "okay, sure" survive.
@Test func twoWordRunIsKept() {
    #expect(echoSpans([
        echoSegment("SYS", ["thank", "you"], track: "system", start: 5.0),
        echoSegment("MIC", ["thank", "you"], track: "mic", start: 5.1),
    ]).isEmpty)
}

@Test func outsideWindowIsKept() {
    #expect(echoSpans([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "should", "vote", "now"], track: "mic", start: 11.5),
    ]).isEmpty)
    // Earlier by as much is outside the window too; exactly 1 s is inside.
    #expect(echoSpans([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "should", "vote", "now"], track: "mic", start: 8.5),
    ]).isEmpty)
    #expect(echoSpans([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "should", "vote", "now"], track: "mic", start: 9.0),
    ]) == [WordSpan(segmentID: "MIC", first: 0, end: 4)])
}

/// No window (in-person settings, `AlignmentParameters.v1`) means no filter.
@Test func noWindowMeansNoFilter() {
    let segments = [
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "should", "vote", "now"], track: "mic", start: 10.3),
    ]
    #expect(echoSpans(segments, parameters: .v1).isEmpty)
    var negative = callParameters
    negative.echoWindowSeconds = -1
    #expect(echoSpans(segments, parameters: negative).isEmpty)
    var notANumber = callParameters
    notANumber.echoWindowSeconds = .nan
    #expect(echoSpans(segments, parameters: notANumber).isEmpty)
}

/// The microphone words must repeat consecutive system words: a word the microphone missed breaks the run.
@Test func echoNeedsConsecutiveSystemWords() {
    #expect(echoSpans([
        echoSegment("SYS", ["we", "should", "really", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "should", "vote", "now"], track: "mic", start: 10.2),
    ]).isEmpty)
    // A longer run on either side of the gap is still echo.
    #expect(echoSpans([
        echoSegment("SYS", ["we", "should", "all", "really", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "should", "all", "vote", "now"], track: "mic", start: 10.2),
    ]) == [WordSpan(segmentID: "MIC", first: 0, end: 3)])
}

@Test func caseAndPunctuationAreIgnored() {
    #expect(echoSpans([
        echoSegment("SYS", ["We", "should,", "vote", "now."], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "Should", "VOTE", "now"], track: "mic", start: 10.4),
    ]) == [WordSpan(segmentID: "MIC", first: 0, end: 4)])
    #expect(EchoFilter.normalized("Don't!") == "dont")
    #expect(EchoFilter.normalized("—") == "")
    #expect(EchoFilter.normalized("Café") == "café")
    #expect(EchoFilter.normalized("2026,") == "2026")
}

/// A punctuation token inside echo leaves with it; one at the edge of a run stays.
@Test func punctuationInsideEchoIsDropped() {
    let spans = echoSpans([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["—", "we", "should", "—", "vote", "now", "…"], track: "mic", start: 9.9, wordSeconds: 0.2),
    ])
    #expect(spans == [WordSpan(segmentID: "MIC", first: 1, end: 6)])
}

@Test func echoRunCrossesMicrophoneSegments() {
    let spans = echoSpans([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC-B", ["vote", "now", "please"], track: "mic", start: 10.9),
        echoSegment("MIC-A", ["we", "should"], track: "mic", start: 10.3),
    ])
    #expect(spans == [WordSpan(segmentID: "MIC-A", first: 0, end: 2), WordSpan(segmentID: "MIC-B", first: 0, end: 2)])
}

/// Only the microphone copy goes: system words, and segments of other or no track, are never echo.
@Test func onlyMicrophoneWordsAreEcho() {
    let spans = echoSpans([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("OTHER", ["we", "should", "vote", "now"], track: "other", start: 10.3),
        TranscriptSegment(id: "NONE", start: 10.3, end: 11.5, text: "we should vote now", track: nil),
    ])
    #expect(spans.isEmpty)
}

/// Untimed segments spread their words evenly (`WordTiming`); their echo is found the same way.
@Test func estimatedWordsAreMatched() {
    let spans = echoSpans([
        TranscriptSegment(id: "SYS", start: 10.0, end: 11.2, text: "we should vote now", track: "system"),
        TranscriptSegment(id: "MIC", start: 10.5, end: 11.7, text: "We should vote now.", track: "mic"),
    ])
    #expect(spans == [WordSpan(segmentID: "MIC", first: 0, end: 4)])
}

/// A 3-hour call's worth of one repeated word (the worst case for candidate pairs) stays fast and exact.
@Test(.timeLimit(.minutes(1)))
func longCallIsFilteredQuickly() {
    var segments: [TranscriptSegment] = []
    for index in 0..<1_000 {
        let start = Double(index) * 6.0
        segments.append(echoSegment("SYS-\(index)", Array(repeating: "the", count: 20), track: "system", start: start))
        segments.append(echoSegment("MIC-\(index)", Array(repeating: "the", count: 20), track: "mic", start: start + 0.1))
    }
    let spans = echoSpans(segments)
    #expect(spans.count == 1_000)
    #expect(spans.allSatisfy { $0.first == 0 && $0.end == 20 && $0.segmentID.hasPrefix("MIC-") })
}

// MARK: - The run without echo

@Test func droppedWordsExcludedFromTurnsAndExports() throws {
    let transcript = echoTranscript([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["okay", "we", "should", "vote", "now", "sounds", "good"], track: "mic", start: 9.0,
                    wordSeconds: 0.5),
    ])
    // Microphone words: okay 9.0, we 9.5, should 10.0, vote 10.5, now 11.0, sounds 11.5, good 12.0.
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript,
        tracks: [.init(track: "mic", policy: echoMe),
                 .init(track: "system", policy: .diarized, output: echoOutput(("S1", 9.5, 12)))],
        engine: .fake, parameters: callParameters, id: "RUN", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    let run = result.run
    #expect(run.droppedWords == [DroppedWords(spans: [WordSpan(segmentID: "MIC", first: 1, end: 5)], reason: "echo")])
    #expect(run.alignment.parameters.echoWindowSeconds == 1.0)
    let covered = wordsInTurns(run)
    for word in 1..<5 { #expect(!covered.contains(WordRef(segmentID: "MIC", word: word))) }
    #expect(covered.contains(WordRef(segmentID: "MIC", word: 0)))
    #expect(covered.contains(WordRef(segmentID: "MIC", word: 5)) && covered.contains(WordRef(segmentID: "MIC", word: 6)))
    #expect((0..<4).allSatisfy { covered.contains(WordRef(segmentID: "SYS", word: $0)) }, "System words stay.")
    #expect(run.turns.filter { $0.track == "mic" }.flatMap(\.spans)
        == [WordSpan(segmentID: "MIC", first: 0, end: 1), WordSpan(segmentID: "MIC", first: 5, end: 7)])
    #expect(run.speakers.map(\.id) == ["mic:me", "system:S1"])

    let projection = SpeakerProjection.make(run: run, transcript: transcript, edits: [], recognition: nil,
                                            profileNames: [:])
    let document = ExportDocument(
        metadata: ExportMetadata(sessionID: "SESSION", name: "Call", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                                 durationSeconds: 20, source: .microphoneAndSystem, locale: "en-CA", backend: .speech,
                                 timeZone: .gmt),
        transcript: transcript, run: run, projection: projection)
    let markdown = String(decoding: try TranscriptExporter.render(document, format: .md), as: UTF8.self)
    #expect(markdown.components(separatedBy: "we should vote now").count == 2, "The phrase appears once.")
    #expect(markdown.contains("**Me** · 00:00:09\n\nokay\n"))
    #expect(markdown.contains("sounds good"))
    let text = String(decoding: try TranscriptExporter.render(document, format: .txt), as: UTF8.self)
    #expect(text.components(separatedBy: "we should vote now").count == 2)
    let json = String(decoding: try TranscriptExporter.render(document, format: .json), as: UTF8.self)
    #expect(json.components(separatedBy: "we should vote now").count == 2)
}

/// A hybrid call (others in the room): the microphone track is diarized. A cluster that is mostly echo is the call
/// heard through the laptop speakers, not a person in the room.
@Test func echoHeavyMicClusterIsHidden() throws {
    let echo = ["please", "review", "the", "budget", "before", "friday", "morning"]
    let transcript = echoTranscript([
        echoSegment("ROOM", ["good", "afternoon", "everyone", "shall", "we", "begin"], track: "mic", start: 0,
                    wordSeconds: 0.4),
        echoSegment("SYS", echo, track: "system", start: 20.0, wordSeconds: 0.4),
        // mic:S2: the 7 echoed words, then 3 words of its own: 70 % echo.
        echoSegment("ECHO", echo + ["uh", "hmm", "right"], track: "mic", start: 20.2, wordSeconds: 0.4),
    ])
    var micOutput = echoOutput(("S1", 0, 3), ("S2", 20, 25))
    micOutput.centroids = ["S1": FloatVector([1, 0]), "S2": FloatVector([0, 1])]
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript,
        tracks: [.init(track: "mic", policy: .diarized, output: micOutput),
                 .init(track: "system", policy: .diarized, output: echoOutput(("S1", 19.5, 23.5)))],
        engine: .fake, parameters: callParameters)
    let run = result.run
    #expect(run.droppedWords == [DroppedWords(spans: [WordSpan(segmentID: "ECHO", first: 0, end: 7)], reason: "echo")])
    #expect(run.speakers.map(\.id) == ["mic:S1", "system:S1"], "The echo cluster is not listed.")
    let rest = try #require(run.turns.first { $0.spans.contains { $0.segmentID == "ECHO" } })
    #expect(rest.spans == [WordSpan(segmentID: "ECHO", first: 7, end: 10)])
    #expect(rest.speakerID == nil && rest.clusterID == nil && rest.assignmentScore == 0 && !rest.overlap)
    #expect(run.turns.filter { $0.spans.contains { $0.segmentID == "ECHO" } }.count == 1)
    // The room speaker keeps their words and label; the cluster's segments stay in the track.
    #expect(run.turns.first { $0.spans.first?.segmentID == "ROOM" }?.speakerID == "mic:S1")
    #expect(run.tracks.first { $0.track == "mic" }?.clusters.map(\.clusterID) == ["mic:S1", "mic:S2"])
    // No voice data of the echo cluster.
    #expect(result.voiceData.map { Set($0.centroids.keys) } == ["mic:S1"])

    let projection = SpeakerProjection.make(run: run, transcript: transcript, edits: [], recognition: nil,
                                            profileNames: [:])
    #expect(projection.speakers.map(\.id) == ["mic:S1", "system:S1"])
    #expect(projection.turns.first { $0.spans.first?.segmentID == "ECHO" }?.speakerID == nil)
}

/// The share is of the cluster's labelled words: 3 of 5 (60 %) hides it, 3 of 6 (50 %) does not.
@Test func echoShareThresholdIsSixtyPercent() {
    func build(ownWords: [String]) -> DiarizationRun {
        let transcript = echoTranscript([
            echoSegment("SYS", ["vote", "on", "it"], track: "system", start: 20.0, wordSeconds: 0.4),
            echoSegment("MIC", ["vote", "on", "it"] + ownWords, track: "mic", start: 20.2, wordSeconds: 0.4),
        ])
        return SpeakerRunBuilder.build(
            sessionID: "SESSION", transcript: transcript,
            tracks: [.init(track: "mic", policy: .diarized, output: echoOutput(("S2", 20, 25))),
                     .init(track: "system", policy: .diarized, output: echoOutput(("S1", 19.5, 22)))],
            engine: .fake, parameters: callParameters).run
    }
    let sixty = build(ownWords: ["yes", "indeed"])
    #expect(!sixty.speakers.contains { $0.id == "mic:S2" })
    #expect(sixty.turns.first { $0.track == "mic" }?.speakerID == nil)
    let fifty = build(ownWords: ["yes", "I", "agree"])
    #expect(fifty.speakers.contains { $0.id == "mic:S2" })
    let kept = fifty.turns.filter { $0.track == "mic" }
    #expect(kept.map(\.speakerID) == ["mic:S2"])
    #expect(kept.flatMap(\.spans) == [WordSpan(segmentID: "MIC", first: 3, end: 6)])
}

/// Without others in the room the microphone is "Me": its echo leaves Me's turns, and Me stays listed.
@Test func echoLeavesTheChannelSpeaker() {
    let transcript = echoTranscript([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["we", "should", "vote", "now"], track: "mic", start: 10.3),
        echoSegment("MINE", ["I", "agree"], track: "mic", start: 14.0),
    ])
    let run = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript,
        tracks: [.init(track: "mic", policy: echoMe),
                 .init(track: "system", policy: .diarized, output: echoOutput(("S1", 9.5, 12)))],
        engine: .fake, parameters: callParameters).run
    let mine = run.turns.filter { $0.track == "mic" }
    #expect(mine.map(\.speakerID) == ["mic:me"])
    #expect(mine.flatMap(\.spans) == [WordSpan(segmentID: "MINE", first: 0, end: 2)])
    #expect(run.speakers.map(\.id) == ["system:S1", "mic:me"])
}

/// Without echo the run is exactly what it was before PR11.
@Test func runWithoutEchoIsUnchanged() {
    let transcript = echoTranscript([
        echoSegment("SYS", ["we", "should", "vote", "now"], track: "system", start: 10.0),
        echoSegment("MIC", ["sounds", "good", "to", "me"], track: "mic", start: 12.0),
    ])
    let tracks: [SpeakerRunBuilder.TrackInput] = [
        .init(track: "mic", policy: echoMe),
        .init(track: "system", policy: .diarized, output: echoOutput(("S1", 9.5, 12))),
    ]
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let call = SpeakerRunBuilder.build(sessionID: "SESSION", transcript: transcript, tracks: tracks, engine: .fake,
                                       parameters: callParameters, id: "RUN", createdAt: date).run
    let plain = SpeakerRunBuilder.build(sessionID: "SESSION", transcript: transcript, tracks: tracks, engine: .fake,
                                        parameters: .v1, id: "RUN", createdAt: date).run
    #expect(call.droppedWords.isEmpty)
    #expect(call.turns == plain.turns)
    #expect(call.speakers == plain.speakers)
}
