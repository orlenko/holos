import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

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

private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
    Transcript(id: "TRANSCRIPT", source: "mic+system", locale: "en-US", backend: .speech, segments: segments)
}

private func output(_ segments: (String, Double, Double)...) -> DiarizerOutput {
    DiarizerOutput(segments: segments.map { RawDiarizationSegment(speaker: $0.0, start: $0.1, end: $0.2) },
                   centroids: [:], windows: [], processingSeconds: 0)
}

private let me = TrackPolicy.channel(speakerID: "mic:me", displayName: "Me")

/// Every key of every JSON object in `value`, at any depth.
private func allKeys(_ value: Any) -> Set<String> {
    if let object = value as? [String: Any] {
        return object.reduce(into: Set(object.keys)) { $0.formUnion(allKeys($1.value)) }
    }
    if let array = value as? [Any] {
        return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
    }
    return []
}

@Test func runBuilderNumbersTurnsAndOrdinals() {
    let segments = [
        seg(3, 3.8, ("hello", 3.0, 3.8), track: "mic"),
        seg(1, 1.8, ("good", 1.0, 1.4), ("morning", 1.5, 1.8)),
        seg(5, 5.8, ("thanks", 5.0, 5.8)),
    ]
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript(segments),
        tracks: [.init(track: "mic", policy: me),
                 .init(track: "system", policy: .diarized, output: output(("S2", 0.5, 2.5), ("S1", 4.5, 7)))],
        engine: .fake, id: "RUN", createdAt: Date(timeIntervalSince1970: 1_000_000))
    let run = result.run
    #expect(run.id == "RUN")
    #expect(run.sessionID == "SESSION")
    #expect(run.transcriptID == "TRANSCRIPT")
    #expect(run.createdAt == Date(timeIntervalSince1970: 1_000_000))
    #expect(run.schemaVersion == 1)
    #expect(run.engine == .fake)
    #expect(run.alignment == AlignmentInfo(version: 1, parameters: .v1, trackOffsets: ["system": 0]))
    #expect(run.turns.map(\.id) == ["T1", "T2", "T3"])
    #expect(run.turns.map(\.speakerID) == ["system:S2", "mic:me", "system:S1"])
    #expect(run.turns.map(\.track) == ["system", "mic", "system"])
    #expect(run.speakers.map(\.id) == ["system:S2", "mic:me", "system:S1"])
    #expect(run.speakers.map(\.ordinal) == [1, 2, 3])
    #expect(run.speakers == [
        SessionSpeaker(id: "system:S2", ordinal: 1, provenance: .diarizer, clusterIDs: ["system:S2"]),
        SessionSpeaker(id: "mic:me", ordinal: 2, displayName: "Me", provenance: .channelAssumption),
        SessionSpeaker(id: "system:S1", ordinal: 3, provenance: .diarizer, clusterIDs: ["system:S1"]),
    ])
    #expect(run.tracks.map(\.track) == ["mic", "system"])
    #expect(run.tracks.first?.policy == me)
    #expect(run.tracks.first?.segments.isEmpty == true)
    #expect(run.tracks.last?.clusters.map(\.clusterID) == ["system:S1", "system:S2"])
    #expect(run.droppedWords.isEmpty)
}

@Test func runHoldsNoVectors() throws {
    let words = (0..<40).map { index in ("w\(index)", Double(index) * 0.5, Double(index) * 0.5 + 0.4) }
    var segment = seg(0, 20)
    for word in words {
        segment.text += (segment.text.isEmpty ? "" : " ")
        segment.words.append(TimedWord(text: word.0, start: word.1, end: word.2,
                                       utf16Offset: segment.text.utf16.count, utf16Length: word.0.utf16.count))
        segment.text += word.0
    }
    let fake = FakeDiarizer.alternating(speakers: ["S1", "S2"], turnSeconds: 5, duration: 20)
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript([segment]),
        tracks: [.init(track: "system", policy: .diarized, output: fake)], engine: .fake, id: "RUN",
        createdAt: Date(timeIntervalSince1970: 1_000_000))   // whole seconds: HolosJSON dates keep second precision

    let encoded = try HolosJSON.encoder().encode(result.run)
    let keys = allKeys(try JSONSerialization.jsonObject(with: encoded))
    for forbidden in ["centroid", "centroids", "vector", "turnEmbeddings"] {
        #expect(!keys.contains(forbidden), "run JSON contains \(forbidden)")
    }
    #expect(try HolosJSON.decoder().decode(DiarizationRun.self, from: encoded) == result.run)

    let voice = try #require(result.voiceData)
    #expect(voice.runID == "RUN")
    #expect(voice.sessionID == "SESSION")
    #expect(voice.embeddingModel == DiarizationEngineInfo.fake.embeddingModel)
    #expect(voice.centroids.count == 2)
    #expect(voice.centroids["system:S1"] == fake.centroids["S1"])
    #expect(voice.centroids["system:S2"] == fake.centroids["S2"])
    #expect(result.run.turns.map(\.speakerID) == ["system:S1", "system:S2", "system:S1", "system:S2"])
    #expect(voice.turnEmbeddings.map(\.turnID) == ["T1", "T2", "T3", "T4"])
    for embedding in voice.turnEmbeddings {
        let turn = try #require(result.run.turns.first { $0.id == embedding.turnID })
        let centroid = try #require(voice.centroids[turn.clusterID ?? ""])
        #expect(VectorMath.cosineDistance(embedding.vector.values, centroid.values) < 1e-6)
    }
}

