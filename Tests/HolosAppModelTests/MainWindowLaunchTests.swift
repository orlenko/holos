import Testing
@testable import HolosAppModel

private let sections: Set<String> = ["history", "corrections", "meetings", "people", "reading", "settings"]

@Test func theWindowOpensAtLaunchUntilTheSettingIsTurnedOff() {
    #expect(MainWindowLaunch.opensWindow(saved: nil))
    #expect(MainWindowLaunch.opensWindow(saved: true))
    #expect(!MainWindowLaunch.opensWindow(saved: false))
}

@Test func aLaunchOpensTheLastSectionOrHistory() {
    #expect(MainWindowLaunch.section(lastUsed: nil, known: sections, meetingRecording: false) == "history")
    #expect(MainWindowLaunch.section(lastUsed: "reading", known: sections, meetingRecording: false) == "reading")
    #expect(MainWindowLaunch.section(lastUsed: "settings", known: sections, meetingRecording: false) == "settings")
    // A section a later build added and this one does not know.
    #expect(MainWindowLaunch.section(lastUsed: "notes", known: sections, meetingRecording: false) == "history")
}

@Test func aMeetingRecordingAtLaunchOpensMeetings() {
    #expect(MainWindowLaunch.section(lastUsed: "reading", known: sections, meetingRecording: true) == "meetings")
    #expect(MainWindowLaunch.section(lastUsed: nil, known: sections, meetingRecording: true) == "meetings")
}
