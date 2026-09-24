import Foundation

// Contract file added by PR6 in wave 0 (docs/meeting-design.md §3.3). Speaker value types, the diarizer
// boundary, the edit journal record, and per-session voice data. No FluidAudio types.
// Adding a case to an enum persisted in runs (LabelProvenance, TrackPolicy, WordTimingQuality,
// RecognitionTier) requires DiarizationRun.schemaVersion 2.

// MARK: - Vectors

/// A Float32 vector encoded in JSON as base64 of little-endian IEEE 754 values, so 256-d
/// speaker embeddings stay compact and round-trip bit-exactly.
public struct FloatVector: Codable, Sendable, Equatable {
    public var values: [Float]

    public init(_ values: [Float]) { self.values = values }

    public var count: Int { values.count }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let data = Data(base64Encoded: text), data.count % 4 == 0 else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected base64 of little-endian Float32 values.")
        }
        let bytes = [UInt8](data)
        var decoded: [Float] = []
        decoded.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            var bits = UInt32(bytes[index])
            bits |= UInt32(bytes[index + 1]) << 8
            bits |= UInt32(bytes[index + 2]) << 16
            bits |= UInt32(bytes[index + 3]) << 24
            decoded.append(Float(bitPattern: bits))
            index += 4
        }
        values = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * 4)
        for value in values {
            let bits = value.bitPattern
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        var container = encoder.singleValueContainer()
        try container.encode(Data(bytes).base64EncodedString())
    }
}

// MARK: - Diarization engine boundary (not persisted as-is)

/// Identifies an embedding space. Voiceprints from different models are never compared.
public struct EmbeddingModelID: Codable, Sendable, Hashable {
    public var id: String
    public var revision: String

    public init(id: String, revision: String) { self.id = id; self.revision = revision }
}

/// A downloaded model pinned by revision and content digest.
public struct ModelDescriptor: Codable, Sendable, Equatable {
    public var id: String
    public var revision: String
    /// Tree digest of the model folder (HolosDiarization `ModelTreeDigest`).
    public var sha256: String

    public init(id: String, revision: String, sha256: String) {
        self.id = id; self.revision = revision; self.sha256 = sha256
    }
}

/// Engine provenance recorded in every run.
public struct DiarizationEngineInfo: Codable, Sendable, Equatable {
    public var engine: String
    public var engineVersion: String
    public var models: [ModelDescriptor]
    public var embeddingModel: EmbeddingModelID
    public var embeddingDimension: Int
    /// Flattened engine settings, for reproducibility only.
    public var configuration: [String: String]

    public init(engine: String, engineVersion: String, models: [ModelDescriptor],
                embeddingModel: EmbeddingModelID, embeddingDimension: Int, configuration: [String: String]) {
        self.engine = engine; self.engineVersion = engineVersion; self.models = models
        self.embeddingModel = embeddingModel; self.embeddingDimension = embeddingDimension
        self.configuration = configuration
    }
}

/// Optional speaker-count constraints for the engine.
public struct SpeakerCountHint: Codable, Sendable, Equatable {
    public var minimum: Int?
    public var maximum: Int?
    public var exactly: Int?

    public init(minimum: Int? = nil, maximum: Int? = nil, exactly: Int? = nil) {
        self.minimum = minimum; self.maximum = maximum; self.exactly = exactly
    }
}

public struct DiarizationRequest: Sendable, Equatable {
    /// Mono audio (a `TrackRenderer` output). Output times are seconds from the file's first frame;
    /// the post-processor maps them to session time with the render's time map.
    public var audio: URL
    /// "mic" or "system".
    public var track: String
    public var speakers: SpeakerCountHint?

    public init(audio: URL, track: String, speakers: SpeakerCountHint? = nil) {
        self.audio = audio; self.track = track; self.speakers = speakers
    }
}

/// One engine segment in seconds of the request's audio. `speaker` is the engine label, e.g. "S1".
public struct RawDiarizationSegment: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var quality: Double?

    public init(speaker: String, start: Double, end: Double, quality: Double? = nil) {
        self.speaker = speaker; self.start = start; self.end = end; self.quality = quality
    }
}

