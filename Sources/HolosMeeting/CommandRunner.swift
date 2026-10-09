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
/// actor and removed, however it ended. A command is stopped with SIGTERM: by the caller with the pid `start` returns,
/// or by cancelling the task awaiting `run`.
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
    /// `errors` (nil discards it), and returns its pid. When it exits, its stdout (at most `maxOutputBytes`) is given
    /// to `decode` and its stderr read, both off the main actor, the files are removed, and `completion` gets the
    /// result on the main actor. When it cannot start, the files are removed and the error is thrown. The child is
    /// reaped before its files are read, so between the exit and `completion` a signal to the pid reaches no child of
    /// this app.
    @discardableResult
    public func start<Outcome: Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int,
        decode: @escaping @Sendable (Data) throws -> Outcome,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws -> Int32 {
        try start(arguments, output: output, errors: errors, maxOutputBytes: maxOutputBytes, decode: decode,
                  exited: {}, completion: completion)
    }

    /// `start` for a command that prints `Outcome` as JSON (`HolosJSON`).
    @discardableResult
    public func start<Outcome: Decodable & Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int, as type: Outcome.Type,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws -> Int32 {
        try start(arguments, output: output, errors: errors, maxOutputBytes: maxOutputBytes,
                  decode: Self.json(type), completion: completion)
    }

    /// Runs `voiceislocal <arguments>` like `start` and returns its result. Cancelling the task sends the command
    /// SIGTERM (at once if it has not started yet); the result is still returned once it exits, with its files removed.
    public func run<Outcome: Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int,
        decode: @escaping @Sendable (Data) throws -> Outcome) async throws -> CommandResult<Outcome> {
        try Task.checkCancellation()
        let child = RunningChild()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let pid = try start(arguments, output: output, errors: errors, maxOutputBytes: maxOutputBytes,
                                        decode: decode, exited: { child.exited() }) {
                        continuation.resume(returning: $0)
                    }
                    child.started(pid)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            child.terminate()
        }
    }

    /// `run` for a command that prints `Outcome` as JSON (`HolosJSON`).
    public func run<Outcome: Decodable & Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int,
        as type: Outcome.Type) async throws -> CommandResult<Outcome> {
        try await run(arguments, output: output, errors: errors, maxOutputBytes: maxOutputBytes,
                      decode: Self.json(type))
    }

    /// `exited` is called on the main actor as soon as the child is reaped, before its output is read.
    private func start<Outcome: Sendable>(
        _ arguments: [String], output: String, errors: String?, maxOutputBytes: Int,
        decode: @escaping @Sendable (Data) throws -> Outcome, exited: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws -> Int32 {
        let outputFile = TemporaryArtifact(kind: output, in: folder)
        let errorFile = errors.map { TemporaryArtifact(kind: $0, in: folder) }
        do {
            return try launcher.run(arguments, standardOutput: outputFile.url,
                                    standardError: errorFile?.url) { code in
                exited()
                Task {
                    let result = await Task.detached {
                        Self.collect(code: code, output: outputFile, errors: errorFile,
                                     maxOutputBytes: maxOutputBytes, decode: decode)
                    }.value
                    completion(result)
                }
            }
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

    private static func json<Outcome: Decodable & Sendable>(_ type: Outcome.Type) -> @Sendable (Data) throws -> Outcome {
        { try HolosJSON.decoder().decode(Outcome.self, from: $0) }
    }
}

/// The pid of a command `CommandRunner.run` started, for its cancellation: SIGTERM once it has started and only until
/// it is reaped, so a pid the system reuses afterwards is never signalled.
private final class RunningChild: Sendable {
    private struct State {
        var pid: Int32 = 0
        var cancelled = false
        var exited = false
    }

    private let state = Mutex(State())

    func started(_ pid: Int32) {
        state.withLock { state in
            state.pid = pid
            if state.cancelled, !state.exited { kill(pid, SIGTERM) }
        }
    }

    func exited() {
        state.withLock { $0.exited = true }
    }

    func terminate() {
        state.withLock { state in
            state.cancelled = true
            if state.pid > 0, !state.exited { kill(state.pid, SIGTERM) }
        }
    }
}
