import Foundation
import HolosCore

// MARK: - Document

/// Session facts for the export headers (docs/meeting-design.md §4.11).
public struct ExportMetadata: Sendable, Equatable {
    public var sessionID: String
    public var name: String
    public var createdAt: Date
    /// Max chunk end over tracks.
    public var durationSeconds: Double
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    /// For the Markdown header's local date and start time; tests pass UTC.
    public var timeZone: TimeZone

    public init(sessionID: String, name: String, createdAt: Date, durationSeconds: Double, source: AudioSource,
                locale: String, backend: SpeechBackend, timeZone: TimeZone) {
        self.sessionID = sessionID; self.name = name; self.createdAt = createdAt
        self.durationSeconds = durationSeconds; self.source = source; self.locale = locale
        self.backend = backend; self.timeZone = timeZone
    }
}

/// Everything one export is rendered from. `SessionExports` (PR7b) loads it from a session folder; the exporter
/// itself does no file IO.
public struct ExportDocument: Sendable, Equatable {
    public var metadata: ExportMetadata
    /// The transcript the projection's spans reference: the head run's transcript (§2.4).
    public var transcript: Transcript
    /// Supplies `runID`, `engine`, and `alignment` of the JSON export; ignored when built from another transcript.
    public var run: DiarizationRun?
    /// nil → one pseudo-turn per segment named by track ("Microphone", "System audio"). A projection built from
    /// another transcript (`projection.transcriptID != transcript.id`) is treated the same way, because its spans
    /// would name other words.
    public var projection: SpeakerProjection?
    public var gaps: [TimelineGap]
    public var markers: [TimelineMarker]

    public init(metadata: ExportMetadata, transcript: Transcript, run: DiarizationRun? = nil,
                projection: SpeakerProjection? = nil, gaps: [TimelineGap] = [], markers: [TimelineMarker] = []) {
        self.metadata = metadata; self.transcript = transcript; self.run = run; self.projection = projection
        self.gaps = gaps; self.markers = markers
    }
}

/// The document keeps transcript text, names, and marker labels. Printing, `dump`, and test-failure output show only
/// IDs and counts (docs/meeting-design.md §1.5, §1.9).
extension ExportDocument: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ExportDocument(sessionID: \(metadata.sessionID), transcriptID: \(transcript.id), "
            + "segments: \(transcript.segments.count), runID: \(run?.id ?? "nil"), "
            + "projection: \(projection.map { String(describing: $0) } ?? "nil"), gaps: \(gaps.count), "
            + "markers: \(markers.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "sessionID": metadata.sessionID,
            "transcriptID": transcript.id,
            "segments": transcript.segments.count,
            "runID": run?.id as Any,
            // The projection's own mirror lists speaker names; its description has IDs and counts only.
            "projection": projection.map { String(describing: $0) } as Any,
            "gaps": gaps.count,
            "markers": markers.count,
        ], displayStyle: .struct)
    }
}

/// v1 export formats: `exports/transcript.<rawValue>`.
public enum ExportFormat: String, CaseIterable, Sendable {
    case md, json, txt
}

/// One speaker block of the Markdown and text exports: consecutive turns of one speaker.
public struct ExportBlock: Sendable, Equatable {
    /// The projection's label ("Jim", "Jim (auto)", "Speaker 3", "Me"), "Unknown speaker", or the track name
    /// without a projection.
    public var speakerLabel: String
    /// Start of the first turn.
    public var start: Double
    public var turnIDs: [String]
    /// The turns' texts joined with " ".
    public var text: String
    /// Labels of other speakers whose clusters overlap the block's turns, in speaker order.
    public var overlapWith: [String]

    public init(speakerLabel: String, start: Double, turnIDs: [String], text: String, overlapWith: [String] = []) {
        self.speakerLabel = speakerLabel; self.start = start; self.turnIDs = turnIDs; self.text = text
        self.overlapWith = overlapWith
    }
}

// MARK: - Exporter

