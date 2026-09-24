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

    public init(id: String = UUID().uuidString, displayName: String, createdAt: Date = Date(), lastUsedAt: Date? = nil,
                isSelf: Bool = false, embeddingModel: EmbeddingModelID? = nil, recognitionEnabled: Bool = true,
                samples: [VoiceprintSample] = []) {
        self.id = id; self.displayName = displayName; self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt; self.isSelf = isSelf; self.embeddingModel = embeddingModel
        self.recognitionEnabled = recognitionEnabled; self.samples = samples
    }
}

/// Contents of `profiles.json`.
public struct SpeakerProfileDatabase: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    /// 1.
    public var schemaVersion: Int
    /// Off by default. Governs voice samples, per-session voice data, and recognition. Never names.
    public var rememberVoices: Bool
    /// Set by `holos people calibrate --apply`; `likely` exists only when this is set.
    public var calibratedThresholds: RecognitionThresholds?
    public var profiles: [SpeakerProfile]

    public init(schemaVersion: Int = SpeakerProfileDatabase.currentSchemaVersion, rememberVoices: Bool = false,
                calibratedThresholds: RecognitionThresholds? = nil, profiles: [SpeakerProfile] = []) {
        self.schemaVersion = schemaVersion; self.rememberVoices = rememberVoices
        self.calibratedThresholds = calibratedThresholds; self.profiles = profiles
    }

    /// Every stored sample.
    public var sampleCount: Int { profiles.reduce(0) { $0 + $1.samples.count } }

    /// Sessions that contributed at least one sample.
    public var sampleSessionIDs: Set<String> { Set(profiles.flatMap { $0.samples.map(\.sessionID) }) }
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
        "SpeakerProfileDatabase(rememberVoices: \(rememberVoices), calibrated: \(calibratedThresholds != nil), "
            + "profiles: \(profiles.count), samples: \(sampleCount))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["rememberVoices": rememberVoices, "calibrated": calibratedThresholds != nil,
                                "profiles": profiles.count, "samples": sampleCount], displayStyle: .struct)
    }
}
