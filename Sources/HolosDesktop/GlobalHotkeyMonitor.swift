import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import HolosCore

public enum HotkeyChoice: String, CaseIterable, Sendable {
    case controlOptionSpace
    case rightOption
}

public enum HotkeyAction: Sendable, Equatable {
    case began
    case ended
    case cancelled
}

struct HotkeyTransition {
    let action: HotkeyAction?
    let consume: Bool
}

enum HotkeyInput {
    case keyDown(code: Int, flags: CGEventFlags)
    case keyUp(code: Int, flags: CGEventFlags)
    case flagsChanged(code: Int, flags: CGEventFlags)
    case tapDisabled
    case stopped
    case secureInput
}

/// Pure event reducer. Physical Right Option transitions are tracked independently
/// of the aggregate Option flag, which can also be held by Left Option.
struct HotkeyReducer {
    let shortcut: HotkeyChoice
    private(set) var active = false
    private(set) var sessionActive = false
    private var rightDown = false
    private var waitForNeutralOption = false
    private var suppressSpaceUntilUp = false
    private var suppressedKeyUps: Set<Int> = []

    init(shortcut: HotkeyChoice, optionWasDownAtStart: Bool = false) {
        self.shortcut = shortcut
        self.waitForNeutralOption = optionWasDownAtStart
    }

    mutating func setSessionActive(_ active: Bool) {
        sessionActive = active
    }

    mutating func receive(_ input: HotkeyInput) -> HotkeyTransition {
        switch input {
        case .tapDisabled, .stopped, .secureInput:
            let action: HotkeyAction? = active || sessionActive ? .cancelled : nil
            active = false
            sessionActive = false
            rightDown = false
            waitForNeutralOption = true
            if case .stopped = input { suppressedKeyUps.removeAll(); suppressSpaceUntilUp = false }
            return HotkeyTransition(action: action, consume: false)

        case .flagsChanged(let code, let flags):
            if shortcut == .rightOption {
                if code == Int(kVK_RightOption) {
                    if waitForNeutralOption {
                        if !flags.contains(.maskAlternate) {
                            waitForNeutralOption = false
                            rightDown = false
                        }
                        return HotkeyTransition(action: nil, consume: true)
                    }
                    rightDown.toggle()
                    if rightDown {
                        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskShift) {
                            waitForNeutralOption = true
                            return HotkeyTransition(action: nil, consume: true)
                        }
                        if active { return HotkeyTransition(action: nil, consume: true) }
                        active = true
                        return HotkeyTransition(action: .began, consume: true)
                    }
                    let action: HotkeyAction? = active ? .ended : nil
                    active = false
                    return HotkeyTransition(action: action, consume: true)
                }
                if waitForNeutralOption && !flags.contains(.maskAlternate) {
                    waitForNeutralOption = false
                    rightDown = false
                }
                if active {
                    if !flags.contains(.maskAlternate) {
                        active = false; rightDown = false
                        return HotkeyTransition(action: .ended, consume: false)
                    }
                    if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskShift) {
                        active = false; waitForNeutralOption = true
                        return HotkeyTransition(action: .cancelled, consume: false)
                    }
                }
                return HotkeyTransition(action: nil, consume: false)
            }
            if active {
                if !flags.contains(.maskControl) || !flags.contains(.maskAlternate) {
                    active = false
                    return HotkeyTransition(action: .ended, consume: false)
                }
                if flags.contains(.maskCommand) || flags.contains(.maskShift) {
                    active = false
                    return HotkeyTransition(action: .cancelled, consume: false)
                }
            }
            return HotkeyTransition(action: nil, consume: false)

        case .keyDown(let code, let flags):
            if suppressedKeyUps.contains(code) { return HotkeyTransition(action: nil, consume: true) }
            if active && shortcut == .rightOption && !flags.contains(.maskAlternate) &&
                code != Int(kVK_Escape) {
                active = false
                rightDown = false
                return HotkeyTransition(action: .ended, consume: false)
            }
            if shortcut == .rightOption && waitForNeutralOption && flags.contains(.maskAlternate) {
                suppressedKeyUps.insert(code)
                return HotkeyTransition(action: nil, consume: true)
            }
            if code == Int(kVK_Escape) && (active || sessionActive) {
                active = false
                sessionActive = false
                suppressedKeyUps.insert(code)
                if shortcut == .rightOption && rightDown { waitForNeutralOption = true }
                return HotkeyTransition(action: .cancelled, consume: true)
            }
            if shortcut == .controlOptionSpace && code == Int(kVK_Space) {
                if suppressSpaceUntilUp { return HotkeyTransition(action: nil, consume: true) }
                let exactChord = flags.contains(.maskControl) && flags.contains(.maskAlternate) &&
                    !flags.contains(.maskCommand) && !flags.contains(.maskShift)
                if exactChord {
                    active = true
                    suppressSpaceUntilUp = true
                    return HotkeyTransition(action: .began, consume: true)
                }
            }
            if shortcut == .controlOptionSpace && suppressSpaceUntilUp && code != Int(kVK_Space) {
                let action: HotkeyAction? = active ? .cancelled : nil
                active = false
                suppressedKeyUps.insert(code)
                return HotkeyTransition(action: action, consume: true)
            }
            if active {
                active = false
                suppressedKeyUps.insert(code)
                if shortcut == .rightOption { waitForNeutralOption = true }
                return HotkeyTransition(action: .cancelled, consume: true)
            }
            return HotkeyTransition(action: nil, consume: false)

        case .keyUp(let code, let flags):
            if suppressedKeyUps.remove(code) != nil {
                return HotkeyTransition(action: nil, consume: true)
            }
            if active && shortcut == .rightOption && !flags.contains(.maskAlternate) {
                active = false
                rightDown = false
                return HotkeyTransition(action: .ended, consume: false)
            }
            if shortcut == .controlOptionSpace && code == Int(kVK_Space) && suppressSpaceUntilUp {
                suppressSpaceUntilUp = false
                let action: HotkeyAction? = active ? .ended : nil
                active = false
                return HotkeyTransition(action: action, consume: true)
            }
            return HotkeyTransition(action: nil, consume: false)
        }
    }
}

@MainActor public final class GlobalHotkeyMonitor {
    private let shortcut: HotkeyChoice
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

    public init(shortcut: HotkeyChoice, onAction: @escaping @MainActor (HotkeyAction) -> Void) {
        self.shortcut = shortcut
        self.onAction = onAction
        self.reducer = HotkeyReducer(shortcut: shortcut)
    }

    public func start() throws {
        guard tap == nil else { return }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            throw HolosError.permissionDenied("Global hotkey requires Accessibility and Input Monitoring access for Holos. Enable both in System Settings, then retry.")
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        generation += 1
        pendingActions.removeAll()
        deliveryScheduled = false
        reducer = HotkeyReducer(shortcut: shortcut, optionWasDownAtStart: flags.contains(.maskAlternate))
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
            let consume = MainActor.assumeIsolated { monitor.handle(type: type, code: code, flags: flags) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            Unmanaged<GlobalHotkeyMonitor>.fromOpaque(context).release()
            throw HolosError.unavailable("Could not install the global hotkey event tap. Check Accessibility and Input Monitoring permissions.")
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            Unmanaged<GlobalHotkeyMonitor>.fromOpaque(context).release()
            throw HolosError.unavailable("Could not attach the global hotkey event tap to the main run loop.")
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

    private func handle(type: CGEventType, code: Int, flags: CGEventFlags) -> Bool {
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
        case .keyDown: input = .keyDown(code: code, flags: flags)
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