/// Renders an `ExportDocument` as Markdown, plain text, or JSON (docs/meeting-design.md §4.11). Pure: no file IO.
///
/// Common rules: turns in `(start, track)` order; the speaker shown is the projection's `label`; an unknown speaker is
/// "Unknown speaker"; without a projection, turns are the transcript's segments, named "Microphone" and
/// "System audio" by track (a segment without a track takes it from a single-track `metadata.source`).
/// Suggestions (`ProjectedSpeaker.suggestion`) never appear, and no format contains vectors of any kind.
public enum TranscriptExporter {
    public static func render(_ document: ExportDocument, format: ExportFormat) throws -> Data {
        let content = ExportContent(document)
        switch format {
        case .md: return MarkdownExport.render(content)
        case .txt: return TextExport.render(content)
        case .json: return try JSONExport.render(content)
        }
    }

    /// Turn text: from the first word's UTF-16 offset (or 0 for the segment's first word) to the next word's offset
    /// (or the end of the segment text), per span, joined with " ", trimmed.
    ///
    /// Spans are clamped to the segment's effective words, and a span of a missing segment contributes nothing, so
    /// an invalid span never traps. When recognizer offsets do not fit the text (out of order, past its end), the
    /// span's word texts joined with " " are used instead.
    public static func text(of spans: [WordSpan], in transcript: Transcript) -> String {
        TranscriptText(transcript).text(of: spans)
    }

    /// Markdown and text blocks: consecutive turns of the same speaker are merged unless a gap, a marker, or more
    /// than 30 s of silence separates them.
    ///
    /// Turns without printable text are left out. A gap separates two turns when it starts after the first turn's start and
    /// no later than the second turn's start (gap and marker lines are placed by time, before a block starting at
    /// the same time, so a separating line always lands between the two blocks); a marker likewise by its time.
    /// Silence is measured from the latest end of the block's turns. Consecutive unknown-speaker turns merge only
    /// on the same track; without a projection, consecutive segments of one track merge.
    public static func blocks(_ document: ExportDocument) -> [ExportBlock] {
        ExportContent(document).blocks
    }
}

// MARK: - Shared content

/// Labels and limits shared by the formats.
enum ExportRules {
    static let unknownSpeaker = "Unknown speaker"
    static let microphone = "Microphone"
    static let systemAudio = "System audio"
    /// More silence than this between two turns of one speaker starts a new block.
    static let blockSilenceSeconds = 30.0
}

/// One turn as every format shows it.
struct ExportTurn: Sendable, Equatable {
    let id: String
    let speakerID: String?
    /// Turns merge into one block only with the same key: the speaker, the track of an unknown speaker, or the
    /// track without a projection.
    let groupKey: String
    let label: String
    let track: String?
    let start: Double
    let end: Double
    let text: String
    let overlap: Bool
    /// Current speakers of the turn's other clusters, in speaker order, without the turn's own speaker.
    let otherSpeakerIDs: [String]
    let score: Double
    let timing: WordTimingQuality
    let spans: [WordSpan]
}

/// The document resolved once for every format: turns with text and labels, sorted annotations, and blocks.
struct ExportContent {
    let document: ExportDocument
    /// The document's run and projection when they were built from `document.transcript`.
    let run: DiarizationRun?
    let projection: SpeakerProjection?
    let turns: [ExportTurn]
    /// Finite, `start <= end`, by start.
    let gaps: [TimelineGap]
    /// Finite, by time.
    let markers: [TimelineMarker]
    let blocks: [ExportBlock]

    init(_ document: ExportDocument) {
        self.document = document
        run = document.run.flatMap { $0.transcriptID == document.transcript.id ? $0 : nil }
        let projection = document.projection.flatMap { $0.transcriptID == document.transcript.id ? $0 : nil }
        self.projection = projection

        // Speaker ID → label and position in `projection.speakers`.
        var labels: [String: String] = [:]
        var speakerOrder: [String: Int] = [:]
        for (index, speaker) in (projection?.speakers ?? []).enumerated() where labels[speaker.id] == nil {
            labels[speaker.id] = speaker.label
            speakerOrder[speaker.id] = index
        }

        if let projection {
            turns = Self.projectedTurns(projection, transcript: document.transcript, labels: labels,
                                        speakerOrder: speakerOrder)
        } else {
            turns = Self.segmentTurns(document.transcript, source: document.metadata.source)
        }
        gaps = document.gaps.enumerated()
            .filter { $0.element.start.isFinite && $0.element.end.isFinite && $0.element.start <= $0.element.end }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        markers = document.markers.enumerated()
            .filter { $0.element.at.isFinite }
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
        blocks = Self.makeBlocks(turns, lineTimes: (gaps.map(\.start) + markers.map(\.at)).sorted(),
                                 labels: labels, speakerOrder: speakerOrder)
    }

