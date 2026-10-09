import Foundation
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import HolosTestSupport
import Testing

// SpeakerEditCommand (what `voiceislocal speakers link|me|reject` and every edit do to voices): what it says about
// links and voice samples, and how the samples learned from the meeting follow a change. Helpers come from
// SpeakerEditCommand+EditsTests.swift.

/// A voice extractor that records the turns it is asked about and returns one embedding per turn; `failure` makes it
/// throw instead.
private final class SpeakerCommandVoice: VoiceSampleExtractor {
    let asked = SharedValue<[[String]]>([])
    let failure: String?

    init(failure: String? = nil) { self.failure = failure }

    func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding] {
        asked.update { $0.append(turns.map(\.id)) }
        if let failure { throw HolosError.unavailable(failure) }
        return turns.map {
            TurnEmbedding(turnID: $0.id, speechSeconds: $0.end - $0.start,
                          vector: FloatVector([0.6, 0.8, 0, 0, 0, 0, 0, 0]))
        }
    }
}

private let removedJimNote = "Removed Jim's voice sample from this meeting: the speakers or turns it was learned "
    + "from changed, and it could not be learned again from the new labels."

/// A labelled call (system:S1 has T1 and T3, system:S2 T2 and T4) and a store with Remember voices `remember` and
/// one person, Jim (ID JIM).
private func speakerVoiceSession(_ temp: TemporaryDirectory, remember: Bool = true) async throws
    -> (session: URL, store: SpeakerProfileStore) {
    let store = speakerCommandStore(temp)
    try store.update {
        $0.rememberVoices = remember
        $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim")]
    }
    return (try await SessionFixtures.labelledSession(in: temp.url).session, store)
}

/// Links system:S1 to Jim and learns his voice from it.
private func speakerVoiceLearnJim(_ session: URL, store: SpeakerProfileStore,
                                  voice: SpeakerCommandVoice) async throws {
    let link = try await speakerCommandRun(.link(speakerID: "system:S1", to: .existing(profileID: "JIM"),
                                                 learnVoice: true), session: session, store: store, extractor: voice)
    #expect(link.failure == nil)
    #expect(try store.load().sampleCount == 1)
}

// MARK: - Link and me

@Test(.timeLimit(.minutes(1)))
func linkWithLearnVoiceSaysHowMuchSpeechTheVoiceWasLearnedFrom() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp)
    let voice = SpeakerCommandVoice()
    let run = try await speakerCommandRun(.link(speakerID: "system:S1", to: .existing(profileID: "JIM"),
                                                learnVoice: true), session: session, store: store, extractor: voice)
    #expect(run.failure == nil)
    let sample = try #require(try store.load().profiles.first?.samples.first)
    #expect(run.messages == [
        .output("Linked system:S1 to Jim."),
        .note("Learned Jim's voice from this meeting (\(TimeFormat.duration(sample.speechSeconds)) of speech)."
              + (sample.weak ? " It is short, so it can only give suggestions." : "")),
    ])
    #expect(voice.asked.value == [["T1", "T3"]])
    #expect(run.outcome?.saved == true)
}

@Test(.timeLimit(.minutes(1)))
func linkSaysWhyNoVoiceWasLearned() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp, remember: false)
    let off = try await speakerCommandRun(.link(speakerID: "system:S1", to: .existing(profileID: "JIM"),
                                                learnVoice: true), session: session, store: store,
                                          extractor: SpeakerCommandVoice())
    #expect(off.messages == [
        .output("Linked system:S1 to Jim."),
        .note("Remember voices is off, so no voice was learned. Turn it on with voiceislocal people remember on."),
    ])

    try store.update { $0.rememberVoices = true }
    let noModels = try await speakerCommandRun(.link(speakerID: "system:S2", to: .new(name: "Ana"),
                                                     learnVoice: true), session: session, store: store)
    #expect(noModels.messages == [.output("Linked system:S2 to Ana."), .note(SpeakerEditCommand.modelsMissing)])
    #expect(try store.load().sampleCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func linkWithoutLearnVoiceSaysOnlyTheLink() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp)
    let voice = SpeakerCommandVoice()
    let run = try await speakerCommandRun(.link(speakerID: "system:S1", to: .existing(profileID: "JIM"),
                                                learnVoice: false), session: session, store: store, extractor: voice)
    #expect(run.messages == [.output("Linked system:S1 to Jim.")])
    #expect(voice.asked.value.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aRefusedLinkSaysNothing() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp)
    let journal = SessionFixtures.journalBytes(session)
    let run = try await speakerCommandRun(.link(speakerID: "system:S9", to: .existing(profileID: "JIM"),
                                                learnVoice: false), session: session, store: store)
    #expect(run.outcome == nil)
    #expect(run.messages.isEmpty)
    #expect(SessionFixtures.journalBytes(session) == journal)
}

