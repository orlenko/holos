import Darwin
import Foundation
import HolosCore
import HolosStorage
import Synchronization

/// A private temporary file for a command's output: `holos-command-<UUID>.<kind>` in the temporary folder, created 0600
/// by the spawn. `remove()` removes it (only a regular file, never through a link; again is a no-op). Files an app that
/// quit or crashed left behind are swept by their `prefix` (`ProcessSpawner.removeStaleFiles`).
public struct TemporaryArtifact: Sendable, Equatable {
    /// The start of every such file's name.
    public static let prefix = "holos-command-"

    public let url: URL

    public init(kind: String, in folder: URL = FileManager.default.temporaryDirectory) {
        url = folder.appendingPathComponent("\(Self.prefix)\(UUID().uuidString).\(kind)", isDirectory: false)
    }

    public func remove() { ProcessSpawner.removeRegularFile(url) }
}

/// How a command run by `CommandRunner` ended.
public struct CommandResult<Outcome: Sendable>: Sendable {
    /// The exit code (128 + the signal for a killed child).
    public var code: Int32
    /// Its stdout, decoded; nil when it printed nothing, more than allowed, or something that does not decode.
    public var outcome: Outcome?
    /// Its stderr, up to `CommandRunner.maxErrorBytes`; "" when discarded, missing, or longer.
    public var errors: String
    /// The last non-empty line of its stderr (`ProcessSpawner.lastLine`), nil when none.
    public var lastErrorLine: String?

    public init(code: Int32, outcome: Outcome?, errors: String = "", lastErrorLine: String? = nil) {
        self.code = code; self.outcome = outcome; self.errors = errors; self.lastErrorLine = lastErrorLine
    }
}

/// Runs the app's `voiceislocal` commands (deep-transcribe, summarize, echo-analyze, recover, diarize, delete, rename,
/// doctor) through `MaintenanceLauncher`, so each is detached in its own session and a quit app never cuts one short.
/// Its stdout (and stderr, when kept) go to `TemporaryArtifact`s; once it exits they are read and decoded off the main
/// actor and removed, however it ended. A command is stopped with SIGTERM: by the caller through the `CommandHandle`
/// `start` returns, or by cancelling the task awaiting `run`.
@MainActor public struct CommandRunner {
    /// How much of a command's stderr is read.
    public nonisolated static let maxErrorBytes = 1 << 16

    public let launcher: MaintenanceLauncher
    /// Where the output files are made.
    public let folder: URL

    public init(launcher: MaintenanceLauncher, folder: URL = FileManager.default.temporaryDirectory) {
        self.launcher = launcher
        self.folder = folder
    }

    /// Starts `voiceislocal <arguments>` with stdout in a temporary file named `output` and stderr in one named
    /// `errors` (nil discards it), and returns its handle. When it exits, its stdout (at most `maxOutputBytes`) is
    /// given to `decode` and its stderr read, both off the main actor, the files are removed, and `completion` gets
    /// the result on the main actor. When it cannot start, the files are removed and the error is thrown. The handle
    /// stops signalling as soon as the child is reaped, before its files are read: a pid the system reuses while they
    /// are is never signalled.
    @discardableResult
    public func start<Outcome: Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int,
        decode: @escaping @Sendable (Data) throws -> Outcome,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws -> CommandHandle {
        let handle = CommandHandle()
        try launch(arguments, output: output, errors: errors, maxOutputBytes: maxOutputBytes, decode: decode,
                   handle: handle, completion: completion)
        return handle
    }

    /// `start` for a command that prints `Outcome` as JSON (`HolosJSON`).
    @discardableResult
    public func start<Outcome: Decodable & Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int, as type: Outcome.Type,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws -> CommandHandle {
        try start(arguments, output: output, errors: errors, maxOutputBytes: maxOutputBytes,
                  decode: Self.json(type), completion: completion)
    }