    /// The projection's turns, already in (start, track, id) order.
    private static func projectedTurns(_ projection: SpeakerProjection, transcript: Transcript,
                                       labels: [String: String], speakerOrder: [String: Int]) -> [ExportTurn] {
        var clusterOwner: [String: String] = [:]
        for speaker in projection.speakers {
            for clusterID in speaker.clusterIDs where clusterOwner[clusterID] == nil {
                clusterOwner[clusterID] = speaker.id
            }
        }
        let text = TranscriptText(transcript)
        return projection.turns.map { turn in
            var others: [String] = []
            for clusterID in turn.otherClusters {
                guard let owner = clusterOwner[clusterID], owner != turn.speakerID, !others.contains(owner) else {
                    continue
                }
                others.append(owner)
            }
            others.sort { speakerOrder[$0, default: .max] < speakerOrder[$1, default: .max] }
            let label = turn.speakerID.flatMap { labels[$0] } ?? ExportRules.unknownSpeaker
            return ExportTurn(
                id: turn.id, speakerID: turn.speakerID,
                groupKey: turn.speakerID.map { "speaker:\($0)" } ?? "unknown:\(turn.track)",
                label: label, track: turn.track, start: turn.start, end: turn.end, text: text.text(of: turn.spans),
                overlap: turn.overlap, otherSpeakerIDs: others, score: turn.assignmentScore, timing: turn.timing,
                spans: turn.spans)
        }
    }

    /// One pseudo-turn "T1"… per segment with text, in (start, track) order, named by track.
    private static func segmentTurns(_ transcript: Transcript, source: AudioSource) -> [ExportTurn] {
        let singleTrack: String? = switch source {
        case .microphone: "mic"
        case .system: "system"
        case .microphoneAndSystem: nil
        }
        let order = transcript.segments.indices.sorted { left, right in
            let a = transcript.segments[left]
            let b = transcript.segments[right]
            let aStart = a.start.isNaN ? Double.infinity : a.start
            let bStart = b.start.isNaN ? Double.infinity : b.start
            if aStart != bStart { return aStart < bStart }
            if a.track != b.track { return (a.track ?? "") < (b.track ?? "") }
            return left < right
        }
        var turns: [ExportTurn] = []
        for index in order {
            let segment = transcript.segments[index]
            let entry = TranscriptText.Segment(segment)
            let text = entry.text(first: 0, end: entry.words.count)
            guard !text.isEmpty else { continue }
            let track = segment.track ?? singleTrack
            let label = switch track {
            case "mic"?: ExportRules.microphone
            case "system"?: ExportRules.systemAudio
            case let other?: other
            case nil: ExportRules.unknownSpeaker
            }
            let estimated = entry.words.filter(\.estimated).count
            turns.append(ExportTurn(
                id: "T\(turns.count + 1)", speakerID: nil, groupKey: "track:\(track ?? "")", label: label,
                track: track, start: segment.start, end: segment.end, text: text, overlap: false, otherSpeakerIDs: [],
                score: 0,
                timing: estimated == 0 ? .measured : estimated == entry.words.count ? .estimated : .mixed,
                spans: [WordSpan(segmentID: segment.id, first: 0, end: entry.words.count)]))
        }
        return turns
    }