@Test(.timeLimit(.minutes(1)))
func markSelfLinksTheSpeakerToYou() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp)
    let run = try await speakerCommandRun(.markSelf(speakerID: "system:S2", learnVoice: false), session: session,
                                          store: store)
    let me = try #require(try store.load().profiles.first(where: \.isSelf))
    #expect(run.messages == [.output("Linked system:S2 to \(me.displayName) (you).")])
}

// MARK: - Samples after a change

@Test(.timeLimit(.minutes(1)))
func anEditOfTheTurnsAVoiceWasLearnedFromLearnsItAgain() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp)
    let voice = SpeakerCommandVoice()
    try await speakerVoiceLearnJim(session, store: store, voice: voice)
    let s2 = try speakerCommandName("system:S2", in: session)
    let run = try await speakerCommandRun(.edit([.reassignTurns(turnIDs: ["T3"], to: "system:S2")]),
                                          session: session, store: store, extractor: voice)
    #expect(run.failure == nil)
    #expect(run.messages == [.output("Assigned T3 to \(s2).")])
    #expect(voice.asked.value.last == ["T1"])
    #expect(try store.load().profiles.first?.samples.first?.speakerIDs == ["system:S1"])
}

@Test(.timeLimit(.minutes(1)))
func aVoiceThatCannotBeLearnedAgainIsRemovedAndTheCommandSaysSo() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp)
    try await speakerVoiceLearnJim(session, store: store, voice: SpeakerCommandVoice())
    let s2 = try speakerCommandName("system:S2", in: session)
    // No extractor (the speaker models are gone): the sample can only be removed.
    let run = try await speakerCommandRun(.edit([.reassignTurns(turnIDs: ["T3"], to: "system:S2")]),
                                          session: session, store: store, extractor: nil)
    #expect(run.failure == nil)
    #expect(run.messages == [.output("Assigned T3 to \(s2)."), .note(removedJimNote)])
    #expect(try store.load().sampleCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func aVoiceThatFailsToUpdateLeavesTheChangeSavedAndSaysSo() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp)
    try await speakerVoiceLearnJim(session, store: store, voice: SpeakerCommandVoice())
    let s2 = try speakerCommandName("system:S2", in: session)
    let run = try await speakerCommandRun(.edit([.reassignTurns(turnIDs: ["T3"], to: "system:S2")]),
                                          session: session, store: store,
                                          extractor: SpeakerCommandVoice(failure: "The models broke."))
    #expect(run.messages == [.output("Assigned T3 to \(s2).")])
    #expect(run.failure == "incomplete: The change was saved, but a voice sample learned from this meeting could "
        + "not be updated: The models broke.")
    #expect(try SessionFixtures.view(session).turns.first { $0.id == "T3" }?.speakerID == "system:S2")
    #expect(try store.load().sampleCount == 1, "A failed extraction leaves the sample as it was.")
}

// MARK: - Reject

@Test(.timeLimit(.minutes(1)))
func rejectUnlinksTheSpeakerRemovesTheVoiceAndSaysSo() async throws {
    let temp = try TemporaryDirectory("speaker-voice", permissions: 0o700)
    defer { temp.remove() }
    let (session, store) = try await speakerVoiceSession(temp)
    let voice = SpeakerCommandVoice()
    try await speakerVoiceLearnJim(session, store: store, voice: voice)
    let s1 = try speakerCommandName("system:S1", in: session)
    let run = try await speakerCommandRun(.reject(speakerID: "system:S1", profileID: "JIM"), session: session,
                                          store: store, extractor: voice)
    #expect(run.failure == nil)
    #expect(run.messages == [.output("Marked \(s1) as not Jim."), .note(removedJimNote)])
    #expect(run.outcome?.saved == true)
    #expect(try store.load().sampleCount == 0)

    let journal = SessionFixtures.journalBytes(session)
    let again = try await speakerCommandRun(.reject(speakerID: "system:S1", profileID: "JIM"), session: session,
                                            store: store, extractor: voice)
    #expect(again.messages == [.output("Nothing to change; the speaker labels already look like that.")])
    #expect(again.outcome?.saved == false)
    #expect(SessionFixtures.journalBytes(session) == journal)
}
