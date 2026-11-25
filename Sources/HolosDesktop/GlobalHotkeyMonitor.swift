import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import HolosCore

/// Why the hotkey's event tap could not start. The tap is active (`.defaultTap`: it consumes the shortcut), which
/// macOS authorises with Accessibility; Input Monitoring is what listen-only taps need, so it is not asked for up
/// front. It is only the fallback when macOS refuses the tap with Accessibility granted.
public enum HotkeyStartError: Error, LocalizedError, Equatable, Sendable {
    /// Accessibility is not granted.
    case accessibilityNotGranted
    /// Accessibility is granted, yet macOS refused the tap: Input Monitoring may be needed on this Mac.
    case tapRefused
    /// The tap could not be attached to the main run loop.
    case runLoopUnavailable

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "The hold-to-talk shortcut needs Accessibility access for Voice is Local. Turn it on in System Settings, then retry."
        case .tapRefused:
            "macOS refused the hold-to-talk shortcut although Accessibility is on. Turn on Voice is Local under Input Monitoring in System Settings (Settings shows it), then quit and reopen Voice is Local."
        case .runLoopUnavailable:
            "Could not attach the global hotkey event tap to the main run loop."
        }
    }

    /// The check before the tap is created: Accessibility only.
    static func gate(accessibility: Bool) -> HotkeyStartError? {
        accessibility ? nil : .accessibilityNotGranted
    }

    /// Why `CGEvent.tapCreate` returned nil: Accessibility was revoked meanwhile, or macOS wants more.
    static func tapFailure(accessibility: Bool) -> HotkeyStartError {
        accessibility ? .tapRefused : .accessibilityNotGranted
    }
}

/// Invariants:
/// 1. One tap owns both bindings and delivers events in order on the main actor.
/// 2. Stopping or losing the tap retires any queued actions from the previous generation.
@MainActor public final class GlobalHotkeyMonitor {
    private let shortcuts: DictationShortcuts
    private let onAction: @MainActor (HotkeyAction) -> Void
    private var reducer: HotkeyReducer
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retainedContext: UnsafeMutableRawPointer?
    private var generation = 0
    private var pendingActions: [HotkeyAction] = []
    private var deliveryScheduled = false

    public var isRunning: Bool { tap != nil }

    public func setSessionActive(_ active: Bool) {
        reducer.setSessionActive(active)
    }

    public init(shortcuts: DictationShortcuts, onAction: @escaping @MainActor (HotkeyAction) -> Void) {
        self.shortcuts = shortcuts
        self.onAction = onAction
        self.reducer = HotkeyReducer(shortcuts: shortcuts)
    }

    public func start() throws {
        guard tap == nil else { return }
        if let refused = HotkeyStartError.gate(accessibility: AXIsProcessTrusted()) { throw refused }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        generation += 1
        pendingActions.removeAll()
        deliveryScheduled = false
        reducer = HotkeyReducer(shortcuts: shortcuts, optionWasDownAtStart: flags.contains(.maskAlternate))
        let events: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .defaultTap, eventsOfInterest: events,
                                               callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.eventSourceUserData) == KeystrokeTarget.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let repeating = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let consume = MainActor.assumeIsolated {
                monitor.handle(type: type, code: code, flags: flags, repeating: repeating)
            }
            return consume ? nil : Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            Unmanaged<GlobalHotkeyMonitor>.fromOpaque(context).release()
            throw HotkeyStartError.tapFailure(accessibility: AXIsProcessTrusted())
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            Unmanaged<GlobalHotkeyMonitor>.fromOpaque(context).release()
            throw HotkeyStartError.runLoopUnavailable
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = runLoopSource
        retainedContext = context
    }

    public func stop() {
        let action = reducer.receive(.stopped).action
        generation += 1
        pendingActions.removeAll()
        deliveryScheduled = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        if let retainedContext {
            Unmanaged<GlobalHotkeyMonitor>.fromOpaque(retainedContext).release()
            self.retainedContext = nil
        }
        if let action { onAction(action) }
    }

    /// Whether macOS would let `start` install the tap now; nil when it would. The same tap is created, disabled and
    /// removed at once without joining a run loop, so no key reaches it. The Setup Assistant runs this once
    /// Accessibility is granted, to learn before its Reopen page whether Input Monitoring is needed too.
    public static func probe() -> HotkeyStartError? {
        if let refused = HotkeyStartError.gate(accessibility: AXIsProcessTrusted()) { return refused }
        let events: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .defaultTap, eventsOfInterest: events,
                                               callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                               userInfo: nil) else {
            return HotkeyStartError.tapFailure(accessibility: AXIsProcessTrusted())
        }
        CGEvent.tapEnable(tap: created, enable: false)
        CFMachPortInvalidate(created)
        return nil
    }

    private func handle(type: CGEventType, code: Int, flags: CGEventFlags, repeating: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let action = reducer.receive(.tapDisabled).action
            generation += 1
            pendingActions.removeAll()
            deliveryScheduled = false
            if let action { queue(action) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if IsSecureEventInputEnabled() {
            let action = reducer.receive(.secureInput).action
            if let action { queue(action) }
            return false
        }
        let input: HotkeyInput
        switch type {
        case .keyDown: input = .keyDown(code: code, flags: flags, repeating: repeating)
        case .keyUp: input = .keyUp(code: code, flags: flags)
        case .flagsChanged: input = .flagsChanged(code: code, flags: flags)
        default: return false
        }
        let transition = reducer.receive(input)
        if let action = transition.action { queue(action) }
        return transition.consume
    }

    private func queue(_ action: HotkeyAction) {
        pendingActions.append(action)
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        let expectedGeneration = generation
        Task { @MainActor [weak self] in
            self?.drainActions(generation: expectedGeneration)
        }
    }

    private func drainActions(generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        deliveryScheduled = false
        while !pendingActions.isEmpty {
            let action = pendingActions.removeFirst()
            onAction(action)
            if generation != expectedGeneration { return }
        }
    }
}
