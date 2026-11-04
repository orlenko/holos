import AppKit
import HolosCore
import Testing
@testable import HolosApp

@MainActor
struct DictationLevelViewTests {
    private static func frame(amplitude: Float) throws -> PCMFrame {
        try PCMFrame(samples: [Float](repeating: amplitude, count: 4800), sampleRate: 48_000, channels: 1, startTime: 0)
    }

    @Test func levelGrowsWithLoudnessAndStaysInRange() {
        #expect(DictationLevel.level(of: []) == 0)
        #expect(DictationLevel.level(of: [0, 0, 0]) == 0)
        #expect(DictationLevel.level(of: [Float](repeating: 0.0001, count: 100)) == 0, "Room noise moves nothing.")
        let quiet = DictationLevel.level(of: [Float](repeating: 0.01, count: 100))
        let speech = DictationLevel.level(of: [Float](repeating: 0.05, count: 100))
        #expect(quiet > 0 && speech > quiet && speech < 1)
        #expect(DictationLevel.level(of: [Float](repeating: 1, count: 100)) == 1)
        #expect(DictationLevel.level(of: [.nan, .infinity]) == 0)
    }

    @Test func theNewestLevelEntersOnTheRight() {
        let view = DictationLevelView()
        view.add(0.5)
        view.add(1)
        #expect(view.levels == [0, 0, 0, 0.5, 1])
        view.reset()
        #expect(view.levels.allSatisfy { $0 == 0 })
    }

    @Test func barsMoveOnlyWhileListening() throws {
        let overlay = DictationOverlay()
        _ = overlay.fill(title: "Preparing", hint: nil, text: "", attention: false)
        #expect(overlay.levelView.isHidden)
        overlay.hear(try Self.frame(amplitude: 0.1))
        #expect(overlay.levelView.levels.allSatisfy { $0 == 0 })
        _ = overlay.fill(title: "Listening", hint: nil, text: "", attention: false, listening: true)
        #expect(!overlay.levelView.isHidden)
        overlay.hear(try Self.frame(amplitude: 0.1))
        #expect(overlay.levelView.levels.last ?? 0 > 0)
        _ = overlay.fill(title: "Listening", hint: nil, text: "Some words", attention: false, listening: true)
        #expect(overlay.levelView.levels.last ?? 0 > 0, "New words do not restart the bars.")
    }

    @Test func theBarsDoNotChangeThePanelsHeight() {
        let overlay = DictationOverlay()
        let quiet = overlay.fill(title: "Listening", hint: "Esc cancels", text: "Some words", attention: false)
        let listening = overlay.fill(title: "Listening", hint: "Esc cancels", text: "Some words", attention: false,
                                     listening: true)
        #expect(listening == quiet)
    }

    @Test func eachDictationStartsFromSilence() throws {
        let overlay = DictationOverlay()
        _ = overlay.fill(title: "Listening", hint: nil, text: "", attention: false, listening: true)
        overlay.hear(try Self.frame(amplitude: 0.1))
        overlay.hide()
        #expect(overlay.levelView.isHidden)
        #expect(overlay.levelView.levels.allSatisfy { $0 == 0 })
        _ = overlay.fill(title: "Couldn't write.", hint: nil, text: "", attention: true)
        #expect(overlay.levelView.isHidden, "A failure is not listening.")
    }
}
