import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage

/// `voiceislocal speakers …` (docs/meeting-design.md §5.7, §5.9): list a session's speakers, and correct them and link
/// them to people through `SpeakerEditCommand`, which prints here what it says. Content goes to stdout; notes and
/// warnings to stderr (§1.4).
struct Speakers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and correct the speaker labels of a session, and link speakers to people.",
        discussion: """
            <session> is the path to a .holos folder, or a session ID in the sessions folder (HOLOS_DATA_DIR, or \
            Application Support/Holos/Sessions). <speaker> is a speaker ID (system:S2), its engine label (S2), its \
            number (3 or "Speaker 3"), its name, or unknown. <turn> is a turn ID (T12) or a time inside the turn \
            (01:12:03, 12:03.5, or 723.5 seconds); add --track mic or --track system when both tracks speak then. \
            <person> is a person's ID or unique name from voiceislocal people list. \
            Each change is checked against the labels it was worked out on and refused if they changed meanwhile, \
            is saved in the session's edit journal (voiceislocal speakers undo reverts it), and rewrites the session's \
            exports. A person's voice sample learned from the session is updated when a change affects it.
            """,
        subcommands: [
            List.self,
            Rename.self,
            Merge.self,
            Assign.self,
            Split.self,
            Exclude.self,
            Undo.self,
            Link.self,
            Me.self,
            Reject.self,
            Embed.self,
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

    struct Rename: AsyncParsableCommand {
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

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let speakerID = try SpeakerCommand.speakerID(speaker, in: loaded.view)
            // One line, as the exports show it: line breaks and control characters become spaces.
            let clean = clear ? nil : SpeakerEditor.cleanName(name)
            try await SpeakerCommand.save([.rename(speakerID: speakerID, name: clean)], loaded)
        }
    }

    // MARK: - merge

    struct Merge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move every turn of one speaker to another; the first speaker disappears.",
            discussion: "The speaker merged into keeps its name.")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The speaker whose turns move.") var from: String
        @Argument(help: "The speaker they move to.") var into: String

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let source = try SpeakerCommand.speakerID(from, in: loaded.view)
            let target = try SpeakerCommand.speakerID(into, in: loaded.view)
            guard source != target else {
                throw HolosError.invalidInput("Both name \(source); merge two different speakers.")
            }
            try await SpeakerCommand.save([.merge(from: source, into: target)], loaded)
        }
    }

    // MARK: - assign

    struct Assign: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give turns to another speaker, to the unknown speaker, or to a new speaker.")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The turns to move (IDs or times).") var turns: [String]
        @Option(help: "A speaker, unknown, or new (optionally new:NAME) for a new speaker; new:NAME with a name a speaker already has gives the turns to that speaker.") var to: String
        @Option(help: "The track (mic or system) for turns given as times.") var track: String?

        func validate() throws {
            if turns.isEmpty { throw ValidationError("Name at least one turn.") }
        }

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let turnIDs = try SpeakerCommand.turnIDs(turns, track: track, in: loaded.view)
            let action: SpeakerEditAction
            if let name = SpeakerSelector.newSpeakerName(to) {
                // Same name, same person: a name a listed speaker already has gives the turns to that speaker.
                if let name, let existing = loaded.view.speaker(named: name) {
                    action = .reassignTurns(turnIDs: turnIDs, to: existing.id)
                } else {
                    action = .newSpeaker(speakerID: "user:\(UUID().uuidString)", name: name, turnIDs: turnIDs)
                }
            } else {
                switch try SpeakerSelector.speaker(to, in: loaded.view) {
                case .speaker(let speakerID): action = .reassignTurns(turnIDs: turnIDs, to: speakerID)
                case .unknown: action = .reassignTurns(turnIDs: turnIDs, to: nil)
                }
            }
            try await SpeakerCommand.save([action], loaded)
        }
    }

    // MARK: - split

    struct Split: AsyncParsableCommand {
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

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let turnID = try SpeakerSelector.turn(turn, track: track, in: loaded.view)
            let word = try SpeakerSelector.splitWord(turnID: turnID, atWord: atWord, at: at, in: loaded.view,
                                                     transcript: loaded.snapshot.transcript)
            try await SpeakerCommand.save([.splitTurn(turnID: turnID, at: word)], loaded)
        }
    }

    // MARK: - exclude

    struct Exclude: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Keep turns out of voice learning (for example, someone else talking over the speaker).")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The turns to exclude (IDs or times).") var turns: [String]
        @Option(help: "The track (mic or system) for turns given as times.") var track: String?

        func validate() throws {
            if turns.isEmpty { throw ValidationError("Name at least one turn.") }
        }

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let turnIDs = try SpeakerCommand.turnIDs(turns, track: track, in: loaded.view)
            try await SpeakerCommand.save([.excludeFromEnrollment(turnIDs: turnIDs)], loaded)
        }
    }

    // MARK: - undo

    struct Undo: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Undo the newest speaker change; run it again to undo the one before.")

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            try await SpeakerCommand.run(.undo, loaded)
        }
    }

    // MARK: - link

    struct Link: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Link a speaker to a person, so the name carries across meetings.",
            discussion: """
                <person> is a person's ID or unique name (voiceislocal people list), or new:NAME for a new person. The \
                speaker is named after the person too, so the meeting keeps the name if the person is forgotten \
                later. With --learn-voice and Remember voices on (voiceislocal people remember on), the person's voice is \
                learned from this speaker's clear turns (2 s or longer, not overlapped) so later meetings can suggest \
                them. Only learn the voices of people who agreed to it. Learning needs the speaker models and the \
                meeting's audio.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The speaker to link.") var speaker: String
        @Argument(help: "A person's ID or name, or new:NAME.") var person: String
        @Flag(help: "Learn the person's voice from this speaker (needs Remember voices on).") var learnVoice = false

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let speakerID = try SpeakerCommand.speakerID(speaker, in: loaded.view)
            let target = try PeopleCommand.target(person, store: loaded.store)
            try await SpeakerCommand.run(.link(speakerID: speakerID, to: target, learnVoice: learnVoice), loaded)
        }
    }

    // MARK: - me

    struct Me: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Link a speaker to you (\"This is me\").",
            discussion: """
                The first time, Voice is Local creates the person who is you with your account's full name; rename it with \
                voiceislocal people rename. --learn-voice learns your voice as voiceislocal speakers link does.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The speaker who is you.") var speaker: String
        @Flag(help: "Learn your voice from this speaker (needs Remember voices on).") var learnVoice = false

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let speakerID = try SpeakerCommand.speakerID(speaker, in: loaded.view)
            try await SpeakerCommand.run(.markSelf(speakerID: speakerID, learnVoice: learnVoice), loaded)
        }
    }

    // MARK: - reject

    struct Reject: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Say a speaker is not a person, in this meeting only.",
            discussion: """
                Voice is Local stops suggesting that person for the speaker, and unlinks the speaker if it was linked to them \
                (the speaker keeps its name; rename it or clear it with voiceislocal speakers rename).
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The speaker.") var speaker: String
        @Argument(help: "The person the speaker is not (an ID or a name).") var person: String

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let speakerID = try SpeakerCommand.speakerID(speaker, in: loaded.view)
            let profileID = try PeopleCommand.profileID(person, store: loaded.store)
            try await SpeakerCommand.run(.reject(speakerID: speakerID, profileID: profileID), loaded)
        }
    }

    // MARK: - embed (hidden)

    /// The app's voice sample extractor (docs/meeting-design.md §4.10): prints the embeddings of the requested turns
    /// as JSON on stdout, which must be a pipe, and writes nothing.
    struct Embed: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the voice embeddings of some turns to a pipe (used by VoiceIsLocal.app).",
            shouldDisplay: false)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Option(help: "The track (mic or system).") var track: String
        @Option(help: """
            Turn IDs, separated by commas; ID@start-end (session seconds) embeds exactly that span. "-" reads them \
            from stdin, one per line (how VoiceIsLocal.app passes them, so the arguments stay short).
            """)
        var turns: String
        @Flag(help: "Print JSON (the only format).") var json = false

        func validate() throws {
            guard json else { throw ValidationError("voiceislocal speakers embed prints JSON only; add --json.") }
            guard track == "mic" || track == "system" else { throw ValidationError("--track must be mic or system.") }
        }

        mutating func run() async throws {
            var info = stat()
            guard fstat(STDOUT_FILENO, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFIFO || (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw HolosError.invalidInput("voiceislocal speakers embed writes voice data only to a pipe.")
            }
            let loaded = try SpeakerCommand.load(session)
            var seen = Set<String>()
            let entries = try Self.entries(turns == "-" ? Self.readStandardInput() : turns)
            let byID = Dictionary(loaded.view.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var refs: [TurnRef] = []
            for entry in entries {
                // With a span, exactly that audio is embedded, whatever the labels say now: the app's voice pass
                // keeps each vector against the times it asked about, and a split made while it runs must not
                // shorten one of them behind its back.
                if let span = SubprocessVoiceSampleExtractor.parseSpan(entry) {
                    if seen.insert(span.id).inserted { refs.append(span) }
                    continue
                }
                guard !entry.contains("@") else {
                    throw HolosError.invalidInput("\(entry) is not a turn ID or ID@start-end.")
                }
                guard seen.insert(entry).inserted else { continue }
                guard let turn = byID[entry], turn.track == track else {
                    throw HolosError.invalidInput("There is no turn \(entry) on the \(track) track.")
                }
                refs.append(TurnRef(turn))
            }
            // Stopped by the app (SIGTERM) when its review closes or a newer change comes: the render, a decoded copy
            // of the meeting's audio, is deleted before exiting instead of waiting for the stale-render sweep.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                DiarizerVoiceSampleExtractor.renderPrefix + UUID().uuidString, isDirectory: true)
            signal(SIGTERM, SIG_IGN)
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            terminate.setEventHandler {
                try? FileManager.default.removeItem(at: scratch)
                _exit(143)
            }
            terminate.resume()
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            guard let extractor = makeVoiceSampleExtractor(session: loaded.session, temporaryDirectory: scratch) else {
                throw HolosError.unavailable(SpeakerEditCommand.modelsMissing)
            }
            let embeddings = try await extractor.turnEmbeddings(session: loaded.session, track: track, turns: refs)
            var data = try HolosJSON.encoder(pretty: false).encode(TurnEmbeddingsOutput(turnEmbeddings: embeddings))
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        }

        /// The most turn text read from stdin: far more than a day of turns.
        static let maxInputBytes = 16 << 20

        /// The turn entries of `text`: separated by commas or line breaks, blanks dropped.
        static func entries(_ text: String) -> [String] {
            text.split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        /// stdin to its end, as UTF-8 text.
        static func readStandardInput() throws -> String {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw HolosError.io("Cannot read the turns from stdin.") }
                if count == 0 { break }
                data.append(contentsOf: buffer[0..<count])
                guard data.count <= maxInputBytes else { throw HolosError.invalidInput("Too many turns on stdin.") }
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw HolosError.invalidInput("The turns on stdin are not UTF-8 text.")
            }
            return text
        }
    }
}

// MARK: - Shared steps

/// Loading, selectors, running a change, and listing for the `speakers` subcommands.
enum SpeakerCommand {
    /// Resolves the session and loads its snapshot with people's current names; refuses a session without usable
    /// speaker labels.
    static func load(_ text: String) throws -> LoadedSpeakers {
        try LoadedSpeakers.load(session: SessionLocator.resolve(text), store: SpeakerProfileStore())
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

    /// Saves one change on the loaded view (`SpeakerEditCommand`).
    static func save(_ actions: [SpeakerEditAction], _ loaded: LoadedSpeakers) async throws {
        try await run(.edit(actions), loaded)
    }

    /// Makes `change` through `SpeakerEditCommand`, printing what it says as it goes: content on stdout, notes on
    /// stderr.
    static func run(_ change: SpeakerEditCommand.Change, _ loaded: LoadedSpeakers) async throws {
        _ = try await SpeakerEditCommand.run(
            SpeakerEditCommand.Request(loaded: loaded, change: change),
            makeExtractor: { makeVoiceSampleExtractor(session: $0) },
            report: { message in
                switch message {
                case .output(let text): Console.output(text)
                case .note(let text): Console.error(text)
                }
            })
    }

    /// Warnings about the labels themselves, on stderr.
    static func printNotes(_ diagnostics: SpeakerSnapshotDiagnostics) {
        for note in diagnostics.notes { Console.error(note) }
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
