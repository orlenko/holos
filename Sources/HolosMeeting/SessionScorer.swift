import CryptoKit
import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// `holos session score` (hidden; docs/meeting-design.md §5.5 PR7c, R24, R25): how a session's speaker labels agree
/// with Otter's for the same audio. Otter labels are people's names and Otter transcripts hold what was said, so
/// nothing here keeps or reports either: a label becomes the first 12 hex digits of its SHA-256 as soon as it is read,
/// and the report holds counts, seconds, ratios, and those keys only (§1.9).
public enum SessionScorer {
    /// A label shared by at least this many seconds of turns (Otter) or of speech (Holos) counts as a speaker in the
    /// "with at least 30 s" counts; the evaluation's speaker-count hint is built from the Otter count.
    public static let substantialSeconds = 30.0

    /// Everything `holos session score` prints. Numbers, run and cluster IDs, and hashed labels only.
    public struct Report: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        /// The head run scored.
        public var runID: String
        public var collar: Double
        /// End of the session's audio (the last chunk's end), which also ends Otter's last turn.
        public var audioSeconds: Double
        /// Otter labels with at least one turn, and those whose turns add up to at least 30 s.
        public var referenceSpeakers: Int
        public var referenceSpeakersOver30s: Int
        /// Holos speakers in the run's diarization segments (and channel speakers), and those with at least 30 s of
        /// speech.
        public var holosSpeakers: Int
        public var holosSpeakersOver30s: Int
        /// "Agreement with Otter" over the diarization segments: the share of the time where both sides have a
        /// speaker whose mapped speaker differs (`DiarizationScoring.agreement`).
        public var agreementConfusion: Double
        public var comparedSeconds: Double
        /// Mapped reference–Holos pairs.
        public var mappingSize: Int
        /// Hashed Otter label (first 12 hex digits of the SHA-256 of the label) → Holos cluster ID.
        public var mapping: [String: String]
        /// Hashed Otter labels that name nobody ("Speaker 2", "Unknown Speaker"): the same key in two files is not
        /// the same person.
        public var genericLabels: [String]
        /// The same agreement over the run's turns (what the labelled transcript shows): one speaker per word, so
        /// overlapping diarization segments do not count twice.
        public var turnAgreementConfusion: Double
        public var turnComparedSeconds: Double
        /// `AlignmentInfo.trackOffsets`: seconds added to diarization times before alignment, per track.
        public var trackOffsets: [String: Double]
        /// The engine settings the run recorded (for example `exclusiveSegments`); empty without an engine.
        public var engineConfiguration: [String: String]

        public init(schemaVersion: Int = 1, runID: String, collar: Double, audioSeconds: Double,
                    referenceSpeakers: Int, referenceSpeakersOver30s: Int, holosSpeakers: Int,
                    holosSpeakersOver30s: Int, agreementConfusion: Double, comparedSeconds: Double,
                    mappingSize: Int, mapping: [String: String], genericLabels: [String],
                    turnAgreementConfusion: Double, turnComparedSeconds: Double, trackOffsets: [String: Double],
                    engineConfiguration: [String: String]) {
            self.schemaVersion = schemaVersion; self.runID = runID; self.collar = collar
            self.audioSeconds = audioSeconds; self.referenceSpeakers = referenceSpeakers
            self.referenceSpeakersOver30s = referenceSpeakersOver30s; self.holosSpeakers = holosSpeakers
            self.holosSpeakersOver30s = holosSpeakersOver30s; self.agreementConfusion = agreementConfusion
            self.comparedSeconds = comparedSeconds; self.mappingSize = mappingSize; self.mapping = mapping
            self.genericLabels = genericLabels; self.turnAgreementConfusion = turnAgreementConfusion
            self.turnComparedSeconds = turnComparedSeconds; self.trackOffsets = trackOffsets
            self.engineConfiguration = engineConfiguration
        }

        /// The text `holos session score` prints without `--json`: numbers only, not even hashed labels.
        public var summaryLines: [String] {
            [
                "Reference speakers: \(referenceSpeakers) (\(referenceSpeakersOver30s) with at least 30 s)",
                "Holos speakers: \(holosSpeakers) (\(holosSpeakersOver30s) with at least 30 s)",
                "Agreement with Otter, speaker segments: confusion \(Self.percent(agreementConfusion)) over "
                    + "\(Self.seconds(comparedSeconds)) compared",
                "Agreement with Otter, labelled turns: confusion \(Self.percent(turnAgreementConfusion)) over "
                    + "\(Self.seconds(turnComparedSeconds)) compared",
                "Mapped speakers: \(mappingSize)",
            ]
        }

