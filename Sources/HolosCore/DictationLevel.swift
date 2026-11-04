import Foundation

/// How loud a stretch of microphone audio is, from 0 (silence) to 1 (loud speech), for the dictation preview's bars.
public enum DictationLevel {
    /// Below this, a room's noise; at the top, speech close to the microphone.
    private static let quietDecibels: Float = -55
    private static let loudDecibels: Float = -15

    public static func level(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        guard power.isFinite, power > 0 else { return 0 }
        let decibels = 10 * log10(power)
        return Double(min(1, max(0, (decibels - quietDecibels) / (loudDecibels - quietDecibels))))
    }
}
