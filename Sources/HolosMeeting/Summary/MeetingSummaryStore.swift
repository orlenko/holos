import CryptoKit
import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Contents of `summary.json` (docs/meeting/titles-summaries.md §4.17): the generated title, summary, key points and action
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
    /// `createdAt` in milliseconds since 1970 (JSON dates keep whole seconds).
    public var createdAtMilliseconds: Int64?
    /// The ID of the Summarize Again request it was made for (`MeetingSummarySchedule.Request.id`): it answers that
    /// request (`MeetingSummarySchedule.satisfied`). Nil for one made without a request.
    public var answersRequest: String?
    /// The speakers' names it was made with (`MeetingSummaryKey.namesDigest`): with `transcriptID`, its key. It is
    /// current only while that key is the meeting's (`MeetingSummaryKey.isCurrent`).
    public var namesDigest: String?

    /// What breaks the rules every summary Voice is Local writes meets (`MeetingSummaryDraft.cleaned`), or nil: a
    /// title and a summary within their lengths, at most five key points and five action items within theirs, part
    /// counts that add up, and a time from 2020 on and not in the future (a day of clock skew allowed).
    func problem(now: Date = Date()) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.count > MeetingSummaryDraft.maximumTitleCharacters { return "the title" }
        // The summary and the items are cut with "…" after their limit.
        if summary.isEmpty || summary.count > MeetingSummaryDraft.maximumSummaryCharacters + 1 { return "the summary" }
        for list in [points, actions] where list.count > MeetingSummaryDraft.maximumItems || list.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.count > MeetingSummaryDraft.maximumItemCharacters + 1
        }) {
            return "the key points or action items"
        }
        if let parts, parts < 0 { return "the parts" }
        if let answersRequest, answersRequest.isEmpty || answersRequest.count > 64 { return "the request it answers" }
        if let skippedParts, skippedParts < 0 || skippedParts > (parts ?? .max) { return "the parts left out" }
        let earliest = MeetingSummaryRecord.earliestMilliseconds
        let latest = MeetingSummarySchedule.milliseconds(now.addingTimeInterval(24 * 3600))
        for stamp in [MeetingSummarySchedule.milliseconds(createdAt)] + (createdAtMilliseconds.map { [$0] } ?? [])
        where stamp < earliest || stamp > latest {
            return "the time it was made"
        }
        return nil
    }

    /// 2020-01-01 UTC in milliseconds: no summary was made before.
    static let earliestMilliseconds: Int64 = 1_577_836_800_000

    public init(schemaVersion: Int = currentVersion, sessionID: String, transcriptID: String, title: String,
                summary: String, points: [String] = [], actions: [String] = [], model: String,
                language: String? = nil, createdAt: Date = Date(), parts: Int? = nil, skippedParts: Int? = nil,
                namesDigest: String? = nil) {
        self.namesDigest = namesDigest
        createdAtMilliseconds = MeetingSummarySchedule.milliseconds(createdAt)
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.transcriptID = transcriptID
        self.title = title; self.summary = summary; self.points = points; self.actions = actions
        self.model = model; self.language = language; self.createdAt = createdAt
        self.parts = parts; self.skippedParts = skippedParts
    }
}

/// The record holds what the meeting was about. Printing, `dump`, and test-failure output show only IDs and counts
/// (docs/conventions.md §1.5, §1.9).
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

/// What a summary is of: the transcript and the speakers' names as the exports show them (docs/meeting/titles-summaries.md
/// §4.17). A summary is current only while its stored key is the meeting's; then the exports carry it, and it is not
/// made again. Computed the same way everywhere (the command, the exports, the app's scan), without the model.
public struct MeetingSummaryKey: Sendable, Equatable {
    public var transcriptID: String
    /// A digest of the prompt's source exactly (`MeetingSummarySource.promptSpeakers`): every speaker-labelled line as
    /// rendered, in order (the user's own name for the unnamed channel speaker), and the people named. Renames, links,
    /// merges, assignments, people renamed (the user too), and Remember voices' automatic names all change it.
    public var namesDigest: String

    public init(transcriptID: String, namesDigest: String) {
        self.transcriptID = transcriptID; self.namesDigest = namesDigest
    }

