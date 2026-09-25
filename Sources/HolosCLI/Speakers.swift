import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage

/// `holos speakers …` (docs/meeting-design.md §5.7, §5.9): list a session's speakers, correct them through
/// `SpeakerEditor`, and link them to people through `VoiceProfileService`. Content goes to stdout; notes and warnings
/// to stderr (§1.4).
struct Speakers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and correct the speaker labels of a session, and link speakers to people.",
        discussion: """
            <session> is the path to a .holos folder, or a session ID in the sessions folder (HOLOS_DATA_DIR, or \
            Application Support/Holos/Sessions). <speaker> is a speaker ID (system:S2), its engine label (S2), its \
            number (3 or "Speaker 3"), its name, or unknown. <turn> is a turn ID (T12) or a time inside the turn \
            (01:12:03, 12:03.5, or 723.5 seconds); add --track mic or --track system when both tracks speak then. \
            <person> is a person's ID or unique name from holos people list. \
            Each change is checked against the labels it was worked out on and refused if they changed meanwhile, \
            is saved in the session's edit journal (holos speakers undo reverts it), and rewrites the session's \
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
        @Option(help: "A speaker, unknown, or new (optionally new:NAME) for a new speaker.") var to: String
        @Option(help: "The track (mic or system) for turns given as times.") var track: String?

        func validate() throws {
            if turns.isEmpty { throw ValidationError("Name at least one turn.") }
        }

        mutating func run() async throws {
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
            let undone = SpeakerCommand.newestBatch(loaded)
            let owners = SpeakerCommand.sampleOwners(loaded)
            let result: SpeakerEditResult
            do {
                result = try SpeakerEditor.undoLast(view: loaded.view, session: loaded.session,
                                                    source: SpeakerCommand.source, regenerateExports: false,
                                                    profiles: loaded.store)
            } catch HolosError.incomplete(let message) {
                try await SpeakerCommand.refreshAfterSavedChange(HolosError.incomplete(message), loaded,
                                                                 owners: owners)
            }
            let descriptions = undone.map {
                SpeakerCommand.describe($0.action, before: loaded.view, after: nil, editID: $0.id,
                                        people: loaded.people)
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
            try await SpeakerCommand.finishChange(
                needsSampleRefresh: result.needsSampleRefresh, rewritingExports: true, loaded, owners: owners,
                diagnostics: result.diagnostics.merging(loaded.snapshot.diagnostics))
        }
    }

    // MARK: - link

    struct Link: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Link a speaker to a person, so the name carries across meetings.",
            discussion: """
                <person> is a person's ID or unique name (holos people list), or new:NAME for a new person. The \
                speaker is named after the person too, so the meeting keeps the name if the person is forgotten \
                later. With --learn-voice and Remember voices on (holos people remember on), the person's voice is \
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
            // Also without --learn-voice: a sample the person already has from this meeting is kept in step.
            let extractor = makeVoiceSampleExtractor(session: loaded.session)
            let owners = SpeakerCommand.sampleOwners(loaded)
            let snapshot: SpeakerSessionSnapshot
            do {
                snapshot = try await VoiceProfileService.link(
                    session: loaded.session, speakerID: speakerID, to: target, view: loaded.view,
                    learnVoice: learnVoice, extractor: extractor, store: loaded.store)
            } catch {
                SpeakerCommand.noteRemovedSamples(owners, loaded)
                throw error
            }
            try SpeakerCommand.reportLink(speakerID: speakerID, snapshot: snapshot, learnVoice: learnVoice,
                                          extractorAvailable: extractor != nil, loaded: loaded)
            SpeakerCommand.noteRemovedSamples(owners, loaded)
        }
    }

    // MARK: - me

    struct Me: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Link a speaker to you (\"This is me\").",
            discussion: """
                The first time, Holos creates the person who is you with your account's full name; rename it with \
                holos people rename. --learn-voice learns your voice as holos speakers link does.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The speaker who is you.") var speaker: String
        @Flag(help: "Learn your voice from this speaker (needs Remember voices on).") var learnVoice = false

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let speakerID = try SpeakerCommand.speakerID(speaker, in: loaded.view)
            let extractor = makeVoiceSampleExtractor(session: loaded.session)
            let owners = SpeakerCommand.sampleOwners(loaded)
            let snapshot: SpeakerSessionSnapshot
            do {
                snapshot = try await VoiceProfileService.markSelf(
                    session: loaded.session, speakerID: speakerID, view: loaded.view, learnVoice: learnVoice,
                    extractor: extractor, store: loaded.store)
            } catch {
                SpeakerCommand.noteRemovedSamples(owners, loaded)
                throw error
            }
            try SpeakerCommand.reportLink(speakerID: speakerID, snapshot: snapshot, learnVoice: learnVoice,
                                          extractorAvailable: extractor != nil, loaded: loaded)
            SpeakerCommand.noteRemovedSamples(owners, loaded)
        }
    }

    // MARK: - reject

    struct Reject: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Say a speaker is not a person, in this meeting only.",
            discussion: """
                Holos stops suggesting that person for the speaker, and unlinks the speaker if it was linked to them \
                (the speaker keeps its name; rename it or clear it with holos speakers rename).
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Argument(help: "The speaker.") var speaker: String
        @Argument(help: "The person the speaker is not (an ID or a name).") var person: String

        mutating func run() async throws {
            let loaded = try SpeakerCommand.load(session)
            let speakerID = try SpeakerCommand.speakerID(speaker, in: loaded.view)
            let profileID = try PeopleCommand.profileID(person, store: loaded.store)
            let action = SpeakerEditAction.rejectProfile(speakerID: speakerID, profileID: profileID)
            let owners = SpeakerCommand.sampleOwners(loaded)
            let snapshot: SpeakerSessionSnapshot
            do {
                // Whether this changes nothing is decided on the meeting's current labels under the speaker lock,
                // not on the loaded view: another window may have undone the rejection, or linked the speaker to
                // the person, since the load.
                guard let saved = try VoiceProfileService.reject(session: loaded.session, speakerID: speakerID,
                                                                 profileID: profileID, view: loaded.view,
                                                                 store: loaded.store) else {
                    Console.output("Nothing to change; the speaker labels already look like that.")
                    try await SpeakerCommand.finishChange(needsSampleRefresh: true, rewritingExports: false, loaded,
                                                          owners: owners,
                                                          diagnostics: loaded.snapshot.diagnostics)
                    return
                }
                snapshot = saved
            } catch HolosError.incomplete(let message) {
                // Saved, but the exports (rewritten by the editor here) or the reload failed.
                try await SpeakerCommand.refreshAfterSavedChange(HolosError.incomplete(message), loaded,
                                                                 owners: owners)
            }
            Console.output(SpeakerCommand.describe(action, before: loaded.view, after: snapshot.projection,
                                                   people: loaded.people))
            // A person's sample from this meeting stops using the speaker's turns (a no-op when none is affected).
            try await SpeakerCommand.finishChange(
                needsSampleRefresh: true, rewritingExports: false, loaded, owners: owners,
                diagnostics: snapshot.diagnostics.merging(loaded.snapshot.diagnostics))
        }
    }

    // MARK: - embed (hidden)

    /// The app's voice sample extractor (docs/meeting-design.md §4.10): prints the embeddings of the requested turns
    /// as JSON on stdout, which must be a pipe, and writes nothing.
    struct Embed: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the voice embeddings of some turns to a pipe (used by Holos.app).",
            shouldDisplay: false)

        @Argument(help: "Path to a .holos folder, or a session ID.") var session: String
        @Option(help: "The track (mic or system).") var track: String
        @Option(help: "Turn IDs, separated by commas.") var turns: String
        @Flag(help: "Print JSON (the only format).") var json = false

        func validate() throws {
            guard json else { throw ValidationError("holos speakers embed prints JSON only; add --json.") }
            guard track == "mic" || track == "system" else { throw ValidationError("--track must be mic or system.") }
        }

        mutating func run() async throws {
            var info = stat()
            guard fstat(STDOUT_FILENO, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFIFO || (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw HolosError.invalidInput("holos speakers embed writes voice data only to a pipe.")
            }
            let loaded = try SpeakerCommand.load(session)
            var seen = Set<String>()
            let ids = turns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            let byID = Dictionary(loaded.view.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let refs = try ids.map { id -> TurnRef in
                guard let turn = byID[id], turn.track == track else {
                    throw HolosError.invalidInput("There is no turn \(id) on the \(track) track.")
                }
                return TurnRef(turn)
            }
            guard let extractor = makeVoiceSampleExtractor(session: loaded.session) else {
                throw HolosError.unavailable(SpeakerCommand.modelsMissing)
            }
            let embeddings = try await extractor.turnEmbeddings(session: loaded.session, track: track, turns: refs)
            var data = try HolosJSON.encoder(pretty: false).encode(TurnEmbeddingsOutput(turnEmbeddings: embeddings))
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}

// MARK: - Shared steps

/// A session loaded for a speaker command: its snapshot and the projection selectors resolve against, which is also
/// the view the edit is made on, with the people store and people's current names.
struct LoadedSpeakers {
    let session: URL
    let snapshot: SpeakerSessionSnapshot
    let view: SpeakerProjection
    let store: SpeakerProfileStore
    /// Profile ID → name.
    let people: [String: String]
    /// The people store as read when the session was loaded (nil when it could not be read), to tell whether a
    /// change reset the calibration.
    let peopleBefore: SpeakerProfileDatabase?
}

enum SpeakerCommand {
    /// `SpeakerEdit.source` of every CLI edit.
    static let source = "cli"

    static let modelsMissing = "Speaker models are not installed, so voices can't be learned. Install them with "
        + "holos setup --speakers."

    /// Resolves the session and loads its snapshot with people's current names; refuses a session without usable
    /// speaker labels.
    static func load(_ text: String) throws -> LoadedSpeakers {
        let session = try SessionLocator.resolve(text)
        let store = SpeakerProfileStore()
        let peopleBefore = try? store.load()
        let people = VoiceProfileService.profileNames(store: store)
        let snapshot = try SpeakerSessionSnapshot.load(
            session: session, profileNames: people,
            applyRecognition: VoiceProfileService.recognitionAllowed(store: store))
        guard let view = snapshot.projection else {
            throw HolosError.unavailable(snapshot.runProblem
                ?? "This meeting has no speaker labels yet. Label them with holos session diarize \(session.path).")
        }
        return LoadedSpeakers(session: session, snapshot: snapshot, view: view, store: store, people: people,
                              peopleBefore: peopleBefore)
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

    /// Saves one change on the loaded view, prints what it did, rewrites the exports, and updates the voice samples
    /// the change affects. A change that would leave the labels as they are is not saved (it would only use up an
    /// undo step); the editor decides that on the current labels under the speaker lock, after refusing a change
    /// whose labels moved on since the load.
    static func save(_ actions: [SpeakerEditAction], _ loaded: LoadedSpeakers) async throws {
        let owners = sampleOwners(loaded)
        let result: SpeakerEditResult
        do {
            guard let saved = try SpeakerEditor.applyUnlessUnchanged(
                actions, view: loaded.view, session: loaded.session, source: source, regenerateExports: false,
                profileNames: loaded.people, profiles: loaded.store) else {
                Console.output("Nothing to change; the speaker labels already look like that.")
                // An earlier run of this same change may have saved its edit and then failed to bring this
                // meeting's samples in step, which would leave a voiceprint holding speech the edit moved to
                // someone else. Repeating the change lands here, so the refresh runs from here too; it is decided
                // by input digests, so it costs nothing when the samples are already in step.
                // The editor found the current labels as loaded, so the loaded snapshot's warnings still hold.
                try await finishChange(needsSampleRefresh: true, rewritingExports: false, loaded, owners: owners,
                                       diagnostics: loaded.snapshot.diagnostics)
                return
            }
            result = saved
        } catch HolosError.incomplete(let message) {
            try await refreshAfterSavedChange(HolosError.incomplete(message), loaded, owners: owners)
        }
        for action in actions {
            Console.output(describe(action, before: loaded.view, after: result.snapshot.projection,
                                    people: loaded.people))
        }
        try await finishChange(needsSampleRefresh: result.needsSampleRefresh, rewritingExports: true, loaded,
                               owners: owners,
                               diagnostics: result.diagnostics.merging(loaded.snapshot.diagnostics))
    }

    /// After a saved change: rewrites the exports (when asked), then updates the voice samples the change affects
    /// whether or not the exports could be rewritten (a stale sample would hold turns the change moved to someone
    /// else, and no later edit would notice), notes removed samples, and prints the label notes. Every failure is
    /// reported together as `incomplete`.
    static func finishChange(needsSampleRefresh: Bool, rewritingExports: Bool, _ loaded: LoadedSpeakers,
                             owners: [String: String], diagnostics: SpeakerSnapshotDiagnostics) async throws {
        var failures: [String] = []
        if rewritingExports {
            do {
                try rewriteExports(loaded)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        do {
            try await refreshSamplesIfNeeded(needsSampleRefresh, loaded)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failures.append(error.localizedDescription)
        }
        noteRemovedSamples(owners, loaded)
        printNotes(diagnostics)
        guard failures.isEmpty else { throw HolosError.incomplete(failures.joined(separator: " ")) }
    }

    /// The change was saved, then the editor failed (`incomplete`) before it could say whether samples are
    /// affected: brings this meeting's samples in step anyway, then throws `error`.
    static func refreshAfterSavedChange(_ saved: HolosError, _ loaded: LoadedSpeakers,
                                        owners: [String: String]) async throws -> Never {
        do {
            try await VoiceProfileService.refreshSamples(
                afterSaving: saved, session: loaded.session,
                extractor: makeVoiceSampleExtractor(session: loaded.session), store: loaded.store)
        } catch {
            // `error` here is what the refresh threw, which is the combined report when the samples could not be
            // brought in step, or a cancellation. The parameter is named `saved` so that is plain to read: a
            // `catch` binds `error` itself, and a parameter of that name would be shadowed rather than rethrown.
            noteRemovedSamples(owners, loaded)
            throw error
        }
    }

    /// After a saved change that affects a person's voice sample from this meeting, recomputes it (or removes it).
    static func refreshSamplesIfNeeded(_ needed: Bool, _ loaded: LoadedSpeakers) async throws {
        guard needed else { return }
        do {
            try await VoiceProfileService.refreshSamples(session: loaded.session,
                                                         extractor: makeVoiceSampleExtractor(session: loaded.session),
                                                         store: loaded.store)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HolosError.incomplete("The change was saved, but a voice sample learned from this meeting could "
                                        + "not be updated: \(error.localizedDescription)")
        }
    }

    /// The people who have a voice sample from this meeting (profile ID → name); empty when the store cannot be read.
    static func sampleOwners(_ loaded: LoadedSpeakers) -> [String: String] {
        guard let database = try? loaded.store.load() else { return [:] }
        let sessionID = loaded.snapshot.manifest.id
        return Dictionary(database.profiles.filter { $0.samples.contains { $0.sessionID == sessionID } }
            .map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// On stderr, for each person in `before` who no longer has a sample from this meeting, and when a sample
    /// change reset the calibration.
    static func noteRemovedSamples(_ before: [String: String], _ loaded: LoadedSpeakers) {
        PeopleCommand.noteCalibrationReset(before: loaded.peopleBefore, store: loaded.store)
        guard !before.isEmpty else { return }
        let after = sampleOwners(loaded)
        for (profileID, name) in before.sorted(by: { $0.value < $1.value }) where after[profileID] == nil {
            Console.error("Removed \(name)'s voice sample from this meeting: the speakers or turns it was learned "
                          + "from changed, and it could not be learned again from the new labels.")
        }
    }

    /// Rewrites exports/ after a change was saved (the editor has released the speaker lock).
    static func rewriteExports(_ loaded: LoadedSpeakers) throws {
        let session = loaded.session
        let written: ExportWriteResult
        do {
            written = try SessionExports.regenerate(
                session: session, profileNames: VoiceProfileService.profileNames(store: loaded.store),
                applyRecognition: VoiceProfileService.recognitionAllowed(store: loaded.store))
        } catch {
            throw HolosError.incomplete("The change was saved, but the exports could not be rewritten: "
                                        + "\(error.localizedDescription) Rewrite them with holos session export "
                                        + "\(session.path) --all.")
        }
        for url in written.movedAside { Console.error(movedAsideNote(url)) }
    }

    /// Prints what `speakers link` or `me` did: the link, and what happened to the voice.
    static func reportLink(speakerID: String, snapshot: SpeakerSessionSnapshot, learnVoice: Bool,
                           extractorAvailable: Bool, loaded: LoadedSpeakers) throws {
        let database = try loaded.store.load()
        let speaker = snapshot.projection?.speakers.first { $0.id == speakerID }
        guard let profileID = speaker?.profileID,
              let profile = database.profiles.first(where: { $0.id == profileID }) else {
            Console.output("Linked \(speakerID).")
            printNotes(snapshot.diagnostics)
            return
        }
        Console.output("Linked \(speakerID) to \(profile.displayName)\(profile.isSelf ? " (you)" : "").")
        if learnVoice {
            Console.error(voiceNote(profile: profile, database: database, snapshot: snapshot,
                                    extractorAvailable: extractorAvailable))
        }
        printNotes(snapshot.diagnostics)
    }

    /// What happened to a voice that was asked to be learned.
    static func voiceNote(profile: SpeakerProfile, database: SpeakerProfileDatabase, snapshot: SpeakerSessionSnapshot,
                          extractorAvailable: Bool) -> String {
        if let sample = profile.samples.first(where: { $0.sessionID == snapshot.manifest.id }) {
            return "Learned \(profile.displayName)'s voice from this meeting "
                + "(\(TimeFormat.duration(sample.speechSeconds)) of speech)."
                + (sample.weak ? " It is short, so it can only give suggestions." : "")
        }
        if !database.rememberVoices {
            return "Remember voices is off, so no voice was learned. Turn it on with holos people remember on."
        }
        if snapshot.audioDeleted { return VoiceProfileService.audioDeletedNote }
        if !extractorAvailable { return modelsMissing }
        if let model = profile.embeddingModel, let run = snapshot.run?.engine?.embeddingModel, model != run {
            return "\(profile.displayName)'s voice samples come from other speaker models, so this one can't be "
                + "added. Forget their samples first (holos people forget)."
        }
        return "No turn of this speaker was long and clear enough (2 s or more, without overlap) to learn the voice."
    }

    /// "Your edited transcript.md was kept as exports/edited-20260923-171200.md."
    static func movedAsideNote(_ url: URL) -> String {
        "Your edited transcript.\(url.pathExtension) was kept as exports/\(url.lastPathComponent)."
    }

    /// Warnings about the labels themselves, on stderr.
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
    /// journal line's ID when the change is already saved (it names a split's second part). `people` (profile ID →
    /// name) names the person of a link or rejection.
    static func describe(_ action: SpeakerEditAction, before: SpeakerProjection, after: SpeakerProjection?,
                         editID: String? = nil, people: [String: String] = [:]) -> String {
        func person(_ id: String) -> String { people[id] ?? "person \(id)" }
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
            return "Linked \(speaker(speakerID)) to \(person(profileID))."
        case .rejectProfile(let speakerID, let profileID):
            return "Marked \(speaker(speakerID)) as not \(person(profileID))."
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
