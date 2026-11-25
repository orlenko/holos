import HolosCore
import HolosSpeakers
import Testing

@Test func speakerGroupsNeedDistinctEarlierMeetingsWithSomeoneOtherThanSelf() throws {
    let people = [
        person("host", ["A", "B", "C"], isSelf: true),
        person("anchor", ["A", "B", "current"]),
        person("regular", ["A", "B"]),
        person("single", ["A", "A", "current"]),
        person("other-circle", ["B", "C"]),
        person("already-shown", ["A", "B"]),
        person("disabled", ["A", "B"], enabled: false),
        person("unlinked-draft", ["A", "B"], provisional: true),
    ]
    #expect(try SpeakerGroupSuggestions.rankedIDs(people: people, confirmed: ["host"], present: [],
                                                  sessionID: "current").isEmpty)
    #expect(try SpeakerGroupSuggestions.rankedIDs(people: people, confirmed: ["host", "anchor"],
                                                  present: ["already-shown"], sessionID: "current") == ["regular"])
}

@Test func speakerGroupsRankByAnchorCountThenOverlapThenPickerOrder() throws {
    let people = [
        person("anchor-one", ["A", "B"]), person("anchor-two", ["C", "D"]),
        person("lower-overlap", ["A", "B", "E"]),
        person("recent", ["A", "B"]), person("less-recent", ["A", "B"]),
        person("both", ["A", "B", "C", "D", "E"]),
        person("remaining", ["A", "B", "F"]), person("below-limit", ["A", "B", "G"]),
    ]
    #expect(try SpeakerGroupSuggestions.rankedIDs(people: people, confirmed: ["anchor-one", "anchor-two"],
                                                  present: [], sessionID: "current") ==
            ["both", "recent", "less-recent", "lower-overlap", "remaining"])
}

private func person(_ id: String, _ sessions: [String], isSelf: Bool = false, enabled: Bool = true,
                    provisional: Bool? = nil) -> SpeakerProfile {
    let samples = sessions.map {
        VoiceprintSample(sessionID: $0, sessionName: "Fixture", speakerIDs: [], speechSeconds: 15,
                         embedding: FloatVector([1, 0]), condition: .call, weak: false)
    }
    return SpeakerProfile(id: id, displayName: id, isSelf: isSelf, recognitionEnabled: enabled,
                          samples: samples, provisional: provisional)
}
