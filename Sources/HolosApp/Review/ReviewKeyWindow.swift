import AppKit

/// The review window; it handles its own shortcuts first, and the playback keys before any view sees them. Typing for a
/// word's field about to open again goes to that field's hold first (`typingHold`).
///
/// Invariants:
/// 1. Every key press goes to the open hold first (`typingHold`, in both `performKeyEquivalent` and `sendEvent`); a key
///    it takes (held, or refused with a beep) reaches neither the window's shortcuts (`keyHandler`), nor playback
///    (`playbackKeyHandler`), nor any view.
/// 2. A key it does not take goes on as it would without a hold: the window's shortcuts, then playback, then the views.
/// 3. Held typing is never sent through the window again: it is written into the field it was held for, or kept as an
///    edit of that field's word (`ReviewWindow+JoinTyping`).
final class ReviewKeyWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Key presses on their way to the first responder; true when handled.
    var playbackKeyHandler: ((NSEvent) -> Bool)?
    /// Typing done while a join asked from the field saves its speaker change (`ReviewWindow.applyJoin`).
    let typingHold = TypingHold<JoinTypingPlace>()

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Invariant 1.
        if takes(event) { return true }
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // Invariant 1, then 2.
        if event.type == .keyDown, takes(event) || playbackKeyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    private func takes(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && typingHold.take(event, keyboardInText: (firstResponder as? NSTextView)?.isEditable == true)
    }
}

/// Typing held for a word's field that is about to open again. Backspace at a row's start (forward Delete at its end)
/// joins two rows from the field; when the join gives the later row the earlier row's speaker, the field closes and
/// opens again at the join only once that change has saved, which an earlier change in the queue or a slow save can
/// delay. What is typed meanwhile is the field's: held here as plain typing (`HeldTyping.Edit`) with the place it was
/// typed for (`Place`), never the list's or playback's (Space, J, K, L), then written into the field, or kept as an
/// edit of that place, the same edits either way (`ReviewWindow+JoinTyping`).
///
/// Invariants:
/// 1. A key is taken only while a hold is open (from `begin` to its `end`), the keyboard is in no text field, and the
///    hold's `accepting` says its field can still open; otherwise it goes where it always goes.
/// 2. Held: plain typing only, a key without ⌘ that `HeldTyping.edits` reads as characters, Delete, forward Delete or
///    an arrow. Refused with a beep (`refuse`), neither held nor sent on: a text field's ⌘ editing shortcuts (⌘A, ⌘X,
///    ⌘C, ⌘V, ⌘Z, ⇧⌘Z), except ⌘Z with nothing held, which goes on (the review's undo, taking the join back). Every
///    other key goes on.
/// 3. Every held edit is handed back exactly once and in order, with the place of the hold that held it: by that hold's
///    `end`, or by the `begin` of a newer hold, which ends the open one first. Edits never move to another place.
@MainActor
final class TypingHold<Place> {
    /// What one hold held: the place it was opened for and its edits, in order.
    struct Held {
        let place: Place
        let edits: [HeldTyping.Edit]
    }

    /// What the hold does with a key (invariant 2).
    enum Taking: Equatable {
        case hold([HeldTyping.Edit])
        case refuse
        case pass
    }

    private var edits: [HeldTyping.Edit] = []
    private var place: Place?
    /// The open hold's number; nil when none is open.
    private(set) var current: Int?
    private var count = 0
    private var accepting: () -> Bool = { false }
    /// Says a refused shortcut was refused (a beep; tests count it).
    var refuse: () -> Void = { NSSound.beep() }

    /// Opens a hold for `place` and returns its number for `end`, with what the hold open until now held (invariant
    /// 3: it ends first, and its edits stay its own). `accepting`: whether its field can still open (edit mode is on),
    /// asked for each key.
    func begin(_ place: Place, accepting: @escaping () -> Bool) -> (id: Int, ended: Held?) {
        let ended = current.flatMap(end)
        count += 1
        current = count
        self.place = place
        self.accepting = accepting
        return (count, ended)
    }