/// One per-window embedding for an engine speaker, in seconds of the request's audio.
public struct EmbeddingWindow: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var vector: FloatVector

    public init(speaker: String, start: Double, end: Double, vector: FloatVector) {
        self.speaker = speaker; self.start = start; self.end = end; self.vector = vector
    }
}

public struct DiarizerOutput: Sendable, Equatable {
    public var segments: [RawDiarizationSegment]
    /// Engine speaker label → centroid in the embedding space.
    public var centroids: [String: FloatVector]
    public var windows: [EmbeddingWindow]
    public var processingSeconds: Double

    public init(segments: [RawDiarizationSegment], centroids: [String: FloatVector],
                windows: [EmbeddingWindow], processingSeconds: Double) {
        self.segments = segments; self.centroids = centroids
        self.windows = windows; self.processingSeconds = processingSeconds
    }
}

/// The only boundary between Holos and a diarization engine.
/// Implementations: `FluidDiarizer` (HolosDiarization) and `FakeDiarizer` (HolosSpeakers, for tests).
public protocol SpeakerDiarizer: Sendable {
    /// Engine and model provenance. Throws `HolosError.unavailable` when models are missing or fail verification.
    func engineInfo() async throws -> DiarizationEngineInfo

    /// Diarizes one track. `progress` receives 0...1 from any thread. Throws `CancellationError` when cancelled.
    func diarize(_ request: DiarizationRequest,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput
}

// MARK: - Diarization run (speakers/runs/<runID>.json). Contains no voice embeddings.

public struct DiarizationSegment: Codable, Sendable, Equatable {
    public var track: String
    /// Session-local cluster ID "<track>:<engine label>", e.g. "system:S2".
    public var clusterID: String
    /// Session time.
    public var start: Double
    public var end: Double
    /// Number of other clusters on this track whose segments intersect this one.
    public var overlapCount: Int
    public var quality: Double?

    public init(track: String, clusterID: String, start: Double, end: Double, overlapCount: Int = 0,
                quality: Double? = nil) {
        self.track = track; self.clusterID = clusterID; self.start = start; self.end = end
        self.overlapCount = overlapCount; self.quality = quality
    }
}

public struct ClusterSummary: Codable, Sendable, Equatable {
    public var clusterID: String
    public var track: String
    public var speechSeconds: Double

    public init(clusterID: String, track: String, speechSeconds: Double) {
        self.clusterID = clusterID; self.track = track; self.speechSeconds = speechSeconds
    }
}

/// How the post-processor treated one track.
public enum TrackPolicy: Codable, Sendable, Equatable {
    /// Diarized; turns carry cluster IDs.
    case diarized
    /// Not diarized; every word belongs to one speaker (the microphone in a call is "Me").
    case channel(speakerID: String, displayName: String)
    /// Not analysed, e.g. no audio or no words on this track.
    case skipped(reason: String)
}

public struct TrackDiarization: Codable, Sendable, Equatable {
    public var track: String
    public var policy: TrackPolicy
    public var segments: [DiarizationSegment]
    public var clusters: [ClusterSummary]

    public init(track: String, policy: TrackPolicy, segments: [DiarizationSegment] = [],
                clusters: [ClusterSummary] = []) {
        self.track = track; self.policy = policy; self.segments = segments; self.clusters = clusters
    }
}

public struct AlignmentParameters: Codable, Sendable, Equatable {
    /// A word outside every segment joins the nearest segment within this distance.
    public var gapSnapSeconds: Double
    /// A run of at most this many words labelled B between A words goes back to A…
    public var flickerMaxWords: Int
    /// …when the run spans at most this many seconds,
    public var flickerMaxSeconds: Double
    /// …the pauses to the A words on both sides are at most this long,
    public var flickerMaxGapSeconds: Double
    /// …the run lies within this distance of an A/B diarization segment boundary,
    public var flickerBoundarySeconds: Double
    /// …and no B segment at least this long covers the run.
    public var flickerMinOwnSegmentSeconds: Double
    /// A pause longer than this starts a new turn even for the same speaker.
    public var turnPauseSeconds: Double
    /// Another cluster overlapping a word by at least min(overlapMinSeconds, overlapMinFraction × word) marks overlap.
    public var overlapMinSeconds: Double
    public var overlapMinFraction: Double
    /// Search ±this many seconds for a constant offset between word times and diarization times; 0 disables.
    public var offsetSearchSeconds: Double
    public var offsetStepSeconds: Double
    /// Echo filter window in seconds (PR11); nil disables the filter.
    public var echoWindowSeconds: Double?
    /// Minimum run of consecutive matching words treated as echo (PR11).
    public var echoMinRunWords: Int

