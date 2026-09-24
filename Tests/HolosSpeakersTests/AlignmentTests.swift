import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// Alignment tests (docs/meeting-design.md §5.3). Segments are "system" track segments with measured words;
// diarization labels "A", "B" become clusters "system:A", "system:B".

private let a = "system:A"
private let b = "system:B"

/// A segment with measured words `(text, start, end)`, joined by single spaces.
private func seg(_ start: Double, _ end: Double, _ words: (String, Double, Double)...,
                 id: String = UUID().uuidString, track: String? = "system") -> TranscriptSegment {
    var text = ""
    var timed: [TimedWord] = []
    for (index, word) in words.enumerated() {
        if index > 0 { text += " " }
        timed.append(TimedWord(text: word.0, start: word.1, end: word.2,
                               utf16Offset: text.utf16.count, utf16Length: word.0.utf16.count))
        text += word.0
    }
    return TranscriptSegment(id: id, start: start, end: end, text: text, words: timed, track: track)
}

/// A normalized "system" track from engine segments `(label, start, end)`.
private func diarization(_ segments: (String, Double, Double)...) -> TrackDiarization {
    DiarizationNormalizer.normalize(
        DiarizerOutput(segments: segments.map { RawDiarizationSegment(speaker: $0.0, start: $0.1, end: $0.2) },
                       centroids: [:], windows: [], processingSeconds: 0),
        track: "system")
}

private func align(_ segments: [TranscriptSegment], _ diarization: TrackDiarization) -> [AlignedWord] {
    SpeakerAlignment.assignWords(segments: segments, track: "system", diarization: diarization, parameters: .v1)
}

private func turns(_ segments: [TranscriptSegment], _ diarization: TrackDiarization) -> [SpeakerTurn] {
    SpeakerAlignment.buildTurns(align(segments, diarization), parameters: .v1)
}

// MARK: - Main cluster

@Test func wordInsideSegment() {
    let words = align([seg(1, 1.4, ("hello", 1.0, 1.4))], diarization(("A", 0, 5), ("B", 5, 10)))
    #expect(words.map(\.label) == [a])
    #expect(abs(words[0].coveredSeconds - 0.4) < 1e-9)
    #expect(words[0].overlapClusters.isEmpty)
    #expect(words[0].ref == WordRef(segmentID: words[0].ref.segmentID, word: 0))
}

@Test func boundaryWordTakesLargerOverlap() {
    let words = align([seg(4.8, 5.3, ("so", 4.8, 5.3))], diarization(("A", 0, 5), ("B", 5, 10)))
    #expect(words.map(\.label) == [b])
    #expect(abs(words[0].coveredSeconds - 0.3) < 1e-9)
}

@Test func equalOverlapTakesEarlierSegment() {
    let words = align([seg(4.8, 5.2, ("so", 4.8, 5.2))], diarization(("A", 0, 5), ("B", 5, 10)))
    #expect(words.map(\.label) == [a])
    // Equal overlap, cluster IDs in the other order: still the segment that starts first.
    let reversed = align([seg(4.8, 5.2, ("so", 4.8, 5.2))], diarization(("B", 0, 5), ("A", 5, 10)))
    #expect(reversed.map(\.label) == [b])
}

@Test func gapWordSnapsWithinHalfSecond() {
    let words = align([seg(5.3, 6.4, ("well", 5.3, 5.6), ("then", 6.0, 6.4))],
                      diarization(("A", 0, 5), ("B", 7, 10)))
    #expect(words.map(\.label) == [a, nil])
    #expect(words.map(\.coveredSeconds) == [0, 0])
}

@Test func equalSnapDistanceTakesEarlierSegment() {
    let words = align([seg(5.2, 5.6, ("hm", 5.2, 5.6))], diarization(("B", 0, 5), ("A", 5.8, 10)))
    #expect(words.map(\.label) == [b])
}

// MARK: - Flicker smoothing

