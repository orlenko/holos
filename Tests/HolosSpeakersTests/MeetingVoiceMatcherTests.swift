import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// MeetingVoiceMatcher (docs/meeting-design.md §4.10, "Voices within one meeting"), on synthetic runs and embeddings.

// MARK: - Fixture

private let matchDate = Date(timeIntervalSince1970: 1_790_000_000)

/// One turn: its ID, diarizer speaker, track, start, length, and voice (unnormalized; the fixture normalizes it).
private struct MatchTurn {
    var id: String
    var speaker: String
    var start: Double
    var seconds = 4.0
    var voice: [Float]
    var track = "system"
    var overlap = false
}

/// A run with one three-word segment per turn, the projection with `edits` applied, and each turn's embedding.
private func matchFixture(_ specs: [MatchTurn], edits: [SpeakerEditAction] = [],
                          names: [String: String] = ["JIM": "Jim", "SAM": "Sam"])
    -> (projection: SpeakerProjection, embeddings: [String: TurnEmbedding]) {
    let segments = specs.map { spec -> TranscriptSegment in
        var text = ""
        var words: [TimedWord] = []
        let step = spec.seconds / 3
        for index in 0..<3 {
            if index > 0 { text += " " }
            let token = "w\(index)"
            let start = spec.start + Double(index) * step
            words.append(TimedWord(text: token, start: start, end: start + step * 0.9,
                                   utf16Offset: text.utf16.count, utf16Length: token.utf16.count))
            text += token
        }
        return TranscriptSegment(id: "seg-\(spec.id)", start: spec.start, end: spec.start + spec.seconds, text: text,
                                 words: words, track: spec.track)
    }
    let transcript = Transcript(id: "TRANSCRIPT", createdAt: matchDate, source: "fixture", locale: "en-CA",
                                backend: .speech, segments: segments)
    let speakers = Array(Set(specs.map(\.speaker))).sorted().enumerated().map { index, id in
        SessionSpeaker(id: id, ordinal: index + 1, provenance: .diarizer, clusterIDs: [id])
    }
    let tracks = Array(Set(specs.map(\.track))).sorted().map { TrackDiarization(track: $0, policy: .diarized) }
    let run = DiarizationRun(
        id: "RUN", sessionID: "SESSION", createdAt: matchDate, transcriptID: "TRANSCRIPT", engine: .fake,
        alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: tracks, speakers: speakers,
        turns: specs.map { spec in
            SpeakerTurn(id: spec.id, track: spec.track, start: spec.start, end: spec.start + spec.seconds,
                        speakerID: spec.speaker, clusterID: spec.speaker,
                        spans: [WordSpan(segmentID: "seg-\(spec.id)", first: 0, end: 3)], overlap: spec.overlap,
                        assignmentScore: 0.9, timing: .measured)
        })
    let journal = edits.map { SpeakerEdit(baseRunID: "RUN", at: matchDate, source: "test", action: $0) }
    let projection = SpeakerProjection.make(run: run, transcript: transcript, edits: journal, recognition: nil,
                                            profileNames: names)
    var embeddings: [String: TurnEmbedding] = [:]
    for spec in specs {
        embeddings[spec.id] = TurnEmbedding(turnID: spec.id, speechSeconds: spec.seconds,
                                            vector: FloatVector(VectorMath.normalized(spec.voice)))
    }
    return (projection, embeddings)
}

/// A unit voice at cosine distance `distance` from [1, 0, 0, 0], in the plane of the first two axes.
private func voice(at distance: Double) -> [Float] {
    let cosine = 1 - distance
    return [Float(cosine), Float((1 - cosine * cosine).squareRoot()), 0, 0]
}

private let jimVoice: [Float] = [1, 0, 0, 0]
private let otherVoice: [Float] = [0, 0, 1, 0]
private let s1 = "system:S1"
private let s2 = "system:S2"
private let s3 = "system:S3"
private let s4 = "system:S4"
private let linkJim: [SpeakerEditAction] = [.linkProfile(speakerID: s1, profileID: "JIM"), .rename(speakerID: s1, name: "Jim")]

private func match(_ fixture: (projection: SpeakerProjection, embeddings: [String: TurnEmbedding]),
                   thresholds: MeetingVoiceThresholds = .defaults) -> MeetingVoiceMatches {
    MeetingVoiceMatcher.match(projection: fixture.projection, embeddings: fixture.embeddings, thresholds: thresholds)
}

// MARK: - Thresholds

