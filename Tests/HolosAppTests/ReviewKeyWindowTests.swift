import AppKit
import Testing
@testable import HolosApp

/// `ReviewKeyWindow` while a join's word field is closed (its speaker change saving).
@MainActor
struct ReviewKeyWindowTests {
    /// Every key without ⌘, and ⌘ with an arrow (⌘← and ⌘→ move playback), is refused; other ⌘ shortcuts (⌘Z undoing
    /// the join, ⌘W) go on.
    @Test func refusesTypingAndPlaybackKeysOnly() {
        let cases: [(NSEvent.ModifierFlags, NSEvent.SpecialKey?, Bool)] = [
            ([], nil, true), ([.shift], nil, true), ([.option], nil, true), ([.control], nil, true),
            ([], .leftArrow, true), ([], .downArrow, true), ([], .delete, true), ([], .carriageReturn, true),
            ([.command], .leftArrow, true), ([.command], .rightArrow, true),
            ([.command], nil, false), ([.command, .shift], nil, false), ([.command, .option], nil, false),
        ]
        for (flags, special, refused) in cases {
            #expect(ReviewKeyWindow.refusedWhileFieldClosed(flags: flags, special: special) == refused,
                    "\(flags) \(String(describing: special))")
        }
    }

    /// Only the newest join's field is closed: an older join ending reopens nothing for it.
    @Test func onlyTheJoinThatClosedTheFieldReopensIt() {
        let window = ReviewKeyWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let first = window.closeFieldForJoin()
        let second = window.closeFieldForJoin()
        window.reopenFieldAfterJoin(first)
        #expect(window.fieldClosedForJoin == second)
        window.reopenFieldAfterJoin(second)
        #expect(window.fieldClosedForJoin == nil)
        window.reopenFieldAfterJoin(nil)
        #expect(window.fieldClosedForJoin == nil)
    }
}