    public init(gapSnapSeconds: Double, flickerMaxWords: Int, flickerMaxSeconds: Double,
                flickerMaxGapSeconds: Double, flickerBoundarySeconds: Double, flickerMinOwnSegmentSeconds: Double,
                turnPauseSeconds: Double, overlapMinSeconds: Double, overlapMinFraction: Double,
                offsetSearchSeconds: Double, offsetStepSeconds: Double,
                echoWindowSeconds: Double?, echoMinRunWords: Int) {
        self.gapSnapSeconds = gapSnapSeconds; self.flickerMaxWords = flickerMaxWords
        self.flickerMaxSeconds = flickerMaxSeconds; self.flickerMaxGapSeconds = flickerMaxGapSeconds
        self.flickerBoundarySeconds = flickerBoundarySeconds
        self.flickerMinOwnSegmentSeconds = flickerMinOwnSegmentSeconds
        self.turnPauseSeconds = turnPauseSeconds
        self.overlapMinSeconds = overlapMinSeconds; self.overlapMinFraction = overlapMinFraction
        self.offsetSearchSeconds = offsetSearchSeconds; self.offsetStepSeconds = offsetStepSeconds
        self.echoWindowSeconds = echoWindowSeconds; self.echoMinRunWords = echoMinRunWords
    }

    public static let v1 = AlignmentParameters(
        gapSnapSeconds: 0.5, flickerMaxWords: 2, flickerMaxSeconds: 0.4,
        flickerMaxGapSeconds: 0.25, flickerBoundarySeconds: 0.3, flickerMinOwnSegmentSeconds: 0.3,
        turnPauseSeconds: 1.5, overlapMinSeconds: 0.1, overlapMinFraction: 0.5,
        offsetSearchSeconds: 0.5, offsetStepSeconds: 0.02, echoWindowSeconds: nil, echoMinRunWords: 3)
}

public struct AlignmentInfo: Codable, Sendable, Equatable {
    /// Bumped whenever the algorithm gives different output for the same input.
    public var version: Int
    public var parameters: AlignmentParameters
    /// Per diarized track: seconds added to diarization times before alignment (0 when not estimated).
    public var trackOffsets: [String: Double]

    public init(version: Int, parameters: AlignmentParameters, trackOffsets: [String: Double] = [:]) {
        self.version = version; self.parameters = parameters; self.trackOffsets = trackOffsets
    }
}

/// A word position: an index into `WordTiming.effectiveWords(of:)` for one transcript segment.
public struct WordRef: Codable, Sendable, Hashable {
    public var segmentID: String
    public var word: Int

    public init(segmentID: String, word: Int) { self.segmentID = segmentID; self.word = word }
}

/// Half-open word range `[first, end)` within one transcript segment's effective words.
public struct WordSpan: Codable, Sendable, Equatable {
    public var segmentID: String
    public var first: Int
    public var end: Int

