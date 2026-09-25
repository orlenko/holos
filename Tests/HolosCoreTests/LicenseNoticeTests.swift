import Testing
@testable import HolosCore

@Test func releaseTagAcceptsOnlyVersionTags() {
    #expect(LicenseNotice.releaseTag("v1.0.0") == "v1.0.0")
    #expect(LicenseNotice.releaseTag("v12") == "v12")
    #expect(LicenseNotice.releaseTag(nil) == nil)
    #expect(LicenseNotice.releaseTag("") == nil)
    #expect(LicenseNotice.releaseTag("v") == nil)
    #expect(LicenseNotice.releaseTag("1.0.0") == nil)
    #expect(LicenseNotice.releaseTag("v1..0") == nil)
    #expect(LicenseNotice.releaseTag("v1.0.") == nil)
    #expect(LicenseNotice.releaseTag("v1.0-beta") == nil)
    #expect(LicenseNotice.releaseTag("v1/../main") == nil)
    #expect(LicenseNotice.releaseTag("v١.٢") == nil)
}

@Test func noticeLinksTheReleaseTagWhenKnown() {
    let text = LicenseNotice.text(bundleName: "VoiceIsLocal.app", sourceTag: "v1.2.0")
    #expect(text.contains("VoiceIsLocal.app/Contents/Resources/LICENSE.txt"))
    #expect(text.contains("VoiceIsLocal.app/Contents/Resources/TRADEMARKS.md"))
    #expect(text.contains("https://github.com/orlenko/holos/tree/v1.2.0"))
    #expect(text.contains("https://github.com/orlenko/holos/blob/v1.2.0/TRADEMARKS.md"))
    #expect(!text.contains("/main/"))
    #expect(text.contains("Bjola Software Inc. owns the trademarks and the icon copyright"))
    #expect(text.contains("Copyright © 2026 Vlad Orlenko."))
}

@Test func noticeFallsBackToMainWithoutATag() {
    for tag in [nil, "", "main", "v1.0-rc1"] as [String?] {
        let text = LicenseNotice.text(bundleName: "Voice is Local.app", sourceTag: tag)
        #expect(text.contains("Voice is Local.app/Contents/Resources/TRADEMARKS.md"))
        #expect(text.contains("Source code: https://github.com/orlenko/holos."))
        #expect(text.contains("https://github.com/orlenko/holos/blob/main/TRADEMARKS.md"))
    }
}
