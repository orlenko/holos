import CryptoKit
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
    /// Set while the transcript files are being rewritten with it, and left set when that failed: the next run
    /// rewrites them without making the summary again.
    public var exportsPending: Bool?
    /// `createdAt` in milliseconds since 1970: JSON dates keep whole seconds, too coarse to tell a summary from a
    /// request made in the same second (`MeetingSummarySchedule.satisfied`).
    public var createdAtMilliseconds: Int64?
    /// The speaker labels and people's names it was made with (`MeetingSummarySchedule.speakerStamp`), and a digest
    /// of the names it used (`MeetingSummarySource.speakersDigest`): when the stamp changes, the summary is made again
    /// if the names it would use changed, else only the stamp is updated.
    public var speakerStamp: String?
    public var speakersDigest: String?

    public init(schemaVersion: Int = currentVersion, sessionID: String, transcriptID: String, title: String,
                summary: String, points: [String] = [], actions: [String] = [], model: String,
                language: String? = nil, createdAt: Date = Date(), parts: Int? = nil, skippedParts: Int? = nil,
                speakerStamp: String? = nil, speakersDigest: String? = nil) {
        self.speakerStamp = speakerStamp; self.speakersDigest = speakersDigest
        createdAtMilliseconds = MeetingSummarySchedule.milliseconds(createdAt)
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
        if projection == nil {
            // Without speaker labels the turns are named by track ("Microphone", "System audio"), which are not
            // people: the microphone of a call is the user, the system audio the others; a microphone in the room is
            // anyone in it.
            labels["Microphone"] = document.metadata.source == .microphoneAndSystem ? selfName : unnamedSpeaker
            labels["System audio"] = "Others"
        }
        // A turn nobody was assigned to, with or without speaker labels.
        labels["Unknown speaker"] = unnamedSpeaker
        for speaker in projection?.speakers ?? [] where labels[speaker.label] == nil {
            labels[speaker.label] = isUnnamedChannel(speaker) ? selfName : speaker.name
        }
        let lines = TranscriptExporter.blocks(document).map { block in
            MeetingSummaryLine(speaker: shortName(labels[block.speakerLabel] ?? block.speakerLabel), text: block.text)
        }
        return MeetingSummaryInput(lines: lines, language: mainLanguage(document.transcript),
                                   durationSeconds: document.metadata.durationSeconds,
                                   people: (projection.map { people($0) } ?? []).map(shortName))
    }

    /// Most characters of a speaker's or person's name in a prompt: a name is the user's text, of any length, and must
    /// leave every part room for the words.
    public static let maximumNameCharacters = 40

    /// `name` on one line, at most `maximumNameCharacters` (cut, with "…").
    public static func shortName(_ name: String) -> String {
        let line = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard line.count > maximumNameCharacters else { return line }
        return String(line.prefix(maximumNameCharacters - 1)) + "…"
    }

    /// What a turn of nobody known is called in the prompt.
    static let unnamedSpeaker = "Someone"

    /// A digest of the names the summary is made with: the speakers of its lines in the order they first speak, and
    /// the people named.
    public static func speakersDigest(_ input: MeetingSummaryInput) -> String {
        var seen: Set<String> = []
        let speakers = input.lines.map(\.speaker).filter { seen.insert($0).inserted }
        let text = speakers.joined(separator: "\u{1F}") + "\u{1E}" + input.people.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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

    /// The language most of the transcript is in: for a transcript merged from several languages, the segments'
    /// languages weighed by their characters (grapheme clusters other than spaces, so Chinese, Japanese and Thai,
    /// written without spaces, count as much as they say; ties go to the preferred one, `locale`); else `locale`.
    public static func mainLanguage(_ transcript: Transcript) -> String {
        guard let languages = transcript.languages, languages.count > 1 else { return transcript.locale }
        var words: [String: Int] = [:]
        for segment in transcript.segments {
            words[segment.language ?? transcript.locale, default: 0] += segment.text.filter { !$0.isWhitespace }.count
        }
        let order = [transcript.locale] + languages.filter { $0 != transcript.locale }
        return order.max { (words[$0] ?? 0) < (words[$1] ?? 0) } ?? transcript.locale
    }
}
