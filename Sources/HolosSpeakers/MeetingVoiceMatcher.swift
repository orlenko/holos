import Foundation
import HolosCore

/// How close two voices of one meeting must be for the review window to say so (docs/meeting-design.md §4.10,
/// "Voices within one meeting"). Cosine distances between speech-weighted mean turn embeddings of the same pass.
public struct MeetingVoiceThresholds: Sendable, Equatable {
    /// A speaker whose voice is this close to a named person's voice in the same meeting is suggested as them.
    public var suggestMaxDistance: Double
    /// …unless another named person is within this much of that distance (then it is left alone).
    public var ambiguityMargin: Double
    /// A suggestion this close may be merged automatically (when the review's setting asks for it)…
    public var mergeMaxDistance: Double
    /// …when both voices rest on at least this much speech.
    public var mergeMinSeconds: Double
    /// A turn this close to a named person's voice…
    public var turnHintMaxDistance: Double
    /// …and at least this much closer to them than to the rest of its own speaker is flagged ("sounds like Jim").
    public var turnHintMinMargin: Double

    public init(suggestMaxDistance: Double, ambiguityMargin: Double, mergeMaxDistance: Double,
                mergeMinSeconds: Double, turnHintMaxDistance: Double, turnHintMinMargin: Double) {
        self.suggestMaxDistance = suggestMaxDistance; self.ambiguityMargin = ambiguityMargin
        self.mergeMaxDistance = mergeMaxDistance; self.mergeMinSeconds = mergeMinSeconds
        self.turnHintMaxDistance = turnHintMaxDistance; self.turnHintMinMargin = turnHintMinMargin
    }

    /// Within one meeting a suggestion never reaches past this, whatever recognition allows across meetings: in the
    /// user's own meeting two different people's clusters were 0.41 apart, and the cross-recording measurement put
    /// every same-person pair at 0.244 or less (docs/speaker-evaluation.md).
    public static let suggestCap = 0.35
    /// A merge without asking needs voices closer than the diarizer's own clustering threshold (0.6 Euclidean on unit
    /// vectors, about 0.18 cosine), so it only joins what the diarizer should have joined itself.
    public static let mergeCap = 0.15
    /// A single turn is noisier than a speaker's mean: its own speaker's turns lie within 0.33 of that mean for nine
    /// turns in ten in the user's meeting, and other speakers start at 0.42.
    public static let turnHintCap = 0.30

    /// The thresholds from recognition's (`SpeakerRecognizer.thresholds`): calibrated ones when `calibrated`.
    ///
    /// - `suggestMaxDistance`: recognition's `possibleMaxDistance` (at most 5 % of different-person pairs across
    ///   meetings when calibrated), capped at `suggestCap`.
    /// - `mergeMaxDistance`: `mergeCap`, or the calibrated `likelyMaxDistance` (at most 1 % of different-person pairs)
    ///   when that is lower; never above `suggestMaxDistance`.
    /// - `turnHintMaxDistance`: `turnHintCap`, never above `suggestMaxDistance`.
    public static func derived(from recognition: RecognitionThresholds, calibrated: Bool) -> MeetingVoiceThresholds {
        // A calibrated threshold may be negative on purpose (`RecognitionCalibration.admitting`: even a distance of 0
        // is refused), so only a value that is not finite is left out.
        func usable(_ value: Double) -> Double? { value.isFinite ? value : nil }
        let suggest = min(usable(recognition.possibleMaxDistance) ?? suggestCap, suggestCap)
        var merge = mergeCap
        if calibrated, let likely = usable(recognition.likelyMaxDistance) { merge = min(merge, likely) }
        return MeetingVoiceThresholds(suggestMaxDistance: suggest, ambiguityMargin: 0.05,
                                      mergeMaxDistance: min(merge, suggest), mergeMinSeconds: 10,
                                      turnHintMaxDistance: min(turnHintCap, suggest), turnHintMinMargin: 0.15)
    }

    /// `derived(from:calibrated:)` with the people store's thresholds for runs of `model`.
    public static func derived(database: SpeakerProfileDatabase?, model: EmbeddingModelID?) -> MeetingVoiceThresholds {
        guard let database else { return defaults }
        let (thresholds, calibrated) = SpeakerRecognizer.thresholds(database, model: model)
        return derived(from: thresholds, calibrated: calibrated)
    }

