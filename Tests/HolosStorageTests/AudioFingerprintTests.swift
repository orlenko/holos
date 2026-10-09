import Foundation
import HolosCore
import HolosStorage
import Testing

// `SessionManifest.audioFingerprint` is stored in evaluation run records and in echo/mask.json, so its value for a
// given chunk list must never change: this pins it.

private func fingerprintManifest() -> SessionManifest {
    SessionManifest(id: "S", name: "Fingerprint", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                    source: .microphoneAndSystem, locale: "en-CA", backend: .speech, status: "complete", chunks: [
                        AudioChunkRecord(id: "mic-2", track: "mic", relativePath: "audio/mic-000002.caf", start: 12.5,
                                         end: 25, sampleRate: 48_000, channels: 1, frameCount: 600_000,
                                         sha256: String(repeating: "b", count: 64)),
                        AudioChunkRecord(id: "system-1", track: "system", relativePath: "audio/system-000001.caf",
                                         start: 0, end: 12.5, sampleRate: 16_000, channels: 2, frameCount: 200_000,
                                         sha256: nil),
                        AudioChunkRecord(id: "mic-1", track: "mic", relativePath: "audio/mic-000001.caf", start: 0,
                                         end: 12.5, sampleRate: 48_000, channels: 1, frameCount: 600_000,
                                         sha256: String(repeating: "a", count: 64)),
                    ])
}

@Test func audioFingerprintsKeepTheirStoredValues() {
    let manifest = fingerprintManifest()
    // The track's chunks in (start, path) order, one line each; another track's chunks are left out.
    let mic = manifest.audioFingerprint(track: "mic")
    #expect(mic == "b7496063809cc249b52ecde70536219fd19b5f66c386d63f7062b21001e11c3c")
    // A chunk without a content hash is written "-".
    let system = manifest.audioFingerprint(track: "system")
    #expect(system == "0f4c14e6d61cf70b70a477ca7e4efd6022ab3bb9e69cbda447d11d34fc8ac11d")
    // A track without chunks: the SHA-256 of nothing.
    let other = manifest.audioFingerprint(track: "other")
    #expect(other == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}