        private static func percent(_ value: Double) -> String {
            String(format: "%.1f %%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
        }

        private static func seconds(_ value: Double) -> String {
            String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }

    /// Scores the head run of `session` against `otterTranscript` (Otter's plain-text export, parsed with
    /// `OtterTranscriptParser`). An Otter turn runs from its header to the next header, and the last one to the end
    /// of the audio. Holos speakers are the run's diarization clusters (`DiarizationSegment`, session times) and, on a
    /// channel track, its speaker's turns; the turn scores use each turn's initial speaker. Edits are not applied: the
    /// score is of the machine labels.
    ///
    /// Throws `unavailable` when the session has no speaker labels, and `invalidInput` when the transcript has no
    /// speaker turns or `collar` is not a non-negative number.
    public static func score(session: URL, otterTranscript: String, collar: Double = 0.25) throws -> Report {
        guard collar.isFinite, collar >= 0 else {
            throw HolosError.invalidInput("The collar must be a number of seconds, 0 or more.")
        }
        let manifest = try SessionArchive.readManifest(at: session)
        guard let head = try SessionSpeakerStore.readHead(session: session) else {
            throw HolosError.unavailable(
                "This session has no speaker labels yet. Label them first with holos session diarize.")
        }
        let run = try SessionSpeakerStore.readRun(id: head.runID, session: session)
        let audioSeconds = manifest.chunks.map(\.end).max() ?? 0

        let turns = OtterTranscriptParser.parse(otterTranscript)
        guard !turns.isEmpty else {
            throw HolosError.invalidInput("The Otter transcript has no speaker turns (lines like \"Name  0:05\").")
        }
        var generic = Set<String>()
        var reference: [LabelledInterval] = []
        for turn in turns {
            let key = labelKey(turn.speaker)
            if isGenericLabel(turn.speaker) { generic.insert(key) }
            let end = turn.end ?? audioSeconds
            guard turn.start.isFinite, end.isFinite, end > turn.start else { continue }
            reference.append(LabelledInterval(speaker: key, start: turn.start, end: end))
        }

        let segments = segmentIntervals(run)
        let turnIntervals = run.turns.compactMap { turn -> LabelledInterval? in
            guard let speaker = turn.speakerID else { return nil }
            return LabelledInterval(speaker: speaker, start: turn.start, end: turn.end)
        }
        let agreement = DiarizationScoring.agreement(reference: reference, hypothesis: segments, collar: collar)
        let turnAgreement = DiarizationScoring.agreement(reference: reference, hypothesis: turnIntervals,
                                                         collar: collar)
        let referenceSeconds = speakingSeconds(reference)
        let holosSeconds = speakingSeconds(segments)
        return Report(
            runID: run.id, collar: collar, audioSeconds: audioSeconds,
            referenceSpeakers: referenceSeconds.count,
            referenceSpeakersOver30s: referenceSeconds.values.filter { $0 >= substantialSeconds }.count,
            holosSpeakers: holosSeconds.count,
            holosSpeakersOver30s: holosSeconds.values.filter { $0 >= substantialSeconds }.count,
            agreementConfusion: agreement.confusion, comparedSeconds: agreement.comparedSeconds,
            mappingSize: agreement.mapping.count, mapping: agreement.mapping,
            genericLabels: generic.filter { referenceSeconds[$0] != nil }.sorted(),
            turnAgreementConfusion: turnAgreement.confusion, turnComparedSeconds: turnAgreement.comparedSeconds,
            trackOffsets: run.alignment.trackOffsets, engineConfiguration: run.engine?.configuration ?? [:])
    }

    /// The key a label is reported by: the first 12 hex digits of the SHA-256 of its UTF-8 text, trimmed.
    public static func labelKey(_ label: String) -> String {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Otter's labels for people it did not name: "Speaker 3", "Unknown Speaker", "Unidentified Speaker 2".
    static func isGenericLabel(_ label: String) -> Bool {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.range(of: #"^(?:speaker|unknown|unidentified)(?:\s+speaker)?(?:\s*\d+)?$"#,
                          options: .regularExpression) != nil
    }

    /// The run's speakers over time: each diarized track's segments by cluster, and each channel track's turns by
    /// its speaker.
    static func segmentIntervals(_ run: DiarizationRun) -> [LabelledInterval] {
        var intervals: [LabelledInterval] = []
        for track in run.tracks {
            switch track.policy {
            case .diarized:
                intervals += track.segments.map { LabelledInterval(speaker: $0.clusterID, start: $0.start, end: $0.end) }
            case .channel(let speakerID, _):
                intervals += run.turns.filter { $0.track == track.track }.map {
                    LabelledInterval(speaker: speakerID, start: $0.start, end: $0.end)
                }
            case .skipped:
                break
            }
        }
        return intervals
    }

    /// Seconds each speaker is active: the length of the union of its intervals (finite, non-empty ones).
    static func speakingSeconds(_ intervals: [LabelledInterval]) -> [String: Double] {
        var bySpeaker: [String: [(start: Double, end: Double)]] = [:]
        for interval in intervals where interval.start.isFinite && interval.end.isFinite && interval.end > interval.start {
            bySpeaker[interval.speaker, default: []].append((interval.start, interval.end))
        }
        return bySpeaker.mapValues { ranges in
            var total = 0.0
            var current: (start: Double, end: Double)?
            for range in ranges.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
                if let open = current, range.start <= open.end {
                    current = (open.start, max(open.end, range.end))
                } else {
                    if let open = current { total += open.end - open.start }
                    current = range
                }
            }
            if let open = current { total += open.end - open.start }
            return total
        }
    }
}
