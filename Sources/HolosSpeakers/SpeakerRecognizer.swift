import Foundation
import HolosCore

/// Matches a run's speakers against the people with voice samples (docs/meeting-design.md §4.10, post-processing
/// stage 7). Pure: it reads the run's in-memory voice data and the profile database and returns distances only.
///
/// Without calibrated thresholds (`holos people calibrate --apply`) it only suggests names (`possible`, shown as
/// "Maybe Jim — Confirm"); nothing is applied automatically.
public enum SpeakerRecognizer {
    /// likelyMaxDistance 0 (suggestions only), likelyMinMargin 0.10, possibleMaxDistance from PR7c's
    /// calibration, minSampleSeconds 20.
    ///
    /// `possibleMaxDistance` is 0.43 (the design's placeholder was 0.40): PR7c's cross-recording measurement (docs/speaker-evaluation.md, "Calibration")
    /// found the largest threshold that admits at most 5 % of different-person pairs halfway between the two
    /// smallest different-person distances (0.421 and 0.444); every same-person pair (at most 0.244) is below it.
    /// `likelyMaxDistance` is only stored: `likely` needs `calibratedThresholds` whatever the distance.
    public static let defaultThresholds = RecognitionThresholds(
        likelyMaxDistance: 0, likelyMinMargin: 0.10, possibleMaxDistance: 0.43, minSampleSeconds: 20)

    /// §4.10 steps 1–6. `condition(track)`: system → call, mic → room. nil when the run has no engine or
    /// `voiceData` is nil.
    ///
    /// 1. Candidates: the run's diarizer speakers on diarized tracks whose clusters have a centroid in `voiceData`
    ///    (a speaker with several clusters uses their mean).
    /// 2. Profiles: `recognitionEnabled`, with samples, and the run's embedding model; a profile with samples of
    ///    another model is listed in `skippedProfiles`, the rest are left out silently.
    /// 3. Distance(speaker, profile) = the smallest cosine distance to the profile's non-weak samples of the
    ///    speaker's condition; without any, to its other samples, and the tier is capped at `possible`.
    /// 4. Thresholds: `thresholds(database, model:)`: the calibrated ones only when they were measured on the run's
    ///    embedding model (`calibratedModel`), else `defaultThresholds`.
    /// 5. A pair within `possibleMaxDistance` is `possible`; it is `likely` only with calibrated thresholds, a distance
    ///    within `likelyMaxDistance`, the speaker's next-best profile at least `likelyMinMargin` farther, and an
    ///    uncapped tier.
    /// 6. Pairs within `possibleMaxDistance` are assigned one-to-one, greedily in ascending distance (ties by
    ///    speaker ID, then profile ID). Other unassigned speakers within `possibleMaxDistance` of an assigned profile
    ///    join its speaker in a `MergeSuggestion`. Zero-norm vectors have distance 2 and never match.
    ///
    /// Matches and merge suggestions follow the run's speaker order.
    public static func recognize(run: DiarizationRun, voiceData: SessionVoiceData?, database: SpeakerProfileDatabase,
                                 now: Date = Date()) -> RecognitionResult? {
        guard let engine = run.engine, let voiceData else { return nil }
        let model = engine.embeddingModel
        let (thresholds, calibrated) = SpeakerRecognizer.thresholds(database, model: model)

        let candidates = candidates(run: run, voiceData: voiceData)
        let (eligible, skipped) = profiles(database, model: model)

        // Steps 3 and 5: every pair's distance and tier.
        var pairs: [Pair] = []
        for candidate in candidates {
            let distances = eligible.map { distance(candidate, $0) }
            for (index, profile) in eligible.enumerated() {
                let (value, capped) = distances[index]
                guard value <= thresholds.possibleMaxDistance else { continue }
                let nextBest = distances.enumerated().filter { $0.offset != index }.map(\.element.value).min()
                let margin = nextBest.map { $0 - value } ?? .infinity
                let likely = calibrated && !capped && value <= thresholds.likelyMaxDistance
                    && margin >= thresholds.likelyMinMargin
                pairs.append(Pair(speaker: candidate.id, order: candidate.order, profile: profile.id,
                                  name: profile.displayName, distance: value, tier: likely ? .likely : .possible))
            }
        }

        // Step 6: one-to-one greedy assignment, then merge suggestions.
        pairs.sort { ($0.distance, $0.speaker, $0.profile) < ($1.distance, $1.speaker, $1.profile) }
        var bySpeaker: [String: Pair] = [:]
        var byProfile: [String: Pair] = [:]
        for pair in pairs where bySpeaker[pair.speaker] == nil && byProfile[pair.profile] == nil {
            bySpeaker[pair.speaker] = pair
            byProfile[pair.profile] = pair
        }
        let matches = bySpeaker.values.sorted { ($0.order, $0.speaker) < ($1.order, $1.speaker) }
        var suggestions: [MergeSuggestion] = []
        for match in matches {
            let others = pairs.filter { $0.profile == match.profile && $0.speaker != match.speaker
                && bySpeaker[$0.speaker] == nil }
            guard !others.isEmpty else { continue }
            let members = ([match] + others).sorted { ($0.order, $0.speaker) < ($1.order, $1.speaker) }
            suggestions.append(MergeSuggestion(speakerIDs: members.map(\.speaker), profileID: match.profile))
        }
        return RecognitionResult(
            runID: run.id, createdAt: now, embeddingModel: model, thresholds: thresholds,
            matches: matches.map {
                SpeakerMatch(speakerID: $0.speaker, profileID: $0.profile, profileName: $0.name,
                             distance: $0.distance, tier: $0.tier)
            },
            mergeSuggestions: suggestions, skippedProfiles: skipped)
    }