@Test func channelTrackIsOneSpeaker() {
    let segments = [
        seg(0, 2, ("one", 0, 0.5), ("two", 0.6, 1.0), track: "mic"),
        seg(4, 5, ("three", 4, 4.5), ("four", 4.6, 5.0), track: "mic"),
    ]
    let result = SpeakerRunBuilder.build(sessionID: "SESSION", transcript: transcript(segments),
                                         tracks: [.init(track: "mic", policy: me)], engine: nil)
    let run = result.run
    #expect(run.turns.count == 2)
    #expect(run.turns.allSatisfy {
        $0.speakerID == "mic:me" && $0.clusterID == nil && $0.assignmentScore == 1 && !$0.overlap && $0.otherClusters.isEmpty
    })
    #expect(run.speakers == [SessionSpeaker(id: "mic:me", ordinal: 1, displayName: "Me", provenance: .channelAssumption)])
    #expect(run.engine == nil)
    #expect(run.alignment.trackOffsets.isEmpty)
    #expect(result.voiceData == nil)
}

@Test func channelSpeakerWithoutWordsIsListedLast() {
    let segments = [seg(1, 1.5, ("hello", 1, 1.5))]
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript(segments),
        tracks: [.init(track: "mic", policy: me), .init(track: "system", policy: .diarized, output: output(("S1", 0, 3)))],
        engine: .fake)
    #expect(result.run.speakers.map(\.id) == ["system:S1", "mic:me"])
    #expect(result.run.speakers.map(\.ordinal) == [1, 2])
}

@Test func skippedTrackHasNoTurns() {
    let segments = [seg(1, 1.5, ("hello", 1, 1.5), track: "mic"), seg(2, 2.5, ("there", 2, 2.5))]
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript(segments),
        tracks: [.init(track: "mic", policy: .skipped(reason: "no audio")),
                 .init(track: "system", policy: .diarized, output: output(("S1", 0, 3)))],
        engine: .fake)
    #expect(result.run.turns.map(\.track) == ["system"])
    #expect(result.run.tracks.map(\.policy) == [.skipped(reason: "no audio"), .diarized])
}

@Test func diarizedTrackWithoutOutputHasUnknownTurns() {
    let segments = [seg(1, 1.5, ("hello", 1, 1.5))]
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript(segments),
        tracks: [.init(track: "system", policy: .diarized)], engine: .fake)
    #expect(result.run.turns.count == 1)
    #expect(result.run.turns.first?.speakerID == nil)
    #expect(result.run.speakers.isEmpty)
    #expect(result.voiceData?.centroids.isEmpty == true)
}

@Test func nonFiniteEngineTimesAreDropped() {
    let segments = [seg(1, 1.5, ("hello", 1, 1.5))]
    let engineOutput = DiarizerOutput(
        segments: [RawDiarizationSegment(speaker: "S1", start: .nan, end: 100),
                   RawDiarizationSegment(speaker: "S2", start: 50, end: .infinity)],
        centroids: [:],
        windows: [EmbeddingWindow(speaker: "S1", start: .nan, end: 100, vector: FloatVector([1, 0]))],
        processingSeconds: 0)
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript(segments),
        tracks: [.init(track: "system", policy: .diarized, output: engineOutput)], engine: .fake)
    #expect(result.run.tracks.first?.segments.isEmpty == true)
    #expect(result.run.turns.map(\.speakerID) == [nil])
    #expect(result.voiceData?.turnEmbeddings.isEmpty == true)
}

@Test func untrackedSegmentsJoinOnlyOneTrack() {
    let segments = [seg(1, 1.5, ("hello", 1, 1.5), track: nil)]
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript(segments),
        tracks: [.init(track: "mic", policy: .skipped(reason: "no audio")),
                 .init(track: "system", policy: .diarized, output: output(("S1", 0, 3))),
                 .init(track: "other", policy: me)],
        engine: .fake)
    #expect(result.run.turns.count == 1)
    #expect(result.run.turns.first?.speakerID == "system:S1")
}

@Test func repeatedTrackInputIsIgnored() {
    let segments = [seg(1, 1.5, ("hello", 1, 1.5))]
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript(segments),
        tracks: [.init(track: "system", policy: .diarized, output: output(("S1", 0, 3))),
                 .init(track: "system", policy: .diarized, output: output(("S2", 0, 3)))],
        engine: .fake)
    #expect(result.run.tracks.count == 1)
    #expect(result.run.turns.map(\.speakerID) == ["system:S1"])
}

