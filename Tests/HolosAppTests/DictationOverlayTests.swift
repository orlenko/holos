import AppKit
import Testing
@testable import HolosApp

@MainActor
struct DictationOverlayTests {
    private static let oneLine = "Thanks for sending"
    private static let twoLines = String(repeating: "Thanks for sending the floor plan. ", count: 3)
    private static let many = String(repeating: "Thanks for sending the floor plan. ", count: 30)

    @Test func thePanelHugsItsWords() {
        let overlay = DictationOverlay()
        let one = overlay.fill(title: "Listening", hint: nil, text: Self.oneLine, attention: false)
        let two = overlay.fill(title: "Listening", hint: nil, text: Self.twoLines, attention: false)
        let capped = overlay.fill(title: "Listening", hint: nil, text: Self.many, attention: false)
        #expect(one < 90, "A title and one line leave no empty space.")
        #expect(two > one)
        #expect(capped > two)
        #expect(capped == overlay.fill(title: "Listening", hint: nil, text: Self.many + Self.many, attention: false),
                "The words stop at the preview's lines.")
    }

    @Test func noWordsStillLeaveRoomForOneLine() {
        let overlay = DictationOverlay()
        let empty = overlay.fill(title: "Finishing locally…", hint: nil, text: "", attention: false)
        let one = overlay.fill(title: "Finishing locally…", hint: nil, text: Self.oneLine, attention: false)
        #expect(empty == one)
    }

    @Test func aFailureHasItsOwnLookAndListeningDoesNot() {
        let overlay = DictationOverlay()
        _ = overlay.fill(title: "Listening", hint: "Esc cancels", text: Self.oneLine, attention: false)
        #expect(!overlay.isMarkedForAttention)
        #expect(overlay.shownHint == "Esc cancels")
        _ = overlay.fill(title: "Couldn't write into this field. Use Copy Result.", hint: nil, text: Self.oneLine,
                         attention: true)
        #expect(overlay.isMarkedForAttention)
        #expect(overlay.shownHint == nil)
    }

    @Test func aLongFailureWrapsInsteadOfLosingItsEnd() {
        let overlay = DictationOverlay()
        let short = overlay.fill(title: "Couldn't write.", hint: nil, text: Self.oneLine, attention: true)
        let long = overlay.fill(
            title: "Couldn't write into this field. Some text may already be in the field — check it before using "
                + "Copy Result, which has the words that were not inserted.",
            hint: nil, text: Self.oneLine, attention: true)
        #expect(long > short)
    }

    /// The header's spacing leaves the title narrower than the width it was first measured at; at every length its
    /// frame still holds all of its lines.
    @Test func aWrappedTitleKeepsItsLastLine() {
        let overlay = DictationOverlay()
        let words = ("Couldn't write into this field. Some text may already be in the field — check it before using "
            + "Copy Result, which has the words that were not inserted, and then try again").split(separator: " ")
        for attention in [true, false] {
            for count in 1...words.count {
                let title = words.prefix(count).joined(separator: " ")
                _ = overlay.fill(title: title, hint: nil, text: Self.oneLine, attention: attention)
                #expect(overlay.titleIsWhole, "\(attention ? "With" : "Without") the sign: \(title)")
            }
        }
    }

    @Test func hidingClearsTheSignAndTheHint() {
        let overlay = DictationOverlay()
        _ = overlay.fill(title: "Couldn't write.", hint: "Esc cancels", text: Self.oneLine, attention: true)
        overlay.hide()
        #expect(!overlay.isMarkedForAttention)
        #expect(overlay.shownHint == nil)
    }
}
