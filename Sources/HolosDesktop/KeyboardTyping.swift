import Carbon
import CoreGraphics
import Foundation

/// One printable key in the active layout. Only Shift is admitted: Option and Control can become terminal commands.
struct KeyboardStroke: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    /// `pressingShift`: a Shift stroke also presses and releases Shift itself around the key, as a keyboard does, for
    /// an app that follows Shift's own events rather than each key's flags.
    func events(for character: Character, source: CGEventSource?, marker: Int64, pressingShift: Bool = false) -> [CGEvent]? {
        let units = Array(String(character).utf16)
        var events: [CGEvent] = []
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                return nil
            }
            event.flags = flags
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            events.append(event)
        }
        guard pressingShift, flags.contains(.maskShift) else { return events }
        guard let down = Self.shift(pressed: true, source: source, marker: marker),
              let up = Self.shift(pressed: false, source: source, marker: marker) else { return nil }
        return [down] + events + [up]
    }

    private static func shift(pressed: Bool, source: CGEventSource?, marker: Int64) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: pressed) else { return nil }
        event.type = .flagsChanged
        event.flags = pressed ? .maskShift : []
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
}

/// Inverts a layout without selecting another input source or posting events.
enum KeyboardTyping {
    // Printable ANSI/ISO keys, plus JIS Yen and Underscore. Exclude Return, Tab and every command/function key.
    static let printableKeyCodes: [CGKeyCode] = (0...50).filter { $0 != 36 && $0 != 48 } + [93, 94]

    static func keyMap(translate: (CGKeyCode, Bool) -> String?) -> [Character: KeyboardStroke] {
        var result: [Character: KeyboardStroke] = [:]
        for shifted in [false, true] {
            for code in printableKeyCodes {
                guard let text = translate(code, shifted), text.count == 1,
                      InsertionPolicy.permits(text), let character = text.first,
                      result[character] == nil else { continue }
                result[character] = KeyboardStroke(keyCode: code, flags: shifted ? .maskShift : [])
            }
        }
        return result
    }

    /// Whether a key held now also counts on the other computer. A remote screen sees every key that reaches it. The
    /// hold-to-talk Right Option does not (`HotkeyReducer` consumes it), which the flags cannot tell from Left Option, so
    /// that one is asked for by its key. Control with Option and Space does reach it, before Space starts the dictation.
    /// Not told apart: Right Option left held from that shortcut after Control is released.
    static func heldKeysReachRemote(_ flags: CGEventFlags, leftOption: Bool) -> Bool {
        leftOption || !flags.intersection([.maskControl, .maskCommand, .maskShift]).isEmpty
    }

    /// The same, for the keys held now.
    static func heldKeysReachRemote() -> Bool {
        heldKeysReachRemote(CGEventSource.flagsState(.hidSystemState),
                            leftOption: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Option)))
    }

    /// Preflight the entire chunk so an untypable character never leaves a partially typed chunk.
    static func strokes(for text: String, in map: [Character: KeyboardStroke]) -> [KeyboardStroke]? {
        guard InsertionPolicy.permits(text) else { return nil }
        var result: [KeyboardStroke] = []
        for character in text {
            guard let stroke = map[character] else { return nil }
            result.append(stroke)
        }
        return result
    }

    @MainActor static func currentKeyMap() -> [Character: KeyboardStroke]? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return keyMap(for: source, keyboardType: UInt32(LMGetKbdType()))
    }

    @MainActor static func keyMap(for source: TISInputSource, keyboardType: UInt32) -> [Character: KeyboardStroke]? {
        // An input method with no direct keyboard layout cannot be inverted safely.
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        return withExtendedLifetime(data) {
            keyMap { code, shifted in
                var state: UInt32 = 0
                var length = 0
                var units = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown),
                                            shifted ? UInt32(shiftKey >> 8) : 0, keyboardType, 0,
                                            &state, units.count, &length, &units)
                // A dead key's displayed accent is not the text its physical key commits.
                guard status == noErr, state == 0, length > 0 else { return nil }
                return String(utf16CodeUnits: units, count: length)
            }
        }
    }
}
