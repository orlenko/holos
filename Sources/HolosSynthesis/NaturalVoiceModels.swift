import Darwin
import Foundation
import HolosCore
import os

/// Where the natural voices' models live, whether they are installed, and how they are installed
/// (docs/design.md "Natural voices"). Files only here; the download and the first load (FluidAudio) are passed in by
/// the `voiceislocal` tool, so the app, which does not link FluidAudio, can read the status.
///
/// Layout, under `root` (`<supportRoot>/Models/pocket-tts`, or `$HOLOS_POCKET_MODELS_DIR`):
/// - `<pack>/`: an installed pack, as FluidAudio lays out the base folder it is given
///   (`Models/pocket-tts-coreml/v2.1/<language>/…`), and `installed.json`, written last, once the models loaded and
///   spoke a test sentence on this Mac (the first load compiles them for this Mac's GPU and Neural Engine).
/// - `<pack>.download/`: an unfinished download, kept so the next setup resumes it.
/// - `.<pack>.install.lock`: held by the one process installing the pack.
///
/// FluidAudio lets the base folder be chosen (`PocketTtsManager(directory:)`), so nothing goes to its default
/// `~/.cache/fluidaudio`.
public enum NaturalVoiceModels {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "reading")

    public struct Marker: Codable, Sendable, Equatable {
        public var schemaVersion = 1
        public var pack: NaturalVoicePack
        public var repository: String
        /// The repository's commit the pack was downloaded from; nil in a marker written before it was recorded.
        public var revision: String?
        public var installedAt: Date
        /// Every file of the pack and its size (`NaturalVoicePackFiles.inventory`); nil in a marker written before
        /// they were recorded (such a pack is checked again by the next setup).
        public var files: [String: Int64]? = nil
    }

    public static let repository = "FluidInference/pocket-tts-coreml"
    /// The commit of `repository` the packs are downloaded from (models and voices alike; the voices are its
    /// `constants_bin/*.safetensors`): the one reviewed, never the moving `main`. Update it together with the
    /// FluidAudio pin (Package.swift), after checking the new commit's model card, licences, and file listing. A
    /// pack installed from another commit counts as not installed: the next setup downloads it again at this commit
    /// (FluidAudio clears a pack folder it downloaded at another commit; an interrupted download at this commit
    /// resumes).
    public static let revision = "91748676fe3c8b2eb3007b3125253bcd898202c3"
    static let markerName = "installed.json"

    /// `<supportRoot>/Models/pocket-tts`, or `$HOLOS_POCKET_MODELS_DIR` when it is set and not empty.
    public static var root: URL { root(environment: ProcessInfo.processInfo.environment) }

    public static func root(environment: [String: String]) -> URL {
        if let path = environment["HOLOS_POCKET_MODELS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return HolosPaths.supportRoot(environment: environment)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("pocket-tts", isDirectory: true)
    }

    /// `<root>/<pack>`: the base folder FluidAudio is given for an installed pack.
    public static func directory(root: URL = root, pack: NaturalVoicePack) -> URL {
        root.appendingPathComponent(pack.rawValue, isDirectory: true)
    }

    static func stagingFolder(root: URL, pack: NaturalVoicePack) -> URL {
        root.appendingPathComponent(pack.rawValue + ".download", isDirectory: true)
    }

    static func lockPath(root: URL, pack: NaturalVoicePack) -> String {
        root.appendingPathComponent("." + pack.rawValue + ".install.lock").path
    }

    // MARK: - Status

    /// Files only, no network: `downloading` while a process holds the pack's install lock (it may be replacing the
    /// files), else `installed` once the pack is ready (`isReady`), else `notInstalled`. The readiness is read under
    /// a shared hold of the lock, so no install can start replacing the files while they are looked at.
    public static func status(root: URL = root, pack: NaturalVoicePack) -> DeepModelStatus {
        guard let ready = whileNoInstall(root: root, pack: pack, { isReady(root: root, pack: pack) }) else {
            return .downloading
        }
        return ready ? .installed : .notInstalled
    }

    /// The packs installed now.
    public static func installedPacks(root: URL = root) -> Set<NaturalVoicePack> {
        Set(NaturalVoicePack.allCases.filter { isInstalled(root: root, pack: $0) })
    }

    /// Ready and no install running: what the voice lists and the renderers take for installed.
    static func isInstalled(root: URL, pack: NaturalVoicePack) -> Bool {
        whileNoInstall(root: root, pack: pack, { isReady(root: root, pack: pack) }) ?? false
    }

    /// `body` run while holding the pack's install lock shared (an install, which takes it exclusively, cannot start
    /// meanwhile); nil when an install holds it now. No lock file (no install ever ran): `body` runs as is.
    static func whileNoInstall<T>(root: URL, pack: NaturalVoicePack, _ body: () -> T) -> T? {
        let fd = open(lockPath(root: root, pack: pack), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK ? nil : body() }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// The pack's marker names this pack and the pinned commit, and every file it recorded is there at its size
    /// (`NaturalVoicePackFiles.looksComplete`; not hashed). Whether an install runs is not asked (`setUp` holds the
    /// lock when it asks).
    static func isReady(root: URL, pack: NaturalVoicePack) -> Bool {
        guard let marker = marker(root: root, pack: pack), marker.pack == pack, marker.revision == revision,
              let files = marker.files else { return false }
        return NaturalVoicePackFiles.looksComplete(base: directory(root: root, pack: pack), pack: pack, files: files)
    }

    /// The pack's marker, whatever commit it names.
    static func marker(root: URL, pack: NaturalVoicePack) -> Marker? {
        let url = directory(root: root, pack: pack).appendingPathComponent(markerName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? HolosJSON.decoder().decode(Marker.self, from: data)
    }

    // MARK: - Install

    /// Downloads `pack` into the base folder `base`, fetching only the files missing or damaged there (FluidAudio
    /// resumes a partial file), and returns only once every file of the repository's listing is there, complete
    /// (`NaturalVoicePackFiles.verify`); otherwise it throws and keeps what it got. `progress` 0...1 from any thread.
    public typealias Download = @Sendable (_ pack: NaturalVoicePack, _ base: URL,
                                           _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
    /// Loads the pack from `base` and speaks a short sentence with its default voice: the first load compiles the
    /// models for this Mac, so a reading never waits for it. Downloads nothing (FluidAudio's load only looks for the
    /// pack's folders, which are all there).
    public typealias WarmUp = @Sendable (_ pack: NaturalVoicePack, _ base: URL) async throws -> Void
    /// Tidies an installed pack (removes the voices the app does not offer). Run only once the pack is marked
    /// installed, so a setup cut off before then finds every file the listing has, and checking them needs no
    /// download; run again by a setup that finds the pack installed, so one cut off after the marker is finished.
    public typealias Finish = @Sendable (_ pack: NaturalVoicePack, _ base: URL) -> Void
    /// Whether the pack in `base` holds exactly the files of the pinned commit's listing (sizes and SHA-256s, as the
    /// download checks them). Throws when that cannot be told (offline). A pack in place without a marker (left by an
    /// interrupted setup, maybe an older one) is warmed up where it is only when this says yes.
    public typealias Verify = @Sendable (_ pack: NaturalVoicePack, _ base: URL) async throws -> Bool

    /// What `setUp` says it is doing, for stderr (and the app's Settings row, which shows the last line).
    public static func downloadingLine(_ pack: NaturalVoicePack, resuming: Bool) -> String {
        "\(resuming ? "Resuming" : "Downloading") natural voices (\(pack.languageName), about \(pack.downloadSize))…"
    }

    public static let preparingLine = "Preparing the voices for this Mac (the first time takes a few minutes)…"

    public static func readyMessage(_ pack: NaturalVoicePack) -> String {
        "Ready: natural voices (\(pack.languageName), Kyutai Pocket TTS)."
    }

    public static let creditsLine = "Pocket TTS by Kyutai (CC BY 4.0), converted for Core ML by FluidInference; see "
        + "THIRD_PARTY_NOTICES.md."

    /// `voiceislocal setup --natural-voices` (network). An installed pack is kept unless `force`. Otherwise downloads
    /// into `<root>/<pack>.download` (resuming; `force` starts over), renames it into place, then warms it up from
    /// there (Core ML keys its compiled models by path, so they are compiled where they are used) and writes the
    /// marker last, then tidies it (`finish`). A pack in place without a marker (a warm-up cut off) is warmed up again
    /// without a download; one that does not load there goes back to the staging folder, where the download checks
    /// every file and fetches only what is missing or damaged. Throws `unavailable` while another process installs it.
    public static func setUp(root: URL = root, pack: NaturalVoicePack, force: Bool, download: Download,
                             warmUp: WarmUp, finish: Finish = { _, _ in }, verify: Verify = { _, _ in false },
                             notice: @Sendable (String) -> Void,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = directory(root: root, pack: pack)
        // The lock first, also for a pack that looks installed: a forced reinstall in another process may be about to
        // remove it, and "already installed" is only true once no install runs.
        try ensurePrivateDirectory(root)
        let lock = try InstallLock(path: lockPath(root: root, pack: pack), pack: pack)
        defer { lock.release() }
        // Marked and its files there; a pack marked but with files missing goes on below, where it is checked against
        // the listing and repaired.
        if !force, isReady(root: root, pack: pack) {
            finish(pack, directory)
            notice("The \(pack.languageName) natural voices are already installed.")
            progress(1)
            return
        }
        // A pack installed from another commit: back to staging (below), where the download at this commit replaces it.
        let outdated = marker(root: root, pack: pack).map { $0.revision != revision } ?? false
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(markerName))
        let staging = stagingFolder(root: root, pack: pack)
        if force {
            for folder in [staging, directory] where FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        }
        if outdated, FileManager.default.fileExists(atPath: directory.path) {
            log.notice("Natural voices are from another commit; checking their files against \(revision, privacy: .public)")
            try moveBack(directory, to: staging)
        }
        // A pack moved into place by an earlier setup whose warm-up was cut off: warmed up again where it is, once its
        // files are found to be the pinned commit's. One that is not, or cannot be checked, goes back to staging and
        // through the download, which checks and completes it.
        if FileManager.default.fileExists(atPath: directory.path) {
            let verified: Bool
            do {
                verified = try await verify(pack, directory)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                verified = false
            }
            if !verified {
                log.notice("Natural voices in place are not the pinned commit's; downloading them again")
                try moveBack(directory, to: staging)
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            notice(preparingLine)
            do {
                try await warmUp(pack, directory)
                try Task.checkCancellation()
                try writeMarker(pack, in: directory)
                finish(pack, directory)
                progress(1)
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // Moved back to the staging folder, not deleted: the download checks every file against the
                // repository's listing and fetches only what is missing or damaged.
                log.error("Natural voices did not load in place; checking their files again")
                try moveBack(directory, to: staging)
            }
        }
        notice(downloadingLine(pack, resuming: FileManager.default.fileExists(atPath: staging.path)))
        try ensurePrivateDirectory(staging)
        do {
            try await download(pack, staging) { fraction in progress(0.9 * clamp(fraction)) }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw HolosError.unavailable("Could not download the natural voices (\(error.localizedDescription)). "
                + "Check the network connection, then try again; the download resumes where it stopped.")
        }
        try Task.checkCancellation()
        guard renamex_np(staging.path, directory.path, UInt32(RENAME_EXCL)) == 0 else {
            throw HolosError.io("Cannot move the natural voices into \(directory.path): "
                + String(cString: strerror(errno)) + ".")
        }
        notice(preparingLine)
        progress(0.92)
        do {
            try await warmUp(pack, directory)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw HolosError.unavailable("The natural voices were downloaded but could not be loaded on this Mac "
                + "(\(error.localizedDescription)). Try again, or download them again with --force.")
        }
        try Task.checkCancellation()
        try writeMarker(pack, in: directory)
        finish(pack, directory)
        log.info("Natural voices installed")
        progress(1)
    }

    /// Deletes an installed pack and any unfinished download.
    public static func remove(root: URL = root, pack: NaturalVoicePack) throws {
        try ensurePrivateDirectory(root)
        let lock = try InstallLock(path: lockPath(root: root, pack: pack), pack: pack)
        defer { lock.release() }
        for folder in [directory(root: root, pack: pack), stagingFolder(root: root, pack: pack)]
        where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private static func writeMarker(_ pack: NaturalVoicePack, in directory: URL) throws {
        let marker = Marker(pack: pack, repository: repository, revision: revision, installedAt: Date(),
                            files: NaturalVoicePackFiles.inventory(base: directory, pack: pack))
        try HolosJSON.encoder().encode(marker).write(to: directory.appendingPathComponent(markerName),
                                                     options: .atomic)
    }

    /// A pack in place goes back to the staging folder (where the download checks every file); when an unfinished
    /// download is already there, that one is kept and the pack in place removed.
    private static func moveBack(_ directory: URL, to staging: URL) throws {
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: directory)
        } else {
            guard renamex_np(directory.path, staging.path, UInt32(RENAME_EXCL)) == 0 else {
                throw HolosError.io("Cannot move the natural voices back to \(staging.path): "
                    + String(cString: strerror(errno)) + ".")
            }
        }
    }

    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw HolosError.io("Cannot create the model folder \(url.path).")
        }
    }
}

/// `flock` on a pack's install lock; refuses when another process holds it.
private final class InstallLock {
    private let fd: Int32

    init(path: String, pack: NaturalVoicePack) throws {
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HolosError.io("Cannot open the natural voices' install lock.") }
        // A status check holds a shared lock for an instant; wait that out, but not another install.
        for attempt in 0..<20 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK else { break }
            if attempt < 19 { usleep(50_000) }
        }
        close(fd)
        throw HolosError.unavailable("The \(pack.languageName) natural voices are being installed by another "
            + "process; wait for it to finish, then try again.")
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