    /// The key of what `document` shows (the exports' document), with `selfName` for the unnamed channel speaker.
    public init(_ document: ExportDocument, selfName: String) {
        transcriptID = document.transcript.id
        let speakers = MeetingSummarySource.promptSpeakers(document: document, selfName: selfName)
        // The prompt's source exactly: every line as it is rendered ("Alex: …", speaker and words, in order) and the
        // people named. Anything that changes the prompt changes the key.
        let text = speakers.lines.map(\.rendered).joined(separator: "\n") + "\u{1E}"
            + speakers.people.joined(separator: "\u{1F}")
        namesDigest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The meeting's key now, with people's names, Remember voices and the user's own name as the exports and the
    /// prompt apply them; nil without a readable transcript.
    public static func load(session: URL, profileNames: [String: String], applyRecognition: Bool,
                            selfName: String) -> MeetingSummaryKey? {
        try? loadChecked(session: session, profileNames: profileNames, applyRecognition: applyRecognition,
                         selfName: selfName)
    }

    /// `load`, with the reason it could not be worked out: `HolosError.unavailable` when a file it reads (the
    /// transcript, the speaker labels, meeting.json …) was written by a newer Voice is Local.
    public static func loadChecked(session: URL, profileNames: [String: String], applyRecognition: Bool,
                                   selfName: String) throws -> MeetingSummaryKey {
        let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: profileNames,
                                                       applyRecognition: applyRecognition)
        return MeetingSummaryKey(try SessionExports.exportDocument(snapshot, withSummary: false), selfName: selfName)
    }

    /// `record` is of this transcript and these names.
    public func isCurrent(_ record: MeetingSummaryRecord?) -> Bool {
        guard let record else { return false }
        return record.transcriptID == transcriptID && record.namesDigest == namesDigest
    }

    /// One string, for the app's record of runs that failed.
    public var text: String { transcriptID + "|" + namesDigest }
}

/// Reads and writes `summary.json`, and decides when a meeting needs one.
public enum MeetingSummaryStore {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    static let name = "summary.json"

    /// summary.json; nil when there is none. One written by a newer Voice is Local is refused (`unavailable`); a
    /// damaged one (one that decodes but breaks the record's rules, `problem`), or one of another session, is
    /// `invalidInput`, so it counts as missing and is made again.
    public static func read(session: URL, sessionID: String) throws -> MeetingSummaryRecord? {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.summary(session), maxBytes: 1 << 20) else {
            return nil
        }
        let record = try SessionFiles.decode(MeetingSummaryRecord.self, from: data,
                                             current: MeetingSummaryRecord.currentVersion, name: name)
        guard record.sessionID == sessionID else { throw HolosError.invalidInput("\(name) belongs to another session.") }
        if let problem = record.problem() { throw HolosError.invalidInput("\(name) is damaged: \(problem).") }
        return record
    }

    /// summary.json when it can be used, and why it cannot when that is not damage (written by a newer build, or not
    /// readable now): what the catalog keeps. A missing or damaged one is no problem (made again).
    public static func readChecked(session: URL, sessionID: String) -> (record: MeetingSummaryRecord?, problem: String?) {
        do {
            return (try read(session: session, sessionID: sessionID), nil)
        } catch let error where SessionFiles.isDamage(error) {
            return (nil, nil)
        } catch {
            if case .unavailable? = error as? HolosError {
                return (nil, "summary.json was written by a newer version of Voice is Local.")
            }
            return (nil, "summary.json cannot be read: \(error.localizedDescription)")
        }
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

    /// summary.json for the app's schedule: the record when it can be used, and whether it was written by a newer
    /// Voice is Local (then the meeting is left alone rather than summarized again).
    public static func readForSchedule(session: URL, sessionID: String) -> (record: MeetingSummaryRecord?, newer: Bool) {
        do {
            return (try read(session: session, sessionID: sessionID), false)
        } catch {
            log.error("Session \(sessionID, privacy: .public): \(name, privacy: .public) unusable: \(error.localizedDescription, privacy: .private)")
            if case .unavailable? = error as? HolosError { return (nil, true) }
            return (nil, false)
        }
    }

    /// Replaces summary.json (0600). Callers hold the session's processing lease.
    static func write(_ record: MeetingSummaryRecord, session: URL) throws {
        try AtomicFile.writeJSON(record, to: SessionPaths.summary(session))
    }

    /// The record, when it was made from `transcriptID` (the current transcript); nil when it is out of date.
    public static func current(_ record: MeetingSummaryRecord?, transcriptID: String?) -> MeetingSummaryRecord? {
        guard let record, let transcriptID, record.transcriptID == transcriptID else { return nil }
        return record
    }
}

