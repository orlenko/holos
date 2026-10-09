import Testing
@testable import HolosAppModel

@Test func theAppearanceFollowsMacOSUntilChosen() {
    #expect(AppearanceChoice(saved: nil) == .system)
    #expect(AppearanceChoice(saved: "sepia") == .system)
    #expect(AppearanceChoice(saved: "light") == .light)
    #expect(AppearanceChoice(saved: "dark") == .dark)
    #expect(AppearanceChoice(saved: "system") == .system)
    #expect(AppearanceChoice.allCases.map(\.rawValue) == ["system", "light", "dark"])
}