@Test func boundaryFlickerIsSmoothed() {
    // Continuous speech by A; the diarizer puts a 0.25 s B segment at an A/B boundary. The design's row lists
    // "B 5.1–10, A 10–20" with the B pair at 4.9–5.2, which cannot label the pair B and the words after it A;
    // this keeps its shape (a two-word B run at an A/B meeting point, 0.1 s gaps, continuous speech).
    let segment = seg(4.2, 6.3, ("we", 4.2, 4.5), ("will", 4.6, 5.0), ("now", 5.1, 5.17), ("vote", 5.27, 5.35),
                      ("on", 5.45, 5.8), ("it", 5.9, 6.3))
    let track = diarization(("A", 0, 5.1), ("B", 5.1, 5.35), ("A", 5.35, 20))
    let unsmoothedLabels = SpeakerAlignment.trackWords([segment], track: "system", includeUntracked: nil)
        .map { SpeakerAlignment.label($0, timelines: ClusterTimeline.make(track.segments), parameters: .v1).label }
    #expect(unsmoothedLabels == [a, a, b, b, a, a])

    let words = align([segment], track)
    #expect(words.map(\.label) == [a, a, a, a, a, a])
    #expect(words[2].coveredSeconds == 0)
    #expect(words.allSatisfy { $0.overlapClusters.isEmpty })
    let built = SpeakerAlignment.buildTurns(words, parameters: .v1)
    #expect(built.count == 1)
    #expect(built.first?.spans == [WordSpan(segmentID: segment.id, first: 0, end: 6)])
}

@Test func isolatedShortReplyIsKept() {
    let segments = [
        seg(9, 10, ("the", 9.0, 9.5), ("motion", 9.6, 10.0)),
        seg(11.5, 11.8, ("Yes", 11.5, 11.8)),
        seg(13.3, 14.2, ("thank", 13.3, 13.7), ("you", 13.8, 14.2)),
    ]
    let track = diarization(("A", 0, 10), ("B", 11.5, 11.8), ("A", 13.3, 20))
    #expect(align(segments, track).map(\.label) == [a, a, b, a, a])
    #expect(turns(segments, track).map(\.speakerID) == [a, b, a])
}

@Test func unknownWordBetweenSameSpeakerIsSmoothed() {
    // The middle word is 0.55 s from every segment (unknown), with 0.15 s and 0.1 s pauses to A words.
    let segment = seg(4.5, 6.0, ("one", 4.5, 4.9), ("two", 5.0, 5.4), ("three", 5.55, 5.65), ("four", 5.75, 6.0))
    let track = diarization(("A", 0, 5.0), ("A", 6.2, 10))
    let labels = SpeakerAlignment.trackWords([segment], track: "system", includeUntracked: nil)
        .map { SpeakerAlignment.label($0, timelines: ClusterTimeline.make(track.segments), parameters: .v1).label }
    #expect(labels == [a, a, nil, a])
    #expect(align([segment], track).map(\.label) == [a, a, a, a])
}

@Test func flickerCoveredByOwnSegmentIsKept() {
    let segment = seg(4.3, 6.2, ("a", 4.3, 4.6), ("b", 4.7, 4.9), ("c", 5.0, 5.15), ("d", 5.25, 5.4),
                      ("e", 5.5, 5.8), ("f", 5.9, 6.2))
    let track = diarization(("A", 0, 5.0), ("B", 5.0, 5.5), ("A", 5.5, 20))
    #expect(align([segment], track).map(\.label) == [a, a, b, b, a, a])
}

@Test func flickerOverLimitIsKept() {
    // Three B words: over flickerMaxWords (every other condition holds).
    let threeWords = seg(4.5, 5.7, ("a", 4.5, 4.9), ("b", 5.0, 5.06), ("c", 5.1, 5.16), ("d", 5.2, 5.26),
                         ("e", 5.36, 5.7))
    let short = diarization(("A", 0, 5.0), ("B", 5.0, 5.28), ("A", 5.28, 20))
    #expect(align([threeWords], short).map(\.label) == [a, b, b, b, a])

    // Two B words spanning 0.5 s: over flickerMaxSeconds (each B segment is too short to count as its own).
    let wideRun = seg(4.5, 5.9, ("a", 4.5, 4.9), ("b", 5.0, 5.2), ("c", 5.3, 5.5), ("d", 5.6, 5.9))
    let split = diarization(("A", 0, 5.0), ("B", 5.0, 5.2), ("B", 5.3, 5.5), ("A", 5.5, 20))
    #expect(align([wideRun], split).map(\.label) == [a, b, b, a])
}

