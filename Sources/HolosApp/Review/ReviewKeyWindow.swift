import AppKit

/// The review window; it handles its own shortcuts first, and the playback keys before any view sees them. Keys typed
/// for a word's field about to open again wait for it first (`typingHold`).
///
/// Invariants:
/// 1. Every key press goes to the open hold first (`typingHold`, in both `performKeyEquivalent` and `sendEvent`); a key
///    it holds reaches neither the window's shortcuts (`keyHandler`), nor playback (`playbackKeyHandler`), nor any view.
/// 2. A key it does not hold goes on as it would without a hold: the window's shortcuts, then playback, then the views.
/// 3. Held keys are sent again (`replay`) only after their hold has ended, so a replayed key is never held by the hold
///    that held it; a newer hold a replayed key opens (a Backspace that joins again) holds the keys after it.
final class ReviewKeyWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Key presses on their way to the first responder; true when handled.
    var playbackKeyHandler: ((NSEvent) -> Bool)?
    /// Keys typed while a join asked from the field saves its speaker change (`ReviewWindow.applyJoin`).
    let typingHold = TypingHold<JoinTypingPlace>()

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Invariant 1.
        if holds(event) { return true }
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // Invariant 1, then 2.
        if event.type == .keyDown, holds(event) || playbackKeyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    /// Sends a held key again as if it were typed now (its hold has ended, invariant 3; its field is open): a ⌘ key to
    /// the window's shortcuts first, as AppKit does.
    func replay(_ event: NSEvent) {
        if event.modifierFlags.contains(.command), performKeyEquivalent(with: event) { return }
        sendEvent(event)
    }

    private func holds(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && typingHold.hold(event, keyboardInText: (firstResponder as? NSTextView)?.isEditable == true)
    }
}

/// Keys held for a word's field that is about to open again. Backspace at a row's start (forward Delete at its end)
/// joins two rows from the field; when the join gives the later row the earlier row's speaker, the field closes and
/// opens again at the join only once that change has saved, which an earlier change in the queue or a slow save can
/// delay. What is typed meanwhile is the field's: held here with the place it was typed for (`Place`), never the
/// list's or playback's (Space, J, K, L), then replayed into the field, or kept as an edit of that place
/// (`ReviewWindow+JoinTyping`).
///
/// Invariants:
/// 1. A key is held only while a hold is open (from `begin` to its `end`), the keyboard is in no text field, and the
///    hold's `accepting` says its field can still open; otherwise it goes where it always goes.
/// 2. Held keys: every key without ⌘ (`holds`); once something is held, also a text field's own ⌘ shortcuts (undo, redo,
///    cut, copy, paste, select all), so they act on the typing replayed before them. Any other ⌘ shortcut, and ⌘Z with
///    nothing held (the review's undo, taking the join back), acts at once.
/// 3. Every held key is handed back exactly once, in order, with the place of the hold that held it: by that hold's
///    `end`, or by the `begin` of a newer hold, which ends the open one first. Keys never move to another place.
@MainActor
final class TypingHold<Place> {
    /// What one hold held: the place it was opened for and its keys, in order.
    struct Held {
        let place: Place
        let keys: [NSEvent]
    }

    private var keys: [NSEvent] = []
    private var place: Place?
    /// The open hold's number; nil when none is open.
    private(set) var current: Int?
    private var count = 0
    private var accepting: () -> Bool = { false }

    /// Opens a hold for `place` and returns its number for `end`, with what the hold open until now held (invariant
    /// 3: it ends first, and its keys stay its own). `accepting`: whether its field can still open (edit mode is on),
    /// asked for each key.
    func begin(_ place: Place, accepting: @escaping () -> Bool) -> (id: Int, ended: Held?) {
        let ended = current.flatMap(end)
        count += 1
        current = count
        self.place = place
        self.accepting = accepting
        return (count, ended)
    }

    /// Ends hold `id` and hands back its place and the keys it held; nil when it ended already, or held nothing.
    func end(_ id: Int) -> Held? {
        guard current == id, let place else { return nil }
        current = nil
        self.place = nil
        accepting = { false }
        let held = keys
        keys = []
        return held.isEmpty ? nil : Held(place: place, keys: held)
    }

    /// Holds `event` when invariants 1 and 2 say so (true: the window sends it nowhere else).
    func hold(_ event: NSEvent, keyboardInText: Bool) -> Bool {
        guard current != nil, !keyboardInText,
              Self.holds(flags: event.modifierFlags, key: event.charactersIgnoringModifiers,
                         anythingHeld: !keys.isEmpty),
              accepting() else { return false }
        keys.append(event)
        return true
    }

    /// Invariant 2 for a key with `flags` and `key` (its characters without modifiers).
    nonisolated static func holds(flags: NSEvent.ModifierFlags, key: String?, anythingHeld: Bool) -> Bool {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return true }
        guard anythingHeld, flags.subtracting([.shift, .capsLock, .numericPad, .function]) == [.command],
              let key = key?.lowercased() else { return false }
        return ["z", "x", "c", "v", "a"].contains(key)
    }
}

/// What held keys make of a field's `text` with the caret at `caret` (a character offset), close to what the field
/// would have made of them: characters go in at the caret; Delete and forward Delete remove the character before or
/// after it; ← and → move it one character, ↑ and ↓ to the start or end. ⌘ shortcuts, Return, Tab, Escape and other
/// keys are left out (a field would have saved, moved on, or cancelled).
enum HeldTyping {
    static func apply(_ keys: [(characters: String?, flags: NSEvent.ModifierFlags)], to text: String,
                      caret: Int) -> String {
        var characters = Array(text)
        var at = min(max(caret, 0), characters.count)
        for key in keys where !key.flags.contains(.command) {
            for scalar in (key.characters ?? "").unicodeScalars {
                switch scalar.value {
                case 0x7F, 0x08:
                    if at > 0 {
                        characters.remove(at: at - 1)
                        at -= 1
                    }
                case 0xF728:
                    if at < characters.count { characters.remove(at: at) }
                case 0xF702: at = max(at - 1, 0)
                case 0xF703: at = min(at + 1, characters.count)
                case 0xF700, 0xF729: at = 0
                case 0xF701, 0xF72B: at = characters.count
                case 0..<0x20, 0xF700...0xF8FF:
                    break
                default:
                    characters.insert(Character(scalar), at: at)
                    at += 1
                }
            }
        }
        return String(characters)
    }
}
