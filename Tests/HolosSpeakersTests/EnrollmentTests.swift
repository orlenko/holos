import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// VoiceEnrollment (docs/meeting-design.md §4.10 "Enrollment" and the extractor's selection), on synthetic runs.

// MARK: - Fixture

private let date = Date(timeIntervalSince1970: 1_790_000_000)

/// One turn of the fixture run: its ID, speaker (a diarizer speaker "system:Sn"), start, and length.
private struct TurnSpec {
    var id: String
    var speaker: String
    var start: Double
    var seconds: Double
    var overlap = false
}

/// A run over one segment per turn; each segment has six words spread over the turn.
private func enrollmentRun(_ specs: [TurnSpec]) -> (run: DiarizationRun, transcript: Transcript) {
    let segments = specs.map { spec -> TranscriptSegment in
        var text = ""
        var words: [TimedWord] = []
        let step = spec.seconds / 6
        for index in 0..<6 {
            if index > 0 { text += " " }
            let token = "w\(index)"
            let start = spec.start + Double(index) * step
            words.append(TimedWord(text: token, start: start, end: start + step * 0.9,
                                   utf16Offset: text.utf16.count, utf16Length: token.utf16.count))
            text += token
        }
        return TranscriptSegment(id: "seg-\(spec.id)", start: spec.start, end: spec.start + spec.seconds, text: text,
                                 words: words, track: "system")
    }
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: date, source: "fixture", locale: "en-CA",
                                backend: .speech, segments: segments)
    let speakers = Array(Set(specs.map(\.speaker))).sorted().enumerated().map { index, id in
        SessionSpeaker(id: id, ordinal: index + 1, provenance: .diarizer, clusterIDs: [id])
    }
    let run = DiarizationRun(
        id: "RUN", sessionID: "SESSION", createdAt: date, transcriptID: "TRANSCRIPT", engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1),
        tracks: [TrackDiarization(track: "system", policy: .diarized)], speakers: speakers,
        turns: specs.map { spec in
            SpeakerTurn(id: spec.id, track: "system", start: spec.start, end: spec.start + spec.seconds,
                        speakerID: spec.speaker, clusterID: spec.speaker,
                        spans: [WordSpan(segmentID: "seg-\(spec.id)", first: 0, end: 6)], overlap: spec.overlap,
                        assignmentScore: 0.9, timing: .measured)
        })
    return (run, transcript)
}

private func projection(_ fixture: (run: DiarizationRun, transcript: Transcript)) -> SpeakerProjection {
    SpeakerProjection.make(run: fixture.run, transcript: fixture.transcript, edits: [], recognition: nil,
                           profileNames: [:])
}

private func unit(_ values: [Float]) -> [Float] {
    let norm = values.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
    return values.map { Float(Double($0) / norm) }
}

private func embedding(_ turnID: String, _ values: [Float]) -> TurnEmbedding {
    TurnEmbedding(turnID: turnID, speechSeconds: 1, vector: FloatVector(unit(values)))
}

private func close(_ a: [Float], _ b: [Float], tolerance: Double = 1e-5) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs(Double($0) - Double($1)) <= tolerance }
}

private let s1 = "system:S1"
private let s2 = "system:S2"
private let s3 = "system:S3"

// MARK: - Qualifying turns

@Test func sampleUsesOnlyQualifyingTurns() throws {
    // Eight turns of S1 (T1 made S1's by a reassignment), plus one of S2 to split off T2's tail.
    let fixture = enrollmentRun([
        TurnSpec(id: "T1", speaker: s2, start: 0, seconds: 6),
        TurnSpec(id: "T2", speaker: s1, start: 10, seconds: 6),
        TurnSpec(id: "T3", speaker: s1, start: 20, seconds: 6, overlap: true),
        TurnSpec(id: "T4", speaker: s1, start: 30, seconds: 1.5),
        TurnSpec(id: "T5", speaker: s1, start: 40, seconds: 6),
        TurnSpec(id: "T6", speaker: s1, start: 50, seconds: 6),
        TurnSpec(id: "T7", speaker: s1, start: 60, seconds: 6),
        TurnSpec(id: "T8", speaker: s1, start: 70, seconds: 4),
        TurnSpec(id: "T9", speaker: s2, start: 80, seconds: 6),
    ])
    var view = projection(fixture)
    view = view.applying(.reassignTurns(turnIDs: ["T1"], to: s1), editID: "E1")
    view = view.applying(.splitTurn(turnID: "T2", at: WordRef(segmentID: "seg-T2", word: 3)), editID: "E2")
    view = view.applying(.excludeFromEnrollment(turnIDs: ["T5"]), editID: "E3")
    #expect(view.staleEdits.isEmpty)

    let candidates = VoiceEnrollment.candidateTurns(for: [s1], projection: view).map(\.id)
    #expect(candidates == ["T6", "T7", "T8"])

    // Every turn has an embedding except T6; the non-qualifying ones point elsewhere.
    let elsewhere: [Float] = [0, 0, 0, 0, 0, 1, 0, 0]
    var embeddings = ["T1", "T2", "T2/E2", "T3", "T4", "T5", "T9"].map { embedding($0, elsewhere) }
    embeddings.append(embedding("T7", [1, 0.2, 0, 0, 0, 0, 0, 0]))
    embeddings.append(embedding("T8", [1, -0.2, 0, 0, 0, 0, 0, 0]))
    let sample = try #require(VoiceEnrollment.sample(for: [s1], projection: view, run: fixture.run,
                                                     turnEmbeddings: embeddings))
    // Speech-weighted by the turns' lengths: T7 6 s, T8 4 s.
    let t7 = unit([1, 0.2, 0, 0, 0, 0, 0, 0])
    let t8 = unit([1, -0.2, 0, 0, 0, 0, 0, 0])
    let mean = unit(zip(t7, t8).map { Float(6 * Double($0) + 4 * Double($1)) })
    #expect(close(sample.vector.values, mean))
    #expect(sample.vector.values[5] == 0, "No non-qualifying turn contributes.")
    #expect(abs(sample.speechSeconds - 10) < 1e-9)
    #expect(sample.condition == .call)
    #expect(sample.weak)
    #expect(sample.droppedOutlierTurns == 0)
}

