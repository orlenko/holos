import AVFAudio
import Darwin
import Foundation
import HolosCore

@MainActor public enum SpeechPlayback {
    /// Waits for the per-user playback lock. A message that has become stale returns false.
    public static func play(file: URL, maxWait: TimeInterval = 10) async throws -> Bool {
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else {
            throw HolosError.invalidInput("Speech playback file does not exist: \(file.path)")
        }
        guard let descriptor = try await acquirePlaybackLock(maxWait: maxWait) else { return false }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        let player = try AVAudioPlayer(contentsOf: file)
        guard player.play() else { throw HolosError.unavailable("Audio playback could not start.") }
        defer { player.stop() }
        repeat {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        } while player.isPlaying
        return true
    }

    /// Returns a held lock descriptor, or nil when waiting would make the message stale.
    /// The caller must unlock and close a returned descriptor.
    static func acquirePlaybackLock(maxWait: TimeInterval) async throws -> Int32? {
        guard maxWait.isFinite, maxWait >= 0 else {
            throw HolosError.invalidInput("Playback maxWait must be finite and nonnegative.")
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-playback-\(getuid()).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw HolosError.io("Could not open playback lock: \(String(cString: strerror(errno)))")
        }
        var handedOff = false
        var locked = false
        defer {
            if !handedOff {
                if locked { _ = flock(descriptor, LOCK_UN) }
                close(descriptor)
            }
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw HolosError.io("Playback lock is not a regular file owned by this user.")
        }

        let started = ProcessInfo.processInfo.systemUptime
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EAGAIN {
                throw HolosError.io("Could not acquire playback lock: \(String(cString: strerror(errno)))")
            }
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime - started >= maxWait { return nil }
            try await Task.sleep(for: .milliseconds(50))
        }
        locked = true
        try Task.checkCancellation()
        // maxWait == 0 means "only if immediately available", not "always stale".
        if maxWait > 0 && ProcessInfo.processInfo.systemUptime - started >= maxWait { return nil }
        handedOff = true
        return descriptor
    }
}
