import AppKit

/// The review window; it handles its own shortcuts first, and the playback keys before any view sees them. While a
/// join asked from the word field saves its speaker change, that field is closed, and typing meant for it is refused
/// rather than taken as the list's or playback's keys (`closeFieldForJoin`).
///
/// Invariants:
/// 1. While a join's field is closed (`fieldClosedForJoin`), edit mode is on (`fieldClosedWhile`) and the keyboard is
///    in no text field, every key press without ⌘, and every ⌘-arrow, is refused (`refuse`, a beep): it reaches neither
///    the window's shortcuts, nor playback, nor any view, and nothing is kept to send again. Other ⌘ shortcuts (⌘Z
///    undoing the join, ⌘W) go on as always.
/// 2. At most one join's field is closed at a time: a newer join takes over (`closeFieldForJoin`), and a join reopens
///    only its own (`reopenFieldAfterJoin`), so an older join ending never lets typing through for a newer one.
/// 3. Any other key press goes on as it would: the window's shortcuts, then playback, then the views.
final class ReviewKeyWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Key presses on their way to the first responder; true when handled.
    var playbackKeyHandler: ((NSEvent) -> Bool)?
    /// The join whose word field is closed while its speaker change saves (`ReviewWindow.applyJoin`); nil when none.
    private(set) var fieldClosedForJoin: Int?
    private var joins = 0
    /// Whether typing for the closed field is still refused (edit mode is on), asked for each key.
    var fieldClosedWhile: () -> Bool = { true }
    /// Says a key was refused (a beep; tests count it).
    var refuse: () -> Void = { NSSound.beep() }

    /// A join from the field closed it until its speaker change saves: typing is refused until then (invariant 1).
    /// Returns the join's number for `reopenFieldAfterJoin`.
    func closeFieldForJoin() -> Int {
        joins += 1
        fieldClosedForJoin = joins
        return joins
    }

    /// Join `id` ended (its field opened again, or it was dropped): typing goes where it always goes. Nothing when a
    /// newer join's field is closed (invariant 2).
    func reopenFieldAfterJoin(_ id: Int?) {
        if let id, fieldClosedForJoin == id { fieldClosedForJoin = nil }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if refuses(event) { return true }
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, refuses(event) || playbackKeyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    /// Refuses `event` when invariant 1 says so.
    private func refuses(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, fieldClosedForJoin != nil, fieldClosedWhile(),
              (firstResponder as? NSTextView)?.isEditable != true,
              Self.refusedWhileFieldClosed(flags: event.modifierFlags, special: event.specialKey) else { return false }
        refuse()
        return true
    }

    /// Invariant 1's keys: every key without ⌘, and ⌘ with an arrow or other special key (⌘← and ⌘→ move playback).
    nonisolated static func refusedWhileFieldClosed(flags: NSEvent.ModifierFlags,
                                                    special: NSEvent.SpecialKey?) -> Bool {
        !flags.contains(.command) || special != nil
    }
}
