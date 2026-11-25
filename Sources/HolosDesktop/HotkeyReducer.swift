import Carbon
import CoreGraphics

struct HotkeyTransition {
    let action: HotkeyAction?
    let consume: Bool

    init(_ action: HotkeyAction? = nil, consume: Bool = false) {
        self.action = action
        self.consume = consume
    }
}

enum HotkeyInput {
    case keyDown(code: Int, flags: CGEventFlags, repeating: Bool = false)
    case keyUp(code: Int, flags: CGEventFlags)
    case flagsChanged(code: Int, flags: CGEventFlags)
    case tapDisabled
    case stopped
    case secureInput
}

/// Invariants:
/// 1. Each hold starts at most one utterance, with the binding captured on its initial press.
/// 2. While the tap sees events, a consumed primary key stays consumed through release, even after cancel.
/// 3. The command modifier reaches the focused app; only the hotkey's primary key is reserved.
struct HotkeyReducer {
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
    // NX_DEVICERCMDKEYMASK and NX_DEVICELCMDKEYMASK.
    private static let rightCommand: UInt64 = 0x10
    private static let leftCommand: UInt64 = 0x08
    private static let commandSides = rightCommand | leftCommand
    // NX_DEVICERALTKEYMASK and NX_DEVICELALTKEYMASK.
    private static let rightOption: UInt64 = 0x40
    private static let optionSides = rightOption | 0x20

    let shortcuts: DictationShortcuts
    private(set) var sessionActive = false
    private var held: HotkeyChoice?
    private var reserved: HotkeyChoice?
    private var rightOptionDown = false
    private var waitForNeutralOption: Bool
    private var suppressedKeyUps: Set<Int> = []

    var active: Bool { held != nil }

    init(shortcuts: DictationShortcuts, optionWasDownAtStart: Bool = false) {
        self.shortcuts = shortcuts
        waitForNeutralOption = optionWasDownAtStart
    }

    mutating func setSessionActive(_ active: Bool) {
        sessionActive = active
    }

    mutating func receive(_ input: HotkeyInput) -> HotkeyTransition {
        switch input {
        case .tapDisabled, .secureInput, .stopped:
            let action: HotkeyAction? = active || sessionActive ? .cancelled : nil
            held = nil
            sessionActive = false
            // Space auto-repeat cannot start a hold, even if its old release went past a disabled tap.
            if reserved?.usesRightOption == false { reserved = nil }
            if case .stopped = input {
                reserved = nil
                suppressedKeyUps.removeAll()
            }
            rightOptionDown = false
            waitForNeutralOption = true
            return .init(action)
        case .flagsChanged(let code, let flags):
            return flagsChanged(code, flags)
        case .keyDown(let code, let flags, let repeating):
            return keyDown(code, flags, repeating: repeating)
        case .keyUp(let code, let flags):
            if suppressedKeyUps.remove(code) != nil { return .init(consume: true) }
            if code == kVK_Space, reserved?.usesRightOption == false {
                reserved = nil
                return finish(.ended, consume: true)
            }
            return recoverOptionRelease(flags) ?? .init()
        }
    }

    private mutating func flagsChanged(_ code: Int, _ flags: CGEventFlags) -> HotkeyTransition {
        if code == kVK_RightOption, reserved?.usesRightOption != false,
           shortcuts.live.usesRightOption || shortcuts.accurate.usesRightOption {
            // The device bits distinguish sides when Left Option stays held.
            let optionSides = flags.rawValue & Self.optionSides
            if waitForNeutralOption {
                let consume = reserved?.usesRightOption == true
                if !flags.contains(.maskAlternate) || (optionSides != 0 && optionSides & Self.rightOption == 0) {
                    clearRightOption()
                }
                return .init(consume: consume)
            }
            rightOptionDown = if optionSides != 0 { optionSides & Self.rightOption != 0 }
                else { flags.contains(.maskAlternate) && !rightOptionDown }
            if !rightOptionDown {
                guard reserved?.usesRightOption == true else { return .init() }
                reserved = nil
                return finish(.ended, consume: true)
            }
            guard reserved == nil, !sessionActive else { return .init() }
            let modifiers = flags.intersection(Self.modifiers).subtracting(.maskAlternate)
            let choice: HotkeyChoice
            if modifiers.isEmpty {
                choice = .rightOption
            } else if modifiers == .maskCommand, flags.rawValue & Self.commandSides == Self.rightCommand {
                choice = .rightCommandOption
            } else {
                return .init()
            }
            return start(choice)
        }

        if let recovered = recoverOptionRelease(flags) { return recovered }
        guard let held else { return .init() }
        let modifiers = flags.intersection(Self.modifiers)
        if held.usesRightOption {
            let others = modifiers.subtracting(.maskAlternate)
            // Releasing Command first keeps Accurate listening until the consumed Option goes up.
            if others.isSubset(of: held.modifiers), flags.rawValue & Self.leftCommand == 0 { return .init() }
            return finish(.cancelled)
        }
        if !modifiers.subtracting(held.modifiers).isEmpty { return finish(.cancelled) }
        return modifiers.isSuperset(of: held.modifiers) ? .init() : finish(.ended)
    }

    private mutating func keyDown(_ code: Int, _ flags: CGEventFlags, repeating: Bool) -> HotkeyTransition {
        if suppressedKeyUps.contains(code) { return .init(consume: true) }
        if code == kVK_Escape, active || sessionActive {
            held = nil
            sessionActive = false
            suppressedKeyUps.insert(code)
            return .init(.cancelled, consume: true)
        }
        if let recovered = recoverOptionRelease(flags) { return recovered }
        if let reserved {
            if code != kVK_Space || reserved.usesRightOption { suppressedKeyUps.insert(code) }
            if code == kVK_Space, !reserved.usesRightOption { return .init(consume: true) }
            return finish(.cancelled, consume: true)
        }
        guard code == kVK_Space, !repeating, !sessionActive else { return .init() }
        let modifiers = flags.intersection(Self.modifiers)
        for choice: HotkeyChoice in [.controlOptionSpace, .controlShiftSpace] where choice.modifiers == modifiers {
            return start(choice)
        }
        return .init()
    }

    private mutating func start(_ choice: HotkeyChoice) -> HotkeyTransition {
        guard let mode = shortcuts.mode(for: choice) else { return .init() }
        held = choice
        reserved = choice
        return .init(.began(mode), consume: true)
    }

    private mutating func finish(_ action: HotkeyAction, consume: Bool = false) -> HotkeyTransition {
        let wasActive = active
        held = nil
        return .init(wasActive ? action : nil, consume: consume)
    }

    private mutating func recoverOptionRelease(_ flags: CGEventFlags) -> HotkeyTransition? {
        guard !flags.contains(.maskAlternate), rightOptionDown || waitForNeutralOption else { return nil }
        let hadOption = reserved?.usesRightOption == true
        clearRightOption()
        return hadOption ? finish(.ended) : nil
    }

    private mutating func clearRightOption() {
        rightOptionDown = false
        waitForNeutralOption = false
        if reserved?.usesRightOption == true { reserved = nil }
    }
}
