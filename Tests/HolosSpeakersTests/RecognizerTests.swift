import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// SpeakerRecognizer (docs/meeting-design.md §4.10 "Recognition", §5.9 tests), on synthetic unit vectors.

// MARK: - Fixture

private let model = EmbeddingModelID(id: "fake", revision: "1")
private let date = Date(timeIntervalSince1970: 1_790_000_000)

/// Unit vector along `axis` of 8.
private func axis(_ index: Int) -> [Float] {
    var values = [Float](repeating: 0, count: 8)
    values[index] = 1
    return values
}

/// A unit vector at cosine distance `distance` from axis 0, leaning towards axis `towards`.
private func away(_ distance: Double, towards other: Int) -> [Float] {
    let cosine = 1 - distance
    var values = [Float](repeating: 0, count: 8)
    values[0] = Float(cosine)
    values[other] = Float((1 - cosine * cosine).squareRoot())
    return values
}

/// A run whose diarized speakers are `speakers` (ID, track), each one cluster with the same ID.
private func recognizerRun(_ speakers: [(id: String, track: String)], engine: Bool = true) -> DiarizationRun {
    let tracks = Array(Set(speakers.map(\.track))).sorted().map { track in
        TrackDiarization(track: track, policy: .diarized,
                         clusters: speakers.filter { $0.track == track }.map {
                             ClusterSummary(clusterID: $0.id, track: track, speechSeconds: 60)
                         })
    }
    return DiarizationRun(
        id: "RUN", sessionID: "SESSION", createdAt: date, transcriptID: "TRANSCRIPT",
        engine: engine ? .fake : nil, alignment: AlignmentInfo(version: 1, parameters: .v1), tracks: tracks,
        speakers: speakers.enumerated().map { index, speaker in
            SessionSpeaker(id: speaker.id, ordinal: index + 1, provenance: .diarizer, clusterIDs: [speaker.id])
        },
        turns: [])
}

private func voiceData(_ centroids: [String: [Float]]) -> SessionVoiceData {
    SessionVoiceData(runID: "RUN", sessionID: "SESSION", createdAt: date, embeddingModel: model,
                     centroids: centroids.mapValues { FloatVector($0) }, turnEmbeddings: [])
}

private func sample(_ vector: [Float], condition: RecordingCondition = .call, weak: Bool = false,
                    session: String = UUID().uuidString) -> VoiceprintSample {
    VoiceprintSample(sessionID: session, sessionName: "Earlier meeting", speakerIDs: ["system:S1"],
                     speechSeconds: weak ? 10 : 60, embedding: FloatVector(vector), condition: condition, weak: weak,
                     addedAt: date)
}

private func person(_ id: String, _ samples: [VoiceprintSample], model: EmbeddingModelID? = model,
                    suggestions: Bool = true) -> SpeakerProfile {
    SpeakerProfile(id: id, displayName: id.capitalized, createdAt: date, embeddingModel: samples.isEmpty ? nil : model,
                   recognitionEnabled: suggestions, samples: samples)
}

private let calibrated = RecognitionThresholds(likelyMaxDistance: 0.25, likelyMinMargin: 0.10,
                                               possibleMaxDistance: 0.43, minSampleSeconds: 20)

private func database(_ profiles: [SpeakerProfile], thresholds: RecognitionThresholds? = nil) -> SpeakerProfileDatabase {
    SpeakerProfileDatabase(rememberVoices: true, calibratedThresholds: thresholds, profiles: profiles)
}

private let oneSpeaker = recognizerRun([("system:S1", "system")])
private let oneCentroid = voiceData(["system:S1": axis(0)])

// MARK: - Tiers