    /// Ends hold `id` and hands back its place and edits; nil when it ended already, or held nothing.
    func end(_ id: Int) -> Held? {
        guard current == id, let place else { return nil }
        current = nil
        self.place = nil
        accepting = { false }
        let held = edits
        edits = []
        return held.isEmpty ? nil : Held(place: place, edits: held)
    }

    /// Takes `event` when invariants 1 and 2 say so (true: the window sends it nowhere else).
    func take(_ event: NSEvent, keyboardInText: Bool) -> Bool {
        guard current != nil, !keyboardInText, accepting() else { return false }
        switch Self.taking(flags: event.modifierFlags, characters: event.characters,
                           key: event.charactersIgnoringModifiers, anythingHeld: !edits.isEmpty) {
        case .hold(let typed):
            edits += typed
            return true
        case .refuse:
            refuse()
            return true
        case .pass:
            return false
        }
    }

    /// Invariant 2 for a key with `flags`, its `characters`, and `key` (its characters without modifiers).
    nonisolated static func taking(flags: NSEvent.ModifierFlags, characters: String?, key: String?,
                                   anythingHeld: Bool) -> Taking {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else {
            let typed = HeldTyping.edits(characters)
            return typed.isEmpty ? .pass : .hold(typed)
        }
        let extra = flags.subtracting([.command, .capsLock, .numericPad, .function])
        guard let key = key?.lowercased(), ["z", "x", "c", "v", "a"].contains(key),
              extra.isEmpty || (key == "z" && extra == [.shift]) else { return .pass }
        return key == "z" && extra.isEmpty && !anythingHeld ? .pass : .refuse
    }
}

/// Plain typing held for a field (`TypingHold`), and what it makes of the field's text: the one model both a field
/// that opens again and a field that does not (an edit kept of its word) apply, so they read the same.
enum HeldTyping {
    enum Edit: Equatable {
        case insert(String)
        case deleteBackward, deleteForward
        /// ← and → move the caret one character; ↑ and Home to the start, ↓ and End to the end.
        case left, right, start, end
    }

    /// The edits a key's characters make; none for keys that are not plain typing (Return, Tab, Escape, ⌃ keys and
    /// other function keys).
    static func edits(_ characters: String?) -> [Edit] {
        var edits: [Edit] = []
        var text = ""
        func flush() {
            if !text.isEmpty { edits.append(.insert(text)) }
            text = ""
        }
        for scalar in (characters ?? "").unicodeScalars {
            let edit: Edit?
            switch scalar.value {
            case 0x7F, 0x08: edit = .deleteBackward
            case 0xF728: edit = .deleteForward
            case 0xF702: edit = .left
            case 0xF703: edit = .right
            case 0xF700, 0xF729: edit = .start
            case 0xF701, 0xF72B: edit = .end
            case 0..<0x20, 0xF700...0xF8FF: continue
            default:
                text.unicodeScalars.append(scalar)
                continue
            }
            flush()
            if let edit { edits.append(edit) }
        }
        flush()
        return edits
    }

    /// `edits` applied to `text` with the caret at `caret` (a character offset): the text and where the caret ends.
    static func apply(_ edits: [Edit], to text: String, caret: Int) -> (text: String, caret: Int) {
        var characters = Array(text)
        var at = min(max(caret, 0), characters.count)
        for edit in edits {
            switch edit {
            case .insert(let typed):
                characters.insert(contentsOf: typed, at: at)
                at += typed.count
            case .deleteBackward:
                if at > 0 {
                    characters.remove(at: at - 1)
                    at -= 1
                }
            case .deleteForward:
                if at < characters.count { characters.remove(at: at) }
            case .left: at = max(at - 1, 0)
            case .right: at = min(at + 1, characters.count)
            case .start: at = 0
            case .end: at = characters.count
            }
        }
        return (String(characters), at)
    }
}
