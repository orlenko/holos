import Darwin
import Foundation
import HolosCore
import os
import WhisperKit

/// The deep-transcription model files (docs/meeting-design.md §4.16): where they live, whether they are installed, and
/// how they are installed.
///
/// Layout, under `DeepTranscriptionModel.root` (`<supportRoot>/Models/whisperkit`):
/// - `<model>/`: the installed model, as WhisperKit's Hugging Face download lays it out
///   (`models/argmaxinc/whisperkit-coreml/<model>/*.mlmodelc`), the tokenizer it needs
///   (`models/openai/whisper-large-v3/tokenizer.json`), and `installed.json`, written last, once the model loaded.
/// - `<model>.download/`: an unfinished download, kept so the next `setup --whisper` resumes it (Hugging Face's
///   downloader continues partial files).
/// - `.<model>.install.lock`: held by the one process downloading or checking the model.
public enum WhisperModels {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "whisper")

    /// The marker of a finished install.
    public struct Marker: Codable, Sendable, Equatable {
        public var schemaVersion = 1
        public var model: String
        public var repository: String
        public var installedAt: Date
    }

    static let markerName = "installed.json"
    /// The tokenizer WhisperKit loads for large-v3 models (`ModelUtilities.tokenizerNameForVariant`).
    static let tokenizerRepository = "openai/whisper-large-v3"
    /// The Core ML models WhisperKit loads from the model folder.
    static let requiredModels = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    /// What `voiceislocal setup --whisper` prints when the model is ready.
    public static let readyMessage = "Ready: deep transcription model (\(DeepTranscriptionModel.displayName), "
        + "WhisperKit)."
    /// What a deep transcription without the model says.
    public static let missingModelMessage = DeepTranscriptionModel.missingModelMessage
    /// The credits line `setup --whisper` prints (THIRD_PARTY_NOTICES.md has the full text).
    public static let creditsLine = "Whisper by OpenAI (MIT), converted for Core ML by Argmax (WhisperKit, MIT); "
        + "see THIRD_PARTY_NOTICES.md."

    // MARK: - Paths

    /// `<directory>/models/argmaxinc/whisperkit-coreml/<model>`: the folder WhisperKit loads.
    public static func modelFolder(in directory: URL, model: String = DeepTranscriptionModel.name) -> URL {
        hubFolder(in: directory, repository: DeepTranscriptionModel.repository)
            .appendingPathComponent(model, isDirectory: true)
    }

    /// `<directory>/models/openai/whisper-large-v3`: where WhisperKit finds the tokenizer when `tokenizerFolder` is
    /// `directory`.
    static func tokenizerFolder(in directory: URL) -> URL {
        hubFolder(in: directory, repository: tokenizerRepository)
    }

    private static func hubFolder(in directory: URL, repository: String) -> URL {
        repository.split(separator: "/").reduce(directory.appendingPathComponent("models", isDirectory: true)) {
            $0.appendingPathComponent(String($1), isDirectory: true)
        }
    }

    static func stagingFolder(root: URL, model: String) -> URL {
        root.appendingPathComponent(model + ".download", isDirectory: true)
    }

    static func lockPath(root: URL, model: String) -> String {
        root.appendingPathComponent("." + model + ".install.lock").path
    }

    // MARK: - Status

    /// Files only, no network: `installed` when the model folder has its marker for `model`, its Core ML models,
    /// and the tokenizer; `downloading` when another process holds the install lock; else `notInstalled`.
    public static func status(root: URL = DeepTranscriptionModel.root,
                              model: String = DeepTranscriptionModel.name) -> DeepModelStatus {
        if isInstalled(DeepTranscriptionModel.directory(root: root, model: model), model: model) { return .installed }
        return lockIsHeld(root: root, model: model) ? .downloading : .notInstalled
    }

    /// Whether `directory` holds a finished install of `model`.
    static func isInstalled(_ directory: URL, model: String) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(markerName)),
              let marker = try? HolosJSON.decoder().decode(Marker.self, from: data), marker.model == model else {
            return false
        }
        let folder = modelFolder(in: directory, model: model)
        var isFolder: ObjCBool = false
        for name in requiredModels {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path,
                                                 isDirectory: &isFolder), isFolder.boolValue else { return false }
        }
        return FileManager.default.fileExists(
            atPath: tokenizerFolder(in: directory).appendingPathComponent("tokenizer.json").path)
    }

    /// Whether some process holds the install lock now (a shared lock cannot be had).
    static func lockIsHeld(root: URL, model: String) -> Bool {
        let fd = open(lockPath(root: root, model: model), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }

    // MARK: - Install

    /// Downloads `model` (and its tokenizer) into `staging`, resuming what an earlier download left there; returns
    /// the model folder WhisperKit loads.
    typealias Download = @Sendable (_ staging: URL, _ model: String,
                                    _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// Loads the model from `modelFolder` with the tokenizer under `tokenizerBase` (fetching the tokenizer into it
    /// when it is not there yet), proving it runs on this Mac.
    typealias Check = @Sendable (_ modelFolder: URL, _ tokenizerBase: URL) async throws -> Void

    /// `voiceislocal setup --whisper` (network). An installed model is kept unless `force`. Otherwise downloads into
    /// `<root>/<model>.download` (resuming an unfinished download; `force` deletes it first and starts over), loads it once offline-ready (fetching the tokenizer
    /// with it), writes the marker, and renames the folder into place, replacing an older install in one rename.
    /// `notice` gets one line for stderr saying which case applies; `progress` 0...1 from any thread. Throws
    /// `unavailable` while another process installs it.
    public static func setUp(root: URL = DeepTranscriptionModel.root, model: String = DeepTranscriptionModel.name,
                             force: Bool, notice: @Sendable (String) -> Void,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        try await setUp(root: root, model: model, force: force, download: hubDownload, check: loadCheck,
                        notice: notice, progress: progress)
    }

    static func setUp(root: URL, model: String, force: Bool, download: Download, check: Check,
                      notice: @Sendable (String) -> Void,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = DeepTranscriptionModel.directory(root: root, model: model)
        if !force, isInstalled(directory, model: model) {
            notice("The deep transcription model is already installed.")
            progress(1)
            return
        }
        try ensurePrivateDirectory(root)
        let lock = try InstallLock(path: lockPath(root: root, model: model))
        defer { lock.release() }
        // Checked again under the lock: another setup may have finished meanwhile.
        if !force, isInstalled(directory, model: model) {
            notice("The deep transcription model is already installed.")
            progress(1)
            return
        }
        let staging = stagingFolder(root: root, model: model)
        // Forced: downloaded again from scratch, so a damaged file an earlier download left is not kept as done.
        if force, FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        let resuming = FileManager.default.fileExists(atPath: staging.path)
        notice(resuming
            ? "Resuming the deep transcription model download (\(DeepTranscriptionModel.displayName), about 1.6 GB)…"
            : "Downloading the deep transcription model (\(DeepTranscriptionModel.displayName), about 1.6 GB)…")
        try ensurePrivateDirectory(staging)
        // A marker left in the staging folder by an install that failed after writing it is not trusted.
        try? FileManager.default.removeItem(at: staging.appendingPathComponent(markerName))
        let folder = try await download(staging, model) { fraction in progress(0.9 * clamp(fraction)) }
        try Task.checkCancellation()
        guard folder.standardizedFileURL.path == modelFolder(in: staging, model: model).standardizedFileURL.path else {
            throw HolosError.incomplete("The deep transcription model download landed in an unexpected folder. Run "
                + "voiceislocal setup --whisper again.")
        }
        notice("Checking that the model loads on this Mac (the first load can take a few minutes)…")
        try await check(folder, staging)
        try Task.checkCancellation()
        guard FileManager.default.fileExists(
            atPath: tokenizerFolder(in: staging).appendingPathComponent("tokenizer.json").path) else {
            throw HolosError.incomplete("The model's tokenizer was not downloaded. Check the network connection, then "
                + "run voiceislocal setup --whisper again.")
        }
        progress(0.97)
        let marker = Marker(model: model, repository: DeepTranscriptionModel.repository, installedAt: Date())
        try HolosJSON.encoder().encode(marker).write(to: staging.appendingPathComponent(markerName), options: .atomic)
        try publish(staging, to: directory)
        log.info("Deep transcription model installed")
        progress(1)
    }

    /// Deletes the installed model and any unfinished download (Settings' Remove).
    public static func remove(root: URL = DeepTranscriptionModel.root,
                              model: String = DeepTranscriptionModel.name) throws {
        try ensurePrivateDirectory(root)
        let lock = try InstallLock(path: lockPath(root: root, model: model))
        defer { lock.release() }
        for folder in [DeepTranscriptionModel.directory(root: root, model: model), stagingFolder(root: root, model: model)]
        where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - WhisperKit seams

    static let hubDownload: Download = { staging, model, progress in
        do {
            return try await WhisperKit.download(variant: model, downloadBase: staging,
                                                 from: DeepTranscriptionModel.repository) { update in
                progress(update.fractionCompleted)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            log.error("Deep transcription model download failed: \(String(describing: type(of: error)), privacy: .public)")
            throw HolosError.unavailable("Could not download the deep transcription model "
                + "(\(error.localizedDescription)). Check the network connection, then run voiceislocal setup "
                + "--whisper again; the download resumes where it stopped.")
        }
    }

    static let loadCheck: Check = { folder, tokenizerBase in
        do {
            let kit = try await WhisperKit(WhisperKitConfig(
                model: DeepTranscriptionModel.name, modelFolder: folder.path, tokenizerFolder: tokenizerBase,
                verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
            guard kit.tokenizer != nil else { throw HolosError.unavailable("the tokenizer did not load") }
            await kit.unloadModels()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw HolosError.unavailable("The deep transcription model was downloaded but could not be loaded on this "
                + "Mac (\(error.localizedDescription)). Run voiceislocal setup --whisper --force to download it again.")
        }
    }

    // MARK: - Files

    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw HolosError.io("Cannot create the model folder \(url.path).")
        }
    }

    /// Moves `staging` to `directory` in one rename: exclusive when nothing is there, else swapped with the old
    /// install, which is then deleted.
    private static func publish(_ staging: URL, to directory: URL) throws {
        var moved = renamex_np(staging.path, directory.path, UInt32(RENAME_EXCL)) == 0
        var swapped = false
        if !moved, errno == EEXIST {
            moved = renamex_np(staging.path, directory.path, UInt32(RENAME_SWAP)) == 0
            swapped = moved
        }
        guard moved else {
            throw HolosError.io("Cannot move the deep transcription model into \(directory.path): "
                + String(cString: strerror(errno)) + ".")
        }
        if swapped { try? FileManager.default.removeItem(at: staging) }
    }
}

/// `flock` on the install lock of one model; refuses when another process holds it.
private final class InstallLock {
    private let fd: Int32

    init(path: String) throws {
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HolosError.io("Cannot open the deep transcription model's install lock.") }
        // A status check holds a shared lock for an instant; wait that out, but not another install.
        for attempt in 0..<20 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK else { break }
            if attempt < 19 { usleep(50_000) }
        }
        close(fd)
        throw HolosError.unavailable("The deep transcription model is being installed by another process; wait for "
            + "it to finish, then try again.")
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
