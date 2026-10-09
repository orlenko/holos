import AppKit

/// The review window; it handles its own shortcuts first, and the playback keys before any view sees them. Keys typed
/// for a word's field about to open again wait for it first (`typingHold`).
final class ReviewKeyWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Key presses on their way to the first responder; true when handled.
    var playbackKeyHandler: ((NSEvent) -> Bool)?
    /// Keys typed while a join asked from the field saves its speaker change (`ReviewWindow.applyJoin`).
    let typingHold = TypingHold()

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if holds(event) { return true }
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, holds(event) || playbackKeyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    /// Sends a held key again as if it were typed now (its field is open): a ⌘ key to the window's shortcuts first,
    /// as AppKit does.
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
/// delay. What is typed meanwhile is the field's: held here, never the list's or playback's (Space, J, K, L), then
/// replayed into the field, or said in the footer when no field opens (`ReviewWindow.handOverTyping`).
///
/// Invariants:
/// 1. A key is held only while a hold is open (from `begin` to its `end`), the keyboard is in no text field, and the
///    hold's `accepting` says its field can still open; otherwise it goes where it always goes.
/// 2. Held keys: every key without ⌘ (`holds`); once something is held, also a text field's own ⌘ shortcuts (undo, redo,
///    cut, copy, paste, select all), so they act on the typing replayed before them. Any other ⌘ shortcut, and ⌘Z with
///    nothing held (the review's undo, taking the join back), acts at once.
/// 3. Every held key is handed back exactly once and in order: by the `end` of the hold open when it was held. A hold
///    begun while another is open takes over its keys (the newer field is where typing goes on), so the older hold's
///    `end` hands back nothing.
@MainActor
final class TypingHold {
    private var keys: [NSEvent] = []
    /// The open hold's number; nil when none is open.
    private(set) var current: Int?
    private var count = 0
    private var accepting: () -> Bool = { false }

    /// Opens a hold (invariant 3: keys an open one held stay, now this one's) and returns its number for `end`.
    /// `accepting`: whether its field can still open (edit mode is on), asked for each key.
    func begin(accepting: @escaping () -> Bool) -> Int {
        count += 1
        current = count
        self.accepting = accepting
        return count
    }

    /// Ends hold `id` and hands back the keys it held, in order; none when it ended already or a newer hold took over.
    func end(_ id: Int) -> [NSEvent] {
        guard current == id else { return [] }
        current = nil
        accepting = { false }
        let held = keys
        keys = []
        return held
    }

    /// Holds `event` when invariants 1 and 2 say so (true: the window sends it nowhere else).
    func hold(_ event: NSEvent, keyboardInText: Bool) -> Bool {
        guard current != nil, !keyboardInText,
              Self.holds(flags: event.modifierFlags, key: event.charactersIgnoringModifiers, anythingHeld: !keys.isEmpty),
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

    /// The text `keys` typed, to say it when no field takes them: their characters, without ⌘ shortcuts, Delete,
    /// arrows and other function keys.
    nonisolated static func typedText(_ keys: [(characters: String?, flags: NSEvent.ModifierFlags)]) -> String {
        var text = ""
        for key in keys where !key.flags.contains(.command) {
            for scalar in (key.characters ?? "").unicodeScalars {
                let control = scalar.value < 0x20 || scalar.value == 0x7F
                let function = (0xF700...0xF8FF).contains(scalar.value)
                if !control && !function { text.unicodeScalars.append(scalar) }
            }
        }
        return text
    }
}
