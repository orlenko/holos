import CryptoKit
import Darwin
import FluidAudio
import Foundation
import HolosCore
import os

/// One downloaded model file pinned by size and content (docs/meeting-design.md §4.8).
public struct PinnedFile: Sendable, Equatable {
    /// Relative to `FluidModels.repoFolder(in:)`, e.g. "Embedding.mlmodelc/coremldata.bin".
    public let relativePath: String
    public let size: Int
    /// Lowercase hex SHA-256 of the file.
    public let sha256: String

    public init(relativePath: String, size: Int, sha256: String) {
        self.relativePath = relativePath; self.size = size; self.sha256 = sha256
    }
}

public enum ModelInstallStatus: Sendable, Equatable {
    case notInstalled
    case verified
    /// Files that are missing, the wrong size, or fail SHA-256; ".fluidaudio-revision" when the marker differs.
    case corrupt(files: [String])
}

/// Encodes as its `doctorValue` string; `voiceislocal doctor --json` stores the status itself in `speakerModels`, so the
/// tests check the same encoding the report uses.
extension ModelInstallStatus: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(doctorValue)
    }
}

extension ModelInstallStatus {
    /// The `speakerModels` value of `voiceislocal doctor --json`: "verified", "notInstalled", or "damaged".
    public var doctorValue: String {
        switch self {
        case .verified: "verified"
        case .notInstalled: "notInstalled"
        case .corrupt: "damaged"
        }
    }

    /// Plain text for `voiceislocal doctor`: "verified", "not installed", or "damaged (N files)".
    public var summary: String {
        switch self {
        case .verified: "verified"
        case .notInstalled: "not installed"
        case .corrupt(let files): "damaged (\(files.count) \(files.count == 1 ? "file" : "files"))"
        }
    }
}

/// The digest recorded for a model folder in every run's `ModelDescriptor.sha256`: SHA-256 over the sorted lines
/// `"<relativePath>\t<size>\t<sha256>\n"` of its files, so it depends only on the files, not on the order they were
/// written or listed.
public enum ModelTreeDigest {
    /// The digest of `files` (any order). Lines sort by their UTF-8 bytes.
    public static func digest(of files: [PinnedFile]) -> String {
        let lines = files.map(line).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        return FileDigest.hex(SHA256.hash(data: Data(lines.joined().utf8)))
    }

    /// Every regular file under `folder` (recursively, sorted by path), with its size and SHA-256, except the
    /// top-level `.fluidaudio-revision` marker. Throws on a symbolic link or anything that is not a regular file or
    /// folder, and when a file cannot be read.
    public static func manifest(of folder: URL) throws -> [PinnedFile] {
        var files: [PinnedFile] = []
        try collect(folder, prefix: "", into: &files)
        return files.sorted { Array($0.relativePath.utf8).lexicographicallyPrecedes(Array($1.relativePath.utf8)) }
    }

    static func line(_ file: PinnedFile) -> String {
        "\(file.relativePath)\t\(file.size)\t\(file.sha256.lowercased())\n"
    }

    private static func collect(_ folder: URL, prefix: String, into files: inout [PinnedFile]) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw HolosError.io("Cannot list the model folder \(folder.path).")
        }
        for name in names.sorted() {
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            if prefix.isEmpty, name == FluidModels.revisionMarkerName { continue }
            let url = folder.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw HolosError.io("Cannot read the model file \(relative).") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try collect(url, prefix: relative, into: &files)
            case S_IFREG:
                guard case .present(let size, let sha256) = FileDigest.inspect(url, expectedSize: nil) else {
                    throw HolosError.io("Cannot read the model file \(relative).")
                }
                files.append(PinnedFile(relativePath: relative, size: size, sha256: sha256))
            default:
                throw HolosError.invalidInput("The model folder contains \(relative), which is not a regular file.")
            }
        }
    }
}

