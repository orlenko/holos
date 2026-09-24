import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage

/// `holos speakers …` (docs/meeting-design.md §5.7): list a session's speakers and correct them through
/// `SpeakerEditor`. Content goes to stdout; notes and warnings to stderr (§1.4).
struct Speakers: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and correct the speaker labels of a session.",
        discussion: """
            <session> is the path to a .holos folder, or a session ID in the sessions folder (HOLOS_DATA_DIR, or \
            Application Support/Holos/Sessions). <speaker> is a speaker ID (system:S2), its engine label (S2), its \
            number (3 or "Speaker 3"), its name, or unknown. <turn> is a turn ID (T12) or a time inside the turn \
            (01:12:03, 12:03.5, or 723.5 seconds); add --track mic or --track system when both tracks speak then. \
            Each change is checked against the labels it was worked out on and refused if they changed meanwhile, \
            is saved in the session's edit journal (holos speakers undo reverts it), and rewrites the session's \
            exports.
            """,
        subcommands: [
            List.self,
            Rename.self,
            Merge.self,
            Assign.self,
            Split.self,
            Exclude.self,
            Undo.self,
        ])

    // MARK: - list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List a session's speakers, and with --turns every turn.")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Flag(help: "Also list every turn: ID, time, track, speaker, score, flags, and its first 60 characters.")
        var turns = false
        @Flag(help: "Print the speakers (and with --turns the turns) as JSON.") var json = false

        mutating func run() throws {
            let loaded = try SpeakerCommand.load(session)
            if json {
                try Console.json(SpeakerListing(loaded, includeTurns: turns))
            } else {
                for line in SpeakerCommand.listing(loaded, includeTurns: turns) { Console.output(line) }
            }
            SpeakerCommand.printNotes(loaded.snapshot.diagnostics)
        }
    }

    // MARK: - rename

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Name a speaker, or clear the name with --clear.")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The speaker to name.") var speaker: String
        @Argument(help: "The new name.") var name: String?
        @Flag(help: "Remove the speaker's name.") var clear = false

        func validate() throws {
            if clear, name != nil { throw ValidationError("Give a name or --clear, not both.") }
            if !clear, SpeakerEditor.cleanName(name) == nil {
                throw ValidationError("Give the new name, or --clear to remove the name.")
            }
        }

        mutating func run() throws {
            let loaded = try SpeakerCommand.load(session)
            let speakerID = try SpeakerCommand.speakerID(speaker, in: loaded.view)
            // One line, as the exports show it: line breaks and control characters become spaces.
            let clean = clear ? nil : SpeakerEditor.cleanName(name)
            try SpeakerCommand.save([.rename(speakerID: speakerID, name: clean)], loaded)
        }
    }

    // MARK: - merge

    struct Merge: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move every turn of one speaker to another; the first speaker disappears.",
            discussion: "The speaker merged into keeps its name.")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The speaker whose turns move.") var from: String
        @Argument(help: "The speaker they move to.") var into: String

        mutating func run() throws {
            let loaded = try SpeakerCommand.load(session)
            let source = try SpeakerCommand.speakerID(from, in: loaded.view)
            let target = try SpeakerCommand.speakerID(into, in: loaded.view)
            guard source != target else {
                throw HolosError.invalidInput("Both name \(source); merge two different speakers.")
            }
            try SpeakerCommand.save([.merge(from: source, into: target)], loaded)
        }
    }

    // MARK: - assign

    struct Assign: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give turns to another speaker, to the unknown speaker, or to a new speaker.")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The turns to move (IDs or times).") var turns: [String]
        @Option(help: "A speaker, unknown, or new (optionally new:NAME) for a new speaker.") var to: String
        @Option(help: "The track (mic or system) for turns given as times.") var track: String?

        func validate() throws {
            if turns.isEmpty { throw ValidationError("Name at least one turn.") }
        }

        mutating func run() throws {
            let loaded = try SpeakerCommand.load(session)
            let turnIDs = try SpeakerCommand.turnIDs(turns, track: track, in: loaded.view)
            let action: SpeakerEditAction
            if let name = SpeakerSelector.newSpeakerName(to) {
                action = .newSpeaker(speakerID: "user:\(UUID().uuidString)", name: name, turnIDs: turnIDs)
            } else {
                switch try SpeakerSelector.speaker(to, in: loaded.view) {
                case .speaker(let speakerID): action = .reassignTurns(turnIDs: turnIDs, to: speakerID)
                case .unknown: action = .reassignTurns(turnIDs: turnIDs, to: nil)
                }
            }
            try SpeakerCommand.save([action], loaded)
        }
    }

    // MARK: - split

    struct Split: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Split a turn in two; the second part keeps the speaker until you assign it.",
            discussion: """
                --at-word N starts the second part at the turn's Nth word (the first word is 1, so N is at least 2). \
                --at TIME starts it at the first word that begins at or after TIME.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The turn to split (an ID or a time).") var turn: String
        @Option(name: .customLong("at-word"), help: "The word (counting from 1) that starts the second part.")
        var atWord: Int?
        @Option(help: "Start the second part at the first word that begins at or after this time.") var at: String?
        @Option(help: "The track (mic or system) when the turn is given as a time.") var track: String?

        func validate() throws {
            switch (atWord, at) {
            case (nil, nil): throw ValidationError("Say where to split: --at-word N or --at TIME.")
            case (.some, .some): throw ValidationError("Use --at-word or --at, not both.")
            default: break
            }
        }

        mutating func run() throws {
            let loaded = try SpeakerCommand.load(session)
            let turnID = try SpeakerSelector.turn(turn, track: track, in: loaded.view)
            let word = try SpeakerSelector.splitWord(turnID: turnID, atWord: atWord, at: at, in: loaded.view,
                                                     transcript: loaded.snapshot.transcript)
            try SpeakerCommand.save([.splitTurn(turnID: turnID, at: word)], loaded)
        }
    }

    // MARK: - exclude

    struct Exclude: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Keep turns out of voice learning (for example, someone else talking over the speaker).")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The turns to exclude (IDs or times).") var turns: [String]
        @Option(help: "The track (mic or system) for turns given as times.") var track: String?

        func validate() throws {
            if turns.isEmpty { throw ValidationError("Name at least one turn.") }
        }

        mutating func run() throws {
            let loaded = try SpeakerCommand.load(session)
            let turnIDs = try SpeakerCommand.turnIDs(turns, track: track, in: loaded.view)
            try SpeakerCommand.save([.excludeFromEnrollment(turnIDs: turnIDs)], loaded)
        }
    }

    // MARK: - undo

    struct Undo: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Undo the newest speaker change; run it again to undo the one before.")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String

        mutating func run() throws {
            let loaded = try SpeakerCommand.load(session)
            let undone = SpeakerCommand.newestBatch(loaded)
            let result = try SpeakerEditor.undoLast(view: loaded.view, session: loaded.session,
                                                    source: SpeakerCommand.source, regenerateExports: false)
            let descriptions = undone.map {
                SpeakerCommand.describe($0.action, before: loaded.view, after: nil, editID: $0.id)
            }
            switch descriptions.count {
            case 0: Console.output("Undid the last speaker change.")
            case 1: Console.output("Undid: \(descriptions[0])")
            default: Console.output("Undid \(descriptions.count) changes: " + descriptions.joined(separator: " "))
            }
            // Stale lines the undo would have brought back are reverted with it (SpeakerEditor.undoLast).
            let keptOut = Set(loaded.view.staleEdits.map(\.editID))
                .intersection(result.snapshot.projection?.revertedEditIDs ?? []).count
            if keptOut > 0 {
                Console.error("\(keptOut) earlier speaker \(keptOut == 1 ? "change" : "changes") that could not be "
                              + "applied \(keptOut == 1 ? "stays" : "stay") out of effect; undo does not bring "
                              + "\(keptOut == 1 ? "it" : "them") back.")
            }
            try SpeakerCommand.rewriteExports(loaded.session)
            SpeakerCommand.printNotes(result.snapshot.diagnostics)
        }
    }
}

// MARK: - Shared steps

/// A session loaded for a speaker command: its snapshot and the projection selectors resolve against, which is also
/// the view the edit is made on.
struct LoadedSpeakers {
    let session: URL
    let snapshot: SpeakerSessionSnapshot
    let view: SpeakerProjection
}

enum SpeakerCommand {
    /// `SpeakerEdit.source` of every CLI edit.
    static let source = "cli"

    /// Resolves the session and loads its snapshot; refuses a session without usable speaker labels.
    static func load(_ text: String) throws -> LoadedSpeakers {
        let session = try SessionLocator.resolve(text)
        let snapshot = try SpeakerSessionSnapshot.load(session: session)
        guard let view = snapshot.projection else {
            throw HolosError.unavailable(snapshot.runProblem
                ?? "This meeting has no speaker labels yet. Label them with holos session diarize \(session.path).")
        }
        return LoadedSpeakers(session: session, snapshot: snapshot, view: view)
    }

    /// A listed speaker (never "unknown", which only a turn can have).
    static func speakerID(_ text: String, in view: SpeakerProjection) throws -> String {
        switch try SpeakerSelector.speaker(text, in: view) {
        case .speaker(let speakerID): return speakerID
        case .unknown: throw HolosError.invalidInput("“unknown” is not a speaker here; name a listed speaker.")
        }
    }

    /// Resolved turn IDs, each once, in the order given.
    static func turnIDs(_ texts: [String], track: String?, in view: SpeakerProjection) throws -> [String] {
        var seen = Set<String>()
        return try texts.map { try SpeakerSelector.turn($0, track: track, in: view) }
            .filter { seen.insert($0).inserted }
    }

    /// Saves one change on the loaded view, prints what it did, and rewrites the exports. A change that would leave
    /// the labels as they are is not saved (it would only use up an undo step); the editor decides that on the
    /// current labels under the speaker lock, after refusing a change whose labels moved on since the load.
    static func save(_ actions: [SpeakerEditAction], _ loaded: LoadedSpeakers) throws {
        guard let result = try SpeakerEditor.applyUnlessUnchanged(actions, view: loaded.view,
                                                                  session: loaded.session, source: source,
                                                                  regenerateExports: false) else {
            Console.output("Nothing to change; the speaker labels already look like that.")
            // The editor found the current labels as loaded, so the loaded snapshot's warnings still hold.
            printNotes(loaded.snapshot.diagnostics)
            return
        }
        for action in actions {
            Console.output(describe(action, before: loaded.view, after: result.snapshot.projection))
        }
        try rewriteExports(loaded.session)
        printNotes(result.snapshot.diagnostics)
    }

    /// Rewrites exports/ after a change was saved (the editor has released the speaker lock).
    static func rewriteExports(_ session: URL) throws {
        let written: ExportWriteResult
        do {
            written = try SessionExports.regenerate(session: session)
        } catch {
            throw HolosError.incomplete("The change was saved, but the exports could not be rewritten: "
                                        + "\(error.localizedDescription) Rewrite them with holos session export "
                                        + "\(session.path) --all.")
        }
        for url in written.movedAside { Console.error(movedAsideNote(url)) }
    }

    /// "Your edited transcript.md was kept as exports/edited-20260923-171200.md."
    static func movedAsideNote(_ url: URL) -> String {
        "Your edited transcript.\(url.pathExtension) was kept as exports/\(url.lastPathComponent)."
    }

    /// Warnings about the labels themselves, on stderr: the one place every speaker and session command that shows or
    /// writes speaker labels reports what its snapshot skipped, on every successful path.
    static func printNotes(_ diagnostics: SpeakerSnapshotDiagnostics) {
        for note in diagnostics.notes { Console.error(note) }
    }

    /// The applied lines of the view's newest batch, in journal order (what `undoLast` will revert).
    static func newestBatch(_ loaded: LoadedSpeakers) -> [SpeakerEdit] {
        guard let batchID = loaded.view.lastUndoableBatchID else { return [] }
        let applied = Set(loaded.view.appliedEditIDs)
        return loaded.snapshot.journal.edits
            .filter { $0.baseRunID == loaded.view.runID && ($0.batchID ?? $0.id) == batchID && applied.contains($0.id) }
    }

    // MARK: Describing changes

    /// One sentence for a change: "Renamed system:S2 to Maria." Speakers are described on `before`, the labels the
    /// change was made on; a speaker or turn the change created is described on `after` when given. `editID` is the
    /// journal line's ID when the change is already saved (it names a split's second part).
    static func describe(_ action: SpeakerEditAction, before: SpeakerProjection, after: SpeakerProjection?,
                         editID: String? = nil) -> String {
        func speaker(_ id: String) -> String {
            let found = before.speakers.first { $0.id == id } ?? after?.speakers.first { $0.id == id }
            return found.map { "\($0.id) (\($0.label))" } ?? id
        }
        switch action {
        case .rename(let speakerID, let name):
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return "Renamed \(speakerID) to \(name)."
            }
            return "Cleared the name of \(speakerID)."
        case .merge(let from, let into):
            return "Merged \(speaker(from)) into \(speaker(into))."
        case .reassignTurns(let turnIDs, let to):
            return "Assigned \(turnList(turnIDs)) to \(to.map(speaker) ?? "Unknown speaker")."
        case .newSpeaker(let speakerID, _, let turnIDs):
            return "Assigned \(turnList(turnIDs)) to a new speaker, \(speaker(speakerID))."
        case .splitTurn(let turnID, let word):
            let part: ProjectedTurn?
            if let editID {
                // Already saved: the part is in `before` (undo), with the ID the split gave it.
                part = before.turns.first { $0.id == "\(turnID)/\(editID)" }
            } else {
                let beforeIDs = Set(before.turns.map(\.id))
                part = after?.turns.first { $0.id.hasPrefix("\(turnID)/") && !beforeIDs.contains($0.id) }
            }
            let head = before.turns.first { $0.id == turnID }
            // Before the split the word is in the turn; after it, it follows the words the turn kept.
            let position = wordNumber(word, in: head) ?? (editID == nil ? nil : head.map { wordCount($0) + 1 })
            return "Split \(turnID)" + (position.map { " before its word \($0)" } ?? "")
                + (part.map { "; the second part is \($0.id) from \(TimeFormat.clock($0.start))" } ?? "") + "."
        case .excludeFromEnrollment(let turnIDs):
            return "Excluded \(turnList(turnIDs)) from voice learning."
        case .linkProfile(let speakerID, let profileID):
            return "Linked \(speaker(speakerID)) to person \(profileID)."
        case .rejectProfile(let speakerID, let profileID):
            return "Marked \(speaker(speakerID)) as not person \(profileID)."
        case .revert(let editID):
            return "Reverted edit \(editID)."
        }
    }

    /// "T4", "T4 and T5", "T4, T5, and T6", or "12 turns (T4, T5, T6, …)".
    static func turnList(_ ids: [String]) -> String {
        switch ids.count {
        case 0: return "no turns"
        case 1: return ids[0]
        case 2: return "\(ids[0]) and \(ids[1])"
        case 3...5: return ids.dropLast().joined(separator: ", ") + ", and \(ids[ids.count - 1])"
        default: return "\(ids.count) turns (\(ids.prefix(3).joined(separator: ", ")), …)"
        }
    }

    private static func wordCount(_ turn: ProjectedTurn) -> Int {
        turn.spans.reduce(0) { $0 + max(0, $1.end - $1.first) }
    }

    /// The 1-based position of `word` among the turn's words.
    private static func wordNumber(_ word: WordRef, in turn: ProjectedTurn?) -> Int? {
        guard let turn else { return nil }
        var position = 0
        for span in turn.spans {
            for index in span.first..<max(span.first, span.end) {
                position += 1
                if span.segmentID == word.segmentID, index == word.word { return position }
            }
        }
        return nil
    }

    // MARK: Listing

    /// `speakers list` as text lines.
    static func listing(_ loaded: LoadedSpeakers, includeTurns: Bool) -> [String] {
        let view = loaded.view
        var lines = [header(loaded), ""]
        let rows = view.speakers.map { speaker -> [String] in
            var row = ["\(speaker.ordinal)", speaker.id, speaker.label, TimeFormat.duration(speaker.talkSeconds),
                       "\(speaker.turnCount)", provenanceWord(speaker.provenance)]
            if let suggestion = speaker.suggestion {
                let distance = String(format: "%.2f", suggestion.distance)
                row.append("suggestion: Maybe \(suggestion.profileName) (\(distance))")
            } else {
                row.append("")
            }
            return row
        }
        lines += TextTable.render(header: ["#", "Speaker", "Name", "Talk", "Turns", "Label", ""], rows: rows,
                                  alignments: [.right, .left, .left, .left, .right, .left, .left])
        guard includeTurns else { return lines }
        lines.append("")
        let labels = Dictionary(view.speakers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let turnRows = view.turns.map { turn -> [String] in
            [turn.id, "\(TimeFormat.clock(turn.start))–\(TimeFormat.clock(turn.end))", turn.track,
             turn.speakerID.map { labels[$0] ?? $0 } ?? "Unknown speaker",
             String(format: "%.2f", turn.assignmentScore), flags(turn),
             preview(TranscriptExporter.text(of: turn.spans, in: loaded.snapshot.transcript))]
        }
        lines += TextTable.render(header: nil, rows: turnRows,
                                  alignments: [.left, .left, .left, .left, .right, .left, .left])
        return lines
    }

    /// "Council meeting (3F2A9C1E…) · run 5C1D7E2A (FluidAudio 0.17.1) · 11 speakers · 343 turns · 5 changes"
    private static func header(_ loaded: LoadedSpeakers) -> String {
        let view = loaded.view
        let manifest = loaded.snapshot.manifest
        var parts = ["\(manifest.name) (\(manifest.id.prefix(8))…)"]
        var run = "run \(view.runID.prefix(8))"
        if let engine = loaded.snapshot.run?.engine { run += " (\(engine.engine) \(engine.engineVersion))" }
        parts.append(run)
        parts.append(count(view.speakers.count, "speaker"))
        parts.append(count(view.turns.count, "turn"))
        parts.append(count(view.appliedEditIDs.count, "change"))
        if !view.staleEdits.isEmpty { parts.append("\(view.staleEdits.count) could not be applied") }
        return parts.joined(separator: " · ")
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// The Label column: where the speaker's label came from.
    static func provenanceWord(_ provenance: LabelProvenance) -> String {
        switch provenance {
        case .diarizer: "diarizer"
        case .channelAssumption: "channel"
        case .recognized: "auto"
        case .userConfirmed: "confirmed"
        case .userRenamed: "renamed"
        }
    }

    /// "overlap", "reassigned", "split", "excluded", joined with ",".
    private static func flags(_ turn: ProjectedTurn) -> String {
        var flags: [String] = []
        if turn.overlap { flags.append("overlap") }
        if turn.reassigned { flags.append("reassigned") }
        if turn.modified { flags.append("split") }
        if turn.excludedFromEnrollment { flags.append("excluded") }
        return flags.joined(separator: ",")
    }

    /// The first 60 characters on one line, with "…" when cut.
    static func preview(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
        return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
    }
}

/// Columns separated by two spaces, indented by two, trailing spaces removed. A column that is empty in every row
/// (and the header) is left out.
enum TextTable {
    enum Alignment { case left, right }

    static func render(header: [String]?, rows: [[String]], alignments: [Alignment]) -> [String] {
        let all = (header.map { [$0] } ?? []) + rows
        let columns = all.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in all {
            for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) }
        }
        return all.map { row in
            let cells = row.enumerated().compactMap { index, cell -> String? in
                guard widths[index] > 0 else { return nil }
                let padding = String(repeating: " ", count: widths[index] - cell.count)
                let alignment = index < alignments.count ? alignments[index] : .left
                return alignment == .right ? padding + cell : cell + padding
            }
            let line = "  " + cells.joined(separator: "  ")
            return String(line.reversed().drop { $0 == " " }.reversed())
        }
    }
}

// MARK: - JSON

/// `speakers list --json`. Names and turn text are the user's own; no vectors.
struct SpeakerListing: Encodable {
    struct SessionInfo: Encodable {
        var id: String
        var name: String
    }

    struct Edits: Encodable {
        var applied: Int
        var reverted: Int
        var stale: [Stale]
        var otherRuns: Int
        /// Journal lines skipped because they are damaged or from a newer Holos (§1.6 rule 3).
        var unreadable: Int
        /// The journal's last line was cut off and skipped.
        var tornTail: Bool
    }

    struct Stale: Encodable {
        var editID: String
        var reason: String
    }

    struct Suggestion: Encodable {
        var profileID: String
        var profileName: String
        var distance: Double
    }

    struct Speaker: Encodable {
        var id: String
        var ordinal: Int
        var name: String
        var label: String
        var explicitName: String?
        var profileID: String?
        var provenance: LabelProvenance
        var automatic: Bool
        var suggestion: Suggestion?
        var rejectedProfileIDs: [String]
        var clusterIDs: [String]
        var talkSeconds: Double
        var turnCount: Int
    }

    struct Turn: Encodable {
        var id: String
        var track: String
        var start: Double
        var end: Double
        var speakerID: String?
        var label: String
        var score: Double
        var overlap: Bool
        var uncertain: Bool
        var reassigned: Bool
        var modified: Bool
        var excludedFromEnrollment: Bool
        var text: String
    }

    var schemaVersion = 1
    var session: SessionInfo
    var runID: String
    var transcriptID: String
    var transcriptChanged: Bool
    var engine: String?
    var edits: Edits
    var speakers: [Speaker]
    var turns: [Turn]?

    init(_ loaded: LoadedSpeakers, includeTurns: Bool) {
        let view = loaded.view
        session = SessionInfo(id: loaded.snapshot.manifest.id, name: loaded.snapshot.manifest.name)
        runID = view.runID
        transcriptID = view.transcriptID
        transcriptChanged = loaded.snapshot.transcriptChanged
        engine = loaded.snapshot.run?.engine.map { "\($0.engine) \($0.engineVersion)" }
        edits = Edits(applied: view.appliedEditIDs.count, reverted: view.revertedEditIDs.count,
                      stale: view.staleEdits.map { Stale(editID: $0.editID, reason: $0.reason) },
                      otherRuns: view.otherRunEditCount, unreadable: loaded.snapshot.journal.unreadableLines,
                      tornTail: loaded.snapshot.journal.tornTail)
        speakers = view.speakers.map { speaker in
            Speaker(id: speaker.id, ordinal: speaker.ordinal, name: speaker.name, label: speaker.label,
                    explicitName: speaker.explicitName, profileID: speaker.profileID, provenance: speaker.provenance,
                    automatic: speaker.isAutomatic,
                    suggestion: speaker.suggestion.map {
                        Suggestion(profileID: $0.profileID, profileName: $0.profileName, distance: $0.distance)
                    },
                    rejectedProfileIDs: speaker.rejectedProfileIDs, clusterIDs: speaker.clusterIDs,
                    talkSeconds: speaker.talkSeconds, turnCount: speaker.turnCount)
        }
        guard includeTurns else {
            turns = nil
            return
        }
        let labels = Dictionary(view.speakers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        turns = view.turns.map { turn in
            Turn(id: turn.id, track: turn.track, start: turn.start, end: turn.end, speakerID: turn.speakerID,
                 label: turn.speakerID.map { labels[$0] ?? $0 } ?? "Unknown speaker", score: turn.assignmentScore,
                 overlap: turn.overlap, uncertain: turn.uncertain, reassigned: turn.reassigned,
                 modified: turn.modified, excludedFromEnrollment: turn.excludedFromEnrollment,
                 text: TranscriptExporter.text(of: turn.spans, in: loaded.snapshot.transcript))
        }
    }
}
