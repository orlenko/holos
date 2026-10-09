import CryptoKit
import Foundation

extension SessionManifest {
    /// SHA-256 of a track's chunk list (IDs, times, frame counts, sample rates, and each chunk's content hash as the
    /// manifest records it). Evaluation runs and `echo/mask.json` store it to tell whether a track's audio changed,
    /// so its value for a given chunk list never changes.
    public func audioFingerprint(track: String) -> String {
        let lines = chunks.filter { $0.track == track }
            .sorted { ($0.start, $0.relativePath) < ($1.start, $1.relativePath) }
            .map {
                "\($0.id) \($0.relativePath) \($0.start) \($0.end) \($0.frameCount) \($0.sampleRate) \($0.channels) "
                    + ($0.sha256 ?? "-")
            }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
