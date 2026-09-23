import Carbon
import CoreGraphics
import Testing
@testable import HolosDesktop

@Test func rightOptionTracksPhysicalKeyWithLeftOptionHeld() {
    var state = HotkeyReducer(shortcut: .rightOption)
    let option: CGEventFlags = [.maskAlternate]
    #expect(state.receive(.flagsChanged(code: Int(kVK_Option), flags: option)).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began)
    #expect(state.receive(.flagsChanged(code: Int(kVK_Option), flags: option)).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == .ended)
    #expect(!state.active)
}

@Test func controlOptionSpaceConsumesRepeatAndReleaseOnce() {
    var state = HotkeyReducer(shortcut: .controlOptionSpace)
    let chord: CGEventFlags = [.maskControl, .maskAlternate]
    let down = state.receive(.keyDown(code: Int(kVK_Space), flags: chord))
    #expect(down.action == .began && down.consume)
    let repeated = state.receive(.keyDown(code: Int(kVK_Space), flags: chord))
    #expect(repeated.action == nil && repeated.consume)
    let up = state.receive(.keyUp(code: Int(kVK_Space), flags: chord))
    #expect(up.action == .ended && up.consume)
    #expect(state.receive(.keyUp(code: Int(kVK_Space), flags: chord)).action == nil)
}

@Test func escapeAndUnrelatedTypingCancelOnce() {
    var state = HotkeyReducer(shortcut: .rightOption)
    let option: CGEventFlags = [.maskAlternate]
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began)
    let letter = state.receive(.keyDown(code: Int(kVK_ANSI_A), flags: option))
    #expect(letter.action == .cancelled && letter.consume)
    #expect(state.receive(.keyUp(code: Int(kVK_ANSI_A), flags: option)).consume)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began)
    let escape = state.receive(.keyDown(code: Int(kVK_Escape), flags: option))
    #expect(escape.action == .cancelled && escape.consume)
    #expect(state.receive(.keyUp(code: Int(kVK_Escape), flags: option)).consume)
}

@Test func disabledTapRequiresNeutralBeforeRestart() {
    var state = HotkeyReducer(shortcut: .rightOption)
    let option: CGEventFlags = [.maskAlternate]
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began)
    #expect(state.receive(.tapDisabled).action == .cancelled)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began)
}

@Test func escapeCancelsAfterHotkeyReleaseDuringFinalization() {
    var state = HotkeyReducer(shortcut: .rightOption)
    let option: CGEventFlags = [.maskAlternate]
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: option)).action == .began)
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
    var state = HotkeyReducer(shortcut: .rightOption)
    let chord: CGEventFlags = [.maskAlternate, .maskControl]
    let down = state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: chord))
    #expect(down.action == nil && down.consume)
    #expect(state.receive(.flagsChanged(code: Int(kVK_Control), flags: [.maskAlternate])).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [])).action == nil)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [.maskAlternate])).action == .began)
}

@Test func lostRightOptionReleaseEndsOnceOnNextUnmodifiedKey() {
    var state = HotkeyReducer(shortcut: .rightOption)
    #expect(state.receive(.flagsChanged(code: Int(kVK_RightOption), flags: [.maskAlternate])).action == .began)
    let next = state.receive(.keyDown(code: Int(kVK_ANSI_A), flags: []))
    #expect(next.action == .ended)
    #expect(!next.consume)
    #expect(state.receive(.keyUp(code: Int(kVK_ANSI_A), flags: [])).action == nil)
}