@Test func likelyIsOffByDefault() throws {
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid, database: database([person("jim", [sample(away(0.10, towards: 1))])]),
        now: date))
    let match = try #require(result.matches.first)
    #expect(match.profileID == "jim")
    #expect(match.tier == .possible)
    #expect(abs(match.distance - 0.10) < 1e-4)
    #expect(result.thresholds == SpeakerRecognizer.defaultThresholds)
    #expect(SpeakerRecognizer.defaultThresholds.likelyMaxDistance == 0)
    #expect(SpeakerRecognizer.defaultThresholds.likelyMinMargin == 0.10)
    #expect(SpeakerRecognizer.defaultThresholds.minSampleSeconds == 20)
}

@Test func likelyNeedsCalibrationDistanceAndMargin() throws {
    let profiles = [person("jim", [sample(away(0.20, towards: 1))]), person("maria", [sample(away(0.28, towards: 2))])]
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid, database: database(profiles, thresholds: calibrated), now: date))
    #expect(result.matches.map(\.profileID) == ["jim"])
    #expect(result.matches.first?.tier == .possible, "The margin to Maria is 0.08, under 0.10.")
}

@Test func likelyWhenCalibratedAndClear() throws {
    let profiles = [person("jim", [sample(away(0.20, towards: 1))]), person("maria", [sample(away(0.60, towards: 2))])]
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid, database: database(profiles, thresholds: calibrated), now: date))
    #expect(result.matches.map(\.profileID) == ["jim"])
    #expect(result.matches.first?.tier == .likely)
    #expect(result.thresholds == calibrated)
}

@Test func possibleBelowThreshold() throws {
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid, database: database([person("jim", [sample(away(0.35, towards: 1))])]),
        now: date))
    #expect(result.matches.map(\.tier) == [.possible])
}

@Test func noMatchAboveThreshold() throws {
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid, database: database([person("jim", [sample(away(0.45, towards: 1))])]),
        now: date))
    #expect(result.matches.isEmpty)
    #expect(result.mergeSuggestions.isEmpty)
}

@Test func identicalVectorIsOnlyPossibleUntilCalibrated() throws {
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid, database: database([person("jim", [sample(axis(0))])]), now: date))
    let match = try #require(result.matches.first)
    #expect(match.distance < 1e-6)
    #expect(match.tier == .possible, "Without calibrated thresholds nothing is applied automatically.")
}

@Test func weakOrOtherConditionCapsAtPossible() throws {
    // Only weak samples, close enough and clear enough to be likely otherwise.
    let weak = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid,
        database: database([person("jim", [sample(away(0.10, towards: 1), weak: true)])], thresholds: calibrated),
        now: date))
    #expect(weak.matches.map(\.tier) == [.possible])

    // Only call samples for a speaker on the microphone (room).
    let room = recognizerRun([("mic:S1", "mic")])
    let other = try #require(SpeakerRecognizer.recognize(
        run: room, voiceData: voiceData(["mic:S1": axis(0)]),
        database: database([person("jim", [sample(away(0.10, towards: 1), condition: .call)])],
                           thresholds: calibrated),
        now: date))
    #expect(other.matches.map(\.tier) == [.possible])

    // A same-condition, non-weak sample of the same person lifts the cap.
    let both = try #require(SpeakerRecognizer.recognize(
        run: room, voiceData: voiceData(["mic:S1": axis(0)]),
        database: database([person("jim", [sample(away(0.30, towards: 2), condition: .room),
                                           sample(away(0.05, towards: 1), condition: .call)])],
                           thresholds: calibrated),
        now: date))
    let match = try #require(both.matches.first)
    #expect(abs(match.distance - 0.30) < 1e-4, "Room samples are preferred for a room speaker.")
    #expect(match.tier == .possible, "0.30 is above the calibrated likely distance.")
}

// MARK: - Assignment

