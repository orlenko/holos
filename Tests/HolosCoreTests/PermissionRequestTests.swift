import Testing
@testable import HolosCore

@Test func openSettingsDoesOneThingPerClick() {
    // Not granted: ask macOS (this also re-adds a removed entry).
    #expect(PermissionRequest.asks(granted: false))
    // Its prompt took the focus: the prompt leads to the page, so the page is not opened as well.
    #expect(!PermissionRequest.opensSettings(granted: false, stillActiveAfterAsking: false))
    // No prompt came (macOS shows it once per entry): open the page.
    #expect(PermissionRequest.opensSettings(granted: false, stillActiveAfterAsking: true))
    // Granted: nothing to ask; open the page to change it.
    #expect(!PermissionRequest.asks(granted: true))
    #expect(PermissionRequest.opensSettings(granted: true, stillActiveAfterAsking: true))
}