@Test func meetingThresholdsAreCappedBelowRecognitions() {
    let defaults = MeetingVoiceThresholds.defaults
    #expect(defaults.suggestMaxDistance == 0.35, "Recognition's 0.43 is capped for voices of one meeting.")
    #expect(defaults.mergeMaxDistance == 0.15)
    #expect(defaults.turnHintMaxDistance == 0.30)
    #expect(defaults.ambiguityMargin == 0.05)

    let calibrated = RecognitionThresholds(likelyMaxDistance: 0.10, likelyMinMargin: 0.1, possibleMaxDistance: 0.25,
                                           minSampleSeconds: 20)
    let derived = MeetingVoiceThresholds.derived(from: calibrated, calibrated: true)
    #expect(derived.suggestMaxDistance == 0.25, "A calibration tighter than the cap is followed.")
    #expect(derived.mergeMaxDistance == 0.10, "The calibrated likely distance bounds automatic merges.")
    #expect(derived.turnHintMaxDistance == 0.25, "A turn hint never reaches past a suggestion.")

    let uncalibrated = MeetingVoiceThresholds.derived(from: calibrated, calibrated: false)
    #expect(uncalibrated.mergeMaxDistance == 0.15, "An uncalibrated likely distance is not used.")

    // A calibration that refuses even a distance of 0 (negative thresholds) is followed, not replaced.
    let refusing = MeetingVoiceThresholds.derived(
        from: RecognitionThresholds(likelyMaxDistance: -0.01, likelyMinMargin: 0.1, possibleMaxDistance: -0.01,
                                    minSampleSeconds: 20), calibrated: true)
    #expect(refusing.suggestMaxDistance < 0 && refusing.mergeMaxDistance < 0 && refusing.turnHintMaxDistance < 0)
    let fixture = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: jimVoice),
    ], edits: linkJim)
    #expect(match(fixture, thresholds: refusing) == .empty)
}

@Test func aForgottenPersonIsNoAnchor() {
    let fixture = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: jimVoice),
    ], edits: linkJim)
    #expect(MeetingVoiceMatcher.match(projection: fixture.projection, embeddings: fixture.embeddings,
                                      thresholds: .defaults, people: ["JIM"]).suggestion(for: s2) != nil)
    #expect(MeetingVoiceMatcher.match(projection: fixture.projection, embeddings: fixture.embeddings,
                                      thresholds: .defaults, people: ["SAM"]) == .empty,
            "Jim was forgotten: the meeting keeps the name, but nobody could confirm him.")
}

@Test func meetingThresholdsFollowTheStoreOnlyForItsModel() {
    var database = SpeakerProfileDatabase(rememberVoices: true, profiles: [])
    database.calibratedThresholds = RecognitionThresholds(likelyMaxDistance: 0.12, likelyMinMargin: 0.1,
                                                          possibleMaxDistance: 0.30, minSampleSeconds: 20)
    database.calibratedModel = DiarizationEngineInfo.fake.embeddingModel
    let same = MeetingVoiceThresholds.derived(database: database, model: DiarizationEngineInfo.fake.embeddingModel)
    #expect(same.suggestMaxDistance == 0.30 && same.mergeMaxDistance == 0.12)
    let other = MeetingVoiceThresholds.derived(database: database,
                                               model: EmbeddingModelID(id: "other", revision: "1"))
    #expect(other == .defaults)
    #expect(MeetingVoiceThresholds.derived(database: nil, model: nil) == .defaults)
}

// MARK: - Speakers

@Test func aSpeakerSplitFromANamedOneIsSuggested() {
    let fixture = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: [1, 0.1, 0, 0]),
        MatchTurn(id: "T3", speaker: s3, start: 10, voice: otherVoice),
        MatchTurn(id: "T4", speaker: s1, start: 15, voice: jimVoice),
        MatchTurn(id: "T5", speaker: s2, start: 20, voice: [1, 0, 0.1, 0]),
        MatchTurn(id: "T6", speaker: s3, start: 25, voice: otherVoice),
        MatchTurn(id: "T7", speaker: s4, start: 30, voice: [0.98, 0.2, 0, 0]),
    ], edits: linkJim)
    let matches = match(fixture)
    #expect(matches.suggestions.map(\.speakerID) == [s2, s4], "Both parts split off Jim are suggested; S3 is not.")
    let suggestion = matches.suggestion(for: s2)
    #expect(suggestion?.profileID == "JIM")
    #expect(suggestion?.profileName == "Jim")
    #expect(suggestion?.anchorSpeakerID == s1)
    #expect(suggestion?.match.tier == .possible)
    #expect(matches.suggestion(for: s1) == nil, "The named speaker itself is not suggested.")
    #expect(matches.turnHints.isEmpty)
}

@Test func onlyVoicesWithinTheThresholdAreSuggested() {
    for (distance, expected) in [(0.34, true), (0.36, false)] {
        let fixture = matchFixture([
            MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
            MatchTurn(id: "T2", speaker: s2, start: 5, voice: voice(at: distance)),
        ], edits: linkJim)
        #expect((match(fixture).suggestion(for: s2) != nil) == expected, "distance \(distance)")
    }
}

@Test func nothingIsSuggestedBeforeAnybodyIsNamed() {
    let fixture = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: jimVoice),
    ])
    #expect(match(fixture) == .empty)
    // A name with no person behind it (renamed only) is not an anchor either.
    let renamed = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: jimVoice),
    ], edits: [.rename(speakerID: s1, name: "Jim")])
    #expect(match(renamed) == .empty)
}

@Test func notJimStopsJimBeingSuggestedAgain() {
    let fixture = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: jimVoice),
        MatchTurn(id: "T3", speaker: s2, start: 10, voice: jimVoice),
    ], edits: linkJim + [.rejectProfile(speakerID: s2, profileID: "JIM")])
    let matches = match(fixture)
    #expect(matches.suggestion(for: s2) == nil)
    #expect(matches.turnHints.isEmpty, "Its turns are not flagged as Jim's either.")
}

