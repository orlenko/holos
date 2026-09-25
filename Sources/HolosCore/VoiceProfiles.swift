import Foundation

// People and their opt-in voiceprints (docs/meeting-design.md §4.10, PR10). Names are not biometric; voiceprints are.
// A person (`SpeakerProfile`) exists whether or not "Remember voices" is on, so names carry across meetings; a
// voiceprint reaches disk only as a `VoiceprintSample` of a person the user confirmed with voice learning on.
// Stored in `<support>/Speakers/profiles.json` by `SpeakerProfileStore` (HolosStorage).

/// Where a voice was recorded: in the room (the microphone track) or through a call (the system track). Embeddings of
/// one person differ between the two, so recognition prefers samples of the same condition.
public enum RecordingCondition: String, Codable, Sendable {
    case room, call

    /// "system" → call; anything else (the microphone) → room.
    public init(track: String) { self = track == "system" ? .call : .room }
}

/// One person's voice as learned from one meeting: the speech-weighted mean of the embeddings of the confirmed
/// speaker's qualifying turns (`VoiceEnrollment`). Biometric data.
public struct VoiceprintSample: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionID: String
    public var sessionName: String
    /// Speakers in that session the sample was built from (after merges).
    public var speakerIDs: [String]
    public var speechSeconds: Double
    /// L2-normalized.
    public var embedding: FloatVector
    public var condition: RecordingCondition
    /// speechSeconds < thresholds.minSampleSeconds; cannot produce `likely`.
    public var weak: Bool
    /// Turns dropped by the outlier pass.
    public var droppedOutlierTurns: Int
    public var addedAt: Date
    /// The session's speaker generation (head run and edit-journal length) the sample was built from, so an older
    /// result never replaces a newer one (§4.10).
    public var generation: String?
    /// Digest of the enrollment inputs (the linked speakers and their qualifying turns) the sample was built from;
    /// a refresh re-extracts only when the inputs changed (`VoiceEnrollment.inputDigest`).
    public var inputDigest: String?

    public init(id: String = UUID().uuidString, sessionID: String, sessionName: String, speakerIDs: [String],
                speechSeconds: Double, embedding: FloatVector, condition: RecordingCondition, weak: Bool,
                droppedOutlierTurns: Int = 0, addedAt: Date = Date(), generation: String? = nil,
                inputDigest: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.sessionName = sessionName; self.speakerIDs = speakerIDs
        self.speechSeconds = speechSeconds; self.embedding = embedding; self.condition = condition
        self.weak = weak; self.droppedOutlierTurns = droppedOutlierTurns; self.addedAt = addedAt
        self.generation = generation; self.inputDigest = inputDigest
    }
}

/// A person the user named in a meeting. May have no samples.
public struct SpeakerProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var createdAt: Date
    /// Updated when the person is linked in a meeting; orders the name list.
    public var lastUsedAt: Date
    /// The user ("This is me").
    public var isSelf: Bool
    /// Set with the first sample; samples from another model are refused.
    public var embeddingModel: EmbeddingModelID?
    /// "Suggest <name> in new meetings".
    public var recognitionEnabled: Bool
    /// At most one per sessionID; may be empty.
    public var samples: [VoiceprintSample]
    /// Set while this person exists only for a link that has not been saved yet. It is cleared by any store write
    /// that changes them (`SpeakerProfileStore.update`), and by the operations that take a person up without
    /// necessarily changing anything about them: a merge into them, a rename, a suggestions setting, and the
    /// link's own claim (`SpeakerEditor.claimPeople`). A link that is then refused takes back only a person who is
    /// still provisional, so one another window has linked meanwhile is never removed. It is an explicit state
    /// rather than a comparison of `createdAt` and `lastUsedAt`, which `HolosJSON` stores to the second and which
    /// two windows can therefore share. Absent (nil) in stores written by an earlier Holos, and in every person
    /// who has been linked: neither is ever taken back.
    public var provisional: Bool?

    public init(id: String = UUID().uuidString, displayName: String, createdAt: Date = Date(), lastUsedAt: Date? = nil,
                isSelf: Bool = false, embeddingModel: EmbeddingModelID? = nil, recognitionEnabled: Bool = true,
                samples: [VoiceprintSample] = [], provisional: Bool? = nil) {
        self.id = id; self.displayName = displayName; self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt; self.isSelf = isSelf; self.embeddingModel = embeddingModel
        self.recognitionEnabled = recognitionEnabled; self.samples = samples; self.provisional = provisional
    }
}