@Test func flickerWithoutMeetingPointIsKept() {
    // A short B run with 0.2 s pauses to A words, but the B segment touches no A segment.
    let segment = seg(9.4, 10.8, ("a", 9.4, 9.8), ("b", 10.0, 10.08), ("c", 10.15, 10.25), ("d", 10.45, 10.8))
    let track = diarization(("A", 0, 9.8), ("B", 10.0, 10.25), ("A", 10.45, 20))
    #expect(align([segment], track).map(\.label) == [a, b, b, a])
}

@Test func flickerAfterLongPauseIsKept() {
    let track = diarization(("A", 0, 10.0), ("B", 10.0, 10.25), ("A", 10.25, 20))
    let close = seg(9.5, 10.8, ("a", 9.5, 9.9), ("b", 10.0, 10.08), ("c", 10.15, 10.25), ("d", 10.3, 10.8))
    #expect(align([close], track).map(\.label) == [a, a, a, a])
    // Same run, but the pause before it is 0.4 s.
    let paused = seg(9.2, 10.8, ("a", 9.2, 9.6), ("b", 10.0, 10.08), ("c", 10.15, 10.25), ("d", 10.3, 10.8))
    #expect(align([paused], track).map(\.label) == [a, b, b, a])
}

// MARK: - Turns

@Test func longPauseSplitsSameSpeaker() {
    let segment = seg(1, 4.5, ("one", 1.0, 1.5), ("two", 1.6, 2.0), ("three", 4.0, 4.5))
    let built = turns([segment], diarization(("A", 0, 10)))
    #expect(built.count == 2)
    #expect(built.map(\.speakerID) == [a, a])
    #expect(built.map(\.spans) == [[WordSpan(segmentID: segment.id, first: 0, end: 2)],
                                   [WordSpan(segmentID: segment.id, first: 2, end: 3)]])
    #expect(built.map(\.start) == [1.0, 4.0])
    #expect(built.map(\.end) == [2.0, 4.5])
}

@Test func segmentSplitsAtSpeakerChange() {
    let segment = seg(0.5, 4.5, ("a", 0.5, 0.9), ("b", 1.0, 1.4), ("c", 1.5, 1.9),
                      ("d", 3.1, 3.5), ("e", 3.6, 4.0), ("f", 4.1, 4.5))
    let built = turns([segment], diarization(("A", 0, 3), ("B", 3, 6)))
    #expect(built.count == 2)
    #expect(built.map(\.speakerID) == [a, b])
    #expect(built.map(\.clusterID) == [a, b])
    #expect(built.map(\.spans) == [[WordSpan(segmentID: segment.id, first: 0, end: 3)],
                                   [WordSpan(segmentID: segment.id, first: 3, end: 6)]])
}

@Test func turnSpansTwoSegments() {
    let first = seg(1, 2, ("one", 1.0, 1.4), ("two", 1.5, 2.0))
    let second = seg(2.5, 3.4, ("three", 2.5, 2.9), ("four", 3.0, 3.4))
    let built = turns([second, first], diarization(("A", 0, 10)))
    #expect(built.count == 1)
    #expect(built.first?.spans == [WordSpan(segmentID: first.id, first: 0, end: 2),
                                   WordSpan(segmentID: second.id, first: 0, end: 2)])
    #expect(built.first?.start == 1.0)
    #expect(built.first?.end == 3.4)
    #expect(built.first?.timing == .measured)
}

