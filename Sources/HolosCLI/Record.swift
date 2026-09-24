import ArgumentParser
import Darwin
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record microphone and system audio with a growing local transcript.",
        subcommands: [
            Start.self,
            Status.self,
            Stop.self,
            Pause.self,
            Resume.self,
            Marker.self,
        ])

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a foreground recording. Ctrl-C saves and stops.",
            discussion: """
                Exits 0 when the recording was saved, 1 when it failed or its transcription needs a retry (including \
                10 minutes without audio), and 3 when the audio was saved but the recording stopped by itself (low \
                disk, a long sleep, or a 6-hour pause) or speaker labelling was skipped or failed. The reason is \
                printed on stderr.
                """)
        @Option(help: "Session display name.") var name = "Meeting"
        @Option(help: "Audio sources: mic, system, or mic+system.") var source: AudioSource = .microphoneAndSystem
        @OptionGroup var recognition: RecognitionOptions
        @Option(help: "Session output root (default: HOLOS_DATA_DIR or Application Support/Holos/Sessions).") var directory: String?
        @Option(help: "Automatically stop after this many seconds.") var duration: Double?
        @Flag(help: "Save audio without running speech recognition.") var recordOnly = false
        @Flag(help: "Skip post-processing (speaker labels) after the recording.") var noPostprocess = false
        @Option(help: "Capture system audio only from this running application bundle ID.") var app: String?
        @Option(help: "The new session's ID, a UUID; no session with this ID may exist yet.") var sessionId: String?
        @Flag(help: "Do not print finalized phrases while recording.") var noLiveText = false
        @Flag(help: "In a mic+system call, also label speakers on the microphone track because others share the room.")
        var othersInRoom = false
        @Option(help: "How many people are expected to speak (1-20), a hint for speaker labelling.") var expectedSpeakers: Int?
        @Option(help: "A JSON file of names and terms to recognize ({\"schemaVersion\": 1, \"strings\": [...]}); it is deleted once read.")
        var vocabularyFile: String?

        mutating func validate() throws {
            if let duration, !duration.isFinite || duration <= 0 { throw ValidationError("Duration must be positive and finite.") }
            if source == .microphone, app != nil { throw ValidationError("--app applies to system audio, not mic-only recording.") }
            if othersInRoom, source != .microphoneAndSystem {
                throw ValidationError("--others-in-room applies only to --source mic+system.")
            }
            if let sessionId, UUID(uuidString: sessionId) == nil {
                throw ValidationError("--session-id must be a UUID, like \(UUID().uuidString).")
            }
            if let expectedSpeakers, !(1...20).contains(expectedSpeakers) {
                throw ValidationError("--expected-speakers must be between 1 and 20.")
            }
        }

        @MainActor mutating func run() async throws {
            let vocabulary = try readVocabulary()
            let options = RecordingOptions(name: name, source: source, locale: recognition.locale,
                                           backend: recognition.backend, root: directory.map(fileURL) ?? HolosPaths.sessions,
                                           duration: duration, recordOnly: recordOnly, applicationBundleID: app,
                                           vocabulary: vocabulary, sessionID: sessionId, othersInRoom: othersInRoom,
                                           expectedSpeakers: expectedSpeakers, liveText: !noLiveText)
            let dependencies = RecordingDependencies.live(stop: SignalStopController(), reporter: ConsoleReporter(),
                postProcess: noPostprocess || recordOnly ? nil : recordingPostProcessHook())
            let outcome = try await RecordingWorkflow.run(options, dependencies: dependencies)
            if let record = outcome.postProcessing, record.state == .failed || record.state == .partial,
               let message = record.message {
                Console.error(message)
            }
            Console.error("Saved \(outcome.directory.path)")
            // docs/meeting-design.md §1.4: 1 for failures (as before), 3 for saved audio with a warning.
            if !outcome.transcriptErrors.isEmpty {
                throw HolosError.incomplete("Audio saved; transcription needs retry: \(outcome.transcriptErrors.joined(separator: "; ")).")
            }
            if outcome.stopReason == .captureFailed {
                throw HolosError.incomplete("Audio stayed unavailable for 10 minutes, so the recording ended. The audio recorded before that is saved.")
            }
            if let explanation = Self.automaticStopExplanation(outcome.stopReason) {
                Console.error(explanation)
                throw ExitCode(3)
            }
            if let state = outcome.postProcessing?.state, state == .failed || state == .partial {
                throw ExitCode(3)
            }
        }

        static func automaticStopExplanation(_ reason: StopReason) -> String? {
            switch reason {
            case .diskLow: "The recording stopped because free disk space fell below 500 MB; the audio up to then is saved."
            case .sleepTimeout: "The recording ended where the Mac went to sleep for 15 minutes or more."
            case .pauseTimeout: "The recording ended after staying paused for 6 hours."
            default: nil
            }
        }

        /// The vocabulary the app hands over (docs/meeting-design.md §4.12). The file holds private names, so it is
        /// deleted once read, whether or not it could be used.
        private func readVocabulary() throws -> [String] {
            guard let vocabularyFile else { return [] }
            let url = fileURL(vocabularyFile)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try AtomicFile.readIfPresent(url, maxBytes: 1 << 20) else {
                throw ValidationError("The vocabulary file \(url.path) does not exist.")
            }
            guard let vocabulary = try? HolosJSON.decoder().decode(MeetingVocabulary.self, from: data),
                  vocabulary.schemaVersion == 1 else {
                throw ValidationError("The vocabulary file is not a Holos vocabulary (schemaVersion 1 with strings).")
            }
            return vocabulary.strings
        }

        /// Post-processing after the recording, told how the recording stopped so a `diskLow` stop skips rendering.
        private func recordingPostProcessHook() -> PostProcessHook {
            { session, lease, progress in
                let reason = RecordingWorkflow.recordedStopReason(session: session)
                return await makePostProcessHook(options: PostProcessingOptions(stopReason: reason))(session, lease, progress)
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List saved and currently recording sessions.")
        @Option(help: "Session output root.") var directory: String?
        @Flag(help: "Print the sessions as JSON.") var json = false

        struct Entry: Encodable {
            var id: String
            var status: String
            var name: String
            var chunks: Int
            var phase: RecorderPhase?
            var elapsedSeconds: Double?
        }

        mutating func run() throws {
            let root = directory.map(fileURL) ?? HolosPaths.sessions
            guard FileManager.default.fileExists(atPath: root.path) else {
                if json { Console.output("[]") } else { Console.output("No sessions yet.") }
                return
            }
            let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "holos" }
            var entries: [Entry] = []
            for path in paths.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let manifest = try SessionArchive.readManifest(at: path)
                var status = manifest.status
                if status == ArchiveStatus.recording || status == ArchiveStatus.processing {
                    if try !SessionArchive.isActive(at: path) { status = ArchiveStatus.interrupted }
                }
                var entry = Entry(id: manifest.id, status: status, name: manifest.name, chunks: manifest.chunks.count)
                let liveness = RecorderChannel.liveness(session: path)
                if liveness == .capturing || liveness == .processing,
                   let recorder = try? RecorderChannel.readStatus(session: path) {
                    entry.phase = recorder.phase
                    entry.elapsedSeconds = recorder.elapsedSeconds
                }
                entries.append(entry)
            }
            if json {
                try Console.json(entries)
                return
            }
            for entry in entries {
                var line = "\(entry.id)\t\(entry.status)\t\(entry.name)\t\(entry.chunks) saved chunks"
                if let phase = entry.phase {
                    line += "\tphase=\(phase.rawValue) elapsed=\(Self.clock(entry.elapsedSeconds ?? 0))"
                }
                Console.output(line)
            }
        }

        /// h:mm:ss.
        static func clock(_ seconds: Double) -> String {
            let total = seconds.isFinite ? Int(max(0, min(seconds, 1e9))) : 0
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask a running recorder to stop and save, by exact session ID.")
        @Argument(help: "The session ID from holos record status.") var sessionID: String
        @Option(help: "Session output root.") var directory: String?
        @Flag(help: "Do not wait for the recorder to confirm the request.") var noWait = false
        mutating func run() async throws {
            try await RecorderControl.send(.stop, sessionID: sessionID, directory: directory, noWait: noWait)
        }
    }
}