/// Speaker-diarization model files: where they live, whether they are intact, and how they are installed.
public enum FluidModels {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "diarization")

    public static let repository = "FluidInference/speaker-diarization-coreml"
    /// The revision FluidAudio 0.17.1 pins for this repo (`Repo.diarizer.revision`).
    public static let revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    /// The folder under `HolosPaths.models`: "speaker-diarization-coreml@df2625ac79a7".
    public static let folderName = "speaker-diarization-coreml@" + String(revision.prefix(12))
    /// FluidAudio's revision marker in the repo folder; its content is the revision and a newline.
    public static let revisionMarkerName = ".fluidaudio-revision"

    /// What `diarize` and `engineInfo` throw when the models are not verified.
    public static let missingModelsMessage =
        "Speaker models are missing or damaged. Install them from Setup, or run voiceislocal setup --speakers."
    /// Printed by `voiceislocal setup --speakers` after a verified install.
    public static let readyMessage = "Ready: speaker models (FluidAudio \(FluidDiarizer.engineVersion), "
        + "speaker-diarization-coreml@\(revision.prefix(12)))."
    /// The credits line `voiceislocal setup --speakers` prints after installing (THIRD_PARTY_NOTICES.md has the full text).
    public static let creditsLine = "Speaker models by Fluid Inference (pyannote, WeSpeaker, BUT Speech@FIT), "
        + "CC BY 4.0; see THIRD_PARTY_NOTICES.md."

    /// <supportRoot>/Models/speaker-diarization-coreml@df2625ac79a7; passed to FluidAudio as `directory:`.
    public static var defaultDirectory: URL {
        defaultDirectory(supportRoot: HolosPaths.supportRoot)
    }

    static func defaultDirectory(supportRoot: URL) -> URL {
        HolosPaths.models(supportRoot: supportRoot).appendingPathComponent(folderName, isDirectory: true)
    }

    /// <directory>/speaker-diarization (FluidAudio's `Repo.diarizer.folderName`), where the files live.
    public static func repoFolder(in directory: URL) -> URL {
        directory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    // MARK: - Status

    /// Files next to `speaker-diarization/` that FluidAudio would read instead of a pinned file, relative to the
    /// directory passed to it. `OfflineDiarizerModels.loadPLDAPsi` (FluidAudio 0.17.1) tries
    /// `<directory>/plda-parameters.json` before `<directory>/speaker-diarization/plda-parameters.json`; its other
    /// fallbacks come after the pinned path, so they are never read while the pinned file exists.
    static let shadowingPaths = ["plda-parameters.json"]

    /// No network. Checks `.fluidaudio-revision` == revision and every pinned file's size and SHA-256.
    ///
    /// `notInstalled` when neither the marker nor any pinned file is present; `verified` when the marker matches,
    /// every pinned file is a regular file of the pinned size and digest reached without following a symbolic link
    /// at any level below `directory`, and nothing FluidAudio would read in place of a pinned file
    /// (`shadowingPaths`) exists; otherwise `corrupt` with the marker (listed first), the files that failed, and
    /// each shadowing file as "../<name>". Other files that are not pinned are ignored.
    public static func status(directory: URL = defaultDirectory,
                              pinned: [PinnedFile] = PinnedModels.files) -> ModelInstallStatus {
        let repo = repoFolder(in: directory)
        var info = stat()
        if lstat(repo.path, &info) != 0 {
            let code = errno
            return code == ENOENT || code == ENOTDIR
                ? .notInstalled : .corrupt(files: [revisionMarkerName] + pinned.map(\.relativePath))
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return .corrupt(files: [revisionMarkerName] + pinned.map(\.relativePath))
        }
        var damaged: [String] = []
        var present = 0
        switch readMarker(in: repo) {
        case .missing: damaged.append(revisionMarkerName)
        case .matches: present += 1
        case .differs: present += 1; damaged.append(revisionMarkerName)
        }
        for file in pinned {
            guard isSafeRelativePath(file.relativePath) else {
                damaged.append(file.relativePath)
                continue
            }
            switch FileDigest.inspect(file.relativePath, in: repo, expectedSize: file.size) {
            case .missing:
                damaged.append(file.relativePath)
            case .unusable:
                present += 1
                damaged.append(file.relativePath)
            case .present(_, let sha256):
                present += 1
                if sha256 != file.sha256.lowercased() { damaged.append(file.relativePath) }
            }
        }
        for name in shadowingPaths {
            var shadow = stat()
            if lstat(directory.appendingPathComponent(name).path, &shadow) == 0 || errno != ENOENT {
                damaged.append("../" + name)
            }
        }
        if present == 0 { return .notInstalled }
        // A build without a pinned list can verify nothing, so it never reports `verified`.
        if pinned.isEmpty { return .corrupt(files: damaged) }
        return damaged.isEmpty ? .verified : .corrupt(files: damaged)
    }

    // MARK: - Install

    /// Network. Downloads into "<directory>.partial-<UUID>", verifies against `pinned`, renames into place.
    /// Never leaves a partially verified directory at `directory`; deletes the partial folder on failure.
    ///
    /// Only this call turns FluidAudio's offline mode off, for the download; it is on again when the call returns.
    /// After verification the models are loaded once (offline) from the partial folder, so an install that
    /// succeeds is one this Mac can run. A damaged install at `directory` is replaced in one rename. `progress`
    /// receives 0...1 from any thread. Throws `unavailable` while another process installs into the same folder.
    public static func install(directory: URL = defaultDirectory, pinned: [PinnedFile] = PinnedModels.files,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        try await install(directory: directory, pinned: pinned, download: fluidDownload, check: fluidLoadCheck,
                          progress: progress)
    }

    /// `voiceislocal setup --speakers`. Models that are verified and load on this Mac (checked offline, as a fresh install
    /// is) are left in place unless `force`; anything else (missing, damaged, verified but failing to load, or
    /// `force`) is installed again through `install`, whose rename replaces the whole folder. `notice` receives one
    /// line for stderr saying which case applies. The same network and lock rules as `install`.
    public static func setUp(directory: URL = defaultDirectory, force: Bool,
                             notice: @Sendable (String) -> Void,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        try await setUp(directory: directory, pinned: PinnedModels.files, force: force, download: fluidDownload,
                        check: fluidLoadCheck, notice: notice, progress: progress)
    }

    static func setUp(directory: URL, pinned: [PinnedFile], force: Bool, download: Download, check: Check,
                      notice: @Sendable (String) -> Void,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let source = "\(repository)@\(revision.prefix(12)), about 21 MB"
        let status = status(directory: directory, pinned: pinned)
        switch status {
        case .verified where !force:
            do {
                try await check(directory)
                notice("Speaker models are already installed, verified, and load on this Mac.")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("Verified speaker models failed to load; reinstalling")
                notice("The installed speaker models could not be loaded (\(error.localizedDescription)); "
                    + "downloading them again (\(source))…")
            }
        case .verified:
            notice("Downloading the speaker models again (\(source))…")
        case .notInstalled:
            notice("Downloading speaker models (\(source))…")
        case .corrupt:
            notice("The installed speaker models are \(status.summary); downloading them again (\(source))…")
        }
        try await install(directory: directory, pinned: pinned, download: download, check: check, progress: progress)
    }

    /// Network. Downloads the pinned revision into a temporary folder next to `directory`, lists every file with
    /// its size and SHA-256 (`ModelTreeDigest.manifest`), and deletes the download: nothing is installed. The
    /// one-time pinning step behind `HOLOS_RECORD_MODEL_MANIFEST=1 voiceislocal setup --speakers`. Throws when the
    /// download's revision marker is not `revision`.
    public static func recordManifest(directory: URL = defaultDirectory,
                                      progress: @escaping @Sendable (Double) -> Void) async throws -> [PinnedFile] {
        try await recordManifest(directory: directory, download: fluidDownload, progress: progress)
    }

    /// Downloads the offline diarizer's files into `directory` (FluidAudio creates `speaker-diarization/` in it).
    typealias Download = @Sendable (_ directory: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws
        -> Void
    /// Loads verified models from `directory` to prove they run on this Mac.
    typealias Check = @Sendable (_ directory: URL) async throws -> Void

    static func install(directory: URL, pinned: [PinnedFile], download: Download, check: Check,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !pinned.isEmpty else {
            throw HolosError.unavailable(
                "This build of Voice is Local has no pinned speaker-model manifest; it cannot install speaker models.")
        }
        try await withStagingFolder(for: directory) { partial in
            try await download(partial) { fraction in progress(0.85 * clamp(fraction)) }
            try Task.checkCancellation()
            switch status(directory: partial, pinned: pinned) {
            case .verified:
                break
            case .notInstalled:
                throw HolosError.incomplete(
                    "The speaker-model download produced no files. Check the network connection, then run "
                        + "voiceislocal setup --speakers again.")
            case .corrupt(let files):
                log.error("Downloaded speaker models failed verification: \(files.count, privacy: .public) files")
                let count = files.count == 1 ? "1 file differs" : "\(files.count) files differ"
                throw HolosError.incomplete(
                    "The downloaded speaker models failed verification: \(count) from the pinned list. Run voiceislocal "
                        + "setup --speakers again; if it keeps failing, the download source has changed.")
            }
            progress(0.9)
            try await check(partial)
            try Task.checkCancellation()
            try publish(partial, to: directory)
            log.info("Speaker models installed")
            progress(1)
        }
    }

    static func recordManifest(directory: URL, download: Download,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> [PinnedFile] {
        try await withStagingFolder(for: directory) { partial in
            try await download(partial) { fraction in progress(0.95 * clamp(fraction)) }
            try Task.checkCancellation()
            let repo = repoFolder(in: partial)
            guard readMarker(in: repo) == .matches else {
                throw HolosError.incomplete("The downloaded speaker models are not revision \(revision).")
            }
            let files = try ModelTreeDigest.manifest(of: repo)
            progress(1)
            return files
        }
    }

    /// Runs `body` with a fresh, empty "<directory>.partial-<UUID>" folder under the install lock for `directory`,
    /// and removes that folder afterwards whatever happens (after a successful publish it holds the replaced
    /// install, if any). Leftover partial folders of an earlier, killed install are removed first.
    private static func withStagingFolder<T>(for directory: URL, _ body: (URL) async throws -> T) async throws -> T {
        let parent = directory.deletingLastPathComponent()
        try ensurePrivateDirectory(parent)
        let lock = try InstallLock(folder: parent, name: directory.lastPathComponent)
        defer { lock.release() }
        removeLeftovers(of: directory)
        let partial = parent.appendingPathComponent(directory.lastPathComponent + ".partial-" + UUID().uuidString,
                                                    isDirectory: true)
        guard mkdir(partial.path, 0o700) == 0 else {
            throw HolosError.io("Cannot create a folder for the speaker-model download in \(parent.path).")
        }
        defer { removeTree(partial) }
        return try await body(partial)
    }

    // MARK: - FluidAudio seams

    static let fluidDownload: Download = { directory, progress in
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        do {
            // The same file set `OfflineDiarizerModels.load` downloads (repo .diarizer, variant "offline"), without
            // loading anything before it is verified. FluidAudio reports the download as 0...0.5 of a load.
            try await ModelHub.download(.diarizer, to: directory, variant: "offline") { update in
                progress(update.fractionCompleted * 2)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            log.error("Speaker-model download failed: \(String(describing: type(of: error)), privacy: .public)")
            throw HolosError.unavailable(
                "Could not download the speaker models (\(error.localizedDescription)). Check the network "
                    + "connection, then run voiceislocal setup --speakers again.")
        }
    }

    static let fluidLoadCheck: Check = { directory in
        ModelHub.offlineMode = true
        do {
            _ = try await OfflineDiarizerModels.load(from: directory, configuration: nil)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw HolosError.unavailable(
                "The speaker models are verified but could not be loaded on this Mac "
                    + "(\(error.localizedDescription)).")
        }
    }

    // MARK: - Files

    enum MarkerState: Equatable { case missing, matches, differs }

    static func readMarker(in repo: URL) -> MarkerState {
        let (fd, code) = FileDigest.openBeneath(repo, relativePath: revisionMarkerName)
        guard fd >= 0 else { return code == ENOENT ? .missing : .differs }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 1024 else { return .differs }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == buffer.count, let text = String(bytes: buffer, encoding: .utf8) else { return .differs }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == revision ? .matches : .differs
    }

    /// Relative, with no empty, ".", or ".." component.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw HolosError.io("Cannot create the model folder \(url.path).")
        }
    }

    /// Moves the verified `partial` folder to `directory` in one rename: exclusive when nothing is there, else an
    /// atomic swap with the old install (which then sits at `partial` and is removed by the caller).
    private static func publish(_ partial: URL, to directory: URL) throws {
        var moved = renamex_np(partial.path, directory.path, UInt32(RENAME_EXCL)) == 0
        if !moved, errno == EEXIST {
            moved = renamex_np(partial.path, directory.path, UInt32(RENAME_SWAP)) == 0
        }
        guard moved else {
            let reason = String(cString: strerror(errno))
            throw HolosError.io("Cannot move the speaker models into \(directory.path): \(reason).")
        }
        let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        if parent >= 0 {
            _ = fsync(parent)
            close(parent)
        }
    }

    private static func removeLeftovers(of directory: URL) {
        let parent = directory.deletingLastPathComponent()
        let prefix = directory.lastPathComponent + ".partial-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            removeTree(parent.appendingPathComponent(name))
        }
    }

    private static func removeTree(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            log.error("Could not remove a speaker-model staging folder")
        }
    }
}

