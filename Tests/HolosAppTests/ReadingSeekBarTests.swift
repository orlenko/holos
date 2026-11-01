import AppKit
import Testing
@testable import HolosApp

@MainActor @Suite struct ReadingSeekBarTests {
    private func bar() -> (ReadingSeekBar, () -> [Double]) {
        let bar = ReadingSeekBar()
        final class Seeks { var values: [Double] = [] }
        let seeks = Seeks()
        bar.onSeek = { seeks.values.append($0) }
        bar.show(current: 100, duration: 1_000)
        return (bar, { seeks.values })
    }

    /// The player's ticks never move the knob under the person's finger, and only the release seeks.
    @Test func aDragSeeksOnlyOnReleaseAndIgnoresThePlayer() {
        let (bar, seeks) = bar()
        bar.moved(to: 500, during: .leftMouseDown)
        bar.moved(to: 600, during: .leftMouseDragged)
        #expect(bar.shownElapsed == "10:00")
        bar.show(current: 101, duration: 1_000)
        #expect(bar.shownValue == 600)
        #expect(bar.shownElapsed == "10:00")
        #expect(seeks().isEmpty)
        bar.moved(to: 610, during: .leftMouseUp)
        #expect(seeks() == [610])
        bar.show(current: 611, duration: 1_000)
        #expect(bar.shownValue == 611)
    }

    @Test func arrowKeysMoveByAStepWithinTheLength() {
        let (bar, seeks) = bar()
        bar.pressArrowForTesting(forward: true)
        #expect(seeks() == [100 + ReadingSeekBar.keyStep])
        bar.show(current: 5, duration: 1_000)
        bar.pressArrowForTesting(forward: false)
        #expect(seeks().last == 0)
        bar.show(current: 999, duration: 1_000)
        bar.pressArrowForTesting(forward: true)
        #expect(seeks().last == 1_000)
    }

    @Test func aReadingOfUnknownLengthCannotSeek() throws {
        let (bar, seeks) = bar()
        bar.show(current: 0, duration: 0)
        bar.pressArrowForTesting(forward: true)
        #expect(seeks().isEmpty)
    }

    @Test func voiceOverIsToldATime() throws {
        let bar = ReadingSeekBar()
        bar.setSubject("A Guide")
        bar.show(current: 130, duration: 3_600)
        let slider = try #require(Self.allViews(bar).compactMap { $0 as? NSSlider }.first)
        #expect(slider.accessibilityLabel() == "Playback position — A Guide")
        #expect(slider.accessibilityValue() as? String == "2:10 of 1:00:00")
    }

    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