/// A meeting's name, where it came from, and the title shown for it (docs/meeting/titles-summaries.md §4.17).
public enum MeetingNaming {
    /// Names Voice is Local gives on its own: the start panel's and `record start`'s "Meeting 2026-10-03 14:00", the
    /// bare "Meeting" of older command-line recordings, and "Imported meeting".
    public static func isDefaultName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Meeting" || trimmed == "Imported meeting" || trimmed.isEmpty { return true }
        return trimmed.wholeMatch(of: /Meeting \d{4}-\d{2}-\d{2} \d{2}:\d{2}/) != nil
    }

    /// The recorded source, else, for meetings saved before it was recorded, `default` for a default name
    /// (`isDefaultName`) or, for an import (`importedFileName`), the file's name without its extension, and `user`
    /// for any other.
    public static func source(stored: MeetingNameSource?, name: String,
                              importedFileName: String? = nil) -> MeetingNameSource {
        if let stored { return stored }
        if isDefaultName(name) { return .default }
        if let file = importedFileName,
           name.trimmingCharacters(in: .whitespacesAndNewlines) == (file as NSString).deletingPathExtension {
            return .default
        }
        return .user
    }

    /// A meeting's title, the one rule the Meetings list, Review, the rename command and the Markdown heading follow:
    /// the user's name, else the title of a summary made from the current transcript (`transcriptID`), else the name
    /// (the default one). A summary of an earlier transcript (a final transcript replaced it) gives no title until it
    /// is made again, since the transcript files cannot carry it.
    public static func title(name: String, source: MeetingNameSource, summary: MeetingSummaryRecord?,
                             transcriptID: String?) -> String {
        displayTitle(name: name, source: source,
                     generatedTitle: MeetingSummaryStore.current(summary, transcriptID: transcriptID)?.title)
    }

    /// A meeting's name: meeting.json's (`MeetingInfo.name`, written with its `nameSource` in one write by a rename,
    /// the one place a rename commits), else, for a meeting never renamed (or one meeting.json cannot be read for), the
    /// manifest's. The manifest's name is a copy a rename updates after meeting.json; when they differ, the meeting's
    /// files read as out of date and Update Transcript Files (Finish Rename) writes the copy again.
    public static func name(manifestName: String, meeting: MeetingInfo?) -> String {
        guard let name = meeting?.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return manifestName
        }
        return name
    }

    /// The user's name, else `generatedTitle`, else the name (`title` decides which generated title counts).
    public static func displayTitle(name: String, source: MeetingNameSource, generatedTitle: String?) -> String {
        if source.isUser { return name }
        if let generatedTitle, !generatedTitle.isEmpty { return generatedTitle }
        return name
    }

    /// Most characters of a name the user gives a meeting by renaming it: as many as a generated title.
    public static let maximumUserNameCharacters = MeetingSummaryDraft.maximumTitleCharacters
    /// And at most this many UTF-8 bytes: a character can carry any number of combining marks.
    public static let maximumUserNameBytes = 240

    /// A name the user typed to rename a meeting, as it is saved: one line (runs of spaces, tabs and line breaks
    /// become one space), without control characters, trimmed, and cut as titles are (`MeetingSummaryDraft.cut`) to
    /// `maximumUserNameCharacters` and `maximumUserNameBytes`. Nil when nothing is left: an empty name means "use the
    /// generated title".
    public static func cleanUserName(_ text: String) -> String? {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }))
        var name = visible.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        name = MeetingSummaryDraft.cut(name, toCharacters: maximumUserNameCharacters)
        while name.utf8.count > maximumUserNameBytes { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The name a meeting gets back when the user chooses its generated title again (`MeetingNameSource.default`):
    /// its name when its source (`currentSource`, as `source` reads it) is already `default` (the name and source are
    /// written together, so a `default` source always sits beside the name Voice is Local made up), else, whatever
    /// the name looks like (a user may have typed one that matches the default pattern), the default name made from
    /// the meeting's own data: an import's file name without the extension (else "Imported meeting"), or a
    /// recording's start ("Meeting 2026-10-03 14:00", in `timeZone`).
    public static func defaultName(current: String, currentSource: MeetingNameSource, createdAt: Date,
                                   origin: MeetingOrigin, importedFileName: String?,
                                   timeZone: TimeZone = .current) -> String {
        if currentSource == .default, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return current
        }
        if origin == .imported {
            let stem = ((importedFileName ?? "") as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stem.isEmpty ? "Imported meeting" : stem
        }
        return MeetingStartSettings.defaultName(now: createdAt, timeZone: timeZone)
    }

    /// The title a meeting shows now (`title`), read from its folder: its name (`name(manifestName:meeting:)`),
    /// meeting.json's `nameSource` (unknown when meeting.json cannot be read: the user's), summary.json and the current
    /// transcript's ID. Nil without a readable manifest. For windows that show a meeting outside the list (Review).
    public static func currentTitle(session: URL) -> String? {
        guard let manifest = try? SessionArchive.readManifest(at: session) else { return nil }
        let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest)
        let name = name(manifestName: manifest.name, meeting: meeting)
        let source = meeting.map {
            MeetingNaming.source(stored: $0.nameSource, name: name,
                                 importedFileName: $0.origin == .imported ? $0.importedFileName : nil)
        } ?? .user
        // The revision read and checked as the catalog reads it (`SessionFiles.currentTranscript`), so the title is
        // the one the Meetings list shows: none of a summary when the transcript cannot be read.
        return title(name: name, source: source,
                     summary: MeetingSummaryStore.readIfUsable(session: session, sessionID: manifest.id),
                     transcriptID: try? SessionFiles.currentTranscript(session: session)?.id)
    }
}

