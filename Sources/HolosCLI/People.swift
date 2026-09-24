import ArgumentParser
import Darwin
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage

/// `holos people …` (docs/meeting-design.md §5.9): the people Holos knows by name, and their opt-in voice samples.
/// Names and counts go to stdout; notes and warnings to stderr (§1.4). Voice vectors are printed only by
/// `export --include-voiceprints`, and never to a terminal.
struct People: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the people Holos knows by name, and their remembered voices.",
        discussion: """
            People are created when you link a speaker to a person (holos speakers link or me). Their names carry \
            across meetings whatever the Remember voices setting says. With Remember voices on, linking with \
            --learn-voice learns a person's voice from that meeting, and later meetings suggest them (\"Maybe Jim\"). \
            Voiceprints are biometric data: only remember people who agreed to it. They stay on this Mac, in \
            Application Support/Holos/Speakers, which is not included in Time Machine backups. <person> is a \
            person's ID or unique name.
            """,
        subcommands: [
            List.self,
            Remember.self,
            Rename.self,
            Merge.self,
            Forget.self,
            Export.self,
            Calibrate.self,
        ])

    // MARK: - list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List people and their voice samples.")

        @Flag(help: "Print the people and their samples (without voiceprints) as JSON.") var json = false

        mutating func run() throws {
            let store = SpeakerProfileStore()
            if json {
                var data = try VoiceProfileService.exportPeople(store: store, includeVoiceprints: false)
                data.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: data)
                return
            }
            let database = try store.load()
            Console.output("Remember voices: \(database.rememberVoices ? "on" : "off")"
                           + (database.isCalibrated ? " · automatic names: on (calibrated)" : ""))
            let people = VoiceProfileService.sortedPeople(database.profiles)
            guard !people.isEmpty else {
                Console.output("No people yet. Link a speaker to a person with holos speakers link.")
                return
            }
            let rows = people.map { profile -> [String] in
                [PeopleCommand.name(profile), PeopleCommand.samplesText(profile),
                 profile.samples.isEmpty ? "" : "suggestions \(profile.recognitionEnabled ? "on" : "off")"]
            }
            for line in TextTable.render(header: nil, rows: rows, alignments: [.left, .left, .left]) {
                Console.output(line)
            }
        }
    }

    // MARK: - remember

    struct Remember: ParsableCommand {
        enum Setting: String, ExpressibleByArgument, CaseIterable { case on, off, status }

        static let configuration = CommandConfiguration(
            abstract: "Turn Remember voices on or off, or show it.",
            discussion: """
                On: linking a speaker with --learn-voice learns that person's voice, and later meetings suggest \
                people whose voices match. Off: no voice is learned or compared; names are still kept. \
                off --forget also forgets every voice sample and every meeting's voice data.
                """)

        @Argument(help: "on, off, or status.") var setting: Setting
        @Flag(help: "With off: also forget every voice sample and every meeting's voice data.") var forget = false

        func validate() throws {
            if forget, setting != .off { throw ValidationError("--forget goes with off.") }
        }

        mutating func run() throws {
            let store = SpeakerProfileStore()
            let before = try store.load()
            let samples = before.sampleCount
            let meetings = before.sampleSessionIDs.count
            switch setting {
            case .status:
                Console.output("Remember voices: \(before.rememberVoices ? "on" : "off") "
                               + "(\(PeopleCommand.count(samples, "voice sample")) of "
                               + "\(PeopleCommand.count(before.profiles.filter { !$0.samples.isEmpty }.count, "person", "people")) "
                               + "from \(PeopleCommand.count(meetings, "meeting")))")
            case .on:
                try VoiceProfileService.setRemember(true, forgetExisting: false, store: store)
                Console.output("Remember voices: on. A voice is learned only when you link a speaker with "
                               + "--learn-voice; only remember people who agreed to it.")
            case .off:
                let forgotten = try VoiceProfileService.setRemember(false, forgetExisting: forget, store: store)
                Console.output("Remember voices: off.")
                if forget {
                    Console.output("Forgot \(PeopleCommand.count(forgotten, "voice sample")) and the voice data of "
                                   + "every meeting in \(HolosPaths.sessions.path). Names are kept.")
                } else if samples > 0 {
                    Console.error("Kept \(PeopleCommand.count(samples, "voice sample")) from "
                                  + "\(PeopleCommand.count(meetings, "meeting")); forget them with "
                                  + "holos people forget --all --yes.")
                }
            }
        }
    }

    // MARK: - rename

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rename a person.",
            discussion: "Meetings keep the name the person had when they were linked; new links use the new name.")

        @Argument(help: "The person (an ID or a name).") var person: String
        @Argument(help: "The new name.") var name: String

        mutating func run() throws {
            let store = SpeakerProfileStore()
            let profileID = try PeopleCommand.profileID(person, store: store)
            try VoiceProfileService.rename(profileID: profileID, to: name, store: store)
            Console.output("Renamed \(person) to \(SpeakerEditor.cleanName(name) ?? name).")
        }
    }

    // MARK: - merge

    struct Merge: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Merge two people who are the same person.",
            discussion: """
                The first person's voice samples move to the second, which keeps its name; the first is removed. \
                People whose samples come from different speaker models cannot be merged.
                """)

        @Argument(help: "The person to merge (an ID or a name).") var person: String
        @Argument(help: "The person to keep (an ID or a name).") var into: String

        mutating func run() throws {
            let store = SpeakerProfileStore()
            let source = try PeopleCommand.profileID(person, store: store)
            let target = try PeopleCommand.profileID(into, store: store)
            try VoiceProfileService.merge(profileID: source, into: target, store: store)
            let name = try store.load().profiles.first { $0.id == target }?.displayName ?? target
            Console.output("Merged \(person) into \(name).")
        }
    }

    // MARK: - forget

    struct Forget: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Forget a person, one of their voice samples, the samples from a meeting, or every voice.",
            discussion: """
                forget <person> removes the person and their voice samples; meetings keep the name they were given. \
                forget <person> --sample ID removes one sample. forget --session <session> removes the samples \
                learned from that meeting (the meeting may already be deleted; give its session ID). forget --all \
                removes every sample and every meeting's voice data; names stay. Meetings are cleaned in the \
                sessions folder only (HOLOS_DATA_DIR, or Application Support/Holos/Sessions), not in sessions \
                created elsewhere with --directory. Forgetting cannot be undone.
                """)

        @Argument(help: "The person (an ID or a name).") var person: String?
        @Option(help: "Forget only this voice sample of the person.") var sample: String?
        @Option(help: "Forget the voice samples learned from this meeting (a path or a session ID).") var session: String?
        @Flag(help: "Forget every voice sample and every meeting's voice data.") var all = false
        @Flag(help: "Confirm; forgetting cannot be undone.") var yes = false

        func validate() throws {
            let chosen = [person != nil, session != nil, all].filter { $0 }.count
            guard chosen == 1 else { throw ValidationError("Give a person, --session, or --all (one of them).") }
            if sample != nil, person == nil { throw ValidationError("--sample goes with a person.") }
            guard yes else { throw ValidationError("Forgetting cannot be undone; add --yes to confirm.") }
        }

        mutating func run() throws {
            let store = SpeakerProfileStore()
            let database = try store.load()
            if all {
                let count = try VoiceProfileService.forgetAll(store: store)
                Console.output("Forgot \(PeopleCommand.count(count, "voice sample")) and the voice data of every "
                               + "meeting in \(HolosPaths.sessions.path). Names are kept.")
            } else if let session {
                let (sessionID, name) = try PeopleCommand.session(session)
                let count = try VoiceProfileService.forget(sessionID: sessionID, store: store)
                Console.output("Forgot \(PeopleCommand.count(count, "voice sample")) learned from \(name ?? sessionID).")
            } else if let person {
                let profileID = try PeopleCommand.profileID(person, store: store)
                guard let profile = database.profiles.first(where: { $0.id == profileID }) else {
                    throw HolosError.invalidInput("There is no person \(person).")
                }
                if let sample {
                    guard profile.samples.contains(where: { $0.id == sample }) else {
                        throw HolosError.invalidInput("\(profile.displayName) has no voice sample \(sample).")
                    }
                    try VoiceProfileService.forget(sampleID: sample, store: store)
                    Console.output("Forgot one voice sample of \(profile.displayName).")
                } else {
                    let count = try VoiceProfileService.forget(profileID: profileID, store: store)
                    Console.output("Forgot \(profile.displayName) and "
                                   + "\(PeopleCommand.count(count, "voice sample")). Meetings keep "
                                   + "the name.")
                }
            }
        }
    }

    // MARK: - export

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write people and their voice sample details as JSON.",
            discussion: """
                Names, meetings, and sample details only; with --include-voiceprints also each sample's voiceprint \
                (biometric data), which is never printed to a terminal. --output writes a new file (never over an \
                existing one).
                """)

        @Option(name: .shortAndLong, help: "Write to this new file instead of stdout.") var output: String?
        @Flag(help: "Include each voice sample's voiceprint (biometric data).") var includeVoiceprints = false

        mutating func run() throws {
            if includeVoiceprints, output == nil, isatty(STDOUT_FILENO) != 0 {
                throw HolosError.invalidInput("Voiceprints are not printed to a terminal; use --output FILE.")
            }
            var data = try VoiceProfileService.exportPeople(store: SpeakerProfileStore(),
                                                            includeVoiceprints: includeVoiceprints)
            data.append(0x0A)
            if includeVoiceprints {
                Console.error("This file contains voiceprints, which are biometric data about the people in it.")
            }
            guard let output else {
                try FileHandle.standardOutput.write(contentsOf: data)
                return
            }
            let url = fileURL(output)
            try SessionExports.writeNewFile(data, at: url)
            Console.output(url.path)
        }
    }

    // MARK: - calibrate (hidden)

    struct Calibrate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Measure voice distances in your confirmed meetings and, with --apply, turn on automatic names.",
            discussion: """
                Compares the voice samples of each person across meetings with those of different people and prints \
                counts and percentiles only. --apply stores thresholds that admit at most 1 % (automatic names, \
                shown as "Jim (auto)") and 5 % (suggestions) of the different-person pairs. It needs samples from at \
                least 3 meetings and at least 2 people with samples from 2 or more meetings.
                """,
            shouldDisplay: false)

        @Flag(help: "Store the thresholds.") var apply = false

        mutating func run() throws {
            let store = SpeakerProfileStore()
            let database = try store.load()
            // Each embedding model is measured on its own: distances of different models are not comparable.
            let models = RecognitionCalibration.models(database)
            if models.isEmpty {
                Console.output("Meetings with voice samples: 0 · people with samples from 2 or more meetings: 0")
            }
            for model in models {
                if models.count > 1 { Console.output("Speaker model \(model.id) (\(model.revision)):") }
                Self.report(RecognitionCalibration.distances(database: database, model: model))
            }
            if let calibration = RecognitionCalibration.calibration(database: database) {
                Self.reportThresholds(calibration.thresholds, prefix: "Thresholds")
            }
            guard apply else { return }
            // Computed again under the store's lock, from the samples present when the thresholds are saved.
            let saved = try VoiceProfileService.applyCalibration(store: store)
            Self.reportThresholds(saved.thresholds, prefix: "Saved thresholds")
            Console.output("New meetings name clear matches automatically, shown as \"Jim (auto)\".")
        }

        /// Counts and percentiles of one model's distances.
        private static func report(_ measured: RecognitionCalibration.Distances) {
            Console.output("Meetings with voice samples: \(measured.meetings) · people with samples from 2 or more "
                           + "meetings: \(measured.repeatedPeople)")
            let rows = [("Same person", measured.samePerson), ("Different people", measured.differentPerson)]
                .map { label, values -> [String] in
                    [label, "\(values.count)"] + [0, 0.05, 0.5, 0.95, 1].map { p in
                        RecognitionCalibration.percentile(values, p).map { String(format: "%.3f", $0) } ?? "–"
                    }
                }
            for line in TextTable.render(header: ["Pairs", "Count", "Min", "5th pct", "Median", "95th pct", "Max"],
                                         rows: rows,
                                         alignments: [.left, .right, .right, .right, .right, .right, .right]) {
                Console.output(line)
            }
        }

        private static func reportThresholds(_ thresholds: RecognitionThresholds, prefix: String) {
            Console.output(String(format: "\(prefix): automatic names at distance ≤ %.3f, suggestions ≤ %.3f.",
                                  thresholds.likelyMaxDistance, thresholds.possibleMaxDistance))
        }
    }
}

