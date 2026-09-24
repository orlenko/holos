import Darwin
import Foundation
import HolosAudio
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Extracts voice embeddings for exactly the turns it is asked about (docs/meeting-design.md §4.10, "Voice sample
/// extraction on demand"). `VoiceProfileService` asks only about the qualifying turns of a speaker the user confirmed
/// as a person with voice learning on, and is the only code that turns the result into a stored sample.
public protocol VoiceSampleExtractor: Sendable {
    /// Renders the track, extracts embedding windows, and returns one embedding per
    /// requested turn that has enough clean speech. Every other window is discarded in memory.
    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding]
}

/// What the hidden `holos speakers embed --json` prints on stdout (a pipe): the embeddings of the requested turns.
/// Biometric data; it is never written to a file.
public struct TurnEmbeddingsOutput: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var turnEmbeddings: [TurnEmbedding]

    public init(schemaVersion: Int = 1, turnEmbeddings: [TurnEmbedding]) {
        self.schemaVersion = schemaVersion; self.turnEmbeddings = turnEmbeddings
    }
}

/// The in-process extractor (§4.10): renders the track to a private temporary folder outside the session with
/// `TrackRenderer`, runs a fresh pass of `diarizer` over it (the CLI passes `FluidDiarizer` configured like the
/// session's run, whose windows are FluidAudio's chunk embeddings), maps the times back to the session, and selects
/// vectors by speaker slot first, then by time (`VoiceEnrollment.turnEmbeddings`). Every other vector is dropped in
/// memory and the render is deleted. It writes nothing in the session.
///
/// Refuses (`unavailable`) a session that is still recording, whose audio was deleted, when there is not enough disk
/// space for the render (as post-processing checks it), or when the diarizer's embedding model is not the one the
/// session's head run was labelled with (the vectors would not be comparable).
public struct DiarizerVoiceSampleExtractor: VoiceSampleExtractor {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "profiles")
    static let modelChanged = "The speaker models changed since this meeting was labelled, so its voices can't be "
        + "learned. Label its speakers again first."
    static let noDiskSpace = "Not enough disk space to learn this voice. Free some space, then try again."

    public let diarizer: any SpeakerDiarizer
    public let temporaryDirectory: URL
    let freeSpace: any FreeSpaceProvider

    public init(diarizer: any SpeakerDiarizer, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                freeSpace: any FreeSpaceProvider = VolumeFreeSpace()) {
        self.diarizer = diarizer; self.temporaryDirectory = temporaryDirectory; self.freeSpace = freeSpace
    }

    public func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        guard !turns.isEmpty else { return [] }
        guard track == "mic" || track == "system" else {
            throw HolosError.invalidInput("The track must be mic or system.")
        }
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording. Stop it before learning voices.")
        }
        if SessionFiles.audioDeleted(session: session) {
            throw HolosError.unavailable(VoiceProfileService.audioDeletedNote)
        }
        let manifest = try SessionArchive.readManifest(at: session)
        var hint: SpeakerCountHint?
        if let head = try SessionSpeakerStore.readHead(session: session) {
            let run = try SessionSpeakerStore.readRun(id: head.runID, session: session)
            if let expected = run.engine?.embeddingModel {
                let info = try await diarizer.engineInfo()
                guard info.embeddingModel == expected else { throw HolosError.unavailable(Self.modelChanged) }
            }
            hint = Self.speakerHint(run: run, session: session, manifest: manifest)
        }
        let seconds = TrackRenderer.renderedSeconds(manifest: manifest, track: track)
        if let free = try? freeSpace.availableBytes(at: temporaryDirectory),
           !SpeakerAnalysis.renderAllowed(freeBytes: free, renderSeconds: seconds) {
            throw HolosError.unavailable(Self.noDiskSpace)
        }
        try Task.checkCancellation()
        let folder = temporaryDirectory.appendingPathComponent("\(Self.renderPrefix)\(UUID().uuidString)",
                                                              isDirectory: true)
        defer { Self.remove(folder) }
        let rendered = try TrackRenderer.render(session: session, manifest: manifest, track: track,
                                                to: folder.appendingPathComponent("\(track)-16k.caf"))
        try Task.checkCancellation()
        let output = try await diarizer.diarize(DiarizationRequest(audio: rendered.url, track: track, speakers: hint),
                                                progress: { _ in })
        let mapped = RenderTimeMap.map(output, map: rendered.timeMap)
        let embeddings = VoiceEnrollment.turnEmbeddings(turns: turns, segments: mapped.segments,
                                                        windows: mapped.windows)
        Self.log.info("Session \(manifest.id, privacy: .public): extracted \(embeddings.count, privacy: .public) of \(turns.count, privacy: .public) requested turn embeddings on \(track, privacy: .public)")
        return embeddings
    }

    /// The speaker-count hint post-processing gave the run's pass, so the fresh pass groups speakers the same way:
    /// from meeting.json's expected speakers and the number of tracks the run diarized. A `--speakers` hint given to
    /// `holos session diarize` is not recorded in the run, so it is not repeated here. Nil when meeting.json cannot
    /// be read.
    static func speakerHint(run: DiarizationRun, session: URL, manifest: SessionManifest) -> SpeakerCountHint? {
        guard let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest) else { return nil }
        let diarized = run.tracks.filter { $0.policy == .diarized }.count
        return SpeakerAnalysis.speakerHint(options: PostProcessingOptions(), meeting: meeting, diarizedTracks: diarized)
    }

    /// The name a render folder gets: `holos-voice-<UUID>` in the temporary directory.
    static let renderPrefix = "holos-voice-"

    /// How long a render folder must have been untouched before the sweep takes it: longer than any enrollment
    /// runs, so a render of another Holos that is using it right now is never removed.
    static let staleRenderAge: TimeInterval = 6 * 3600

    /// At most this many folders per sweep, so a temporary directory full of them cannot hold up a launch.
    static let staleRenderLimit = 64

    /// Deletes the temporary render folder (created 0700 by the render). A failure is logged and left to
    /// `removeStaleRenders`, which takes it on a later launch: a render holds a decoded copy of the meeting's audio,
    /// so it must not be left behind silently.
    private static func remove(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            log.error("Cannot delete a temporary voice render; it is removed on a later launch: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Removes render folders an interrupted enrollment left in `temporaryDirectory`: a kill or a power loss skips
    /// the `defer` that deletes one, and the rendered copy of the meeting's audio would then outlive Delete Audio,
    /// Delete Meeting and every voice forget. Only folders named `holos-voice-<token>` that nothing has touched for
    /// `staleRenderAge` are taken, at most `staleRenderLimit` of them, so a render another Holos is using right now
    /// is left alone. Failures are logged, never thrown: this is launch housekeeping, not part of any request.
    /// Returns how many folders were removed.
    @discardableResult
    public static func removeStaleRenders(in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                                          now: Date = Date()) -> Int {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        } catch {
            log.error("Cannot look for leftover voice renders: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return 0
        }
        var removed = 0
        for name in names.sorted() where isRenderName(name) {
            guard removed < staleRenderLimit else { break }
            let folder = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            // Not through a symbolic link: a link named like a render is left where it is.
            guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let touched = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(touched) > staleRenderAge else { continue }
            do {
                try FileManager.default.removeItem(at: folder)
                removed += 1
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                log.error("Cannot delete a leftover voice render: \(error.localizedDescription, privacy: .private)")
            }
        }
        if removed > 0 {
            log.notice("Deleted \(removed, privacy: .public) leftover voice renders")
        }
        return removed
    }

    /// `holos-voice-<token>`, the name `turnEmbeddings` gives its render folder.
    static func isRenderName(_ name: String) -> Bool {
        guard name.hasPrefix(renderPrefix) else { return false }
        return SessionArchive.validToken(String(name.dropFirst(renderPrefix.count)))
    }
}

/// The app's extractor (§4.10): the app never links FluidAudio, so it runs the bundled hidden
/// `holos speakers embed <session> --track <t> --turns <id,id,…> --json` and reads the embeddings from its stdout
/// through a pipe (never a file). The child's stderr goes to a private temporary file that is read on failure and
/// deleted. Cancelling the task stops the child (SIGTERM).
public struct SubprocessVoiceSampleExtractor: VoiceSampleExtractor {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "profiles")
    /// The most output accepted from the child.
    static let maxOutputBytes = 64 << 20

    public let executable: URL
    public let temporaryDirectory: URL

    /// `executable` defaults to the bundled `holos` (Holos.app/Contents/MacOS/holos).
    public init(executable: URL = ChildProcessLauncher.bundledExecutable,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.executable = executable; self.temporaryDirectory = temporaryDirectory
    }

    /// ["speakers", "embed", <session path>, "--track", track, "--turns", "T1,T2,…", "--json"]
    public static func arguments(session: URL, track: String, turnIDs: [String]) -> [String] {
        ["speakers", "embed", session.path, "--track", track, "--turns", turnIDs.joined(separator: ","), "--json"]
    }

    public func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        guard !turns.isEmpty else { return [] }
        guard turns.allSatisfy({ !$0.id.isEmpty && !$0.id.contains(",") }) else {
            throw HolosError.invalidInput("A turn ID cannot contain a comma.")
        }
        let arguments = Self.arguments(session: session, track: track, turnIDs: turns.map(\.id))
        let (code, output, errorText) = try await run(arguments)
        guard code == 0 else {
            Self.log.error("holos speakers embed exited \(code, privacy: .public)")
            throw HolosError.unavailable(errorText ?? "The holos tool could not learn this voice (exit \(code)).")
        }
        let decoded: TurnEmbeddingsOutput
        do {
            decoded = try HolosJSON.decoder().decode(TurnEmbeddingsOutput.self, from: output)
        } catch {
            throw HolosError.io("The holos tool returned voice data Holos cannot read.")
        }
        guard decoded.schemaVersion == 1 else {
            throw HolosError.unavailable("The holos tool is newer than this Holos; rebuild Holos.")
        }
        let requested = Set(turns.map(\.id))
        return decoded.turnEmbeddings.filter { requested.contains($0.turnID) }
    }

    /// Spawns the child with stdout on a pipe, reads it to the end off the cooperative pool, and waits for the exit.
    private func run(_ arguments: [String]) async throws -> (code: Int32, output: Data, error: String?) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw HolosError.io("Cannot start the holos tool: \(String(cString: strerror(errno))).")
        }
        let readEnd = fds[0]
        let writeEnd = fds[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        let errorLog = temporaryDirectory.appendingPathComponent("holos-embed-\(UUID().uuidString).log")
        let pid: pid_t
        do {
            pid = try ProcessSpawner.spawn(executable: executable, arguments: arguments,
                                           standardOutput: .descriptor(writeEnd),
                                           standardError: .file(errorLog, append: false))
        } catch {
            Darwin.close(readEnd)
            Darwin.close(writeEnd)
            ProcessSpawner.removeRegularFile(errorLog)
            throw error
        }
        Darwin.close(writeEnd)
        defer { ProcessSpawner.removeRegularFile(errorLog) }
        let limit = Self.maxOutputBytes
        let result: (Int32, Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let output = Self.readAll(readEnd, limit: limit)
                    Darwin.close(readEnd)
                    if output == nil { kill(pid, SIGTERM) }
                    let code = Self.wait(pid)
                    if let output {
                        continuation.resume(returning: (code, output))
                    } else {
                        continuation.resume(throwing: HolosError.io("The holos tool returned more voice data than Holos accepts."))
                    }
                }
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
        try Task.checkCancellation()
        return (result.0, result.1, result.0 == 0 ? nil : ProcessSpawner.lastLine(of: errorLog))
    }

    /// Everything readable from `fd` until end of file; nil when it exceeds `limit`.
    private static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return data
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit { return nil }
        }
    }

    /// Blocks until `pid` exits and returns its exit code (128 + the signal when killed; -1 when it cannot be waited
    /// for).
    private static func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return ProcessSpawner.exitCode(status) }
            if result < 0, errno == EINTR { continue }
            return -1
        }
    }
}
