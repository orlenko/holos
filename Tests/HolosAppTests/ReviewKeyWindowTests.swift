import AppKit
import Testing
@testable import HolosApp

/// `TypingHold` and `HeldTyping`: the typing the review window holds for a word's field about to open again after a
/// join, and what it makes of the field's text.
@MainActor
struct ReviewKeyWindowTests {
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    /// Plain typing is held; a text field's ⌘ editing shortcuts are refused, except ⌘Z with nothing held (the review's
    /// undo); every other key goes on.
    @Test func holdsPlainTypingAndRefusesTheFieldsShortcuts() {
        typealias Hold = TypingHold<String>
        let cases: [(NSEvent.ModifierFlags, String, Bool, Hold.Taking)] = [
            ([], "k", false, .hold([.insert("k")])), ([], " ", false, .hold([.insert(" ")])),
            ([.shift], "A", false, .hold([.insert("A")])), ([.option], "é", false, .hold([.insert("é")])),
            ([], "\u{7F}", false, .hold([.deleteBackward])), ([.function], "\u{F728}", true, .hold([.deleteForward])),
            ([.numericPad, .function], "\u{F702}", false, .hold([.left])),
            ([], "\r", false, .pass), ([], "\t", false, .pass), ([], "\u{1B}", false, .pass),
            ([.control], "\u{01}", false, .pass),
            ([.command], "z", false, .pass), ([.command], "z", true, .refuse),
            ([.command, .shift], "z", false, .refuse),
            ([.command], "a", false, .refuse), ([.command], "x", true, .refuse), ([.command], "c", false, .refuse),
            ([.command], "v", false, .refuse), ([.command], "w", true, .pass), ([.command], "e", false, .pass),
            ([.command, .option], "z", true, .pass), ([.command, .numericPad, .function], "\u{F702}", true, .pass),
        ]
        for (flags, characters, anythingHeld, taking) in cases {
            #expect(Hold.taking(flags: flags, characters: characters, key: characters.lowercased(),
                                anythingHeld: anythingHeld) == taking, "\(flags) \(characters)")
        }
    }

    /// Held edits applied to a field's text and caret: characters at the caret, Delete and forward Delete, arrows.
    @Test func heldEditsApplyAtTheCaret() {
        #expect(HeldTyping.edits("ko") == [.insert("ko")])
        #expect(HeldTyping.edits("a\u{7F}b") == [.insert("a"), .deleteBackward, .insert("b")])
        #expect(HeldTyping.apply([.insert("ko")], to: "cedar", caret: 0) == ("kocedar", 2))
        #expect(HeldTyping.apply([.insert("ko")], to: "cedar", caret: 5) == ("cedarko", 7))
        let edits: [HeldTyping.Edit] = [.insert("x"), .deleteBackward, .right, .deleteForward, .insert("E"), .end,
                                        .insert("!"), .start, .deleteBackward, .left]
        #expect(HeldTyping.apply(edits, to: "cedar", caret: 0) == ("cEdar!", 0))
        let empty = Array(repeating: HeldTyping.Edit.deleteBackward, count: 7)
        #expect(HeldTyping.apply([.end] + empty, to: "cedar", caret: 0) == ("", 0))
    }

    /// Keys are taken only while a hold is open, the keyboard is in no text field and the hold accepts them; a refused
    /// shortcut beeps and holds nothing; `end` hands the edits back once, in order, with the place.
    @Test func holdsTypingOnlyWhileOpenAndHandsItBackOnce() throws {
        let hold = TypingHold<String>()
        var refused = 0
        hold.refuse = { refused += 1 }
        #expect(!hold.take(try key("a"), keyboardInText: false), "No hold open.")
        var accepting = true
        let opened = hold.begin("cedar") { accepting }
        #expect(opened.ended == nil)
        #expect(hold.take(try key("v", .command), keyboardInText: false) && refused == 1, "⌘V refused, not held.")
        #expect(!hold.take(try key("z", .command), keyboardInText: false), "⌘Z with nothing held: the review's.")
        #expect(hold.take(try key("a"), keyboardInText: false))
        #expect(!hold.take(try key("b"), keyboardInText: true), "Typed into a text field: its own.")
        #expect(hold.take(try key("z", .command), keyboardInText: false) && refused == 2, "⌘Z after typing refused.")
        accepting = false
        #expect(!hold.take(try key("c"), keyboardInText: false), "Edit mode turned off.")
        let held = hold.end(opened.id)
        #expect(held?.place == "cedar" && held?.edits == [.insert("a")])
        #expect(hold.end(opened.id) == nil)
        #expect(hold.current == nil)
    }

    /// A hold begun while another is open ends the open one first: its edits come back with its own place, never moved
    /// to the newer hold's.
    @Test func aNewerHoldEndsTheOpenOneWithItsOwnEdits() throws {
        let hold = TypingHold<String>()
        let first = hold.begin("cedar") { true }
        #expect(hold.take(try key("a"), keyboardInText: false))
        let second = hold.begin("elm") { true }
        #expect(second.ended?.place == "cedar" && second.ended?.edits == [.insert("a")])
        #expect(hold.end(first.id) == nil)
        #expect(hold.take(try key("b"), keyboardInText: false))
        let held = hold.end(second.id)
        #expect(held?.place == "elm" && held?.edits == [.insert("b")])
    }
}