    /// Runs `voiceislocal <arguments>` like `start` and returns its result. Cancelling the task sends the command
    /// SIGTERM (at once if it has not started yet); the result is still returned once it exits, with its files removed.
    public func run<Outcome: Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int,
        decode: @escaping @Sendable (Data) throws -> Outcome) async throws -> CommandResult<Outcome> {
        try Task.checkCancellation()
        let handle = CommandHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try launch(arguments, output: output, errors: errors, maxOutputBytes: maxOutputBytes,
                               decode: decode, handle: handle) {
                        continuation.resume(returning: $0)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// `run` for a command that prints `Outcome` as JSON (`HolosJSON`).
    public func run<Outcome: Decodable & Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int,
        as type: Outcome.Type) async throws -> CommandResult<Outcome> {
        try await run(arguments, output: output, errors: errors, maxOutputBytes: maxOutputBytes,
                      decode: Self.json(type))
    }

    /// Spawns the command for `handle`, which is told its pid at once and that it was reaped before its output is read.
    private func launch<Outcome: Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int,
        decode: @escaping @Sendable (Data) throws -> Outcome, handle: CommandHandle,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws {
        let outputFile = TemporaryArtifact(kind: output, in: folder)
        let errorFile = errors.map { TemporaryArtifact(kind: $0, in: folder) }
        do {
            // The exit is reported on the main queue, never before `started` below.
            let pid = try launcher.run(arguments, standardOutput: outputFile.url,
                                       standardError: errorFile?.url) { code in
                handle.reaped()
                Task {
                    let result = await Task.detached {
                        Self.collect(code: code, output: outputFile, errors: errorFile,
                                     maxOutputBytes: maxOutputBytes, decode: decode)
                    }.value
                    completion(result)
                }
            }
            handle.started(pid)
        } catch {
            outputFile.remove()
            errorFile?.remove()
            throw error
        }
    }

    /// Reads and decodes the files of a command that exited with `code`, then removes them.
    nonisolated static func collect<Outcome: Sendable>(
        code: Int32, output: TemporaryArtifact, errors: TemporaryArtifact?, maxOutputBytes: Int,
        decode: @Sendable (Data) throws -> Outcome) -> CommandResult<Outcome> {
        defer {
            output.remove()
            errors?.remove()
        }
        let errorText = errors.flatMap { file in
            (try? AtomicFile.readIfPresent(file.url, maxBytes: maxErrorBytes)).flatMap {
                $0.map { String(decoding: $0, as: UTF8.self) }
            }
        } ?? ""
        let lastErrorLine = errors.flatMap { ProcessSpawner.lastLine(of: $0.url) }
        let outcome = (try? AtomicFile.readIfPresent(output.url, maxBytes: maxOutputBytes)).flatMap {
            $0.flatMap { try? decode($0) }
        }
        return CommandResult(code: code, outcome: outcome, errors: errorText, lastErrorLine: lastErrorLine)
    }

    private static func json<Outcome: Decodable & Sendable>(
        _ type: Outcome.Type) -> @Sendable (Data) throws -> Outcome {
        { try HolosJSON.decoder().decode(Outcome.self, from: $0) }
    }
}

/// A command `CommandRunner` started, to stop it with SIGTERM: only once it has started and until it is reaped, so a
/// pid the system reuses after the exit, while the command's output is still being read, is never signalled.
public final class CommandHandle: Sendable {
    private struct State {
        var pid: Int32 = 0
        var cancelled = false
        var reaped = false
    }

    private let state = Mutex(State())

    init() {}

    /// The command's pid; 0 before it started.
    public var pid: Int32 { state.withLock { $0.pid } }

    /// Whether the command has ended and been reaped (its output may still be being read).
    public var hasExited: Bool { state.withLock { $0.reaped } }

    /// Sends the command SIGTERM, or, before it has started, makes it get SIGTERM as it starts. Returns whether a
    /// signal was sent now; false once it has been reaped.
    @discardableResult
    public func terminate() -> Bool {
        state.withLock { state in
            state.cancelled = true
            guard state.pid > 0, !state.reaped else { return false }
            return kill(state.pid, SIGTERM) == 0
        }
    }

    func started(_ pid: Int32) {
        state.withLock { state in
            state.pid = pid
            if state.cancelled, !state.reaped { kill(pid, SIGTERM) }
        }
    }

    func reaped() {
        state.withLock { $0.reaped = true }
    }
}