    public init(segmentID: String, first: Int, end: Int) {
        self.segmentID = segmentID; self.first = first; self.end = end
    }
}

public enum WordTimingQuality: String, Codable, Sendable {
    /// Every word has recognizer timing.
    case measured
    /// Times were spread evenly across an untimed segment.
    case estimated
    /// Both kinds occur in the turn.
    case mixed
}

/// A machine-built turn. Text and timing stay in the transcript; the turn only references words.
public struct SpeakerTurn: Codable, Sendable, Equatable, Identifiable {
    /// "T1", "T2", … in (start, track) order within the run.
    public var id: String
    public var track: String
    public var start: Double
    public var end: Double
    /// Initial speaker; nil means unknown.
    public var speakerID: String?
    /// Diarizer cluster that won the words; nil for channel or unknown turns.
    public var clusterID: String?
    public var spans: [WordSpan]
    public var overlap: Bool
    public var otherClusters: [String]
    /// Share of the turn's word time covered by the chosen cluster, 0...1 (1 for channel turns).
    public var assignmentScore: Double
    public var timing: WordTimingQuality

    public init(id: String, track: String, start: Double, end: Double, speakerID: String?, clusterID: String?,
                spans: [WordSpan], overlap: Bool = false, otherClusters: [String] = [],
                assignmentScore: Double, timing: WordTimingQuality) {
        self.id = id; self.track = track; self.start = start; self.end = end; self.speakerID = speakerID
        self.clusterID = clusterID; self.spans = spans; self.overlap = overlap
        self.otherClusters = otherClusters; self.assignmentScore = assignmentScore; self.timing = timing
    }
}

public enum RecognitionTier: String, Codable, Sendable {
    /// Applied automatically and shown as "Jim (auto)". Produced only with calibrated thresholds (§4.10).
    case likely
    /// Shown in the review window as "Maybe Jim" with Confirm; never exported.
    case possible
}

/// Where a speaker's label came from.
public enum LabelProvenance: Codable, Sendable, Equatable {
    case diarizer
    case channelAssumption
    case recognized(distance: Double, tier: RecognitionTier)
    case userConfirmed
    case userRenamed
}

public struct SessionSpeaker: Codable, Sendable, Equatable, Identifiable {
    /// "mic:S1", "system:S2", "mic:me", or "user:<uuid>" for speakers created by edits.
    public var id: String
    /// N in "Speaker N": 1-based, by first turn start across both tracks.
    public var ordinal: Int
    public var displayName: String?
    public var profileID: String?
    public var provenance: LabelProvenance
    public var clusterIDs: [String]

    public init(id: String, ordinal: Int, displayName: String? = nil, profileID: String? = nil,
                provenance: LabelProvenance, clusterIDs: [String] = []) {
        self.id = id; self.ordinal = ordinal; self.displayName = displayName
        self.profileID = profileID; self.provenance = provenance; self.clusterIDs = clusterIDs
    }
}

/// Words left out of every turn, e.g. microphone echo of system audio (PR11).
public struct DroppedWords: Codable, Sendable, Equatable {
    public var spans: [WordSpan]
    public var reason: String

    public init(spans: [WordSpan], reason: String) { self.spans = spans; self.reason = reason }
}

/// Immutable result of diarizing and aligning one transcript revision. Holds no voice embeddings.
public struct DiarizationRun: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int
    /// UUID string; also the file name.
    public var id: String
    public var sessionID: String
    public var createdAt: Date
    /// The `Transcript.id` whose segments the turns reference.
    public var transcriptID: String
    /// Nil when no track was diarized (channel-only sessions).
    public var engine: DiarizationEngineInfo?
    public var alignment: AlignmentInfo
    public var tracks: [TrackDiarization]
    public var speakers: [SessionSpeaker]
    public var turns: [SpeakerTurn]
    public var droppedWords: [DroppedWords]

    public init(schemaVersion: Int = 1, id: String = UUID().uuidString, sessionID: String,
                createdAt: Date = Date(), transcriptID: String, engine: DiarizationEngineInfo?,
                alignment: AlignmentInfo, tracks: [TrackDiarization], speakers: [SessionSpeaker],
                turns: [SpeakerTurn], droppedWords: [DroppedWords] = []) {
        self.schemaVersion = schemaVersion; self.id = id; self.sessionID = sessionID
        self.createdAt = createdAt; self.transcriptID = transcriptID; self.engine = engine
        self.alignment = alignment; self.tracks = tracks; self.speakers = speakers; self.turns = turns
        self.droppedWords = droppedWords
    }
}

