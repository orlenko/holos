import Foundation
import HolosCore

/// `exports/transcript.json` (docs/meeting-design.md §4.11): format `holos-transcript`, `schemaVersion` 1, one entry
/// per turn, with no vectors of any kind.
///
/// ```json
/// {
///   "schemaVersion": 1, "format": "holos-transcript",
///   "session": {"id": "…", "name": "…", "createdAt": "…", "durationSeconds": 10692.4,
///               "source": "mic+system", "locale": "en-CA", "backend": "speech"},
///   "transcriptID": "…", "runID": "…",
///   "engine": { DiarizationEngineInfo }, "alignment": { AlignmentInfo },
///   "speakers": [{"id": "system:S1", "ordinal": 2, "name": "Jim", "label": "Jim",
///                 "provenance": {"userConfirmed": {}}, "automatic": false, "profileID": "…",
///                 "talkSeconds": 2472.3, "turnCount": 88}],
///   "turns": [{"id": "T1", "speakerID": "system:S1", "track": "system", "start": 12.1, "end": 18.7,
///              "text": "…", "overlap": false, "otherSpeakers": [], "score": 0.97,
///              "timing": "measured", "words": [{"segmentID": "…", "first": 0, "end": 17}]}],
///   "gaps": [ TimelineGap ], "markers": [ TimelineMarker ],
///   "edits": {"applied": 5, "stale": 0, "otherRuns": 0}
/// }
/// ```
///
/// Encoded with `HolosJSON` (sorted keys, pretty) and a final newline, so the same document always gives the same
/// bytes. Every listed key is always present: `runID`, `engine`, and `alignment` are `null` without a run, with a
/// run built from another transcript, or with a run other than the projection's; `speakerID` is `null` for an
/// unknown speaker, and `profileID` is `null` without a confirmed link. `otherSpeakers` maps `otherClusters` to
/// current speaker IDs (the speaker whose clusters include it after merges), without the turn's own speaker. A
/// number that is not finite is written as `null`, including inside embedded values (`alignment`, `provenance`);
/// gaps and markers whose times are not finite (or a gap that ends
/// before it starts) are left out, and the rest are sorted by time. Without a projection, `speakers` is empty, each segment with text
/// is a turn with `speakerID` `null` and `score` 0, and the `edits` counts are 0. Suggestions and the profile IDs of
/// automatic matches are never written.
///
/// A transcript merged from several languages (docs/meeting-design.md §4.14) adds two keys, left out otherwise:
/// top-level `languages` (the languages it chose from, the preferred one first) and each turn's `languages` (those of
/// its words, in the order they first appear).
enum JSONExport {
    static func render(_ content: ExportContent) throws -> Data {
        let encoder = HolosJSON.encoder()
        // Numbers this file writes itself are already null when not finite. A non-finite number inside an embedded
        // contract value (alignment parameters and offsets, a recognition distance) is encoded as a per-render
        // random sentinel string, which is then replaced by `null`. Input text cannot contain the sentinel, because
        // it is a fresh UUID, so no real string is touched and the output stays deterministic.
        let sentinel = "holos-nonfinite-\(UUID().uuidString)"
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: sentinel, negativeInfinity: sentinel, nan: sentinel)
        let encoded = try encoder.encode(TranscriptFile(content))
        var json = String(decoding: encoded, as: UTF8.self)
        json = json.replacingOccurrences(of: "\"\(sentinel)\"", with: "null")
        json.append("\n")
        return Data(json.utf8)
    }

    static let format = "holos-transcript"
    static let schemaVersion = 1
}

// MARK: - File layout

private struct TranscriptFile: Encodable {
    let session: SessionEntry
    let transcriptID: String
    let runID: String?
    let engine: DiarizationEngineInfo?
    let alignment: AlignmentInfo?
    let speakers: [SpeakerEntry]
    let turns: [TurnEntry]
    let gaps: [TimelineGap]
    let markers: [TimelineMarker]
    let edits: EditCounts
    let languages: [String]?

