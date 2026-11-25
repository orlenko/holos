import Carbon
import CoreGraphics
import Testing
@testable import HolosDesktop

@Test func rightOptionTracksPhysicalKeyWithLeftOptionHeld() {
    var state = HotkeyReducer(shortcuts: .init(accurate: .off))
    let option: CGEventFlags = [.maskAlternate]
    #expect(state.receive(.flagsChanged(code: Int(kVK_Option), flags: option)).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began(.live))
    #expect(state.receive(.flagsChanged(code: Int(kVK_Option), flags: option)).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == .ended)
    #expect(!state.active)
}

@Test func controlOptionSpaceConsumesRepeatAndReleaseOnce() {
    var state = HotkeyReducer(shortcuts: .init(live: .controlOptionSpace, accurate: .off))
    let chord: CGEventFlags = [.maskControl, .maskAlternate]
    let down = state.receive(.keyDown(code: Int(kVK_Space), flags: chord))
    #expect(down.action == .began(.live) && down.consume)
    let repeated = state.receive(.keyDown(code: Int(kVK_Space), flags: chord))
    #expect(repeated.action == nil && repeated.consume)
    let up = state.receive(.keyUp(code: Int(kVK_Space), flags: chord))
    #expect(up.action == .ended && up.consume)
    #expect(state.receive(.keyUp(code: Int(kVK_Space), flags: chord)).action == nil)
}

@Test func escapeAndUnrelatedTypingCancelOnce() {
    var state = HotkeyReducer(shortcuts: .init(accurate: .off))
    let option: CGEventFlags = [.maskAlternate]
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began(.live))
    let letter = state.receive(.keyDown(code: Int(kVK_ANSI_A), flags: option))
    #expect(letter.action == .cancelled && letter.consume)
    #expect(state.receive(.keyUp(code: Int(kVK_ANSI_A), flags: option)).consume)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began(.live))
    let escape = state.receive(.keyDown(code: Int(kVK_Escape), flags: option))
    #expect(escape.action == .cancelled && escape.consume)
    #expect(state.receive(.keyUp(code: Int(kVK_Escape), flags: option)).consume)
}

@Test func disabledTapRequiresNeutralBeforeRestart() {
    var state = HotkeyReducer(shortcuts: .init(accurate: .off))
    let option: CGEventFlags = [.maskAlternate]
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began(.live))
    #expect(state.receive(.tapDisabled).action == .cancelled)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began(.live))
}

@Test func escapeCancelsAfterHotkeyReleaseDuringFinalization() {
    var state = HotkeyReducer(shortcuts: .init(accurate: .off))
    let option: CGEventFlags = [.maskAlternate]
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began(.live))
    state.setSessionActive(true)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == .ended)
    let escape = state.receive(.keyDown(code: Int(kVK_Escape), flags: []))
    #expect(escape.action == .cancelled && escape.consume)
    #expect(state.receive(.keyDown(code: Int(kVK_Escape), flags: [])).consume)
    #expect(state.receive(.keyUp(code: Int(kVK_Escape), flags: [])).consume)
    #expect(state.receive(.keyDown(code: Int(kVK_Escape), flags: [])).action == nil)
    #expect(!state.receive(.keyDown(code: Int(kVK_Escape), flags: [])).consume)
}

@Test func rightOptionWithAnotherModifierDoesNotBegin() {
    var state = HotkeyReducer(shortcuts: .init(accurate: .off))
    let chord: CGEventFlags = [.maskAlternate, .maskControl]
    let down = state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: chord))
    #expect(down.action == nil && !down.consume)
    #expect(state.receive(.flagsChanged(code: Int(kVK_Control), flags: [.maskAlternate])).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [.maskAlternate])).action == .began(.live))
}

@Test func lostRightOptionReleaseEndsOnceOnNextUnmodifiedKey() {
    var state = HotkeyReducer(shortcuts: .init(accurate: .off))
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [.maskAlternate])).action == .began(.live))
    let next = state.receive(.keyDown(code: Int(kVK_ANSI_A), flags: []))
    #expect(next.action == .ended)
    #expect(!next.consume)
    #expect(state.receive(.keyUp(code: Int(kVK_ANSI_A), flags: [])).action == nil)
}