    /// Without calibration.
    public static let defaults = derived(from: SpeakerRecognizer.defaultThresholds, calibrated: false)
}

/// "Maybe Jim" for a speaker whose voice sounds like a person the user named in the same meeting.
public struct MeetingVoiceSuggestion: Sendable, Equatable {
    public let speakerID: String
    public let profileID: String
    /// The person's name as the meeting shows it.
    public let profileName: String
    /// The named speaker whose voice matched: where an automatic merge sends this speaker's turns.
    public let anchorSpeakerID: String
    public let distance: Double
    /// Close enough, on enough speech, to be merged without asking (`MeetingVoiceThresholds.mergeMaxDistance`).
    public let mergeable: Bool

    public init(speakerID: String, profileID: String, profileName: String, anchorSpeakerID: String, distance: Double,
                mergeable: Bool) {
        self.speakerID = speakerID; self.profileID = profileID; self.profileName = profileName
        self.anchorSpeakerID = anchorSpeakerID; self.distance = distance; self.mergeable = mergeable
    }

    /// As the sidebar shows a recognition suggestion.
    public var match: SpeakerMatch {
        SpeakerMatch(speakerID: speakerID, profileID: profileID, profileName: profileName, distance: distance,
                     tier: .possible)
    }
}

/// "⚠ sounds like Jim" for one turn inside another speaker whose voice matches a named person better than it matches
/// the rest of its own speaker.
public struct MeetingTurnHint: Sendable, Equatable {
    public let turnID: String
    /// The named speaker to give the turn to.
    public let speakerID: String
    public let profileID: String
    public let name: String
    public let distance: Double
    /// The turn's distance to the rest of its own speaker.
    public let ownDistance: Double

    public init(turnID: String, speakerID: String, profileID: String, name: String, distance: Double,
                ownDistance: Double) {
        self.turnID = turnID; self.speakerID = speakerID; self.profileID = profileID; self.name = name
        self.distance = distance; self.ownDistance = ownDistance
    }
}

/// What `MeetingVoiceMatcher.match` found.
public struct MeetingVoiceMatches: Sendable, Equatable {
    /// In speaker order; at most one per speaker.
    public var suggestions: [MeetingVoiceSuggestion]
    /// By turn ID.
    public var turnHints: [String: MeetingTurnHint]

    public init(suggestions: [MeetingVoiceSuggestion] = [], turnHints: [String: MeetingTurnHint] = [:]) {
        self.suggestions = suggestions; self.turnHints = turnHints
    }

    public static let empty = MeetingVoiceMatches()

    public func suggestion(for speakerID: String) -> MeetingVoiceSuggestion? {
        suggestions.first { $0.speakerID == speakerID }
    }
}