/// Contents of `profiles.json`.
public struct SpeakerProfileDatabase: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    /// 1.
    public var schemaVersion: Int
    /// Off by default. Governs voice samples, per-session voice data, and recognition. Never names.
    public var rememberVoices: Bool
    /// Counts the store writes of forgets (`VoiceProfileService.perform`). Voice sample work started before a
    /// forget and published after it would put back what the forget removed, and comparing the samples cannot see
    /// that when the work concerns a person and meeting the forget left empty either way; this counter can.
    /// Absent (nil) in stores written by an earlier Holos, which reads as 0.
    public var forgetEpoch: Int?
    /// Merges whose store write committed, as the person merged away → the person they were merged into. Written in
    /// the same write that removes the source, so it says what a journal record alone cannot: that this merge is
    /// what removed that person, rather than a forget or another merge. Entries let a merge that was interrupted
    /// find where its target has gone since, and they are dropped once no merge is waiting for its meetings.
    public var mergedInto: [String: String]?
    /// Set by `holos people calibrate --apply`; `likely` exists only when this is set, and only for runs of
    /// `calibratedModel`.
    public var calibratedThresholds: RecognitionThresholds?
    /// The embedding model `calibratedThresholds` were measured on (distances of different models cannot be
    /// compared). Set with them; thresholds without it (saved before it existed) are never applied.
    public var calibratedModel: EmbeddingModelID?
    public var profiles: [SpeakerProfile]
    /// When a change to the voice samples last cleared the calibration (`resetCalibrationIfSamplesChanged`); nil
    /// once `holos people calibrate --apply` saves new thresholds. `holos people list` says the calibration was reset
    /// while this is set and nothing is calibrated.
    public var calibrationResetAt: Date?

    public init(schemaVersion: Int = SpeakerProfileDatabase.currentSchemaVersion, rememberVoices: Bool = false,
                calibratedThresholds: RecognitionThresholds? = nil, calibratedModel: EmbeddingModelID? = nil,
                profiles: [SpeakerProfile] = [], calibrationResetAt: Date? = nil, forgetEpoch: Int? = nil,
                mergedInto: [String: String]? = nil) {
        self.schemaVersion = schemaVersion; self.rememberVoices = rememberVoices
        self.calibratedThresholds = calibratedThresholds; self.calibratedModel = calibratedModel
        self.profiles = profiles; self.calibrationResetAt = calibrationResetAt; self.forgetEpoch = forgetEpoch
        self.mergedInto = mergedInto
    }

    /// The calibrated thresholds for a run of `model`: nil unless they were measured on that model.
    public func calibratedThresholds(for model: EmbeddingModelID?) -> RecognitionThresholds? {
        guard let model, calibratedModel == model else { return nil }
        return calibratedThresholds
    }

    /// Whether calibrated thresholds apply to runs of some model (`calibratedModel`).
    public var isCalibrated: Bool { calibratedThresholds(for: calibratedModel) != nil }

    /// Every stored sample.
    public var sampleCount: Int { profiles.reduce(0) { $0 + $1.samples.count } }

    /// Sessions that contributed at least one sample.
    public var sampleSessionIDs: Set<String> { Set(profiles.flatMap { $0.samples.map(\.sessionID) }) }

    /// One stored sample as calibration sees it: whose it is, of which model, from which meeting, and its vector.
    public struct CalibrationSample: Hashable, Sendable {
        public var profileID: String
        public var model: EmbeddingModelID?
        public var sampleID: String
        public var sessionID: String
        public var embedding: [Float]
    }

    /// The population calibration is measured on (`RecognitionCalibration`): every sample, grouped by person, with
    /// its person's embedding model. Names, settings, and people without samples are not part of it.
    public var calibrationPopulation: Set<CalibrationSample> {
        Set(profiles.flatMap { profile in
            profile.samples.map {
                CalibrationSample(profileID: profile.id, model: profile.embeddingModel, sampleID: $0.id,
                                  sessionID: $0.sessionID, embedding: $0.embedding.values)
            }
        })
    }

    /// Clears the calibration (`calibratedThresholds`, `calibratedModel`) when the sample population differs from
    /// `before`'s: a sample learned, refreshed, moved by a merge, or forgotten, or a model changed. Thresholds
    /// measured on another population no longer keep their false-accept budget. Sets `calibrationResetAt` to `now`.
    /// A change that saved new thresholds itself (`calibrate --apply`) is left alone. Returns whether it cleared
    /// anything. `SpeakerProfileStore.update` calls this on every write, inside the same locked update.
    @discardableResult
    /// Clears `provisional` on every person this write changed, keeping it only on those it left exactly as they
    /// were. A person created by this write keeps whatever it was created with.
    public mutating func clearProvisionalOfChangedProfiles(since before: SpeakerProfileDatabase) {
        guard profiles.contains(where: { $0.provisional == true }) else { return }
        let earlier = Dictionary(before.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in profiles.indices where profiles[index].provisional == true {
            guard let was = earlier[profiles[index].id] else { continue }
            var now = profiles[index]
            now.provisional = was.provisional
            if now != was { profiles[index].provisional = nil }
        }
    }

    public mutating func resetCalibrationIfSamplesChanged(since before: SpeakerProfileDatabase,
                                                          now: Date = Date()) -> Bool {
        guard calibratedThresholds != nil || calibratedModel != nil,
              calibratedThresholds == before.calibratedThresholds, calibratedModel == before.calibratedModel,
              calibrationPopulation != before.calibrationPopulation else { return false }
        calibratedThresholds = nil
        calibratedModel = nil
        calibrationResetAt = now
        return true
    }
}