@Test func aSpeakerBetweenTwoNamedPeopleIsLeftAlone() {
    let loose = MeetingVoiceThresholds(suggestMaxDistance: 0.5, ambiguityMargin: 0.05, mergeMaxDistance: 0.1,
                                       mergeMinSeconds: 10, turnHintMaxDistance: 0.3, turnHintMinMargin: 0.15)
    let linkBoth = linkJim + [.linkProfile(speakerID: s2, profileID: "SAM"), .rename(speakerID: s2, name: "Sam")]
    // 0.275 from Jim and 0.311 from Sam: closer to Jim, but not by the margin.
    let ambiguous = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: [0, 1, 0, 0]),
        MatchTurn(id: "T3", speaker: s3, start: 10, voice: [1, 0.95, 0, 0]),
    ], edits: linkBoth)
    #expect(match(ambiguous, thresholds: loose).suggestion(for: s3) == nil)
    // 0.05 from Jim and 0.69 from Sam.
    let clear = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: [0, 1, 0, 0]),
        MatchTurn(id: "T3", speaker: s3, start: 10, voice: voice(at: 0.05)),
    ], edits: linkBoth)
    #expect(match(clear, thresholds: loose).suggestion(for: s3)?.profileID == "JIM")
}

@Test func namedAndOtherTrackSpeakersAreNotSuggested() {
    let fixture = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: jimVoice),
        MatchTurn(id: "T3", speaker: "mic:S1", start: 10, voice: jimVoice, track: "mic"),
    ], edits: linkJim + [.rename(speakerID: s2, name: "Bob")])
    let matches = match(fixture)
    #expect(matches.suggestion(for: s2) == nil, "A speaker the user named keeps their name.")
    #expect(matches.suggestion(for: "mic:S1") == nil, "Voices are compared on the same track only.")
}

@Test func onlyCloseVoicesOnEnoughSpeechAreMergeable() {
    let close = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, seconds: 6, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s1, start: 7, seconds: 6, voice: jimVoice),
        MatchTurn(id: "T3", speaker: s2, start: 14, seconds: 6, voice: voice(at: 0.05)),
        MatchTurn(id: "T4", speaker: s2, start: 21, seconds: 6, voice: voice(at: 0.05)),
        MatchTurn(id: "T5", speaker: s3, start: 28, seconds: 6, voice: voice(at: 0.25)),
        MatchTurn(id: "T6", speaker: s3, start: 35, seconds: 6, voice: voice(at: 0.25)),
        MatchTurn(id: "T7", speaker: s4, start: 42, seconds: 3, voice: voice(at: 0.05)),
    ], edits: linkJim)
    let matches = match(close)
    #expect(matches.suggestion(for: s2)?.mergeable == true)
    #expect(matches.suggestion(for: s3)?.mergeable == false, "Suggested, but too far to merge without asking.")
    #expect(matches.suggestion(for: s4)?.mergeable == false, "Too little speech to merge without asking.")
}

// MARK: - Turns

@Test func aTurnInsideAMixedSpeakerIsHinted() {
    let fixture = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: otherVoice),
        MatchTurn(id: "T3", speaker: s2, start: 10, voice: otherVoice),
        MatchTurn(id: "T4", speaker: s2, start: 15, voice: [0.99, 0, 0.1, 0]),
        MatchTurn(id: "T5", speaker: s2, start: 20, voice: [0, 0.1, 1, 0]),
        MatchTurn(id: "T6", speaker: s1, start: 25, voice: jimVoice),
    ], edits: linkJim)
    let matches = match(fixture)
    #expect(matches.suggestion(for: s2) == nil, "Most of S2 is somebody else.")
    #expect(Array(matches.turnHints.keys) == ["T4"])
    let hint = matches.turnHints["T4"]
    #expect(hint?.speakerID == s1)
    #expect(hint?.profileID == "JIM")
    #expect(hint?.name == "Jim")
    #expect((hint?.ownDistance ?? 0) - (hint?.distance ?? 0) >= 0.15)
}

@Test func turnsTooShortOverlappedOrOnTheirOwnAreNotHinted() {
    let fixture = matchFixture([
        MatchTurn(id: "T1", speaker: s1, start: 0, voice: jimVoice),
        MatchTurn(id: "T2", speaker: s2, start: 5, voice: otherVoice),
        MatchTurn(id: "T3", speaker: s2, start: 10, voice: otherVoice),
        MatchTurn(id: "T4", speaker: s2, start: 15, seconds: 1.5, voice: jimVoice),
        MatchTurn(id: "T5", speaker: s2, start: 20, voice: jimVoice, overlap: true),
        MatchTurn(id: "T6", speaker: s3, start: 25, voice: [0.2, 0, 1, 0]),
    ], edits: linkJim)
    #expect(match(fixture).turnHints.isEmpty,
            "Short and overlapped turns do not count, and a one-turn speaker has nothing to compare its turn with.")
}
