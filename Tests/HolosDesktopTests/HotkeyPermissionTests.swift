import Testing
@testable import HolosDesktop

@Test func theHotkeyTapIsGatedOnAccessibilityAlone() {
    // Input Monitoring is not an input: the active tap is authorised by Accessibility.
    #expect(HotkeyStartError.gate(accessibility: true) == nil)
    #expect(HotkeyStartError.gate(accessibility: false) == .accessibilityNotGranted)
}

@Test func aRefusedTapNamesInputMonitoringOnlyWithAccessibilityGranted() {
    #expect(HotkeyStartError.tapFailure(accessibility: true) == .tapRefused)
    #expect(HotkeyStartError.tapFailure(accessibility: false) == .accessibilityNotGranted)
    let missing = HotkeyStartError.accessibilityNotGranted.localizedDescription
    #expect(missing.contains("Accessibility"))
    #expect(!missing.contains("Input Monitoring"))
    let refused = HotkeyStartError.tapRefused.localizedDescription
    #expect(refused.contains("Accessibility") && refused.contains("Input Monitoring"))
}
