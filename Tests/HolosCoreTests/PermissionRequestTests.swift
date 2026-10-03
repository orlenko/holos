import Foundation
import Testing
@testable import HolosCore

@Test func aPermissionIsAskedOnceThenOpensSettings() throws {
    let suite = "permission-request-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for permission in PrivacyPermission.allCases {
        #expect(PermissionRequest.next(for: permission, asked: PermissionRequest.asked(in: defaults)) == .askSystem)
    }
    PermissionRequest.recordAsked(.accessibility, in: defaults)
    PermissionRequest.recordAsked(.accessibility, in: defaults)
    let asked = PermissionRequest.asked(in: defaults)
    #expect(asked == ["accessibility"])
    #expect(PermissionRequest.next(for: .accessibility, asked: asked) == .openSettings)
    // Each permission has its own first ask.
    #expect(PermissionRequest.next(for: .screenAndSystemAudio, asked: asked) == .askSystem)
    #expect(PermissionRequest.next(for: .inputMonitoring, asked: asked) == .askSystem)
}
