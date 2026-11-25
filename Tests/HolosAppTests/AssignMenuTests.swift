import AppKit
import HolosCore
import Testing
@testable import HolosApp

@Test @MainActor func assignMenuHighlightsCompanionsAndPreservesDuplicateNamesAndTargets() throws {
    let people = [SpeakerProfile(id: "stranger", displayName: "Morgan"),
                  SpeakerProfile(id: "regular", displayName: "Morgan"),
                  SpeakerProfile(id: "self", displayName: "Sky", isSelf: true)]
    let items = AssignMenu.items(speakers: [], people: people, suggested: ["regular", "unknown-profile"])
    #expect(items.filter { !$0.isSeparatorItem }.map(\.title) ==
            ["Often here together", "Morgan", "People", "Morgan", "Sky (you)", "Unknown", "New Speaker…"])
    let matching = items.filter { $0.title == "Morgan" }
    #expect(matching.compactMap { ($0.representedObject as? AssignChoice)?.kind } ==
            [.target(.person(profileID: "regular")), .target(.person(profileID: "stranger"))])
    #expect(AssignMenu.prioritizedPeople(people, suggested: ["regular"]).map(\.id) == ["regular", "stranger", "self"])
    #expect(AssignMenu.items(speakers: [], people: people).allSatisfy { $0.title != "Often here together" })
}
