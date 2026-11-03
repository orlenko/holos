import Carbon
import CoreGraphics
import Foundation
import Testing
@testable import HolosDesktop

private func exampleLayout() -> [Character: KeyboardStroke] {
    KeyboardTyping.keyMap { code, shifted in
        switch (Int(code), shifted) {
        case (kVK_ANSI_A, false): "a"
        case (kVK_ANSI_A, true): "A"
        case (kVK_ANSI_B, false): "b"
        case (kVK_ANSI_B, true): "B"
        case (kVK_ANSI_Slash, false): "/"
        case (kVK_ANSI_Slash, true): "?"
        case (kVK_Space, _): " "
        default: nil
        }
    }
}

@Test func physicalTypingUsesDifferentKeysAndShiftForDifferentCharacters() throws {
    let strokes = try #require(KeyboardTyping.strokes(for: "Ab? /", in: exampleLayout()))
    #expect(strokes.map(\.keyCode) == [CGKeyCode(kVK_ANSI_A), CGKeyCode(kVK_ANSI_B),
                                     CGKeyCode(kVK_ANSI_Slash), CGKeyCode(kVK_Space), CGKeyCode(kVK_ANSI_Slash)])
    #expect(strokes.map(\.flags) == [.maskShift, [], .maskShift, [], []])
}

@Test func physicalTypingFollowsTheLayoutRatherThanAssumingUSLetters() throws {
    let map = KeyboardTyping.keyMap { code, shifted in
        code == kVK_ANSI_A ? (shifted ? "Ф" : "ф") : nil
    }
    let strokes = try #require(KeyboardTyping.strokes(for: "фФ", in: map))
    #expect(strokes.map(\.keyCode) == [0, 0])
    #expect(strokes.map(\.flags) == [[], .maskShift])
    #expect(KeyboardTyping.strokes(for: "a", in: map) == nil)
}

@Test func untypableTextRefusesTheWholeChunk() {
    let map = exampleLayout()
    #expect(KeyboardTyping.strokes(for: "ab👩🏽‍💻", in: map) == nil)
    #expect(KeyboardTyping.strokes(for: "ab’", in: map) == nil)
    #expect(KeyboardTyping.strokes(for: "ab", in: [:]) == nil)
}

@Test func physicalTypingCannotPlanReturnTabOrControlCharacters() {
    let map: [Character: KeyboardStroke] = [
        "\n": KeyboardStroke(keyCode: CGKeyCode(kVK_Return), flags: []),
        "\t": KeyboardStroke(keyCode: CGKeyCode(kVK_Tab), flags: []),
        "\u{1B}": KeyboardStroke(keyCode: CGKeyCode(kVK_Escape), flags: []),
    ]
    for text in ["", "\n", "\t", "\u{1B}"] {
        #expect(KeyboardTyping.strokes(for: text, in: map) == nil)
    }
    #expect(!KeyboardTyping.printableKeyCodes.contains(CGKeyCode(kVK_Return)))
    #expect(!KeyboardTyping.printableKeyCodes.contains(CGKeyCode(kVK_Tab)))
    #expect(!KeyboardTyping.printableKeyCodes.contains(CGKeyCode(kVK_Escape)))
}

@Test func layoutMappingRejectsEmptyControlAndMultipleCharacterTranslations() {
    let map = KeyboardTyping.keyMap { code, _ in
        switch code {
        case 0: ""
        case 1: "\r"
        case 2: "ab"
        default: nil
        }
    }
    #expect(map.isEmpty)
}

@Test func generatedEventsCarryMatchingPhysicalKeysUnicodeAndSyntheticMarker() throws {
    let stroke = KeyboardStroke(keyCode: CGKeyCode(kVK_ANSI_Slash), flags: .maskShift)
    let events = try #require(stroke.events(for: "?", source: CGEventSource(stateID: .privateState), marker: 42))
    #expect(events.map(\.type) == [.keyDown, .keyUp])
    for event in events {
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == kVK_ANSI_Slash)
        #expect(event.flags == .maskShift)
        #expect(event.getIntegerValueField(.eventSourceUserData) == 42)
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length,
                                       unicodeString: &units)
        #expect(String(utf16CodeUnits: units, count: length) == "?")
    }
}

