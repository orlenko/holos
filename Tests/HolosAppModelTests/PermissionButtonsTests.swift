import Testing
@testable import HolosAppModel

@Test func permissionButtonsEachDoOneThing() {
    // Not granted: Allow… only asks macOS; System Settings… only opens the page.
    let missing = PermissionButtons.forPermission(granted: false)
    #expect(missing.primary == .init(title: "Allow…", step: .ask))
    #expect(missing.secondary == .init(title: "System Settings…", step: .openSettings))
    // Granted: nothing to ask; one button opens the page.
    let granted = PermissionButtons.forPermission(granted: true)
    #expect(granted.primary == .init(title: "Open Settings", step: .openSettings))
    #expect(granted.secondary == nil)
}
