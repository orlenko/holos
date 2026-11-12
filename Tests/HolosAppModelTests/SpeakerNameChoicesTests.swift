import Testing
@testable import HolosAppModel

/// Invented names.
struct SpeakerNameChoicesTests {
    @Test func thisMeetingComesFirstAndEachPersonIsNamedOnce() {
        #expect(SpeakerNameChoices.choices(inMeeting: ["Sam", "sam", " Kim "], known: ["Robin", "SAM", ""])
            == ["Sam", "Kim", "Robin"])
    }
}