/// Contents of `speakers/head.json`: the run that exports and the review window use.
public struct SpeakerHead: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runID: String
    public var updatedAt: Date

    public init(schemaVersion: Int = 1, runID: String, updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion; self.runID = runID; self.updatedAt = updatedAt
    }
}

// MARK: - Voice data (speakers/voice/<runID>.json). Biometric; written only while "Remember voices" is on.

/// Mean embedding of one turn's speech, used for enrollment.
public struct TurnEmbedding: Codable, Sendable, Equatable {
    public var turnID: String
    public var speechSeconds: Double
    public var vector: FloatVector

    public init(turnID: String, speechSeconds: Double, vector: FloatVector) {
        self.turnID = turnID; self.speechSeconds = speechSeconds; self.vector = vector
    }
}

/// Voice embeddings for one run. Deleted by Forget All Voices, Delete Audio, and Delete Meeting;
/// Forget <person> removes the entries of that person's speakers.
public struct SessionVoiceData: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runID: String
    public var sessionID: String
    public var createdAt: Date
    public var embeddingModel: EmbeddingModelID
    /// Cluster ID → centroid.
    public var centroids: [String: FloatVector]
    public var turnEmbeddings: [TurnEmbedding]

    public init(schemaVersion: Int = 1, runID: String, sessionID: String, createdAt: Date = Date(),
                embeddingModel: EmbeddingModelID, centroids: [String: FloatVector],
                turnEmbeddings: [TurnEmbedding]) {
        self.schemaVersion = schemaVersion; self.runID = runID; self.sessionID = sessionID
        self.createdAt = createdAt; self.embeddingModel = embeddingModel; self.centroids = centroids
        self.turnEmbeddings = turnEmbeddings
    }
}

// MARK: - Edit journal (speakers/edits.jsonl)

/// Speaker IDs in actions are session speaker IDs; `nil` as a target means "unknown speaker".
public enum SpeakerEditAction: Codable, Sendable, Equatable {
    /// Sets or clears (`name == nil`) the display name.
    case rename(speakerID: String, name: String?)
    /// Links the speaker to a person (a profile); a confirmed label.
    case linkProfile(speakerID: String, profileID: String)
    /// "Not Jim" for this session only.
    case rejectProfile(speakerID: String, profileID: String)
    /// Moves every turn of `from` to `into`; `from` disappears.
    case merge(from: String, into: String)
    case reassignTurns(turnIDs: [String], to: String?)
    /// Splits before `at`; the second part gets ID "<turnID>/<editID>".
    case splitTurn(turnID: String, at: WordRef)
    /// Creates `speakerID` ("user:<uuid>") and moves the turns to it.
    case newSpeaker(speakerID: String, name: String?, turnIDs: [String])
    case excludeFromEnrollment(turnIDs: [String])
    /// Undo: the projection skips the referenced edit.
    case revert(editID: String)
}

/// One append-only journal line. Edits never change the run; the projection applies them.
public struct SpeakerEdit: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int
    public var id: String
    public var baseRunID: String
    public var at: Date
    /// "app", "cli", or "carry" (carried over from an earlier run, §4.9).
    public var source: String
    public var action: SpeakerEditAction
    /// Fingerprint of the prior value in the editor's view (docs/meeting-design.md §4.9);
    /// a mismatch at write time refuses the edit, and at projection time makes it stale.
    public var expected: String?
    /// Edits appended by one `SpeakerEditor.apply` share this ID; undo reverts the whole batch.
    public var batchID: String?

    public init(schemaVersion: Int = 1, id: String = UUID().uuidString, baseRunID: String, at: Date = Date(),
                source: String, action: SpeakerEditAction, expected: String? = nil, batchID: String? = nil) {
        self.schemaVersion = schemaVersion; self.id = id; self.baseRunID = baseRunID; self.at = at
        self.source = source; self.action = action; self.expected = expected; self.batchID = batchID
    }
}

// MARK: - Recognition (speakers/recognition/<runID>.json). Distances only, no vectors.

