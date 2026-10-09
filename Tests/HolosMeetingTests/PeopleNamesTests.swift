import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Synchronization
import Testing

// People's names for dictation (docs/design.md "Pauses inside a sentence"): read in the background, never on the
// caller's thread, so a person added, renamed or removed counts from a later dictation.

@Test func peopleNamesFollowThePeopleStore() async throws {
    let temp = try TemporaryDirectory("people-names")
    defer { temp.remove() }
    let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("Speakers", isDirectory: true))
    let names = PeopleNames(store: store)
    #expect(await names.refreshed().isEmpty)

    // Names are read without the voice samples, from a store that has some.
    let sample = VoiceprintSample(sessionID: "S1", sessionName: "Earlier meeting", speakerIDs: ["mic:S1"],
                                  speechSeconds: 60, embedding: FloatVector([0.6, 0.8]), condition: .room, weak: false)
    try store.update {
        $0.profiles = [SpeakerProfile(id: "P1", displayName: "Will Archer",
                                      embeddingModel: DiarizationEngineInfo.fake.embeddingModel, samples: [sample])]
    }
    #expect(await names.refreshed() == ["Will Archer"])
    #expect(names.current() == ["Will Archer"])

    try store.update {
        $0.profiles = [SpeakerProfile(id: "P1", displayName: "Rose Hale"),
                       SpeakerProfile(id: "P2", displayName: "Grace Lin")]
    }
    #expect(await names.refreshed() == ["Grace Lin", "Rose Hale"])

    try store.update { $0.profiles = [] }
    #expect(await names.refreshed().isEmpty)
}

@Test func peopleNamesNeverWaitForASlowStore() async {
    // A store whose read does not end until the test lets it, and whose file changes when the test says.
    let gate = DispatchSemaphore(value: 0)
    let stored = Mutex((stamp: Int64(1), names: ["Will Archer"]))
    let reads = Mutex(0)
    let names = PeopleNames(stamp: { [stored.withLock { $0.stamp }] }, read: {
        reads.withLock { $0 += 1 }
        gate.wait()
        return stored.withLock { $0.names }
    })
    // The first dictation starts while the store is still being read: it gets no names, at once.
    #expect(names.current().isEmpty)
    #expect(names.current().isEmpty)
    gate.signal()
    await names.settled()
    // The next one has them; an unchanged store is not read again.
    #expect(names.current() == ["Will Archer"])
    await names.settled()
    #expect(reads.withLock { $0 } == 1)

    // People changed: the dictation that sees the change keeps the names it had, the one after gets the new ones.
    stored.withLock { $0 = (2, ["Rose Hale"]) }
    #expect(names.current() == ["Will Archer"])
    gate.signal()
    await names.settled()
    #expect(names.current() == ["Rose Hale"])
    #expect(reads.withLock { $0 } == 2)
}