/// `flock` on "<folder>/.<name>.install.lock" for one install or manifest download into `<folder>/<name>`.
private final class InstallLock {
    private let fd: Int32

    init(folder: URL, name: String) throws {
        let path = folder.appendingPathComponent("." + name + ".install.lock").path
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HolosError.io("Cannot open the speaker-model install lock in \(folder.path).") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw HolosError.unavailable(
                    "Speaker models are being installed by another voiceislocal setup --speakers; wait for it to finish, "
                        + "then try again.")
            }
            throw HolosError.io("Cannot lock the speaker-model install lock in \(folder.path).")
        }
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Size and SHA-256 of one file, read through a descriptor that refuses symbolic links.
enum FileDigest {
    enum Inspection: Equatable {
        /// Nothing at the path.
        case missing
        /// A link, a non-regular file, the wrong size, or unreadable.
        case unusable
        case present(size: Int, sha256: String)
    }

    /// `expectedSize` short-cuts the hash when the size already differs. Only the last path component is opened
    /// without following links; `inspect(_:in:expectedSize:)` refuses links at every level.
    static func inspect(_ url: URL, expectedSize: Int?) -> Inspection {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .unusable }
        return inspect(descriptor: fd, expectedSize: expectedSize)
    }

    /// The file at `relativePath` under `root`, reached through `openBeneath`: a symbolic link at any level makes
    /// it `unusable`.
    static func inspect(_ relativePath: String, in root: URL, expectedSize: Int?) -> Inspection {
        let (fd, code) = openBeneath(root, relativePath: relativePath)
        guard fd >= 0 else { return code == ENOENT ? .missing : .unusable }
        return inspect(descriptor: fd, expectedSize: expectedSize)
    }

    /// Opens `relativePath` (no empty, ".", or ".." component) under the folder `root` one component at a time with
    /// `openat` and `O_NOFOLLOW`, so neither `root` nor any folder or file below it may be a symbolic link. Returns
    /// the read-only descriptor of the last component and 0, or -1 and the errno of the first failure (ENOENT when
    /// a component is missing; ELOOP or ENOTDIR for a link).
    static func openBeneath(_ root: URL, relativePath: String) -> (fd: Int32, code: Int32) {
        var current = open(root.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { return (-1, errno) }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != ".." else {
                close(current)
                return (-1, EINVAL)
            }
            let isLast = index == components.count - 1
            let flags = isLast
                ? O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                : O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            let next = openat(current, component, flags)
            let code = errno
            close(current)
            guard next >= 0 else { return (-1, code) }
            current = next
        }
        return (current, 0)
    }

    /// Takes ownership of `fd` and closes it.
    private static func inspect(descriptor fd: Int32, expectedSize: Int?) -> Inspection {
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unusable }
        let size = Int(info.st_size)
        if let expectedSize, size != expectedSize { return .unusable }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return .unusable
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            total += count
        }
        guard total == size else { return .unusable }
        return .present(size: size, sha256: hex(hasher.finalize()))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
