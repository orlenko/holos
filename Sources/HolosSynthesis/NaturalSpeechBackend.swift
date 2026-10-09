import Foundation

/// Makes speech with a natural (neural) voice: 24 kHz mono samples for one paragraph. The `voiceislocal` tool's
/// implementation is FluidAudio's Pocket TTS (`HolosPocket`); tests pass a fake.
public protocol NaturalSpeechBackend: Sendable {
    /// The paragraph `text` spoken by `voice`, generated with `seed` (the same seed gives the same take).
    func synthesize(_ text: String, voice: NaturalVoice, seed: UInt64) async throws -> [Float]
}

/// The natural voices' audio: 24 kHz mono, and the seed every paragraph's first take uses (the same text and seed give
/// the same take, so a resumed reading sounds as it would have).
public enum NaturalSpeechFormat {
    public static let sampleRate = 24_000.0
    public static let seed: UInt64 = 0x5645_4C4F_4341_4C31
}