public struct RecognitionThresholds: Codable, Sendable, Equatable {
    /// Cosine distance at or below which a match can be `likely`; 0 disables `likely`…
    public var likelyMaxDistance: Double
    /// …if the next-best profile is at least this much farther.
    public var likelyMinMargin: Double
    /// Cosine distance at or below which a match is at least `possible`.
    public var possibleMaxDistance: Double
    /// Samples with less speech are weak and cannot produce `likely`.
    public var minSampleSeconds: Double

    public init(likelyMaxDistance: Double, likelyMinMargin: Double, possibleMaxDistance: Double,
                minSampleSeconds: Double) {
        self.likelyMaxDistance = likelyMaxDistance; self.likelyMinMargin = likelyMinMargin
        self.possibleMaxDistance = possibleMaxDistance; self.minSampleSeconds = minSampleSeconds
    }
}

public struct SpeakerMatch: Codable, Sendable, Equatable {
    /// Machine speaker in the run.
    public var speakerID: String
    public var profileID: String
    /// Profile name when recognition ran; the projection prefers the current name.
    public var profileName: String
    public var distance: Double
    public var tier: RecognitionTier

    public init(speakerID: String, profileID: String, profileName: String, distance: Double, tier: RecognitionTier) {
        self.speakerID = speakerID; self.profileID = profileID; self.profileName = profileName
        self.distance = distance; self.tier = tier
    }
}

/// Two or more speakers of one session matched the same profile.
public struct MergeSuggestion: Codable, Sendable, Equatable {
    public var speakerIDs: [String]
    public var profileID: String

    public init(speakerIDs: [String], profileID: String) {
        self.speakerIDs = speakerIDs; self.profileID = profileID
    }
}

public struct RecognitionResult: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runID: String
    public var createdAt: Date
    public var embeddingModel: EmbeddingModelID
    public var thresholds: RecognitionThresholds
    public var matches: [SpeakerMatch]
    public var mergeSuggestions: [MergeSuggestion]
    /// Profiles left out because their embedding model differs from the run's.
    public var skippedProfiles: [String]

    public init(schemaVersion: Int = 1, runID: String, createdAt: Date = Date(), embeddingModel: EmbeddingModelID,
                thresholds: RecognitionThresholds, matches: [SpeakerMatch], mergeSuggestions: [MergeSuggestion] = [],
                skippedProfiles: [String] = []) {
        self.schemaVersion = schemaVersion; self.runID = runID; self.createdAt = createdAt
        self.embeddingModel = embeddingModel; self.thresholds = thresholds; self.matches = matches
        self.mergeSuggestions = mergeSuggestions; self.skippedProfiles = skippedProfiles
    }
}

// MARK: - Timeline annotations for exports

/// Why audio is missing for an interval. Open string code. The raw values are also the
/// `reason` strings of `audioDiscontinuity` events (§3.2).
public struct GapReason: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let paused = GapReason("paused")
    public static let sleep = GapReason("sleep")
    public static let deviceChanged = GapReason("deviceChanged")
    public static let captureRestarted = GapReason("captureRestarted")
    /// Capture was not running while the recorder waited for audio (phase `waiting`).
    public static let audioUnavailable = GapReason("audioUnavailable")
    /// Audio was dropped because the disk could not keep up.
    public static let overflow = GapReason("overflow")
    /// An unexplained timestamp gap longer than 1 second (exports only; not an event reason).
    public static let audioGap = GapReason("audioGap")
    /// Reserved for a later `holos session redact`; not written in v1.
    public static let redacted = GapReason("redacted")
}

public struct TimelineGap: Codable, Sendable, Equatable {
    /// Nil when every track is missing audio.
    public var track: String?
    public var start: Double
    public var end: Double
    public var reason: GapReason

    public init(track: String? = nil, start: Double, end: Double, reason: GapReason) {
        self.track = track; self.start = start; self.end = end; self.reason = reason
    }
}

public struct TimelineMarker: Codable, Sendable, Equatable {
    public var at: Double
    public var label: String?

    public init(at: Double, label: String? = nil) { self.at = at; self.label = label }
}
