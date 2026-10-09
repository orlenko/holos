import AppKit
import Testing
@testable import HolosApp

/// `TypingHold` and `HeldTyping`: the keys the review window holds for a word's field about to open again after a
/// join, and what they make of the word's text when no field opens.
@MainActor
struct ReviewKeyWindowTests {
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    /// Every key without ⌘; with ⌘, only a text field's own shortcuts, and only after something was held, so ⌘Z with
    /// nothing typed is still the review's undo.
    @Test func holdsTypingAndTheFieldsOwnShortcutsOnly() {
        let cases: [(NSEvent.ModifierFlags, String, Bool, Bool)] = [
            ([], "k", false, true), ([], " ", false, true), ([.shift], "A", false, true), ([.option], "e", false, true),
            ([.numericPad, .function], "\u{F702}", false, true), ([.control], "a", false, true),
            ([.command], "z", false, false), ([.command], "z", true, true), ([.command, .shift], "z", true, true),
            ([.command], "v", true, true), ([.command], "w", true, false), ([.command], "e", true, false),
            ([.command, .option], "z", true, false), ([.command, .numericPad, .function], "\u{F702}", true, false),
        ]
        for (flags, key, anythingHeld, held) in cases {
            #expect(TypingHold<String>.holds(flags: flags, key: key, anythingHeld: anythingHeld) == held,
                    "\(flags) \(key)")
        }
    }

    /// Held keys applied to a word's text as the field would: characters at the caret, Delete and forward Delete,
    /// arrows; ⌘ shortcuts, Return, Tab and Escape left out.
    @Test func heldKeysEditTheWordAsTheFieldWould() {
        let plain: [(String?, NSEvent.ModifierFlags)] = [("k", []), ("o", [])]
        #expect(HeldTyping.apply(plain.map { ($0.0, $0.1) }, to: "cedar", caret: 0) == "kocedar")
        #expect(HeldTyping.apply(plain.map { ($0.0, $0.1) }, to: "cedar", caret: 5) == "cedarko")
        let edits: [(String?, NSEvent.ModifierFlags)] = [
            ("x", []), ("\u{7F}", []), ("\u{F703}", [.function]), ("\u{F728}", [.function]), ("E", [.shift]),
            ("z", [.command]), ("\r", []), ("\t", []), ("\u{1B}", []), ("\u{F701}", [.function]), ("!", []),
            ("\u{7F}", []), ("\u{7F}", []), ("\u{7F}", []), ("\u{7F}", []), ("\u{7F}", []), ("\u{7F}", []),
            ("\u{7F}", []),
        ]
        // x typed and deleted; → past "c"; forward Delete takes "e"; "E" in its place; ⌘Z, Return, Tab, Escape left
        // out; ↓ to the end; "!" typed; seven Deletes empty it and go no further.
        #expect(HeldTyping.apply(Array(edits.prefix(11)).map { ($0.0, $0.1) }, to: "cedar", caret: 0) == "cEdar!")
        #expect(HeldTyping.apply(edits.map { ($0.0, $0.1) }, to: "cedar", caret: 0) == "")
    }

    /// Keys are held only while a hold is open, the keyboard is in no text field and the hold accepts them; its `end`
    /// hands them back once, in order, with its place.
    @Test func holdsKeysOnlyWhileOpenAndHandsThemBackOnce() throws {
        let hold = TypingHold<String>()
        #expect(!hold.hold(try key("a"), keyboardInText: false), "No hold open.")
        var accepting = true
        let opened = hold.begin("cedar") { accepting }
        #expect(opened.ended == nil)
        #expect(hold.hold(try key("a"), keyboardInText: false))
        #expect(!hold.hold(try key("b"), keyboardInText: true), "Typed into a text field: its own.")
        #expect(hold.hold(try key("z", .command), keyboardInText: false), "Undo of the typing held with it.")
        accepting = false
        #expect(!hold.hold(try key("c"), keyboardInText: false), "Edit mode turned off.")
        let held = hold.end(opened.id)
        #expect(held?.place == "cedar" && held?.keys.map(\.characters) == ["a", "z"])
        #expect(hold.end(opened.id) == nil)
        #expect(hold.current == nil)
    }

    /// A hold begun while another is open ends the open one first: its keys come back with its own place, never moved
    /// to the newer hold's.
    @Test func aNewerHoldEndsTheOpenOneWithItsOwnKeys() throws {
        let hold = TypingHold<String>()
        let first = hold.begin("cedar") { true }
        #expect(hold.hold(try key("a"), keyboardInText: false))
        let second = hold.begin("elm") { true }
        #expect(second.ended?.place == "cedar" && second.ended?.keys.map(\.characters) == ["a"])
        #expect(hold.end(first.id) == nil)
        #expect(hold.hold(try key("b"), keyboardInText: false))
        let held = hold.end(second.id)
        #expect(held?.place == "elm" && held?.keys.map(\.characters) == ["b"])
    }
}
