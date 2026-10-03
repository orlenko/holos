import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Contents of `summary.json` (docs/meeting-design.md §4.17): the generated title, summary, key points and action
/// items of one transcript revision. Written by `voiceislocal session summarize` (the app runs it after a meeting's
/// transcript is final); replaced when the current transcript changes or on request.
public struct MeetingSummaryRecord: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var schemaVersion: Int
    public var sessionID: String
    /// The transcript revision it was made from; once the current transcript is another, it is out of date.
    public var transcriptID: String
    /// At most 8 words, no date (`MeetingSummaryDraft.cleanTitle`).
    public var title: String
    /// One or two sentences.
    public var summary: String
    public var points: [String]
    public var actions: [String]
    /// What made it ("apple-on-device").
    public var model: String
    /// The language it is written in ("fr-CA").
    public var language: String?
    public var createdAt: Date
    /// The transcript parts it was made from, and how many of them the model refused or did not answer in time (left
    /// out of it).
    public var parts: Int?
    public var skippedParts: Int?

    public init(schemaVersion: Int = currentVersion, sessionID: String, transcriptID: String, title: String,
                summary: String, points: [String] = [], actions: [String] = [], model: String,
                language: String? = nil, createdAt: Date = Date(), parts: Int? = nil, skippedParts: Int? = nil) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.transcriptID = transcriptID
        self.title = title; self.summary = summary; self.points = points; self.actions = actions
        self.model = model; self.language = language; self.createdAt = createdAt
        self.parts = parts; self.skippedParts = skippedParts
    }
}

/// The record holds what the meeting was about. Printing, `dump`, and test-failure output show only IDs and counts
/// (docs/meeting-design.md §1.5, §1.9).
extension MeetingSummaryRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "MeetingSummaryRecord(sessionID: \(sessionID), transcriptID: \(transcriptID), points: \(points.count), "
            + "actions: \(actions.count), model: \(model))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["sessionID": sessionID, "transcriptID": transcriptID, "points": points.count,
                                "actions": actions.count, "model": model], displayStyle: .struct)
    }
}

/// Reads and writes `summary.json`, and decides when a meeting needs one.
public enum MeetingSummaryStore {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    static let name = "summary.json"