@Test func defaultHoldStartsExactlyTheModeChosenAtRightOptionDown() {
    var state = HotkeyReducer(shortcuts: .init())
    let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    let chord = rightCommand.union(.maskAlternate)
    let command = state.receive(.flagsChanged(code: kVK_RightCommand, flags: rightCommand))
    #expect(command.action == nil && !command.consume)
    let accurate = state.receive(.flagsChanged(code: kVK_RightOption, flags: chord))
    #expect(accurate.action == .began(.accurate) && accurate.consume)
    #expect(state.receive(.flagsChanged(code: kVK_RightCommand, flags: .maskAlternate)).action == nil)
    let release = state.receive(.flagsChanged(code: kVK_RightOption, flags: []))
    #expect(release.action == .ended && release.consume)
    #expect(state.receive(.flagsChanged(code: kVK_RightOption, flags: .maskAlternate)).action == .began(.live))
    #expect(state.receive(.flagsChanged(code: kVK_RightCommand, flags: chord)).action == .cancelled)
    #expect(state.receive(.flagsChanged(code: kVK_RightOption, flags: rightCommand)).action == nil)
}

@Test func unboundOptionCombinationsReachTheOtherApp() {
    var state = HotkeyReducer(shortcuts: .init(live: .off))
    let plain = state.receive(.flagsChanged(code: kVK_RightOption, flags: .maskAlternate))
    #expect(plain.action == nil && !plain.consume)
    #expect(!state.receive(.flagsChanged(code: kVK_RightOption, flags: [])).consume)

    let leftCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
    let leftChord = state.receive(.flagsChanged(code: kVK_RightOption, flags: leftCommand.union(.maskAlternate)))
    #expect(leftChord.action == nil && !leftChord.consume)
    #expect(!state.receive(.flagsChanged(code: kVK_RightOption, flags: leftCommand)).consume)
}

@Test func customBindingCanUseEitherModeAndCannotBeAssignedTwice() throws {
    let shortcuts = try #require(DictationShortcuts(live: .controlOptionSpace).changing(.accurate, to: .controlShiftSpace))
    #expect(shortcuts.changing(.live, to: .controlShiftSpace) == nil)
    #expect(shortcuts.changing(.accurate, to: .off)?.live == .controlOptionSpace)
    var state = HotkeyReducer(shortcuts: shortcuts)
    let fast: CGEventFlags = [.maskControl, .maskAlternate]
    let smart: CGEventFlags = [.maskControl, .maskShift]
    #expect(state.receive(.keyDown(code: kVK_Space, flags: fast)).action == .began(.live))
    #expect(state.receive(.keyUp(code: kVK_Space, flags: fast)).action == .ended)
    state.setSessionActive(true)
    #expect(state.receive(.keyDown(code: kVK_Space, flags: smart)).action == nil)
    state.setSessionActive(false)
    #expect(state.receive(.keyDown(code: kVK_Space, flags: smart)).action == .began(.accurate))
    #expect(state.receive(.keyUp(code: kVK_Space, flags: smart)).action == .ended)
}

@Test func spaceChordRecoversWhenItsReleaseWentPastADisabledTap() {
    var state = HotkeyReducer(shortcuts: .init(live: .controlOptionSpace))
    let chord: CGEventFlags = [.maskControl, .maskAlternate]
    #expect(state.receive(.keyDown(code: kVK_Space, flags: chord)).action == .began(.live))
    #expect(state.receive(.tapDisabled).action == .cancelled)
    #expect(state.receive(.keyDown(code: kVK_Space, flags: chord, repeating: true)).action == nil)
    #expect(!state.receive(.keyDown(code: kVK_ANSI_A, flags: [])).consume)
    #expect(state.receive(.keyDown(code: kVK_Space, flags: chord)).action == .began(.live))
}

@Test func releasingRightOptionEndsASpaceChordThatRequiresIt() {
    var state = HotkeyReducer(shortcuts: .init(live: .controlOptionSpace))
    let chord = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | 0x40)
    #expect(!state.receive(.flagsChanged(code: kVK_RightOption, flags: chord)).consume)
    #expect(state.receive(.keyDown(code: kVK_Space, flags: chord)).action == .began(.live))
    let optionUp = state.receive(.flagsChanged(code: kVK_RightOption, flags: .maskControl))
    #expect(optionUp.action == .ended && !optionUp.consume)
    let spaceUp = state.receive(.keyUp(code: kVK_Space, flags: .maskControl))
    #expect(spaceUp.action == nil && spaceUp.consume)
}
