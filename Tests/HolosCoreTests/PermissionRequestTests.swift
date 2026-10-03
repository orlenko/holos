import Testing
@testable import HolosCore

@Test func openSettingsDoesOneThingOnTheFirstClick() {
    // First click for a permission not granted: only ask (macOS's prompt leads to the page; asking adds the entry).
    #expect(PermissionRequest.forClick(granted: false, clicksBefore: 0) == .init(asks: true, opensSettings: false))
    // A later click: ask again (re-adds a removed entry silently) and open the page.
    #expect(PermissionRequest.forClick(granted: false, clicksBefore: 1) == .init(asks: true, opensSettings: true))
    #expect(PermissionRequest.forClick(granted: false, clicksBefore: 5) == .init(asks: true, opensSettings: true))
    // Granted: nothing to ask; open the page.
    #expect(PermissionRequest.forClick(granted: true, clicksBefore: 0) == .init(asks: false, opensSettings: true))
}