/// Compares the voices of one meeting's speakers with the people named in it (docs/meeting-design.md §4.10, "Voices
/// within one meeting"). Pure: the turn embeddings come from the review window's in-memory cache, and nothing here
/// is stored.
///
/// - A turn counts when it has a speaker, lasts at least `VoiceEnrollment.minimumTurnSeconds`, is not overlapped,
///   not produced by a split, not excluded from voice learning, and has a finite embedding.
/// - A voice is the speech-weighted mean of its turns on one track, L2-normalized, after one outlier pass (turns
///   more than `VoiceEnrollment.outlierDistance` from the first mean are left out), as enrollment builds a sample.
///   Voices are compared only on the same track: the microphone and a call's system audio sound different.
/// - Named people ("anchors") are the people speakers are linked to (a name typed in the review links one); an
///   automatic name, or a name with no person, is not an anchor.
/// - Suggestions go to speakers with no name, no link, and no automatic name, never a channel speaker ("Me"): the
///   person whose voice is nearest, within `suggestMaxDistance`, with no other person within `ambiguityMargin` of
///   it, and not one the speaker rejected ("Not Jim").
/// - A turn hint goes to a turn whose voice is within `turnHintMaxDistance` of a person its speaker is not linked
///   to, has not rejected, and is not suggested as, and at least `turnHintMinMargin` closer to them than to the rest
///   of its own speaker (its speaker's voice without it); with no other person within `ambiguityMargin`.
public enum MeetingVoiceMatcher {
    /// `people`: when given, only speakers linked to these people are anchors (a person forgotten since keeps the
    /// meeting's link and name, but cannot be confirmed any more).
    public static func match(projection: SpeakerProjection, embeddings: [String: TurnEmbedding],
                             thresholds: MeetingVoiceThresholds, people: Set<String>? = nil) -> MeetingVoiceMatches {
        let speakers = Dictionary(projection.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var dimension: Int?
        var bySpeaker: [TrackKey: [Item]] = [:]
        var byPerson: [TrackKey: [Item]] = [:]
        for turn in projection.turns {
            guard let speakerID = turn.speakerID, let speaker = speakers[speakerID], usable(turn),
                  let values = embeddings[turn.id]?.vector.values, !values.isEmpty,
                  values.allSatisfy(\.isFinite) else { continue }
            if dimension == nil { dimension = values.count }
            guard values.count == dimension else { continue }
            let item = Item(turnID: turn.id, speakerID: speakerID, vector: values, seconds: turn.end - turn.start)
            bySpeaker[TrackKey(owner: speakerID, track: turn.track), default: []].append(item)
            if let profileID = speaker.profileID, people?.contains(profileID) ?? true {
                byPerson[TrackKey(owner: profileID, track: turn.track), default: []].append(item)
            }
        }
        let speakerVoices = bySpeaker.compactMapValues(Voice.init)
        let personVoices = byPerson.compactMapValues(Voice.init)
        let names = Dictionary(projection.speakers.compactMap { speaker in speaker.profileID.map { ($0, speaker.name) } },
                               uniquingKeysWith: { first, _ in first })

        /// The nearest person on `track` to `vector` among those `allowed` lets through, with the distance of the
        /// next one; nil when none.
        func nearest(_ vector: [Float], track: String, allowed: (String) -> Bool)
            -> (profileID: String, distance: Double, runnerUp: Double)? {
            var ranked: [(profileID: String, distance: Double)] = []
            for (key, voice) in personVoices where key.track == track && allowed(key.owner) {
                ranked.append((key.owner, VectorMath.cosineDistance(vector, voice.mean)))
            }
            ranked.sort { ($0.distance, $0.profileID) < ($1.distance, $1.profileID) }
            guard let best = ranked.first else { return nil }
            return (best.profileID, best.distance, ranked.dropFirst().first?.distance ?? .infinity)
        }

        /// The speaker of `profileID` with the most counted speech on `track`: where its turns go.
        func anchor(_ profileID: String, track: String) -> String? {
            guard let voice = personVoices[TrackKey(owner: profileID, track: track)] else { return nil }
            var seconds: [String: Double] = [:]
            for item in voice.items { seconds[item.speakerID, default: 0] += item.seconds }
            return seconds.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }

        // Speakers.
        var suggestions: [MeetingVoiceSuggestion] = []
        for speaker in projection.speakers where isCandidate(speaker) {
            var best: (profileID: String, distance: Double, runnerUp: Double, track: String, seconds: Double)?
            for (key, voice) in speakerVoices where key.owner == speaker.id {
                guard let found = nearest(voice.mean, track: key.track,
                                          allowed: { !speaker.rejectedProfileIDs.contains($0) }) else { continue }
                if let current = best, (current.distance, current.track) <= (found.distance, key.track) { continue }
                best = (found.profileID, found.distance, found.runnerUp, key.track, voice.seconds)
            }
            guard let best, best.distance <= thresholds.suggestMaxDistance,
                  best.runnerUp - best.distance >= thresholds.ambiguityMargin,
                  let anchorID = anchor(best.profileID, track: best.track),
                  let anchorVoice = personVoices[TrackKey(owner: best.profileID, track: best.track)] else { continue }
            let mergeable = best.distance <= thresholds.mergeMaxDistance
                && best.seconds >= thresholds.mergeMinSeconds && anchorVoice.seconds >= thresholds.mergeMinSeconds
            suggestions.append(MeetingVoiceSuggestion(
                speakerID: speaker.id, profileID: best.profileID, profileName: names[best.profileID] ?? speaker.name,
                anchorSpeakerID: anchorID, distance: best.distance, mergeable: mergeable))
        }

        // Turns.
        let suggested = Dictionary(suggestions.map { ($0.speakerID, $0.profileID) }, uniquingKeysWith: { a, _ in a })
        var hints: [String: MeetingTurnHint] = [:]
        for (key, voice) in speakerVoices {
            guard let speaker = speakers[key.owner] else { continue }
            for item in voice.items {
                guard let rest = voice.meanWithout(item) else { continue }
                let own = VectorMath.cosineDistance(item.vector, rest)
                guard let found = nearest(item.vector, track: key.track, allowed: { profileID in
                    profileID != speaker.profileID && !speaker.rejectedProfileIDs.contains(profileID)
                        && suggested[speaker.id] != profileID
                }), found.distance <= thresholds.turnHintMaxDistance,
                    own - found.distance >= thresholds.turnHintMinMargin,
                    found.runnerUp - found.distance >= thresholds.ambiguityMargin,
                    let target = anchor(found.profileID, track: key.track), target != speaker.id else { continue }
                hints[item.turnID] = MeetingTurnHint(
                    turnID: item.turnID, speakerID: target, profileID: found.profileID,
                    name: names[found.profileID] ?? found.profileID, distance: found.distance, ownDistance: own)
            }
        }
        return MeetingVoiceMatches(suggestions: suggestions, turnHints: hints)
    }

    /// Whether a turn's voice counts (see the type's description).
    public static func usable(_ turn: ProjectedTurn) -> Bool {
        turn.speakerID != nil && !turn.overlap && !turn.modified && !turn.excludedFromEnrollment
            && turn.start.isFinite && turn.end.isFinite
            && turn.end - turn.start >= VoiceEnrollment.minimumTurnSeconds - timeEpsilon
    }

    /// Whether a speaker can be offered somebody's name: nobody named it, linked it, or named it automatically, and
    /// it is not a channel speaker.
    public static func isCandidate(_ speaker: ProjectedSpeaker) -> Bool {
        speaker.profileID == nil && speaker.effectiveProfileID == nil && speaker.explicitName == nil
            && !speaker.isAutomatic && speaker.provenance != .channelAssumption
    }

    // MARK: - Private

    private struct TrackKey: Hashable {
        let owner: String
        let track: String
    }

    private struct Item {
        let turnID: String
        let speakerID: String
        let vector: [Float]
        let seconds: Double
    }

    /// A group's voice: the kept turns' weighted sum, its normalized mean, and the outlier pass's result.
    private struct Voice {
        let items: [Item]
        let kept: Set<String>
        let sum: [Double]
        let mean: [Float]
        let seconds: Double

        init?(_ items: [Item]) {
            guard let first = Self.sum(items), let firstMean = Self.unit(first) else { return nil }
            let kept = items.filter {
                VectorMath.cosineDistance(firstMean, $0.vector) <= VoiceEnrollment.outlierDistance
            }
            guard !kept.isEmpty, let sum = kept.count == items.count ? first : Self.sum(kept),
                  let mean = Self.unit(sum) else { return nil }
            self.items = items
            self.kept = Set(kept.map(\.turnID))
            self.sum = sum
            self.mean = mean
            seconds = kept.reduce(0) { $0 + $1.seconds }
        }

        /// The voice without `item`: its mean when the outlier pass left the item out, nil when nothing else is kept.
        func meanWithout(_ item: Item) -> [Float]? {
            guard kept.contains(item.turnID) else { return mean }
            guard kept.count > 1 else { return nil }
            var rest = sum
            for index in rest.indices { rest[index] -= Double(item.vector[index]) * item.seconds }
            return Self.unit(rest)
        }

        private static func sum(_ items: [Item]) -> [Double]? {
            guard let dimension = items.first?.vector.count, dimension > 0 else { return nil }
            var sum = [Double](repeating: 0, count: dimension)
            for item in items where item.seconds.isFinite && item.seconds > 0 {
                for index in sum.indices { sum[index] += Double(item.vector[index]) * item.seconds }
            }
            return sum
        }

        private static func unit(_ sum: [Double]) -> [Float]? {
            let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm.isFinite, norm > 1e-9 else { return nil }
            return sum.map { Float($0 / norm) }
        }
    }
}