/// Deterministic pseudo-random numbers in [0, 1) (64-bit LCG), so the property test is reproducible.
private struct SeededNumbers {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

@Test func everyWordLandsInExactlyOneTurn() throws {
    var random = SeededNumbers(state: 42)
    var segments: [TranscriptSegment] = []
    var raw: [RawDiarizationSegment] = []
    var time = 0.0
    var segmentIndex = 0
    // About 3000 words on the system track and 1000 on the microphone, with pauses, jittery speaker changes,
    // overlapping engine segments, and gaps the engine left uncovered.
    while segments.count < 400 {
        let track = random.next() < 0.25 ? "mic" : "system"
        var segment = seg(time, time, id: "S\(segmentIndex)", track: track)
        segmentIndex += 1
        for word in 0..<(5 + Int(random.next() * 15)) {
            let start = time + random.next() * 0.3
            let end = start + 0.05 + random.next() * 0.6
            segment.text += (word == 0 ? "" : " ")
            segment.words.append(TimedWord(text: "w", start: start, end: end,
                                           utf16Offset: segment.text.utf16.count, utf16Length: 1))
            segment.text += "w"
            time = end
        }
        segment.end = time
        segments.append(segment)
        time += random.next() < 0.2 ? 2 + random.next() * 5 : random.next() * 0.8
    }
    var engineTime = 0.0
    while engineTime < time {
        let length = 0.02 + random.next() * 8
        if random.next() < 0.9 {
            raw.append(RawDiarizationSegment(speaker: "S\(1 + Int(random.next() * 5))", start: engineTime,
                                             end: engineTime + length + (random.next() < 0.2 ? 1 : 0)))
        }
        engineTime += length
    }
    let result = SpeakerRunBuilder.build(
        sessionID: "SESSION", transcript: transcript(segments),
        tracks: [.init(track: "mic", policy: me),
                 .init(track: "system", policy: .diarized,
                       output: DiarizerOutput(segments: raw, centroids: [:], windows: [], processingSeconds: 0))],
        engine: .fake)
    let run = result.run

    var seen = Set<WordRef>()
    for turn in run.turns {
        #expect(!turn.spans.isEmpty)
        #expect(turn.start <= turn.end)
        #expect(turn.assignmentScore >= 0 && turn.assignmentScore <= 1)
        for span in turn.spans {
            let segment = try #require(segments.first { $0.id == span.segmentID })
            #expect(segment.track == turn.track)
            #expect(0 <= span.first && span.first < span.end && span.end <= segment.words.count)
            for word in span.first..<span.end {
                #expect(seen.insert(WordRef(segmentID: span.segmentID, word: word)).inserted)
            }
        }
    }
    #expect(seen.count == segments.reduce(0) { $0 + $1.words.count })
    #expect(run.turns.map(\.id) == run.turns.indices.map { "T\($0 + 1)" })
    #expect(zip(run.turns, run.turns.dropFirst()).allSatisfy { ($0.start, $0.track) <= ($1.start, $1.track) })
    #expect(run.speakers.map(\.ordinal) == Array(1...run.speakers.count))
    let speakerIDs = Set(run.speakers.map(\.id))
    #expect(run.turns.allSatisfy { $0.speakerID.map(speakerIDs.contains) ?? true })
    #expect(run.turns.contains { $0.speakerID == nil })
    #expect(run.turns.contains { $0.overlap })
}

@Test func windowsAndSegmentsMoveWithTheOffset() throws {
    // 60 measured words in 12 intervals; engine times are 0.3 s late.
    var segments: [TranscriptSegment] = []
    var raw: [RawDiarizationSegment] = []
    var windows: [EmbeddingWindow] = []
    for interval in 0..<12 {
        let base = Double(interval) * 8
        var segment = seg(base, base + 4.8, id: "S\(interval)")
        for word in 0..<5 {
            let start = base + Double(word)
            segment.text += (word == 0 ? "" : " ")
            segment.words.append(TimedWord(text: "w", start: start, end: start + 0.8,
                                           utf16Offset: segment.text.utf16.count, utf16Length: 1))
            segment.text += "w"
        }
        segments.append(segment)
        raw.append(RawDiarizationSegment(speaker: "S1", start: base + 0.3, end: base + 5.1))
        windows.append(EmbeddingWindow(speaker: "S1", start: base + 0.3, end: base + 5.1, vector: FloatVector([1, 0])))
    }
    let engineOutput = DiarizerOutput(segments: raw, centroids: ["S1": FloatVector([1, 0])], windows: windows,
                                      processingSeconds: 1)
    let result = SpeakerRunBuilder.build(sessionID: "SESSION", transcript: transcript(segments),
                                         tracks: [.init(track: "system", policy: .diarized, output: engineOutput)],
                                         engine: .fake)
    let offset = try #require(result.run.alignment.trackOffsets["system"])
    #expect(abs(offset + 0.3) < 0.011)
    let first = try #require(result.run.tracks.first?.segments.first)
    #expect(abs(first.start - (0.3 + offset)) < 1e-9)
    #expect(result.run.turns.count == 12)
    #expect(result.run.turns.allSatisfy { $0.assignmentScore > 0.99 })
    // Each turn is 4.8 s long and overlaps one shifted window.
    #expect(result.voiceData?.turnEmbeddings.count == 12)
}
