import Carbon
import Foundation

/// Why a key chord could not be registered.
public enum ChordHotkeyError: Error, LocalizedError, Equatable, Sendable {
    /// Another app holds the same chord.
    case taken(String)
    case failed(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .taken(let chord): "\(chord) is already used by another app, so it cannot read the selection aloud."
        case .failed(let chord, let status): "\(chord) could not be set up as a shortcut (error \(status))."
        }
    }
}

/// A global key chord through Carbon's hot keys (`RegisterEventHotKey`): macOS gives it to this app alone, whichever
/// app is in front, and the front app never sees it. Unlike the hold-to-talk tap (`GlobalHotkeyMonitor`) it needs no
/// Accessibility or Input Monitoring permission.
///
/// Invariants:
/// 1. While registered (`isRunning`), the monitor is retained by its event handler's context, and `stop` releases it.
/// 2. Each monitor answers only its own hot key ID; other hot keys' events go on to their handlers.
@MainActor public final class ChordHotkey {
    public struct Chord: Sendable, Equatable {
        public let keyCode: UInt32
        /// Carbon modifier flags (`cmdKey`, `optionKey`, …).
        public let modifiers: UInt32
        /// As menus write it ("⌃⌥⌘R").
        public let title: String
    }

    /// ⌃⌥⌘R: read the selection aloud.
    nonisolated public static let readSelection = Chord(keyCode: UInt32(kVK_ANSI_R),
                                            modifiers: UInt32(controlKey | optionKey | cmdKey), title: "⌃⌥⌘R")
    /// "HLOS": the signature of this app's hot key IDs.
    private static let signature: OSType = 0x484C_4F53
    private static var lastID: UInt32 = 0

    public let chord: Chord
    private let id: UInt32
    private let onPress: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var retainedContext: UnsafeMutableRawPointer?

    public var isRunning: Bool { hotKey != nil }

    public init(_ chord: Chord, onPress: @escaping @MainActor () -> Void) {
        self.chord = chord
        self.onPress = onPress
        Self.lastID += 1
        self.id = Self.lastID
    }

    public func start() throws {
        guard hotKey == nil else { return }
        let context = Unmanaged.passRetained(self).toOpaque()  // invariant 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon calls application event handlers on the main thread.
            return MainActor.assumeIsolated {
                Unmanaged<ChordHotkey>.fromOpaque(userData).takeUnretainedValue().handle(pressed)
            }
        }, 1, &spec, context, &installed)
        guard status == noErr, let installed else {
            Unmanaged<ChordHotkey>.fromOpaque(context).release()
            throw ChordHotkeyError.failed(chord.title, status)
        }
        var registered: EventHotKeyRef?
        let registration = RegisterEventHotKey(chord.keyCode, chord.modifiers,
                                               EventHotKeyID(signature: Self.signature, id: id),
                                               GetApplicationEventTarget(), 0, &registered)
        guard registration == noErr, let registered else {
            RemoveEventHandler(installed)
            Unmanaged<ChordHotkey>.fromOpaque(context).release()
            throw registration == OSStatus(eventHotKeyExistsErr)
                ? ChordHotkeyError.taken(chord.title) : ChordHotkeyError.failed(chord.title, registration)
        }
        handler = installed
        hotKey = registered
        retainedContext = context
    }

    public func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        if let retainedContext {
            Unmanaged<ChordHotkey>.fromOpaque(retainedContext).release()
            self.retainedContext = nil
        }
    }

    /// Invariant 2: only this monitor's hot key.
    private func handle(_ pressed: EventHotKeyID) -> OSStatus {
        guard pressed.signature == Self.signature, pressed.id == id else { return OSStatus(eventNotHandledErr) }
        onPress()
        return noErr
    }
}
