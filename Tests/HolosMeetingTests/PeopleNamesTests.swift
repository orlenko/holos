import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// People's names for dictation (docs/design.md "Pauses inside a sentence"): read before each dictation, so a person
// added, renamed or removed counts from the next one.

@Test func peopleNamesFollowThePeopleStore() throws {
    let temp = try TemporaryDirectory("people-names")
    defer { temp.remove() }
    let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("Speakers", isDirectory: true))
    let names = PeopleNames(store: store)
    #expect(names.current().isEmpty)

    try store.update { $0.profiles = [SpeakerProfile(id: "P1", displayName: "Will Archer")] }
    #expect(names.current() == ["Will Archer"])
    #expect(names.current() == ["Will Archer"])

    try store.update {
        $0.profiles = [SpeakerProfile(id: "P1", displayName: "Rose Hale"),
                       SpeakerProfile(id: "P2", displayName: "Grace Lin")]
    }
    #expect(names.current() == ["Grace Lin", "Rose Hale"])

    try store.update { $0.profiles = [] }
    #expect(names.current().isEmpty)
}
