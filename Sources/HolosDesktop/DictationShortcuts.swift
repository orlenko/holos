import Carbon
import CoreGraphics

public enum DictationShortcutMode: Sendable {
    case live, accurate
}

public enum HotkeyChoice: String, CaseIterable, Sendable {
    case off
    case rightOption
    case rightCommandOption
    case controlOptionSpace
    case controlShiftSpace

    public var title: String {
        switch self {
        case .off: "Off"
        case .rightOption: "Right Option"
        case .rightCommandOption: "Right Command + Right Option"
        case .controlOptionSpace: "Control–Option–Space"
        case .controlShiftSpace: "Control–Shift–Space"
        }
    }

    public var releaseTitle: String { self == .rightCommandOption ? HotkeyChoice.rightOption.title : title }

    var usesRightOption: Bool { self == .rightOption || self == .rightCommandOption }

    var modifiers: CGEventFlags {
        switch self {
        case .off, .rightOption: []
        case .rightCommandOption: .maskCommand
        case .controlOptionSpace: [.maskControl, .maskAlternate]
        case .controlShiftSpace: [.maskControl, .maskShift]
        }
    }
}

public struct DictationShortcuts: Equatable, Sendable {
    public let live: HotkeyChoice
    public let accurate: HotkeyChoice

    public init(live: HotkeyChoice = .rightOption, accurate: HotkeyChoice = .rightCommandOption) {
        self.live = live
        self.accurate = live == accurate ? .off : accurate
    }

    public subscript(mode: DictationShortcutMode) -> HotkeyChoice {
        mode == .live ? live : accurate
    }

    public func changing(_ mode: DictationShortcutMode, to choice: HotkeyChoice) -> Self? {
        let other = self[mode == .live ? .accurate : .live]
        guard choice == .off || choice != other else { return nil }
        return mode == .live ? .init(live: choice, accurate: other) : .init(live: other, accurate: choice)
    }

    func mode(for choice: HotkeyChoice) -> DictationShortcutMode? {
        guard choice != .off else { return nil }
        if choice == live { return .live }
        return choice == accurate ? .accurate : nil
    }
}

public enum HotkeyAction: Sendable, Equatable {
    case began(DictationShortcutMode)
    case ended
    case cancelled
}
