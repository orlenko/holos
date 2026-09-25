import Foundation
import HolosCore

/// Builds an immutable `DiarizationRun` (no voice embeddings) and, separately, the run's in-memory voice data
/// from a transcript and per-track diarizer outputs. Pure: no file IO; the caller persists what it may.
public enum SpeakerRunBuilder {
    /// `AlignmentInfo.version` of runs built by this code. Bump it whenever the output for the same input changes.
    public static let alignmentVersion = 1

    public struct TrackInput: Sendable, Equatable {
        public var track: String
        public var policy: TrackPolicy
        public var output: DiarizerOutput?      // required for .diarized; times already on the session timeline

        public init(track: String, policy: TrackPolicy, output: DiarizerOutput? = nil) {
            self.track = track; self.policy = policy; self.output = output
        }
    }

    public struct Result: Sendable, Equatable {
        public var run: DiarizationRun
        /// Centroids and turn embeddings; nil without an engine. The caller decides whether to persist it.
        public var voiceData: SessionVoiceData?

        public init(run: DiarizationRun, voiceData: SessionVoiceData?) {
            self.run = run; self.voiceData = voiceData
        }
    }

    /// Estimates and applies the per-track offset, normalizes, aligns, numbers turns T1… in (start, track)
    /// order, creates speakers (one per cluster with at least one turn, id = clusterID, provenance .diarizer;
    /// one per channel policy, provenance .channelAssumption, displayName from the policy), assigns ordinals by
    /// first turn start, and computes turn embeddings into `voiceData`.
    ///
    /// Details:
    /// - Tracks keep their input order in `run.tracks`; a repeated track name is ignored after its first input.
    /// - A `.diarized` input without an output is aligned against no segments, so its words are unknown.
    /// - Offsets are recorded for every diarized track (0 when none was found). Shifted diarization times are
    ///   clamped at 0, and the stored segments are the shifted ones the turns were aligned against.
    /// - Segments without a track (older transcripts) count for at most one input: the first non-skipped
    ///   track that step 1 lets count them, so a word is never in two turns.
    /// - Speakers are listed in ordinal order; ties in first turn start follow turn order. A channel speaker
    ///   without turns is still listed, after every speaker that has turns.
    /// - `run.engine` and `voiceData` are nil when no track is diarized or `engine` is nil. Voice data holds the
    ///   centroids of the run's cluster speakers only.
    /// - Echo (PR11), when `parameters.echoWindowSeconds` is set: `EchoFilter.echoSpans` are in no turn and are listed
    ///   in `run.droppedWords` (reason `echo`). The microphone track's words are labelled first, echo included, so
    ///   alignment sees the audio as it was; then the echo words leave. A diarized microphone cluster with at least
    ///   `EchoFilter.echoClusterShare` of its labelled words dropped is not listed, and its remaining words become
    ///   unknown speaker (no cluster, no overlap, score 0). Its segments stay in `run.tracks`. A word that is kept
    ///   stops naming such a cluster among its overlaps, so no turn is marked overlapped with a speaker the run
    ///   does not list.
    public static func build(sessionID: String, transcript: Transcript, tracks: [TrackInput],
                             engine: DiarizationEngineInfo?, parameters: AlignmentParameters = .v1,
                             id: String = UUID().uuidString, createdAt: Date = Date()) -> Result {
        var seenTracks = Set<String>()
        let inputs = tracks.filter { seenTracks.insert($0.track).inserted }
        let untrackedOwner = untrackedSegmentOwner(transcript: transcript, inputs: inputs)
        let echoSpans = EchoFilter.echoSpans(transcript: transcript, parameters: parameters)
        let echoWords = EchoFilter.words(in: echoSpans)

        var trackDiarizations: [TrackDiarization] = []
        var offsets: [String: Double] = [:]
        var turns: [SpeakerTurn] = []
        var windowsByCluster: [String: [EmbeddingWindow]] = [:]
        var centroids: [String: FloatVector] = [:]
        var channelSpeakers: [(id: String, displayName: String)] = []
        var diarized = false

        for input in inputs {
            let includeUntracked = input.track == untrackedOwner
            switch input.policy {
            case .skipped:
                trackDiarizations.append(TrackDiarization(track: input.track, policy: input.policy))
            case .channel(let speakerID, let displayName):
                let diarization = TrackDiarization(track: input.track, policy: input.policy)
                let words = SpeakerAlignment.assignWords(segments: transcript.segments, track: input.track,
                                                         includeUntracked: includeUntracked,
                                                         diarization: diarization, parameters: parameters)
                turns += turnsWithoutEcho(words, track: input.track, echo: echoWords, hidingEchoClusters: false,
                                          parameters: parameters, policy: input.policy)
                trackDiarizations.append(diarization)
                if !channelSpeakers.contains(where: { $0.id == speakerID }) {
                    channelSpeakers.append((speakerID, displayName))
                }
            case .diarized:
                diarized = true
                let output = input.output
                    ?? DiarizerOutput(segments: [], centroids: [:], windows: [], processingSeconds: 0)
                let offset = SpeakerAlignment.estimateOffset(
                    segments: transcript.segments, track: input.track, includeUntracked: includeUntracked,
                    diarization: DiarizationNormalizer.normalize(output, track: input.track), parameters: parameters)
                offsets[input.track] = offset
                let shifted = shift(output, by: offset)
                let diarization = DiarizationNormalizer.normalize(shifted, track: input.track)
                let words = SpeakerAlignment.assignWords(segments: transcript.segments, track: input.track,
                                                         includeUntracked: includeUntracked,
                                                         diarization: diarization, parameters: parameters)
                turns += turnsWithoutEcho(words, track: input.track, echo: echoWords, hidingEchoClusters: true,
                                          parameters: parameters, policy: input.policy)
                trackDiarizations.append(diarization)
                for window in shifted.windows {
                    let clusterID = DiarizationNormalizer.clusterID(track: input.track, speaker: window.speaker)
                    var prefixed = window
                    prefixed.speaker = clusterID
                    windowsByCluster[clusterID, default: []].append(prefixed)
                }
                for (speaker, centroid) in output.centroids {
                    centroids[DiarizationNormalizer.clusterID(track: input.track, speaker: speaker)] = centroid
                }
            }
        }

        turns = turns.enumerated()
            .sorted { ($0.element.start, $0.element.track, $0.offset) < ($1.element.start, $1.element.track, $1.offset) }
            .enumerated()
            .map { index, entry in
                var turn = entry.element
                turn.id = "T\(index + 1)"
                return turn
            }
        let speakers = makeSpeakers(turns: turns, channelSpeakers: channelSpeakers)
        let runEngine = diarized ? engine : nil
        let run = DiarizationRun(
            id: id, sessionID: sessionID, createdAt: createdAt, transcriptID: transcript.id, engine: runEngine,
            alignment: AlignmentInfo(version: alignmentVersion, parameters: parameters, trackOffsets: offsets),
            tracks: trackDiarizations, speakers: speakers, turns: turns,
            droppedWords: echoSpans.isEmpty ? [] : [DroppedWords(spans: echoSpans, reason: EchoFilter.reason)])

        let voiceData = runEngine.map { engine in
            let speakerClusters = Set(speakers.flatMap(\.clusterIDs))
            return SessionVoiceData(
                runID: id, sessionID: sessionID, createdAt: createdAt, embeddingModel: engine.embeddingModel,
                centroids: centroids.filter { speakerClusters.contains($0.key) },
                turnEmbeddings: TurnEmbeddings.compute(turns: turns, windowsByCluster: windowsByCluster))
        }
        return Result(run: run, voiceData: voiceData)
    }