/// What the summarizer reads from a meeting's speaker-labelled transcript.
public enum MeetingSummarySource {
    /// The document's speaker blocks as lines ("Alex: …"): an automatic name without " (auto)", the channel speaker
    /// ("Me") as `selfName`; the language most of the words are in; the length; and the people the labels name.
    public static func input(document: ExportDocument, selfName: String) -> MeetingSummaryInput {
        let speakers = promptSpeakers(document: document, selfName: selfName)
        return MeetingSummaryInput(lines: speakers.lines, language: mainLanguage(document.transcript),
                                   durationSeconds: document.metadata.durationSeconds, people: speakers.people)
    }

    /// The prompt's speaker lines and people, built once for the prompt and for the summary's key
    /// (`MeetingSummaryKey`), so the key hashes exactly the names the model is given: an automatic name without
    /// " (auto)", the unnamed channel speaker as `selfName`, track names without labels mapped to the user, "Others"
    /// or "Someone", each cut to `maximumNameCharacters`.
    static func promptSpeakers(document: ExportDocument, selfName: String)
        -> (lines: [MeetingSummaryLine], people: [String]) {
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
        return (lines, (projection.map { people($0) } ?? []).map(shortName))
    }

    /// Most characters of a speaker's or person's name in a prompt: a name is the user's text, of any length, and must
    /// leave every part room for the words.
    public static let maximumNameCharacters = 40
    /// And at most this many UTF-8 bytes: a character can carry any number of combining marks.
    public static let maximumNameBytes = 160

    /// `name` on one line, at most `maximumNameCharacters` and `maximumNameBytes` (cut between characters, with
    /// "…").
    public static func shortName(_ name: String) -> String {
        let line = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard line.count > maximumNameCharacters || line.utf8.count > maximumNameBytes else { return line }
        let ellipsis = "…"
        var kept = ""
        var bytes = ellipsis.utf8.count
        for character in line.prefix(maximumNameCharacters - 1) {
            bytes += character.utf8.count
            guard bytes <= maximumNameBytes else { break }
            kept.append(character)
        }
        return kept + ellipsis
    }

    /// What a turn of nobody known is called in the prompt.
    static let unnamedSpeaker = "Someone"

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