    /// Step 4: the thresholds for a run of `model`, and whether they are calibrated. Calibrated thresholds apply only
    /// to the embedding model they were measured on (distances of different models are not comparable).
    public static func thresholds(_ database: SpeakerProfileDatabase,
                                  model: EmbeddingModelID?) -> (thresholds: RecognitionThresholds, calibrated: Bool) {
        guard let calibrated = database.calibratedThresholds(for: model) else { return (defaultThresholds, false) }
        return (calibrated, true)
    }

    /// Step 2: the people a run of `model` is compared with (`recognitionEnabled`, with samples, of `model`), and the
    /// IDs of those skipped because their samples are of another model. A caller that rereads the store before saving
    /// a result keeps only what these still allow.
    public static func profiles(_ database: SpeakerProfileDatabase,
                                model: EmbeddingModelID) -> (eligible: [SpeakerProfile], skipped: [String]) {
        var eligible: [SpeakerProfile] = []
        var skipped: [String] = []
        for profile in database.profiles where profile.recognitionEnabled && !profile.samples.isEmpty {
            if profile.embeddingModel == model {
                eligible.append(profile)
            } else {
                skipped.append(profile.id)
            }
        }
        return (eligible, skipped)
    }

    // MARK: - Private

    private struct Candidate {
        let id: String
        let order: Int
        let condition: RecordingCondition
        let vector: [Float]
    }

    private struct Pair {
        let speaker: String
        let order: Int
        let profile: String
        let name: String
        let distance: Double
        let tier: RecognitionTier
    }

    /// Step 1.
    private static func candidates(run: DiarizationRun, voiceData: SessionVoiceData) -> [Candidate] {
        var clusterTracks: [String: String] = [:]
        var diarizedTracks = Set<String>()
        for track in run.tracks {
            if case .diarized = track.policy { diarizedTracks.insert(track.track) }
            for cluster in track.clusters { clusterTracks[cluster.clusterID] = track.track }
            for segment in track.segments where clusterTracks[segment.clusterID] == nil {
                clusterTracks[segment.clusterID] = track.track
            }
        }
        var result: [Candidate] = []
        for (order, speaker) in run.speakers.enumerated() where speaker.provenance == .diarizer {
            let clusters = speaker.clusterIDs.filter { voiceData.centroids[$0] != nil }
            guard let first = clusters.first else { continue }
            let track = clusterTracks[first] ?? String(first.prefix { $0 != ":" })
            guard diarizedTracks.contains(track) else { continue }
            let vectors = clusters.compactMap { voiceData.centroids[$0]?.values }
            let vector = vectors.count == 1 ? vectors[0] : VectorMath.weightedMean(vectors.map { ($0, 1) }) ?? []
            result.append(Candidate(id: speaker.id, order: order, condition: RecordingCondition(track: track),
                                    vector: vector))
        }
        return result
    }

    /// Step 3: the distance and whether the tier is capped at `possible`.
    private static func distance(_ candidate: Candidate, _ profile: SpeakerProfile) -> (value: Double, capped: Bool) {
        let preferred = profile.samples.filter { !$0.weak && $0.condition == candidate.condition }
        let pool = preferred.isEmpty ? profile.samples : preferred
        let value = pool.map { VectorMath.cosineDistance(candidate.vector, $0.embedding.values) }.min() ?? 2
        return (value, preferred.isEmpty)
    }
}
