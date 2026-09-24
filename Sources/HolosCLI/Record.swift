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
        ])

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a foreground recording. Ctrl-C saves and stops.")
        @Option(help: "Session display name.") var name = "Meeting"
        @Option(help: "Audio sources: mic, system, or mic+system.") var source: AudioSource = .microphoneAndSystem
        @OptionGroup var recognition: RecognitionOptions
        @Option(help: "Session output root (default: HOLOS_DATA_DIR or Application Support/Holos/Sessions).") var directory: String?
        @Option(help: "Automatically stop after this many seconds.") var duration: Double?
        @Flag(help: "Save audio without running speech recognition.") var recordOnly = false
        @Flag(help: "Skip post-processing (speaker labels) after the recording.") var noPostprocess = false
        @Option(help: "Capture system audio only from this running application bundle ID.") var app: String?

        mutating func validate() throws {
            if let duration, !duration.isFinite || duration <= 0 { throw ValidationError("Duration must be positive and finite.") }
            if source == .microphone, app != nil { throw ValidationError("--app applies to system audio, not mic-only recording.") }
        }

        @MainActor mutating func run() async throws {
            let options = RecordingOptions(name: name, source: source, locale: recognition.locale,
                                           backend: recognition.backend, root: directory.map(fileURL) ?? HolosPaths.sessions,
                                           duration: duration, recordOnly: recordOnly, applicationBundleID: app)
            let dependencies = RecordingDependencies.live(stop: SignalStopController(), reporter: ConsoleReporter(),
                postProcess: noPostprocess || recordOnly ? nil : makePostProcessHook(options: .init()))
            let outcome = try await RecordingWorkflow.run(options, dependencies: dependencies)
            if let record = outcome.postProcessing, record.state == .failed || record.state == .partial,
               let message = record.message {
                Console.error(message)
            }
            Console.error("Saved \(outcome.directory.path)")
            if !outcome.transcriptErrors.isEmpty {
                throw HolosError.incomplete("Audio saved; transcription needs retry: \(outcome.transcriptErrors.joined(separator: "; ")).")
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List saved and currently recording sessions.")
        @Option(help: "Session output root.") var directory: String?
        mutating func run() throws {
            let root = directory.map(fileURL) ?? HolosPaths.sessions
            guard FileManager.default.fileExists(atPath: root.path) else { Console.output("No sessions yet."); return }
            let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "holos" }
            for path in paths.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let manifest = try SessionArchive.readManifest(at: path)
                var status = manifest.status
                if status == "recording" || status == "processing" {
                    if try !SessionArchive.isActive(at: path) { status = "interrupted" }
                }
                Console.output("\(manifest.id)\t\(status)\t\(manifest.name)\t\(manifest.chunks.count) saved chunks")
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Request a graceful stop for an exact session ID.")
        @Argument var sessionID: String
        @Option(help: "Session output root.") var directory: String?
        mutating func run() throws {
            guard UUID(uuidString: sessionID) != nil else { throw ValidationError("Expected a session UUID from holos record status.") }
            let path = (directory.map(fileURL) ?? HolosPaths.sessions).appendingPathComponent("\(sessionID).holos")
            let manifest = try SessionArchive.readManifest(at: path)
            guard manifest.id == sessionID else { throw HolosError.invalidInput("Session identity mismatch.") }
            guard manifest.status == "recording" else { Console.output("Audio capture is already stopped: \(manifest.status)."); return }
            guard try SessionArchive.isActive(at: path) else {
                throw HolosError.unavailable("Recorder is no longer running. Recover the saved archive with holos session recover.")
            }
            let request = path.appendingPathComponent("stop.request")
            if !FileManager.default.fileExists(atPath: request.path) { try Data("stop\n".utf8).write(to: request, options: .withoutOverwriting) }
            Console.output("Stop requested for \(sessionID). The recording process will finish saving audio and text.")
        }
    }
}
