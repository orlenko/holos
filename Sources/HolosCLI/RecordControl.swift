import ArgumentParser
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

extension Record {
    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pause a running recording: capture stops until resume, and the gap is marked.")
        @Argument(help: "The session ID from voiceislocal record status.") var sessionID: String
        @Option(help: "Session output root.") var directory: String?
        @Flag(help: "Do not wait for the recorder to confirm the request.") var noWait = false
        mutating func run() async throws {
            try await RecorderControl.send(.pause, sessionID: sessionID, directory: directory, noWait: noWait)
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resume a paused recording in the same session.")
        @Argument(help: "The session ID from voiceislocal record status.") var sessionID: String
        @Option(help: "Session output root.") var directory: String?
        @Flag(help: "Do not wait for the recorder to confirm the request.") var noWait = false
        mutating func run() async throws {
            try await RecorderControl.send(.resume, sessionID: sessionID, directory: directory, noWait: noWait)
        }
    }

    struct Marker: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a marker at the current point of a running recording.")
        @Argument(help: "The session ID from voiceislocal record status.") var sessionID: String
        @Option(help: "Text for the marker (at most 200 characters).") var label: String?
        @Option(help: "Session output root.") var directory: String?
        @Flag(help: "Do not wait for the recorder to confirm the request.") var noWait = false

        func validate() throws {
            if let label, label.count > 200 { throw ValidationError("--label is limited to 200 characters.") }
        }

        mutating func run() async throws {
            try await RecorderControl.send(.marker, label: label, sessionID: sessionID, directory: directory,
                                           noWait: noWait)
        }
    }
}

/// Sends one control request to a running recorder (docs/meeting-design.md §4.1) and reports its answer.
enum RecorderControl {
    static let ackTimeout: Duration = .seconds(3)

    static func send(_ command: ControlCommand, label: String? = nil, sessionID: String, directory: String?,
                     noWait: Bool) async throws {
        guard let uuid = UUID(uuidString: sessionID) else {
            throw ValidationError("Expected a session UUID from voiceislocal record status.")
        }
        let id = uuid.uuidString
        let root = directory.map(fileURL) ?? HolosPaths.sessions
        let session = root.appendingPathComponent("\(id).holos", isDirectory: true)
        guard FileManager.default.fileExists(atPath: session.path) else {
            throw HolosError.invalidInput("No session \(id) in \(root.path). List sessions with voiceislocal record status.")
        }
        switch RecorderChannel.liveness(session: session) {
        case .dead:
            throw HolosError.unavailable("Recorder is no longer running. Recover the saved archive with voiceislocal session recover.")
        case .exited:
            if command == .stop {
                let status = (try? SessionArchive.readManifest(at: session).status) ?? "unknown"
                Console.output("Audio capture is already stopped: \(status).")
                return
            }
            throw HolosError.unavailable("The recorder has already exited.")
        case .capturing, .processing, .maintenance:
            // `send` refuses a session that only a maintenance command holds (recovery, rebuild, `session diarize`,
            // deletion): nothing would answer or remove the request. A live recorder whose status is stale still
            // gets it. Both `--no-wait` and the waiting form go through `send` first.
            break
        }
        let request: ControlRequest
        do {
            // `send` reads status.json again after publishing and withdraws a request the recorder exited without
            // reading, so `--no-wait` never reports a request that nothing will answer.
            request = try RecorderChannel.send(command, label: label, session: session, sessionID: id, sender: "cli")
        } catch {
            if try reportExited(command, session: session) { return }
            throw error
        }
        if noWait {
            Console.output("Sent \(command.rawValue) to \(id).")
            return
        }
        guard let ack = await RecorderChannel.waitForAck(request, session: session, timeout: ackTimeout) else {
            // A recorder that exited meanwhile never answers; `waitForAck` has withdrawn the request.
            if try reportExited(command, session: session) { return }
            Console.error("Recorder did not respond within 3 s; the request stays queued.")
            throw ExitCode(1)
        }
        switch ack.result {
        case .applied:
            Console.output(appliedText(command, request: request, session: session))
        case .ignored:
            Console.output("Ignored: \(sentence(ack.message ?? "nothing to do."))")
        case .rejected:
            throw HolosError.unavailable("Rejected: \(sentence(ack.message ?? "the recorder refused the request."))")
        }
    }

    /// When status.json says the recorder exited, a stop is reported as done (true: the command is finished) and any
    /// other command throws. False when the recorder has not exited.
    private static func reportExited(_ command: ControlCommand, session: URL) throws -> Bool {
        guard let status = try? RecorderChannel.readStatus(session: session), status.phase == .exited else { return false }
        let reason = status.exit?.reason.rawValue ?? "unknown"
        guard command == .stop else { throw HolosError.unavailable("The recorder has already exited (\(reason)).") }
        Console.output("The recorder has already exited (\(reason)).")
        return true
    }

    private static func appliedText(_ command: ControlCommand, request: ControlRequest, session: URL) -> String {
        let name = (try? SessionArchive.readManifest(at: session).name) ?? request.sessionID
        switch command {
        case .stop: return "Stopping \(name). The recorder is saving audio and text."
        case .pause: return "Paused \(name)."
        case .resume: return "Resumed \(name)."
        case .marker:
            // The marker's session time is in the event the recorder journaled for this request.
            let journal = try? SessionArchive.readEvents(at: session)
            let at = journal?.events.last {
                $0.kind == MeetingEventKind.marker && $0.details["requestID"] == request.id
            }?.details["at"].flatMap(Double.init)
            guard let at else { return "Marker added." }
            return "Marker added at \(timestamp(at))."
        }
    }

    /// hh:mm:ss.
    static func timestamp(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, min(seconds, 1e9))) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// A message as the rest of a sentence: first letter lowercased, ending with a period.
    private static func sentence(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first { text = first.lowercased() + text.dropFirst() }
        if !text.hasSuffix(".") { text += "." }
        return text
    }
}
