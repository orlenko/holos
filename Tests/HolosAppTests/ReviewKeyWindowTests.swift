import AppKit
import Testing
@testable import HolosApp

/// `TypingHold`: the keys the review window holds for a word's field about to open again after a join.
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
            #expect(TypingHold.holds(flags: flags, key: key, anythingHeld: anythingHeld) == held, "\(flags) \(key)")
        }
    }

    /// What held keys typed, for the footer: characters only, never Delete, arrows or ⌘ shortcuts.
    @Test func typedTextKeepsOnlyCharacters() {
        #expect(TypingHold.typedText([("a", []), ("\u{7F}", []), ("\u{F702}", [.function]), ("z", [.command]),
                                      (" ", []), ("B", [.shift])]) == "a B")
    }

    /// Keys are held only while a hold is open, the keyboard is in no text field and the hold accepts them; its `end`
    /// hands them back once, in order.
    @Test func holdsKeysOnlyWhileOpenAndHandsThemBackOnce() throws {
        let hold = TypingHold()
        #expect(!hold.hold(try key("a"), keyboardInText: false), "No hold open.")
        var accepting = true
        let id = hold.begin { accepting }
        #expect(hold.hold(try key("a"), keyboardInText: false))
        #expect(!hold.hold(try key("b"), keyboardInText: true), "Typed into a text field: its own.")
        #expect(hold.hold(try key("z", .command), keyboardInText: false), "Undo of the typing held with it.")
        accepting = false
        #expect(!hold.hold(try key("c"), keyboardInText: false), "Edit mode turned off.")
        #expect(hold.end(id).map(\.characters) == ["a", "z"])
        #expect(hold.end(id).isEmpty)
        #expect(hold.current == nil)
    }

    /// A hold begun while another is open takes over its keys: the older hold's `end` hands back nothing.
    @Test func aNewerHoldTakesOverTheKeys() throws {
        let hold = TypingHold()
        let first = hold.begin { true }
        #expect(hold.hold(try key("a"), keyboardInText: false))
        let second = hold.begin { true }
        #expect(hold.hold(try key("b"), keyboardInText: false))
        #expect(hold.end(first).isEmpty)
        #expect(hold.end(second).map(\.characters) == ["a", "b"])
    }
}
