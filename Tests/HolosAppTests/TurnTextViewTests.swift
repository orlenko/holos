import AppKit
import Foundation
import HolosCore
import HolosMeeting
import Testing
@testable import HolosApp

/// The meeting review's turn text: its cursor rects. Guards the crash on opening a meeting: a row the table laid out
/// outside the visible part asked AppKit for a cursor rect with the null rect (infinite origin), which throws.
@MainActor
struct TurnTextViewTests {
    @Test func aTurnOutsideTheVisiblePartSetsNoCursorRect() {
        let clip = Self.windowContent(NSSize(width: 400, height: 100))
        let view = Self.turn(frame: NSRect(x: 0, y: 500, width: 400, height: 18))
        clip.addSubview(view)
        // Its visible part (clipped by the scroll view only, not by its own bounds) misses its one line.
        #expect(!view.visibleRect.intersects(view.bounds))
        view.resetCursorRects()
    }

    @Test func aTurnPartlyInViewSetsCursorRectsForItsVisibleLines() {
        let clip = Self.windowContent(NSSize(width: 200, height: 20))
        let text = (1...40).map { "word\($0)" }.joined(separator: " ")
        let view = Self.turn(frame: NSRect(x: 0, y: 0, width: 200, height: 200), text: text)
        clip.addSubview(view)
        #expect(view.visibleRect.intersects(view.bounds))
        view.resetCursorRects()
    }

    /// A tall page in a scroll view `size` big, scrolled to its top, in a window that is never shown: what a turn
    /// row sits in (rows below the scrolled part are outside the visible part).
    static func windowContent(_ size: NSSize) -> NSView {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        let page = FlippedPage(frame: NSRect(x: 0, y: 0, width: size.width, height: 2000))
        scroll.documentView = page
        window.contentView = scroll
        scroll.contentView.scroll(to: .zero)
        windows.append(window)
        return page
    }

    static var windows: [NSWindow] = []

    static func turn(frame: NSRect, text: String = "hello there") -> TurnTextView {
        let view = TurnTextView.make()
        view.frame = frame
        let words = text.split(separator: " ").enumerated().map { index, word in
            ReviewWord(ref: WordRef(segmentID: "s", word: index), text: String(word), start: Double(index))
        }
        view.show(text: text, words: words, color: .labelColor)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        return view
    }
}

private final class FlippedPage: NSView {
    override var isFlipped: Bool { true }
}