    /// summary.json; nil when there is none. One written by a newer Voice is Local is refused (`unavailable`); a
    /// damaged one, or one of another session, is `invalidInput`.
    public static func read(session: URL, sessionID: String) throws -> MeetingSummaryRecord? {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.summary(session), maxBytes: 1 << 20) else {
            return nil
        }
        let record = try SessionFiles.decode(MeetingSummaryRecord.self, from: data,
                                             current: MeetingSummaryRecord.currentVersion, name: name)
        guard record.sessionID == sessionID else { throw HolosError.invalidInput("\(name) belongs to another session.") }
        return record
    }

    /// summary.json when it can be used, else nil (the reason is logged): what the Meetings list shows.
    public static func readIfUsable(session: URL, sessionID: String) -> MeetingSummaryRecord? {
        do {
            return try read(session: session, sessionID: sessionID)
        } catch {
            log.error("Session \(sessionID, privacy: .public): \(name, privacy: .public) unusable: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Replaces summary.json (0600). Callers hold the session's processing lease.
    static func write(_ record: MeetingSummaryRecord, session: URL) throws {
        try AtomicFile.writeJSON(record, to: SessionPaths.summary(session))
    }

    /// Whether a summary should be made for the current transcript `transcriptID`: there is one, and the record is
    /// missing or of another transcript (or a new one was asked for, `force`).
    public static func needsSummary(record: MeetingSummaryRecord?, transcriptID: String?, force: Bool = false) -> Bool {
        guard transcriptID != nil else { return false }
        return force || record?.transcriptID != transcriptID
    }

    /// The record, when it was made from `transcriptID` (the current transcript); nil when it is out of date.
    public static func current(_ record: MeetingSummaryRecord?, transcriptID: String?) -> MeetingSummaryRecord? {
        guard let record, let transcriptID, record.transcriptID == transcriptID else { return nil }
        return record
    }
}

/// A meeting's name, where it came from, and the title shown for it (docs/meeting-design.md §4.17).
public enum MeetingNaming {
    /// Names Voice is Local gives on its own: the start panel's and `record start`'s "Meeting 2026-10-03 14:00", the
    /// bare "Meeting" of older command-line recordings, and "Imported meeting".
    public static func isDefaultName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Meeting" || trimmed == "Imported meeting" || trimmed.isEmpty { return true }
        return trimmed.wholeMatch(of: /Meeting \d{4}-\d{2}-\d{2} \d{2}:\d{2}/) != nil
    }

    /// The recorded source, else, for meetings saved before it was recorded, `default` for a default name
    /// (`isDefaultName`) and `user` for any other.
    public static func source(stored: MeetingNameSource?, name: String) -> MeetingNameSource {
        stored ?? (isDefaultName(name) ? .default : .user)
    }

    /// What the Meetings list shows: the user's name, else the generated title, else the name.
    public static func displayTitle(name: String, source: MeetingNameSource, generatedTitle: String?) -> String {
        if source.isUser { return name }
        if let generatedTitle, !generatedTitle.isEmpty { return generatedTitle }
        return name
    }
}

/// What the summarizer reads from a meeting's speaker-labelled transcript.
public enum MeetingSummarySource {
    /// The document's speaker blocks as lines ("Alex: …"): an automatic name without " (auto)", the channel speaker
    /// ("Me") as `selfName`; the language most of the words are in; the length; and the people the labels name.
    public static func input(document: ExportDocument, selfName: String) -> MeetingSummaryInput {
        let projection = document.projection.flatMap { $0.transcriptID == document.transcript.id ? $0 : nil }
        var labels: [String: String] = [:]
        for speaker in projection?.speakers ?? [] where labels[speaker.label] == nil {
            labels[speaker.label] = isUnnamedChannel(speaker) ? selfName : speaker.name
        }
        let lines = TranscriptExporter.blocks(document).map { block in
            MeetingSummaryLine(speaker: labels[block.speakerLabel] ?? block.speakerLabel, text: block.text)
        }
        return MeetingSummaryInput(lines: lines, language: mainLanguage(document.transcript),
                                   durationSeconds: document.metadata.durationSeconds,
                                   people: projection.map { people($0) } ?? [])
    }

    /// The people a projection names (an explicit name, a linked or automatically matched person), most talk first;
    /// "Speaker 2" and the unnamed channel speaker ("Me") are not people.
    public static func people(_ projection: SpeakerProjection) -> [String] {
        var seen: Set<String> = []
        return projection.speakers.enumerated()
            .filter { $0.element.turnCount > 0 && isNamed($0.element) }
            .sorted { lhs, rhs in
                let left = lhs.element.talkSeconds.isNaN ? 0 : lhs.element.talkSeconds
                let right = rhs.element.talkSeconds.isNaN ? 0 : rhs.element.talkSeconds
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element.name)
            .filter { seen.insert($0).inserted }
    }

    static func isNamed(_ speaker: ProjectedSpeaker) -> Bool {
        speaker.explicitName != nil || speaker.effectiveProfileID != nil
    }

    static func isUnnamedChannel(_ speaker: ProjectedSpeaker) -> Bool {
        speaker.provenance == .channelAssumption && !isNamed(speaker)
    }

    /// The language most of the transcript's words are in: for a transcript merged from several languages, the
    /// segments' languages counted by words (ties go to the preferred one, `locale`); else `locale`.
    public static func mainLanguage(_ transcript: Transcript) -> String {
        guard let languages = transcript.languages, languages.count > 1 else { return transcript.locale }
        var words: [String: Int] = [:]
        for segment in transcript.segments {
            words[segment.language ?? transcript.locale, default: 0] += segment.text.split(whereSeparator: \.isWhitespace).count
        }
        let order = [transcript.locale] + languages.filter { $0 != transcript.locale }
        return order.max { (words[$0] ?? 0) < (words[$1] ?? 0) } ?? transcript.locale
    }
}
