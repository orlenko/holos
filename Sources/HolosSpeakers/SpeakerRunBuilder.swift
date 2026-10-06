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

    /// `run` with the microphone words `acousticEcho` calls echo taken out of its turns, as `build` takes them out:
    /// no diarizer pass and no new alignment, so every word keeps the turn and speaker the run gives it (including
    /// ownership a word-fix retarget carried by provenance, `SpeakerTranscriptRetarget`, which aligning the fixed
    /// transcript's estimated times again could move), and every cluster and speaker ID stays. `transcript` must be
    /// the run's (`run.transcriptID`).
    ///
    /// - The text filter's drops stay as they are. Every other microphone word is judged by the mask: the run's
    ///   earlier `EchoFilter.acousticReason` drops too, so a mask computed again (a new analysis version, `--force`,
    ///   or no echo found, `acousticEcho` nil) can give back words an older one took. The `acousticReason` entry
    ///   lists exactly the mask's drops now (none: no entry).
    /// - A microphone turn loses its new echo words and is cut where they were, as in `build`; a turn left with no
    ///   word goes; the pieces keep the turn's speaker, cluster and score, and take the time and timing quality of
    ///   their words. Turns of other tracks are unchanged.
    /// - Words given back, which no turn holds, get the speaker the run's stored diarization gives them (the label
    ///   `build` gave them before they were dropped; unknown speaker for a cluster the run does not list) and form
    ///   turns of their own, by `build`'s turn rules, between the turns around them.
    /// - Echo clusters, as in `build`: a diarized microphone cluster that loses words to the mask and then has at
    ///   least `EchoFilter.echoClusterShare` of its labelled words dropped is not listed; its remaining turns become
    ///   unknown speaker, and other turns stop naming it among their overlaps. Its labelled words are those of its
    ///   turns plus its words in no turn (dropped, or given back), labelled by the run's stored diarization. A cluster
    ///   hidden before is not listed again.
    /// - Turns are numbered T1… again in (start, track) order and speakers listed again (`build`'s rules); every
    ///   speaker the run had stays listed after them, even without turns now, so the head's edits that name it still
    ///   apply.
    /// - A word a surviving turn already holds is never given back a second time, and turn and dropped-word spans are
    ///   read only within the words their segments have.
    /// - Nothing to drop or give back returns the run as it is, with the new `id` and `createdAt`.
    ///
    /// Tracks, offsets, alignment and engine are the run's. No voice data: the run's embedding windows were never
    /// stored.
    public static func rebuild(_ run: DiarizationRun, transcript: Transcript, acousticEcho: AcousticEchoMask?,
                               id: String = UUID().uuidString, createdAt: Date = Date()) -> DiarizationRun {
        var rebuilt = run
        rebuilt.id = id
        rebuilt.createdAt = createdAt
        var effective: [String: [EffectiveWord]] = [:]
        for segment in transcript.segments where effective[segment.id] == nil {
            effective[segment.id] = WordTiming.effectiveWords(of: segment)
        }
        // Spans come from a file: only the words they name that exist are read (a span to Int.max must not be
        // expanded word by word).
        let counts = effective.mapValues(\.count)
        let textDropped = EchoFilter.words(in: bounded(run.droppedWords.filter { $0.reason != EchoFilter.acousticReason }
            .flatMap(\.spans), counts))
        let earlier = EchoFilter.words(in: bounded(run.droppedWords.filter { $0.reason == EchoFilter.acousticReason }
            .flatMap(\.spans), counts))
        let held = Set(run.turns.flatMap { turnWords($0, counts) })
        let acousticSpans = acousticEcho.map {
            EchoFilter.acousticEchoSpans(transcript: transcript, mask: $0, excluding: textDropped)
        } ?? []
        let acoustic = EchoFilter.words(in: acousticSpans)
        // Leaving the turns: what the mask flags that a turn holds. Coming back: what an older mask took and this one
        // keeps, unless a turn holds it already (a word fix can map one replacement word both into the dropped words
        // and into a turn).
        let echo = acoustic.intersection(held)
        let restored = earlier.subtracting(acoustic).subtracting(held)
        let listedBefore = run.droppedWords.filter { $0.reason == EchoFilter.acousticReason }.flatMap(\.spans)
        guard !echo.isEmpty || !restored.isEmpty || listedBefore != acousticSpans else { return rebuilt }
        let microphone = EchoFilter.microphoneTrack
        let hidden = echoClusters(run, transcript: transcript, newEcho: echo, counts: counts,
                                  alreadyDropped: textDropped.union(earlier.intersection(acoustic)).subtracting(held),
                                  restored: restored)

        var turns: [SpeakerTurn] = []
        for turn in run.turns {
            guard turn.track == microphone else {
                turns.append(turn)
                continue
            }
            var pieces: [[WordRef]] = [[]]
            for ref in turnWords(turn, counts) {
                if echo.contains(ref) {
                    if !(pieces.last?.isEmpty ?? true) { pieces.append([]) }
                } else {
                    pieces[pieces.count - 1].append(ref)
                }
            }
            for piece in pieces where !piece.isEmpty {
                var kept = turn
                kept.spans = spans(of: piece)
                let words = piece.compactMap { ref in
                    effective[ref.segmentID].flatMap { $0.indices.contains(ref.word) ? $0[ref.word] : nil }
                }
                if !words.isEmpty {
                    kept.start = words.map(\.start).min() ?? turn.start
                    kept.end = words.map(\.end).max() ?? turn.end
                    let estimated = words.filter(\.estimated).count
                    kept.timing = estimated == 0 ? .measured : estimated == words.count ? .estimated : .mixed
                }
                if let cluster = turn.clusterID, hidden.contains(cluster) {
                    kept.speakerID = nil
                    kept.clusterID = nil
                    kept.assignmentScore = 0
                    kept.otherClusters = []
                    kept.overlap = false
                }
                turns.append(kept)
            }
        }
        turns += restoredTurns(run, transcript: transcript, restored: restored, hidden: hidden)
        if !hidden.isEmpty {
            // A hidden cluster is in no `speakers` entry, so no turn may still be overlapped with it.
            for index in turns.indices where turns[index].otherClusters.contains(where: hidden.contains) {
                turns[index].otherClusters.removeAll(where: hidden.contains)
                if turns[index].otherClusters.isEmpty { turns[index].overlap = false }
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
        var channelSpeakers: [(id: String, displayName: String)] = []
        for track in run.tracks {
            if case .channel(let speakerID, let displayName) = track.policy,
               !channelSpeakers.contains(where: { $0.id == speakerID }) {
                channelSpeakers.append((speakerID, displayName))
            }
        }
        rebuilt.turns = turns
        rebuilt.speakers = makeSpeakers(turns: turns, channelSpeakers: channelSpeakers)
        // Every speaker the run had stays listed in it, with or without turns now (after the others): the head's
        // edits name them (a speaker renamed, a system turn given to a microphone speaker whose own turns were all
        // echo), and an edit on a speaker the run does not hold could not apply. The projection shows a speaker
        // only once it has turns.
        var listed = Set(rebuilt.speakers.map(\.id))
        for speaker in run.speakers where listed.insert(speaker.id).inserted {
            var kept = speaker
            kept.ordinal = rebuilt.speakers.count + 1
            rebuilt.speakers.append(kept)
        }
        if let index = rebuilt.droppedWords.firstIndex(where: { $0.reason == EchoFilter.acousticReason }) {
            if acousticSpans.isEmpty {
                rebuilt.droppedWords.remove(at: index)
            } else {
                rebuilt.droppedWords[index].spans = acousticSpans
            }
        } else if !acousticSpans.isEmpty {
            rebuilt.droppedWords.append(DroppedWords(spans: acousticSpans, reason: EchoFilter.acousticReason))
        }
        return rebuilt
    }

    /// Turns for microphone words `rebuild` gives back: each run of such words with no other microphone word between
    /// them, labelled by the run's stored diarization (a cluster in `hidden` or not listed by the run becomes unknown
    /// speaker) and cut into turns by `SpeakerAlignment.buildTurns`.
    private static func restoredTurns(_ run: DiarizationRun, transcript: Transcript, restored: Set<WordRef>,
                                      hidden: Set<String>) -> [SpeakerTurn] {
        let microphone = EchoFilter.microphoneTrack
        guard !restored.isEmpty, let diarization = run.tracks.first(where: { $0.track == microphone }) else {
            return []
        }
        if case .skipped = diarization.policy { return [] }
        let owner = untrackedSegmentOwner(transcript: transcript, tracks: run.tracks.map { ($0.track, $0.policy) })
        let aligned = SpeakerAlignment.assignWords(segments: transcript.segments, track: microphone,
                                                   includeUntracked: owner == microphone, diarization: diarization,
                                                   parameters: run.alignment.parameters)
        var listed = Set(run.speakers.flatMap(\.clusterIDs)).subtracting(hidden)
        if case .channel(let speakerID, _) = diarization.policy { listed.insert(speakerID) }
        var turns: [SpeakerTurn] = []
        var group: [AlignedWord] = []
        func flush() {
            if !group.isEmpty {
                turns += SpeakerAlignment.buildTurns(group, parameters: run.alignment.parameters,
                                                     policy: diarization.policy)
            }
            group = []
        }
        for var word in aligned {
            guard restored.contains(word.ref) else {
                flush()
                continue
            }
            if case .diarized = diarization.policy {
                if let label = word.label, !listed.contains(label) {
                    word.label = nil
                    word.coveredSeconds = 0
                }
                word.overlapClusters = word.overlapClusters.filter(listed.contains)
            }
            group.append(word)
        }
        flush()
        return turns
    }

    /// The diarized microphone clusters `rebuild` hides: each that loses a word to `newEcho` and then has at least
    /// `EchoFilter.echoClusterShare` of its labelled words dropped (words given back, `restored`, count as labelled).
    private static func echoClusters(_ run: DiarizationRun, transcript: Transcript, newEcho: Set<WordRef>,
                                     counts: [String: Int], alreadyDropped: Set<WordRef>,
                                     restored: Set<WordRef>) -> Set<String> {
        let microphone = EchoFilter.microphoneTrack
        guard let diarization = run.tracks.first(where: { $0.track == microphone }),
              case .diarized = diarization.policy else { return [] }
        var labelled: [String: Int] = [:]
        var echoed: [String: Int] = [:]
        var losing = Set<String>()
        for turn in run.turns where turn.track == microphone {
            guard let cluster = turn.clusterID else { continue }
            for ref in turnWords(turn, counts) {
                labelled[cluster, default: 0] += 1
                if newEcho.contains(ref) {
                    echoed[cluster, default: 0] += 1
                    losing.insert(cluster)
                }
            }
        }
        guard !losing.isEmpty else { return [] }
        // Words dropped before are in no turn: their cluster is the one the stored diarization gives them.
        let owner = untrackedSegmentOwner(transcript: transcript, tracks: run.tracks.map { ($0.track, $0.policy) })
        let aligned = SpeakerAlignment.assignWords(segments: transcript.segments, track: microphone,
                                                   includeUntracked: owner == microphone, diarization: diarization,
                                                   parameters: run.alignment.parameters)
        for word in aligned {
            guard let label = word.label else { continue }
            if alreadyDropped.contains(word.ref) {
                labelled[label, default: 0] += 1
                echoed[label, default: 0] += 1
            } else if restored.contains(word.ref) {
                labelled[label, default: 0] += 1
            }
        }
        // The tolerance keeps an exact share (3 of 5 is 60 %) from missing the threshold by rounding.
        return losing.filter { cluster in
            Double(echoed[cluster] ?? 0) >= EchoFilter.echoClusterShare * Double(labelled[cluster] ?? 0) - 1e-9
        }
    }

    /// A turn's words in span order, only those that exist (`counts`: effective words per segment).
    private static func turnWords(_ turn: SpeakerTurn, _ counts: [String: Int]) -> [WordRef] {
        bounded(turn.spans, counts).flatMap { span in
            (span.first..<span.end).map { WordRef(segmentID: span.segmentID, word: $0) }
        }
    }

    /// `spans` cut to the words that exist: a span of a segment the transcript does not have, or one that ends at or
    /// before its first word, goes; the others are clamped to 0..<count.
    private static func bounded(_ spans: [WordSpan], _ counts: [String: Int]) -> [WordSpan] {
        spans.compactMap { span in
            guard let count = counts[span.segmentID] else { return nil }
            let first = max(0, span.first)
            let end = min(count, span.end)
            return first < end ? WordSpan(segmentID: span.segmentID, first: first, end: end) : nil
        }
    }

    /// Spans of consecutive `words` (in the given order) of one segment.
    private static func spans(of words: [WordRef]) -> [WordSpan] {
        var spans: [WordSpan] = []
        for ref in words {
            if let last = spans.last, last.segmentID == ref.segmentID, last.end == ref.word {
                spans[spans.count - 1].end += 1
            } else {
                spans.append(WordSpan(segmentID: ref.segmentID, first: ref.word, end: ref.word + 1))
            }
        }
        return spans
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
