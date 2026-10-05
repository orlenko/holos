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
    /// - Acoustic echo, with `acousticEcho` (a call's mask, `EchoAnalysis`): the microphone words it calls echo leave
    ///   the turns like the text filter's, so a word either filter flags is dropped and both count toward the echo
    ///   cluster share. Words the text filter dropped are listed under reason `echo`; the others the mask dropped under
    ///   `EchoFilter.acousticReason`. Without a mask the run is what it was before the mask existed.
    public static func build(sessionID: String, transcript: Transcript, tracks: [TrackInput],
                             engine: DiarizationEngineInfo?, parameters: AlignmentParameters = .v1,
                             acousticEcho: AcousticEchoMask? = nil,
                             id: String = UUID().uuidString, createdAt: Date = Date()) -> Result {
        var seenTracks = Set<String>()
        let inputs = tracks.filter { seenTracks.insert($0.track).inserted }
        let untrackedOwner = untrackedSegmentOwner(transcript: transcript,
                                                   tracks: inputs.map { ($0.track, $0.policy) })

        var trackDiarizations: [TrackDiarization] = []
        var offsets: [String: Double] = [:]
        var windowsByCluster: [String: [EmbeddingWindow]] = [:]
        var centroids: [String: FloatVector] = [:]
        var diarized = false

        for input in inputs {
            let includeUntracked = input.track == untrackedOwner
            switch input.policy {
            case .skipped, .channel:
                trackDiarizations.append(TrackDiarization(track: input.track, policy: input.policy))
            case .diarized:
                diarized = true
                let output = input.output
                    ?? DiarizerOutput(segments: [], centroids: [:], windows: [], processingSeconds: 0)
                let offset = SpeakerAlignment.estimateOffset(
                    segments: transcript.segments, track: input.track, includeUntracked: includeUntracked,
                    diarization: DiarizationNormalizer.normalize(output, track: input.track), parameters: parameters)
                offsets[input.track] = offset
                let shifted = shift(output, by: offset)
                trackDiarizations.append(DiarizationNormalizer.normalize(shifted, track: input.track))
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

        let aligned = align(transcript: transcript, tracks: trackDiarizations, parameters: parameters,
                            acousticEcho: acousticEcho)
        let runEngine = diarized ? engine : nil
        let run = DiarizationRun(
            id: id, sessionID: sessionID, createdAt: createdAt, transcriptID: transcript.id, engine: runEngine,
            alignment: AlignmentInfo(version: alignmentVersion, parameters: parameters, trackOffsets: offsets),
            tracks: trackDiarizations, speakers: aligned.speakers, turns: aligned.turns,
            droppedWords: aligned.droppedWords)

        let voiceData = runEngine.map { engine in
            let speakerClusters = Set(aligned.speakers.flatMap(\.clusterIDs))
            return SessionVoiceData(
                runID: id, sessionID: sessionID, createdAt: createdAt, embeddingModel: engine.embeddingModel,
                centroids: centroids.filter { speakerClusters.contains($0.key) },
                turnEmbeddings: TurnEmbeddings.compute(turns: aligned.turns, windowsByCluster: windowsByCluster))
        }
        return Result(run: run, voiceData: voiceData)
    }

    /// `run` aligned again on the diarization it stored (`run.tracks`, already shifted and normalized), with its own
    /// alignment parameters and `acousticEcho`, as `build` aligns it: no diarizer pass, so every cluster and speaker
    /// ID stays and only the turns that echo removal changes differ. `transcript` must be the run's
    /// (`run.transcriptID`). The result has a new `id` and `createdAt` and the current `alignmentVersion`; tracks,
    /// offsets and engine are the run's. No voice data: the run's embedding windows were never stored.
    public static func rebuild(_ run: DiarizationRun, transcript: Transcript, acousticEcho: AcousticEchoMask?,
                               id: String = UUID().uuidString, createdAt: Date = Date()) -> DiarizationRun {
        let aligned = align(transcript: transcript, tracks: run.tracks, parameters: run.alignment.parameters,
                            acousticEcho: acousticEcho)
        var rebuilt = run
        rebuilt.id = id
        rebuilt.createdAt = createdAt
        rebuilt.alignment.version = alignmentVersion
        rebuilt.speakers = aligned.speakers
        rebuilt.turns = aligned.turns
        rebuilt.droppedWords = aligned.droppedWords
        return rebuilt
    }

    /// Words, turns, speakers and dropped words of `tracks` (diarized tracks with their final segments): the
    /// alignment `build` and `rebuild` share.
    private static func align(transcript: Transcript, tracks: [TrackDiarization], parameters: AlignmentParameters,
                              acousticEcho: AcousticEchoMask?)
        -> (turns: [SpeakerTurn], speakers: [SessionSpeaker], droppedWords: [DroppedWords]) {
        let untrackedOwner = untrackedSegmentOwner(transcript: transcript, tracks: tracks.map { ($0.track, $0.policy) })
        let textSpans = EchoFilter.echoSpans(transcript: transcript, parameters: parameters)
        let textWords = EchoFilter.words(in: textSpans)
        let acousticSpans = acousticEcho.map {
            EchoFilter.acousticEchoSpans(transcript: transcript, mask: $0, excluding: textWords)
        } ?? []
        let echoWords = textWords.union(EchoFilter.words(in: acousticSpans))

        var turns: [SpeakerTurn] = []
        var channelSpeakers: [(id: String, displayName: String)] = []
        for diarization in tracks {
            let includeUntracked = diarization.track == untrackedOwner
            switch diarization.policy {
            case .skipped:
                continue
            case .channel(let speakerID, let displayName):
                let words = SpeakerAlignment.assignWords(segments: transcript.segments, track: diarization.track,
                                                         includeUntracked: includeUntracked,
                                                         diarization: diarization, parameters: parameters)
                turns += turnsWithoutEcho(words, track: diarization.track, echo: echoWords, hidingEchoClusters: false,
                                          parameters: parameters, policy: diarization.policy)
                if !channelSpeakers.contains(where: { $0.id == speakerID }) {
                    channelSpeakers.append((speakerID, displayName))
                }
            case .diarized:
                let words = SpeakerAlignment.assignWords(segments: transcript.segments, track: diarization.track,
                                                         includeUntracked: includeUntracked,
                                                         diarization: diarization, parameters: parameters)
                turns += turnsWithoutEcho(words, track: diarization.track, echo: echoWords, hidingEchoClusters: true,
                                          parameters: parameters, policy: diarization.policy)
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
        var dropped: [DroppedWords] = []
        if !textSpans.isEmpty { dropped.append(DroppedWords(spans: textSpans, reason: EchoFilter.reason)) }
        if !acousticSpans.isEmpty { dropped.append(DroppedWords(spans: acousticSpans, reason: EchoFilter.acousticReason)) }
        return (turns, makeSpeakers(turns: turns, channelSpeakers: channelSpeakers), dropped)
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

    /// The track whose alignment counts transcript segments without a track, or nil.
    private static func untrackedSegmentOwner(transcript: Transcript,
                                              tracks: [(track: String, policy: TrackPolicy)]) -> String? {
        guard transcript.segments.contains(where: { $0.track == nil }) else { return nil }
        let named = Set(transcript.segments.compactMap(\.track))
        return tracks.first { input in
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
