import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

// A natural voice's Speed: the factor from the rate, and the time-stretch.

@Suite struct NaturalSpeechSpeedTests {
    @Test func theSlidersSpeedsMapToThemselves() {
        #expect(NaturalSpeechSpeed.factor(rate: nil) == 1)
        for speed in stride(from: 0.8, through: 1.4, by: 0.1) {
            let factor = NaturalSpeechSpeed.factor(rate: ReadingSpeed.rate(for: speed))
            #expect(abs(factor - ReadingSpeed.clamped(speed)) < 0.001, "\(speed)")
        }
        #expect(NaturalSpeechSpeed.factor(rate: 0) == 0.5)
        #expect(NaturalSpeechSpeed.factor(rate: 1) == 2)
        #expect(NaturalSpeechSpeed.factor(rate: .nan) == 1)
    }

    @Test func timeStretchChangesTheLength() throws {
        let second = (0..<24_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 24_000)) * 0.3 }
        #expect(try TimeStretch.apply(second, sampleRate: 24_000, rate: 1) == second)
        let faster = try TimeStretch.apply(second, sampleRate: 24_000, rate: 2)
        #expect(abs(faster.count - 12_000) < 200)
        #expect(faster.contains { abs($0) > 0.1 })
        let slower = try TimeStretch.apply(second, sampleRate: 24_000, rate: 0.8)
        #expect(abs(slower.count - 30_000) < 200)
    }
}