// MARK: - Shared steps

enum PeopleCommand {
    /// A person by ID (any case) or by name (case-insensitive, unique).
    static func profileID(_ text: String, store: SpeakerProfileStore) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HolosError.invalidInput("Name a person.") }
        let profiles = try store.load().profiles
        if let exact = profiles.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact.id
        }
        let wanted = SpeakerEditor.cleanName(trimmed) ?? trimmed
        let named = profiles.filter { $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame }
        switch named.count {
        case 1:
            return named[0].id
        case 0:
            throw HolosError.invalidInput("There is no person \(trimmed); list people with holos people list, or "
                                          + "use new:NAME to create one.")
        default:
            throw HolosError.invalidInput("\(named.count) people are named \(wanted); use an ID: "
                                          + named.map(\.id).joined(separator: ", ") + ".")
        }
    }

    /// `new:NAME` → a new person; anything else → a known person.
    static func target(_ text: String, store: SpeakerProfileStore) throws -> ProfileTarget {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("new:") {
            guard let name = SpeakerEditor.cleanName(String(trimmed.dropFirst(4))) else {
                throw HolosError.invalidInput("Give the new person's name: new:NAME.")
            }
            return .new(name: name)
        }
        return .existing(profileID: try profileID(trimmed, store: store))
    }

    /// A session ID and, when the session exists, its name. A bare UUID is taken as is (the meeting may be deleted).
    static func session(_ text: String) throws -> (id: String, name: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) {
            let id = uuid.uuidString
            let url = HolosPaths.sessions.appendingPathComponent("\(id).holos", isDirectory: true)
            return (id, try? SessionArchive.readManifest(at: url).name)
        }
        let manifest = try SessionArchive.readManifest(at: try SessionLocator.resolve(trimmed))
        return (manifest.id, manifest.name)
    }

    /// "Jim", or "Maria (you)".
    static func name(_ profile: SpeakerProfile) -> String {
        profile.displayName + (profile.isSelf ? " (you)" : "")
    }

    /// "3 samples (2:41 of speech; room 2, call 1)", "1 sample (0:12 of speech; room 1; weak)", or "no voice samples".
    static func samplesText(_ profile: SpeakerProfile) -> String {
        let samples = profile.samples
        guard !samples.isEmpty else { return "no voice samples" }
        let seconds = samples.reduce(0) { $0 + $1.speechSeconds }
        var details = [String]()
        let room = samples.filter { $0.condition == .room }.count
        let call = samples.count - room
        details.append([room > 0 ? "room \(room)" : nil, call > 0 ? "call \(call)" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        let weak = samples.filter(\.weak).count
        if weak > 0 { details.append(weak == samples.count ? "weak" : "\(weak) weak") }
        return "\(count(samples.count, "sample")) (\(TimeFormat.duration(seconds)) of speech; "
            + details.joined(separator: "; ") + ")"
    }

    static func count(_ value: Int, _ noun: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? noun : plural ?? noun + "s")"
    }
}