@Test func splitThenReassignKeepsOtherVoiceOut() throws {
    let fixture = enrollmentRun([
        TurnSpec(id: "T1", speaker: s1, start: 0, seconds: 6),
        TurnSpec(id: "T2", speaker: s2, start: 10, seconds: 6),
        TurnSpec(id: "T5", speaker: s1, start: 20, seconds: 6),
    ])
    var view = projection(fixture)
    view = view.applying(.splitTurn(turnID: "T5", at: WordRef(segmentID: "seg-T5", word: 3)), editID: "E1")
    view = view.applying(.reassignTurns(turnIDs: ["T5/E1"], to: s2), editID: "E2")
    view = view.applying(.rename(speakerID: s2, name: "Maria"), editID: "E3")
    view = view.applying(.linkProfile(speakerID: s1, profileID: "JIM"), editID: "E4")
    #expect(view.staleEdits.isEmpty)
    let linked = view.speakers.filter { $0.profileID == "JIM" }.map(\.id)
    #expect(linked == [s1])
    #expect(VoiceEnrollment.candidateTurns(for: linked, projection: view).map(\.id) == ["T1"])
    let own: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
    let other: [Float] = [0, 1, 0, 0, 0, 0, 0, 0]
    let sample = try #require(VoiceEnrollment.sample(
        for: linked, projection: view, run: fixture.run,
        turnEmbeddings: [embedding("T1", own), embedding("T5", other), embedding("T5/E1", other)]))
    #expect(close(sample.vector.values, own), "Jim's sample uses nothing from T5.")
}

@Test func mergeKeepsTurnsInSample() throws {
    let fixture = enrollmentRun([
        TurnSpec(id: "T1", speaker: s1, start: 0, seconds: 6),
        TurnSpec(id: "T2", speaker: s3, start: 10, seconds: 8),
        TurnSpec(id: "T3", speaker: s2, start: 20, seconds: 6),
    ])
    var view = projection(fixture)
    view = view.applying(.merge(from: s3, into: s1), editID: "E1")
    view = view.applying(.linkProfile(speakerID: s1, profileID: "JIM"), editID: "E2")
    #expect(view.turns.first { $0.id == "T2" }?.reassigned == false)
    #expect(VoiceEnrollment.candidateTurns(for: [s1], projection: view).map(\.id) == ["T1", "T2"])
    let sample = try #require(VoiceEnrollment.sample(
        for: [s1], projection: view, run: fixture.run,
        turnEmbeddings: [embedding("T1", [1, 0.1, 0, 0, 0, 0, 0, 0]), embedding("T2", [1, -0.1, 0, 0, 0, 0, 0, 0])]))
    #expect(abs(sample.speechSeconds - 14) < 1e-9, "S3's turn counts.")
}

@Test func mergedClusterSampleDropsOutlierTurns() throws {
    let specs = (0..<8).map { index in
        TurnSpec(id: "T\(index + 1)", speaker: s1, start: Double(index) * 10, seconds: 5)
    }
    let fixture = enrollmentRun(specs)
    let view = projection(fixture)
    var embeddings: [TurnEmbedding] = []
    for index in 0..<6 {
        embeddings.append(embedding("T\(index + 1)", [1, Float(index) * 0.02, 0, 0, 0, 0, 0, 0]))
    }
    embeddings.append(embedding("T7", [0.02, 1, 0, 0, 0, 0, 0, 0]))
    embeddings.append(embedding("T8", [-0.02, 1, 0, 0, 0, 0, 0, 0]))
    let sample = try #require(VoiceEnrollment.sample(for: [s1], projection: view, run: fixture.run,
                                                     turnEmbeddings: embeddings))
    #expect(sample.droppedOutlierTurns == 2)
    #expect(abs(sample.speechSeconds - 30) < 1e-9)
    #expect(sample.vector.values[0] > 0.99, "The recomputed vector is the six close turns' mean.")
    #expect(sample.vector.values[1] < 0.1)
}