    init(_ content: ExportContent) {
        let document = content.document
        session = SessionEntry(document.metadata)
        transcriptID = document.transcript.id
        languages = document.transcript.mergedLanguages
        runID = content.run?.id
        engine = content.run?.engine
        alignment = content.run?.alignment
        speakers = (content.projection?.speakers ?? []).map(SpeakerEntry.init)
        turns = content.turns.map(TurnEntry.init)
        gaps = content.gaps
        markers = content.markers
        edits = EditCounts(applied: content.projection?.appliedEditIDs.count ?? 0,
                           stale: content.projection?.staleEdits.count ?? 0,
                           otherRuns: content.projection?.otherRunEditCount ?? 0)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, format, session, transcriptID, runID, engine, alignment, speakers, turns, gaps, markers
        case edits, languages
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(JSONExport.schemaVersion, forKey: .schemaVersion)
        try container.encode(JSONExport.format, forKey: .format)
        try container.encode(session, forKey: .session)
        try container.encode(transcriptID, forKey: .transcriptID)
        try container.encodeIfPresent(languages, forKey: .languages)
        try container.encodeOrNull(runID, forKey: .runID)
        try container.encodeOrNull(engine, forKey: .engine)
        try container.encodeOrNull(alignment, forKey: .alignment)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(turns, forKey: .turns)
        try container.encode(gaps, forKey: .gaps)
        try container.encode(markers, forKey: .markers)
        try container.encode(edits, forKey: .edits)
    }
}

private struct SessionEntry: Encodable {
    let metadata: ExportMetadata

    init(_ metadata: ExportMetadata) { self.metadata = metadata }

    enum CodingKeys: String, CodingKey { case id, name, createdAt, durationSeconds, source, locale, backend }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata.sessionID, forKey: .id)
        try container.encode(metadata.name, forKey: .name)
        try container.encode(metadata.createdAt, forKey: .createdAt)
        try container.encodeNumber(metadata.durationSeconds, forKey: .durationSeconds)
        try container.encode(metadata.source, forKey: .source)
        try container.encode(metadata.locale, forKey: .locale)
        try container.encode(metadata.backend, forKey: .backend)
    }
}

private struct SpeakerEntry: Encodable {
    let speaker: ProjectedSpeaker

    init(_ speaker: ProjectedSpeaker) { self.speaker = speaker }

    enum CodingKeys: String, CodingKey {
        case id, ordinal, name, label, provenance, automatic, profileID, talkSeconds, turnCount
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speaker.id, forKey: .id)
        try container.encode(speaker.ordinal, forKey: .ordinal)
        try container.encode(speaker.name, forKey: .name)
        try container.encode(speaker.label, forKey: .label)
        try container.encode(speaker.provenance, forKey: .provenance)
        try container.encode(speaker.isAutomatic, forKey: .automatic)
        try container.encodeOrNull(speaker.profileID, forKey: .profileID)
        try container.encodeNumber(speaker.talkSeconds, forKey: .talkSeconds)
        try container.encode(speaker.turnCount, forKey: .turnCount)
    }
}

private struct TurnEntry: Encodable {
    let turn: ExportTurn

    init(_ turn: ExportTurn) { self.turn = turn }

    enum CodingKeys: String, CodingKey {
        case id, speakerID, track, start, end, text, overlap, otherSpeakers, score, timing, words, languages
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turn.id, forKey: .id)
        try container.encodeIfPresent(turn.languages, forKey: .languages)
        try container.encodeOrNull(turn.speakerID, forKey: .speakerID)
        try container.encodeOrNull(turn.track, forKey: .track)
        try container.encodeNumber(turn.start, forKey: .start)
        try container.encodeNumber(turn.end, forKey: .end)
        try container.encode(turn.text, forKey: .text)
        try container.encode(turn.overlap, forKey: .overlap)
        try container.encode(turn.otherSpeakerIDs, forKey: .otherSpeakers)
        try container.encodeNumber(turn.score, forKey: .score)
        try container.encode(turn.timing, forKey: .timing)
        try container.encode(turn.spans, forKey: .words)
    }
}

private struct EditCounts: Encodable {
    let applied: Int
    let stale: Int
    let otherRuns: Int
}

private extension KeyedEncodingContainer {
    /// Writes an explicit `null` for nil, so every documented key is present.
    mutating func encodeOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }

    /// Writes `null` for a number that is not finite (JSON has no NaN or infinity).
    mutating func encodeNumber(_ value: Double, forKey key: Key) throws {
        if value.isFinite { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}