    /// `TranscriptExporter.blocks` rules. `lineTimes` are the sorted times of gap and marker lines.
    private static func makeBlocks(_ turns: [ExportTurn], lineTimes: [Double], labels: [String: String],
                                   speakerOrder: [String: Int]) -> [ExportBlock] {
        struct OpenBlock {
            var key: String
            var label: String
            var start: Double
            var lastStart: Double
            var end: Double
            var turnIDs: [String]
            var texts: [String]
            var others: [String]
        }
        func close(_ open: OpenBlock) -> ExportBlock {
            var overlapWith: [String] = []
            for speakerID in open.others.sorted(by: { speakerOrder[$0, default: .max] < speakerOrder[$1, default: .max] }) {
                let label = labels[speakerID] ?? ExportRules.unknownSpeaker
                if !overlapWith.contains(label) { overlapWith.append(label) }
            }
            return ExportBlock(speakerLabel: open.label, start: open.start, turnIDs: open.turnIDs,
                               text: open.texts.joined(separator: " "), overlapWith: overlapWith)
        }
        /// True when some line time t has `after < t <= upTo`.
        func lineBetween(after: Double, upTo: Double) -> Bool {
            var low = 0
            var high = lineTimes.count
            while low < high {
                let middle = (low + high) / 2
                if lineTimes[middle] > after { high = middle } else { low = middle + 1 }
            }
            return low < lineTimes.count && lineTimes[low] <= upTo
        }

        var blocks: [ExportBlock] = []
        var current: OpenBlock?
        for turn in turns where !ExportText.singleLine(turn.text).isEmpty {
            if var open = current, open.key == turn.groupKey,
               !(turn.start - open.end > ExportRules.blockSilenceSeconds),
               !lineBetween(after: open.lastStart, upTo: turn.start) {
                open.lastStart = turn.start
                open.end = max(open.end, turn.end)
                open.turnIDs.append(turn.id)
                open.texts.append(turn.text)
                for speakerID in turn.otherSpeakerIDs where !open.others.contains(speakerID) {
                    open.others.append(speakerID)
                }
                current = open
                continue
            }
            if let open = current { blocks.append(close(open)) }
            current = OpenBlock(key: turn.groupKey, label: turn.label, start: turn.start, lastStart: turn.start,
                                end: turn.end, turnIDs: [turn.id], texts: [turn.text], others: turn.otherSpeakerIDs)
        }
        if let open = current { blocks.append(close(open)) }
        return blocks
    }
}

// MARK: - Transcript text

/// Segment texts and effective words by segment ID (the first segment wins when IDs repeat), for turn text.
struct TranscriptText {
    struct Segment {
        let utf16: [UInt16]
        let words: [EffectiveWord]

        init(_ segment: TranscriptSegment) {
            utf16 = Array(segment.text.utf16)
            words = WordTiming.effectiveWords(of: segment)
        }

        /// Text of words `[first, end)`, clamped to the words; "" when that range is empty.
        func text(first: Int, end: Int) -> String {
            let first = max(0, first)
            let end = min(words.count, end)
            guard first < end else { return "" }
            let lower = first == 0 ? 0 : min(max(words[first].utf16Offset, 0), utf16.count)
            let upper = end == words.count ? utf16.count : min(max(words[end].utf16Offset, 0), utf16.count)
            if lower < upper {
                let text = ExportText.trimmed(String(decoding: utf16[lower..<upper], as: UTF16.self))
                if !text.isEmpty { return text }
            }
            // Offsets that do not fit the text: fall back to the recognizer's word texts.
            return ExportText.trimmed(words[first..<end].map(\.text).joined(separator: " "))
        }
    }

    private var segments: [String: Segment] = [:]

    init(_ transcript: Transcript) {
        for segment in transcript.segments where segments[segment.id] == nil {
            segments[segment.id] = Segment(segment)
        }
    }

    func text(of spans: [WordSpan]) -> String {
        var pieces: [String] = []
        for span in spans {
            guard let segment = segments[span.segmentID] else { continue }
            let piece = segment.text(first: span.first, end: span.end)
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces.joined(separator: " ")
    }
}

// MARK: - Text helpers

enum ExportText {
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs of whitespace, line breaks, and control characters become one space; the ends are trimmed. The result
    /// never contains two whitespace characters in a row, so a text line can never look like a text-export header.
    static func singleLine(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(character)
        }
        return result
    }

    /// A label on one header line; "Unknown speaker" when nothing printable is left.
    static func headerLabel(_ label: String) -> String {
        let line = singleLine(label)
        return line.isEmpty ? ExportRules.unknownSpeaker : line
    }
}