// Voiceprints are biometric: printing a sample, a profile, or the database (`print`, `dump`, string interpolation,
// test-failure output) shows only IDs, counts, and flags, never an embedding or a name (docs/meeting-design.md §1.5).

extension VoiceprintSample: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "VoiceprintSample(id: \(id), sessionID: \(sessionID), speakers: \(speakerIDs.count), "
            + "speechSeconds: \(speechSeconds), condition: \(condition.rawValue), weak: \(weak), "
            + "dimension: \(embedding.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "sessionID": sessionID, "speechSeconds": speechSeconds,
                                "condition": condition.rawValue, "weak": weak, "dimension": embedding.count],
               displayStyle: .struct)
    }
}

extension SpeakerProfile: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SpeakerProfile(id: \(id), isSelf: \(isSelf), samples: \(samples.count), "
            + "recognitionEnabled: \(recognitionEnabled))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "isSelf": isSelf, "samples": samples.count,
                                "recognitionEnabled": recognitionEnabled], displayStyle: .struct)
    }
}

extension SpeakerProfileDatabase: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SpeakerProfileDatabase(rememberVoices: \(rememberVoices), calibrated: \(isCalibrated), "
            + "profiles: \(profiles.count), samples: \(sampleCount))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["rememberVoices": rememberVoices, "calibrated": isCalibrated,
                                "profiles": profiles.count, "samples": sampleCount], displayStyle: .struct)
    }
}

extension SpeakerProfileDatabase.CalibrationSample: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public var description: String {
        "CalibrationSample(profileID: \(profileID), sampleID: \(sampleID), sessionID: \(sessionID), "
            + "dimension: \(embedding.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["profileID": profileID, "sampleID": sampleID, "sessionID": sessionID,
                                "dimension": embedding.count], displayStyle: .struct)
    }
}