@Test func assignmentIsOneToOne() throws {
    // Jim's sample is axis 0; S1 is at 0.2 from it and S2 at 0.3. Maria is at 0.35 from S2 and far from S1.
    let run = recognizerRun([("system:S1", "system"), ("system:S2", "system")])
    let s1 = away(0.2, towards: 1)
    let s2 = away(0.3, towards: 2)
    var maria = [Float](repeating: 0, count: 8)
    let y = Float(0.65 / (1 - 0.7 * 0.7).squareRoot())
    maria[2] = y
    maria[3] = (1 - y * y).squareRoot()
    let voice = voiceData(["system:S1": s1, "system:S2": s2])

    let withMaria = try #require(SpeakerRecognizer.recognize(
        run: run, voiceData: voice,
        database: database([person("jim", [sample(axis(0))]), person("maria", [sample(maria)])]), now: date))
    #expect(withMaria.matches.map(\.speakerID) == ["system:S1", "system:S2"])
    #expect(withMaria.matches.map(\.profileID) == ["jim", "maria"])
    #expect(withMaria.mergeSuggestions.isEmpty, "S2 is assigned to Maria, so it is not offered as Jim.")

    let jimOnly = try #require(SpeakerRecognizer.recognize(
        run: run, voiceData: voice, database: database([person("jim", [sample(axis(0))])]), now: date))
    #expect(jimOnly.matches.map(\.speakerID) == ["system:S1"])
    #expect(jimOnly.matches.map(\.profileID) == ["jim"])
}

@Test func twoSpeakersOneProfileSuggestMerge() throws {
    let run = recognizerRun([("system:S1", "system"), ("system:S2", "system")])
    let voice = voiceData(["system:S1": away(0.2, towards: 1), "system:S2": away(0.3, towards: 2)])
    let result = try #require(SpeakerRecognizer.recognize(
        run: run, voiceData: voice, database: database([person("jim", [sample(axis(0))])]), now: date))
    #expect(result.matches.map(\.speakerID) == ["system:S1"])
    #expect(result.mergeSuggestions == [MergeSuggestion(speakerIDs: ["system:S1", "system:S2"], profileID: "jim")])
}

@Test func crossModelProfilesSkipped() throws {
    let other = EmbeddingModelID(id: "other", revision: "2")
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid,
        database: database([person("jim", [sample(axis(0))], model: other), person("maria", [sample(axis(0))])]),
        now: date))
    #expect(result.skippedProfiles == ["jim"])
    #expect(result.matches.map(\.profileID) == ["maria"])
    #expect(result.embeddingModel == model)
}

@Test func profilesWithoutSamplesAreNotCandidates() throws {
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: oneCentroid,
        database: database([person("sam", []), person("off", [sample(axis(0))], suggestions: false)]), now: date))
    #expect(result.matches.isEmpty)
    #expect(result.skippedProfiles.isEmpty)
}

@Test func zeroNormVectorsNeverMatch() throws {
    let result = try #require(SpeakerRecognizer.recognize(
        run: oneSpeaker, voiceData: voiceData(["system:S1": [Float](repeating: 0, count: 8)]),
        database: database([person("jim", [sample(axis(0))])]), now: date))
    #expect(result.matches.isEmpty)
}

@Test func recognitionNeedsAnEngineAndVoiceData() {
    let profiles = database([person("jim", [sample(axis(0))])])
    #expect(SpeakerRecognizer.recognize(run: recognizerRun([("system:S1", "system")], engine: false),
                                        voiceData: oneCentroid, database: profiles) == nil)
    #expect(SpeakerRecognizer.recognize(run: oneSpeaker, voiceData: nil, database: profiles) == nil)
}

@Test func channelSpeakersAreNotCandidates() throws {
    var run = recognizerRun([("system:S1", "system")])
    run.tracks.append(TrackDiarization(track: "mic", policy: .channel(speakerID: "mic:me", displayName: "Me")))
    run.speakers.append(SessionSpeaker(id: "mic:me", ordinal: 2, displayName: "Me", provenance: .channelAssumption))
    let result = try #require(SpeakerRecognizer.recognize(
        run: run, voiceData: voiceData(["system:S1": away(0.9, towards: 1), "mic:me": axis(0)]),
        database: database([person("jim", [sample(axis(0))])]), now: date))
    #expect(result.matches.isEmpty)
}