    /// The turns of `track`'s aligned `words`. On the microphone track the `echo` words are in no turn, and a turn
    /// never spans a place where echo was removed: the kept words on either side go to separate turns, so a reply
    /// cannot move ahead of the remote sentence it answers, and a turn's time range (and so its embedding) does not
    /// cover the echo.
    private static func turnsWithoutEcho(_ words: [AlignedWord], track: String, echo: Set<WordRef>,
                                         hidingEchoClusters: Bool, parameters: AlignmentParameters,
                                         policy: TrackPolicy) -> [SpeakerTurn] {
        guard track == EchoFilter.microphoneTrack, !echo.isEmpty else {
            return SpeakerAlignment.buildTurns(words, parameters: parameters, policy: policy)
        }
        return withoutEcho(words, echo: echo, hidingEchoClusters: hidingEchoClusters)
            .flatMap { SpeakerAlignment.buildTurns($0, parameters: parameters, policy: policy) }
    }

    /// `words` of the microphone track without the `echo` words, as runs of kept words: a new run starts wherever
    /// one or more echo words were removed. With `hidingEchoClusters` (a diarized track), a cluster with at least
    /// `EchoFilter.echoClusterShare` of its labelled words in `echo` is echo itself: its other words become unknown
    /// speaker, like words no segment covers.
    private static func withoutEcho(_ words: [AlignedWord], echo: Set<WordRef>,
                                    hidingEchoClusters: Bool) -> [[AlignedWord]] {
        guard !echo.isEmpty else { return [words] }
        var hidden = Set<String>()
        if hidingEchoClusters {
            var labelled: [String: Int] = [:]
            var echoed: [String: Int] = [:]
            for word in words {
                guard let label = word.label else { continue }
                labelled[label, default: 0] += 1
                if echo.contains(word.ref) { echoed[label, default: 0] += 1 }
            }
            // The tolerance keeps an exact share (3 of 5 is 60 %) from missing the threshold by rounding.
            for (label, count) in labelled
            where Double(echoed[label] ?? 0) >= EchoFilter.echoClusterShare * Double(count) - 1e-9 {
                hidden.insert(label)
            }
        }
        var runs: [[AlignedWord]] = []
        var run: [AlignedWord] = []
        for word in words {
            if echo.contains(word.ref) {
                if !run.isEmpty { runs.append(run) }
                run = []
                continue
            }
            guard let label = word.label, hidden.contains(label) else {
                var kept = word
                // A hidden cluster is in no `speakers` entry, so a word that survives must not still name it as an
                // overlap: `buildTurns` would mark the turn overlapped with nobody to overlap with, and enrollment
                // skips overlapped turns, which would cost a real room speaker their voice sample.
                if !hidden.isEmpty {
                    kept.overlapClusters = kept.overlapClusters.filter { !hidden.contains($0) }
                }
                run.append(kept)
                continue
            }
            var unknown = word
            unknown.label = nil
            unknown.coveredSeconds = 0
            unknown.overlapClusters = []
            run.append(unknown)
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    /// The input whose alignment counts transcript segments without a track, or nil.
    private static func untrackedSegmentOwner(transcript: Transcript, inputs: [TrackInput]) -> String? {
        guard transcript.segments.contains(where: { $0.track == nil }) else { return nil }
        let named = Set(transcript.segments.compactMap(\.track))
        return inputs.first { input in
            if case .skipped = input.policy { return false }
            return named.isSubset(of: [input.track])
        }?.track
    }

    /// `output` with `offset` added to every segment and window time, clamped at 0. Non-finite times stay
    /// non-finite (`max(0, .nan)` is 0), so the normalizer and turn embeddings still drop those entries.
    private static func shift(_ output: DiarizerOutput, by offset: Double) -> DiarizerOutput {
        func moved(_ time: Double) -> Double { time.isFinite ? max(0, time + offset) : time }
        var shifted = output
        shifted.segments = output.segments.map { segment in
            var copy = segment
            copy.start = moved(segment.start)
            copy.end = moved(segment.end)
            return copy
        }
        shifted.windows = output.windows.map { window in
            var copy = window
            copy.start = moved(window.start)
            copy.end = moved(window.end)
            return copy
        }
        return shifted
    }

    /// Channel speakers first claim their IDs; every other turn cluster becomes a diarizer speaker. Ordinals
    /// follow the first turn (turns are already in (start, track) order); speakers without turns come last.
    private static func makeSpeakers(turns: [SpeakerTurn],
                                     channelSpeakers: [(id: String, displayName: String)]) -> [SessionSpeaker] {
        var speakers: [String: SessionSpeaker] = [:]
        for channel in channelSpeakers {
            speakers[channel.id] = SessionSpeaker(id: channel.id, ordinal: 0, displayName: channel.displayName,
                                                  provenance: .channelAssumption)
        }
        var order: [String] = []
        var ordered = Set<String>()
        for turn in turns {
            guard let speakerID = turn.speakerID, ordered.insert(speakerID).inserted else { continue }
            order.append(speakerID)
            if speakers[speakerID] == nil {
                speakers[speakerID] = SessionSpeaker(id: speakerID, ordinal: 0, provenance: .diarizer,
                                                     clusterIDs: turn.clusterID.map { [$0] } ?? [])
            }
        }
        let withoutTurns = channelSpeakers.map(\.id).filter { !ordered.contains($0) }
        return (order + withoutTurns).enumerated().compactMap { index, speakerID in
            guard var speaker = speakers[speakerID] else { return nil }
            speaker.ordinal = index + 1
            return speaker
        }
    }
}