@Test func overlapMarkedWithoutDuplicatingWords() {
    let words = (0..<20).map { index in ("w\(index)", Double(index) * 0.5, Double(index) * 0.5 + 0.4) }
    var segment = seg(0, 9.9)
    for word in words {
        segment.text += (segment.text.isEmpty ? "" : " ")
        segment.words.append(TimedWord(text: word.0, start: word.1, end: word.2,
                                       utf16Offset: segment.text.utf16.count, utf16Length: word.0.utf16.count))
        segment.text += word.0
    }
    let aligned = align([segment], diarization(("A", 0, 10), ("B", 4, 6)))
    #expect(aligned.allSatisfy { $0.label == a })
    let overlapped = aligned.filter { !$0.overlapClusters.isEmpty }
    #expect(overlapped.map(\.ref.word) == Array(8..<12))
    #expect(overlapped.allSatisfy { $0.overlapClusters == [b] })

    let built = SpeakerAlignment.buildTurns(aligned, parameters: .v1)
    #expect(built.count == 1)
    #expect(built.first?.speakerID == a)
    #expect(built.first?.overlap == true)
    #expect(built.first?.otherClusters == [b])
    let wordsInTurns = built.flatMap(\.spans).reduce(0) { $0 + $1.end - $1.first }
    #expect(wordsInTurns == words.count)
}

@Test func assignmentScoreIsCoveredShare() {
    let segment = seg(0, 2, ("one", 0, 1), ("two", 1, 2))
    let built = turns([segment], diarization(("A", 0, 1.5)))
    #expect(built.count == 1)
    #expect(abs((built.first?.assignmentScore ?? 0) - 0.75) < 1e-9)
}

@Test func unknownTurnHasNoSpeakerAndZeroScore() {
    let segment = seg(20, 21, ("far", 20, 20.5), ("away", 20.6, 21))
    let built = turns([segment], diarization(("A", 0, 5)))
    #expect(built.count == 1)
    #expect(built.first?.speakerID == nil)
    #expect(built.first?.clusterID == nil)
    #expect(built.first?.assignmentScore == 0)
}

@Test func untimedSegmentGivesEstimatedTiming() {
    let untimed = TranscriptSegment(id: "U", start: 1, end: 3, text: "one two", track: "system")
    let timed = seg(3.2, 3.6, ("three", 3.2, 3.6))
    let built = turns([untimed, timed], diarization(("A", 0, 10)))
    #expect(built.count == 1)
    #expect(built.first?.timing == .mixed)
    #expect(turns([untimed], diarization(("A", 0, 10))).first?.timing == .estimated)
}

@Test func untrackedSegmentsCountOnlyForSingleTrackTranscripts() {
    let untracked = seg(1, 1.4, ("hi", 1, 1.4), track: nil)
    let system = seg(2, 2.4, ("there", 2, 2.4))
    let mic = seg(3, 3.4, ("you", 3, 3.4), track: "mic")
    let track = diarization(("A", 0, 10))
    #expect(align([untracked, system], track).map(\.ref.segmentID) == [untracked.id, system.id])
    #expect(align([untracked, system, mic], track).map(\.ref.segmentID) == [system.id])
}

