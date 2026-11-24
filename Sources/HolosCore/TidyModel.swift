import Darwin
import Foundation

/// The Qwen model Tidy Up runs on (docs/design.md "Tidy Up"): one GGUF file, pinned by its Hugging Face commit, size
/// and SHA-256, and where it is installed. The app reads its status here without linking llama.cpp.
///
/// Layout, under `root` (`<supportRoot>/Models/tidy`):
/// - `<fileName>`: the installed model, moved here only once its size and SHA-256 matched.
/// - `<fileName>.download`: an unfinished download, kept so the next install resumes it.
/// - `<fileName>.copy`: a file being copied in from elsewhere on the Mac (`setup --tidy-model --from`) and checked.
/// - `.install.lock`: held by the one process installing or removing the model.
public enum TidyModel {
    /// The name people read.
    public static let displayName = "Qwen3.5 9B"
    /// The Hugging Face repository, and the commit of it the file comes from.
    public static let repository = "unsloth/Qwen3.5-9B-GGUF"
    public static let revision = "3885219b6810b007914f3a7950a8d1b469d598a5"
    public static let fileName = "Qwen3.5-9B-Q4_K_M.gguf"
    public static let size: Int64 = 5_680_522_464
    public static let sha256 = "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8"
    /// Where the file is downloaded from.
    public static var downloadURL: URL {
        Variant.qwen.downloadURL
    }

    /// What a Qwen tidy-up without the model says.
    public static let missingModelMessage = "Qwen is not installed. Install it in Voice is Local's Tidy Up (⌘6), or run voiceislocal "
        + "setup --tidy-model (about 5.7 GB)."
    /// What `setup --tidy-model` prints when the model is ready.
    public static let readyMessage = "Ready: Tidy Up model (\(displayName))."
    /// The credits line (THIRD_PARTY_NOTICES.md has the full text).
    public static let creditsLine = "Qwen3.5 by Alibaba Cloud (Apache 2.0), quantized by Unsloth; run with llama.cpp (MIT); "
        + "see THIRD_PARTY_NOTICES.md."

    /// `<supportRoot>/Models/tidy`, or `$HOLOS_TIDY_MODELS_DIR` when it is set and not empty.
    public static var root: URL { root(environment: ProcessInfo.processInfo.environment) }

    static func root(environment: [String: String]) -> URL {
        if let path = environment["HOLOS_TIDY_MODELS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return HolosPaths.supportRoot(environment: environment)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("tidy", isDirectory: true)
    }

    /// `<root>/<fileName>`: the installed model.
    public static func file(root: URL = root) -> URL { root.appendingPathComponent(fileName) }
    /// `<root>/<fileName>.download`: an unfinished download.
    public static func partialFile(root: URL = root) -> URL { root.appendingPathComponent(fileName + ".download") }
    /// `<root>/<fileName>.copy`: a copy of a file from elsewhere on the Mac, until it is checked.
    public static func copyFile(root: URL = root) -> URL { root.appendingPathComponent(fileName + ".copy") }
    public static func lockFile(root: URL) -> URL { root.appendingPathComponent(".install.lock") }

    /// `.installed` when the file is in place with the pinned size (its SHA-256 was checked before it was moved
    /// there), `.downloading` while a process holds the install lock, else `.notInstalled`. From the files alone.
    public static func status(root: URL = root) -> DeepModelStatus {
        Variant.qwen.status(in: root)
    }

    /// Whether some process holds the install lock now (a shared lock cannot be had).
    static func lockIsHeld(root: URL) -> Bool {
        let fd = open(lockFile(root: root).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
}