@Test func underTwentySecondsIsWeak() throws {
    let short = enrollmentRun([TurnSpec(id: "T1", speaker: s1, start: 0, seconds: 6),
                               TurnSpec(id: "T2", speaker: s1, start: 10, seconds: 6)])
    let shortSample = try #require(VoiceEnrollment.sample(
        for: [s1], projection: projection(short), run: short.run,
        turnEmbeddings: [embedding("T1", [1, 0, 0, 0, 0, 0, 0, 0]), embedding("T2", [1, 0, 0, 0, 0, 0, 0, 0])]))
    #expect(abs(shortSample.speechSeconds - 12) < 1e-9)
    #expect(shortSample.weak)

    let long = enrollmentRun((0..<4).map { TurnSpec(id: "T\($0 + 1)", speaker: s1, start: Double($0) * 10, seconds: 6) })
    let longSample = try #require(VoiceEnrollment.sample(
        for: [s1], projection: projection(long), run: long.run,
        turnEmbeddings: (1...4).map { embedding("T\($0)", [1, 0, 0, 0, 0, 0, 0, 0]) }))
    #expect(!longSample.weak)
}

@Test func noQualifyingTurnMeansNoSample() {
    let fixture = enrollmentRun([TurnSpec(id: "T1", speaker: s1, start: 0, seconds: 6)])
    let view = projection(fixture)
    #expect(VoiceEnrollment.sample(for: [s1], projection: view, run: fixture.run, turnEmbeddings: []) == nil)
    #expect(VoiceEnrollment.sample(for: [s2], projection: view, run: fixture.run,
                                   turnEmbeddings: [embedding("T1", [1, 0, 0, 0, 0, 0, 0, 0])]) == nil)
}

@Test func inputDigestFollowsTheSpeakersTurns() {
    let fixture = enrollmentRun([
        TurnSpec(id: "T1", speaker: s1, start: 0, seconds: 6),
        TurnSpec(id: "T2", speaker: s2, start: 10, seconds: 6),
        TurnSpec(id: "T3", speaker: s1, start: 20, seconds: 6),
    ])
    let view = projection(fixture)
    let digest = VoiceEnrollment.inputDigest(speakerIDs: [s1], projection: view)
    #expect(digest == VoiceEnrollment.inputDigest(speakerIDs: [s1], projection: view))
    #expect(digest.hasPrefix("venroll1:"))
    let renamed = view.applying(.rename(speakerID: s1, name: "Jim"), editID: "E1")
    #expect(digest == VoiceEnrollment.inputDigest(speakerIDs: [s1], projection: renamed), "Names do not matter.")
    let reassigned = view.applying(.reassignTurns(turnIDs: ["T3"], to: s2), editID: "E1")
    #expect(digest != VoiceEnrollment.inputDigest(speakerIDs: [s1], projection: reassigned))
    #expect(digest != VoiceEnrollment.inputDigest(speakerIDs: [s1, s2], projection: view))
}

// MARK: - Extractor selection

@Test func selectionPrefersTheTurnsOwnSpeakerSlot() {
    let own: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
    let other: [Float] = [0, 1, 0, 0, 0, 0, 0, 0]
    let segments = [RawDiarizationSegment(speaker: "S1", start: 0, end: 6),
                    RawDiarizationSegment(speaker: "S2", start: 6, end: 10)]
    let windows = [EmbeddingWindow(speaker: "S1", start: 0, end: 10, vector: FloatVector(own)),
                   EmbeddingWindow(speaker: "S2", start: 0, end: 10, vector: FloatVector(other))]
    let result = VoiceEnrollment.turnEmbeddings(
        turns: [TurnRef(id: "A", start: 1, end: 5), TurnRef(id: "B", start: 6.5, end: 9.5),
                TurnRef(id: "C", start: 4, end: 8)],
        segments: segments, windows: windows)
    #expect(result.map(\.turnID) == ["A", "B"], "C is half S1, half S2.")
    #expect(result.first?.vector.values == own)
    #expect(result.last?.vector.values == other)
    #expect(result.first?.speechSeconds == 4)
}

@Test func selectionNeedsSixtyPercentAndAtMostTwentyFivePercentOfAnother() {
    let segments = [RawDiarizationSegment(speaker: "S1", start: 0, end: 7),
                    RawDiarizationSegment(speaker: "S2", start: 7, end: 20)]
    let windows = [EmbeddingWindow(speaker: "S1", start: 0, end: 20, vector: FloatVector([1, 0])),
                   EmbeddingWindow(speaker: "S2", start: 0, end: 20, vector: FloatVector([0, 1]))]
    // 7 of 10 s S1 but 3 s (30 %) S2: refused. 7 of 9 s S1 and 2 s (22 %) S2: kept.
    let result = VoiceEnrollment.turnEmbeddings(
        turns: [TurnRef(id: "A", start: 0, end: 10), TurnRef(id: "B", start: 0, end: 9)],
        segments: segments, windows: windows)
    #expect(result.map(\.turnID) == ["B"])
}