@Test func aRemoteScreenSeesShiftPressedAndReleasedAroundTheKey() throws {
    let source = CGEventSource(stateID: .privateState)
    let shifted = KeyboardStroke(keyCode: CGKeyCode(kVK_ANSI_A), flags: .maskShift)
    let events = try #require(shifted.events(for: "A", source: source, marker: 42, pressingShift: true))
    #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
    #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [kVK_Shift, kVK_ANSI_A, kVK_ANSI_A, kVK_Shift].map(Int64.init))
    #expect(events.map { $0.flags.contains(.maskShift) } == [true, true, true, false])
    #expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 42 })

    // An unshifted key presses nothing else, and Shift is only pressed when asked for.
    let plain = KeyboardStroke(keyCode: CGKeyCode(kVK_ANSI_A), flags: [])
    #expect(try #require(plain.events(for: "a", source: source, marker: 42, pressingShift: true)).map(\.type) == [.keyDown, .keyUp])
    #expect(try #require(shifted.events(for: "A", source: source, marker: 42)).map(\.type) == [.keyDown, .keyUp])
}

@Test func leftOptionIsToldFromRightOptionByItsDeviceBit() {
    // The flags macOS reports with only Right Option held, measured on a real keyboard.
    #expect(!KeyboardTyping.leftOption(in: CGEventFlags(rawValue: 0x80140)))
    #expect(KeyboardTyping.leftOption(in: CGEventFlags(rawValue: 0x80120)), "Left Option alone.")
    #expect(KeyboardTyping.leftOption(in: CGEventFlags(rawValue: 0x80160)), "Both.")
    #expect(!KeyboardTyping.leftOption(in: CGEventFlags(rawValue: 0x100)), "Nothing held.")
    // Holding only the hold-to-talk key never refuses typing, which is what lets words go out mid-hold.
    let right = CGEventFlags(rawValue: 0x80140)
    #expect(!KeyboardTyping.heldKeysReachRemote(right, leftOption: KeyboardTyping.leftOption(in: right), shortcut: .rightOption))
}

@Test func keysHeldForTheOtherComputerAreTold() {
    // Right Option alone never reaches the remote screen when it is the hold-to-talk key: the hotkey tap consumes it.
    #expect(!KeyboardTyping.heldKeysReachRemote([], leftOption: false, shortcut: .rightOption))
    #expect(!KeyboardTyping.heldKeysReachRemote(.maskAlternate, leftOption: false, shortcut: .rightOption))
    // Left Option does, also beside Right Option.
    #expect(KeyboardTyping.heldKeysReachRemote(.maskAlternate, leftOption: true, shortcut: .rightOption))
    // With Control-Option-Space every Option counts, also Right Option left held after Control is released.
    #expect(KeyboardTyping.heldKeysReachRemote(.maskAlternate, leftOption: false, shortcut: .controlOptionSpace))
    #expect(KeyboardTyping.heldKeysReachRemote([.maskControl, .maskAlternate], leftOption: false, shortcut: .controlOptionSpace))
    #expect(!KeyboardTyping.heldKeysReachRemote([], leftOption: false, shortcut: .controlOptionSpace))
    for shortcut in HotkeyChoice.allCases {
        #expect(KeyboardTyping.heldKeysReachRemote(.maskCommand, leftOption: false, shortcut: shortcut))
        #expect(KeyboardTyping.heldKeysReachRemote(.maskShift, leftOption: false, shortcut: shortcut))
    }
}

@Test @MainActor func screenSharingIsTypedIntoAsARemoteScreen() {
    #expect(KeystrokeTarget.terminalBundleIDs.contains("com.apple.ScreenSharing"))
    #expect(KeystrokeTarget.remoteScreenBundleIDs.isSubset(of: KeystrokeTarget.terminalBundleIDs))
}

@Test @MainActor func macOSUSLayoutProducesRealLetterAndPunctuationKeysWithoutChangingTheInputSource() throws {
    let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
    let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue())
    #expect(CFArrayGetCount(sources) > 0)
    guard CFArrayGetCount(sources) > 0 else { return }
    let source = unsafeBitCast(CFArrayGetValueAtIndex(sources, 0), to: TISInputSource.self)
    let map = try #require(KeyboardTyping.keyMap(for: source, keyboardType: 40))
    let strokes = try #require(KeyboardTyping.strokes(for: "Ab? /", in: map))
    #expect(strokes.map(\.keyCode) == [CGKeyCode(kVK_ANSI_A), CGKeyCode(kVK_ANSI_B),
                                     CGKeyCode(kVK_ANSI_Slash), CGKeyCode(kVK_Space), CGKeyCode(kVK_ANSI_Slash)])
    #expect(strokes.map(\.flags) == [.maskShift, [], .maskShift, [], []])
    #expect(KeyboardTyping.strokes(for: "é", in: map) == nil)
}
