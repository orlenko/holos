import Foundation
import HolosCore
import HolosSynthesis

/// One natural voice pack's download as Settings › Reading shows it (docs/design.md "Natural voices"): the app runs
/// `voiceislocal setup --natural-voices` and follows its last stderr line; Cancel sends it SIGTERM (what it downloaded
/// is kept, so the next download resumes). Pure: the app feeds it what happens.
struct NaturalVoiceDownload: Equatable {
    enum Phase: Equatable {
        case notInstalled
        /// This app's download runs; the line it last said.
        case downloading(String)
        /// Cancel was pressed; the download has not ended yet.
        case cancelling
        case installed
        /// Another process (`voiceislocal setup` in Terminal) is installing the pack.
        case otherProcess
        /// The last download failed, with why.
        case failed(String)
    }

    let pack: NaturalVoicePack
    private(set) var phase: Phase = .notInstalled

    init(pack: NaturalVoicePack, phase: Phase = .notInstalled) {
        self.pack = pack
        self.phase = phase
    }

    static let startingLine = "Starting the download…"

    /// This app's download runs (or is being cancelled).
    var isRunning: Bool {
        switch phase {
        case .downloading, .cancelling: true
        default: false
        }
    }

    /// The row's button was pressed: a download starts (true: launch it) unless the pack is installed or being
    /// installed elsewhere; a running one is cancelled (see `cancel`).
    mutating func start() -> Bool {
        switch phase {
        case .notInstalled, .failed:
            phase = .downloading(Self.startingLine)
            return true
        default:
            return false
        }
    }

    /// Cancel: true when the running download should be stopped now.
    mutating func cancel() -> Bool {
        guard case .downloading = phase else { return false }
        phase = .cancelling
        return true
    }

    /// The download's last line, shown while it runs (progress, "Preparing…").
    mutating func said(_ line: String) {
        guard case .downloading = phase else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Natural voices") || trimmed.hasPrefix("Downloading")
            || trimmed.hasPrefix("Resuming") || trimmed.hasPrefix("Preparing") else { return }
        phase = .downloading(trimmed)
    }

    /// The download ended with `code`; `lastLine` is what it said last; `installed` whether the pack's files say it is
    /// installed now.
    mutating func ended(code: Int32, lastLine: String?, installed: Bool) {
        if installed {
            phase = .installed
        } else if phase == .cancelling {
            phase = .notInstalled
        } else {
            let reason = lastLine?.replacingOccurrences(of: "Error: ", with: "")
            phase = .failed(code == 0 ? "The voices were not installed." : reason ?? "The download failed (code \(code)).")
        }
    }

    /// What the pack's files say now (checked when Settings shows, and every so often): taken unless this app's own
    /// download runs. A failure stays shown until the files say otherwise.
    mutating func checked(_ status: DeepModelStatus) {
        guard !isRunning else { return }
        switch status {
        case .installed: phase = .installed
        case .downloading: phase = .otherProcess
        case .notInstalled:
            if case .failed = phase { return }
            phase = .notInstalled
        }
    }

    /// The Settings row: whether it is done, what it says, and its button (nil: none; `enabled` false: shown dimmed).
    var row: (done: Bool, problem: Bool, detail: String, button: String?, enabled: Bool) {
        let size = "\(pack.downloadSize)"
        let voice = NaturalVoiceCatalog.defaultVoice(for: pack).displayName
        switch phase {
        case .notInstalled:
            return (false, false, "Not installed — Kyutai Pocket TTS voices that run on this Mac (\(voice) and "
                + "others), about \(size). Apple's voices read until then.", "Download (\(size))…", true)
        case .downloading(let line):
            return (false, false, line, "Cancel", true)
        case .cancelling:
            return (false, false, "Cancelling…", "Cancel", false)
        case .installed:
            return (true, false, "Installed — new \(pack.languageName) readings use \(voice) unless you choose "
                + "another voice", nil, true)
        case .otherProcess:
            return (false, false, "Being installed by another process…", "Download (\(size))…", false)
        case .failed(let reason):
            return (false, true, "Download failed: \(reason)", "Try Again (\(size))…", true)
        }
    }
}