@Test func channelPolicyLabelsEveryWord() {
    let segment = seg(0, 1, ("a", 0, 0.4), ("b", 0.5, 1.0), track: "mic")
    let words = SpeakerAlignment.assignWords(
        segments: [segment], track: "mic",
        diarization: TrackDiarization(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")),
        parameters: .v1)
    #expect(words.map(\.label) == ["mic:me", "mic:me"])
    #expect(words.allSatisfy { $0.overlapClusters.isEmpty })
    let skipped = SpeakerAlignment.assignWords(
        segments: [segment], track: "mic",
        diarization: TrackDiarization(track: "mic", policy: .skipped(reason: "no audio")), parameters: .v1)
    #expect(skipped.isEmpty)
}

@Test func channelPolicyTurnsHaveNoClusterAndFullScore() {
    // Includes a zero-length word, whose covered share would be 0/0 without step 6.
    let segment = seg(0, 1, ("a", 0, 0.4), ("b", 0.5, 0.5), ("c", 0.6, 1.0), track: "mic")
    let policy = TrackPolicy.channel(speakerID: "mic:me", displayName: "Me")
    let words = SpeakerAlignment.assignWords(segments: [segment], track: "mic",
                                             diarization: TrackDiarization(track: "mic", policy: policy),
                                             parameters: .v1)
    let built = SpeakerAlignment.buildTurns(words, parameters: .v1, policy: policy)
    #expect(built.count == 1)
    #expect(built.first?.speakerID == "mic:me")
    #expect(built.first?.clusterID == nil)
    #expect(built.first?.overlap == false)
    #expect(built.first?.assignmentScore == 1)
    #expect(SpeakerAlignment.buildTurns(words, parameters: .v1, policy: .skipped(reason: "no audio")).isEmpty)
}

// MARK: - Offset

/// 200 measured words in 40 speech intervals of 5 words ([7k, 7k + 4.8)), speakers alternating; the engine's
/// segments are the intervals shifted by `shift`.
private func shiftedSpeech(intervals: Int, shift: Double) -> (segments: [TranscriptSegment], output: DiarizerOutput) {
    var segments: [TranscriptSegment] = []
    var raw: [RawDiarizationSegment] = []
    for interval in 0..<intervals {
        let base = Double(interval) * 7
        var segment = seg(base, base + 4.8, id: "S\(interval)")
        for word in 0..<5 {
            let start = base + Double(word)
            segment.text += (word == 0 ? "" : " ")
            segment.words.append(TimedWord(text: "w", start: start, end: start + 0.8,
                                           utf16Offset: segment.text.utf16.count, utf16Length: 1))
            segment.text += "w"
        }
        segments.append(segment)
        raw.append(RawDiarizationSegment(speaker: interval.isMultiple(of: 2) ? "S1" : "S2",
                                         start: base + shift, end: base + 4.8 + shift))
    }
    return (segments, DiarizerOutput(segments: raw, centroids: [:], windows: [], processingSeconds: 0))
}

@Test func offsetEstimateRecoversShift() throws {
    let speech = shiftedSpeech(intervals: 40, shift: 0.2)
    let offset = SpeakerAlignment.estimateOffset(
        segments: speech.segments, track: "system",
        diarization: DiarizationNormalizer.normalize(speech.output, track: "system"), parameters: .v1)
    #expect(abs(offset + 0.2) <= 0.02)

    let transcript = Transcript(id: "TR", source: "system", locale: "en-US", backend: .speech, segments: speech.segments)
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript,
        tracks: [.init(track: "system", policy: .diarized, output: speech.output)], engine: .fake)
    let recorded = try #require(result.run.alignment.trackOffsets["system"])
    #expect(abs(recorded + 0.2) <= 0.02)
    // The stored segments are the shifted ones, and every word is covered by its speaker.
    #expect(abs((result.run.tracks.first?.segments.first?.start ?? -1) - 0) < 0.021)
    #expect(result.run.turns.count == 40)
    #expect(result.run.turns.allSatisfy { $0.assignmentScore > 0.99 })
}

@Test func offsetIsZeroWithFewWords() {
    let speech = shiftedSpeech(intervals: 6, shift: 0.2)   // 30 measured words
    let offset = SpeakerAlignment.estimateOffset(
        segments: speech.segments, track: "system",
        diarization: DiarizationNormalizer.normalize(speech.output, track: "system"), parameters: .v1)
    #expect(offset == 0)
}

@Test func offsetIsZeroWithoutGainOrWhenDisabled() {
    let aligned = shiftedSpeech(intervals: 40, shift: 0)
    let track = DiarizationNormalizer.normalize(aligned.output, track: "system")
    #expect(SpeakerAlignment.estimateOffset(segments: aligned.segments, track: "system", diarization: track,
                                            parameters: .v1) == 0)

    let shifted = shiftedSpeech(intervals: 40, shift: 0.2)
    var disabled = AlignmentParameters.v1
    disabled.offsetSearchSeconds = 0
    #expect(SpeakerAlignment.estimateOffset(
        segments: shifted.segments, track: "system",
        diarization: DiarizationNormalizer.normalize(shifted.output, track: "system"), parameters: disabled) == 0)
}

@Test func offsetWithTinyStepDoesNotTrap() {
    // search / step overflows Int; the step count is capped before the conversion.
    let speech = shiftedSpeech(intervals: 12, shift: 0.2)   // 60 measured words
    var tiny = AlignmentParameters.v1
    tiny.offsetStepSeconds = 1e-300
    let offset = SpeakerAlignment.estimateOffset(
        segments: speech.segments, track: "system",
        diarization: DiarizationNormalizer.normalize(speech.output, track: "system"), parameters: tiny)
    #expect(offset.isFinite)
}
