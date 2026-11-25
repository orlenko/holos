import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage
import HolosTestSupport
import Testing

@Test(.timeLimit(.minutes(1))) @MainActor
func reviewSpeakerGroupsFollowConfirmedLinksUndoAndVoicePrivacy() async throws {
    let temp = try TemporaryDirectory("speaker-groups", permissions: 0o700)
    defer { temp.remove() }
    let fixture = try await SessionFixtures.labelledSession(in: temp.url, speakers: ["S1", "S2"], duration: 30)
    let store = SpeakerProfileStore(directory: temp.url.appendingPathComponent("people"))
    let model = DiarizationEngineInfo.fake.embeddingModel
    try store.update {
        $0.profiles = [groupPerson("anchor", model: model), groupPerson("companion", model: model)]
    }
    try SessionArchive.withSpeakerLock(at: fixture.session) {
        try SessionSpeakerStore.writeRecognition(
            RecognitionResult(runID: fixture.run.id, embeddingModel: model, thresholds: SpeakerRecognizer.defaultThresholds,
                              matches: [SpeakerMatch(speakerID: "system:S1", profileID: "anchor", profileName: "anchor",
                                                     distance: 0.1, tier: .likely)]),
            session: fixture.session)
    }
    let review = try await ReviewSession(session: fixture.session, profiles: store, maintenance: nil)
    review.learnVoices = false
    #expect(review.projection.speakers.first?.isAutomatic == true)
    #expect(review.suggestedAssignPeople().isEmpty)

    try await review.link(speakerID: "system:S1", to: .existing(profileID: "anchor"))
    #expect(await eventually { review.suggestedAssignPeople() == ["companion"] })
    try await review.undo()
    #expect(review.suggestedAssignPeople().isEmpty)
    try await review.link(speakerID: "system:S1", to: .existing(profileID: "anchor"))
    #expect(await eventually { review.suggestedAssignPeople() == ["companion"] })

    try store.update { $0.rememberVoices = false }
    await review.reload()
    #expect(review.suggestedAssignPeople().isEmpty)
    try store.update { $0.rememberVoices = true }
    await review.reload()
    #expect(await eventually { review.suggestedAssignPeople() == ["companion"] })

    try store.appendForgetRecord(ForgetRecord(kind: .profile, profileID: "companion"))
    await review.reload()
    #expect(review.suggestedAssignPeople().isEmpty)
    await review.close()
}

private func groupPerson(_ id: String, model: EmbeddingModelID) -> SpeakerProfile {
    let samples = ["earlier-one", "earlier-two"].map {
        VoiceprintSample(sessionID: $0, sessionName: "Fixture", speakerIDs: ["system:S1"], speechSeconds: 15,
                         embedding: FloatVector([1, 0]), condition: .call, weak: false)
    }
    return SpeakerProfile(id: id, displayName: id, embeddingModel: model, samples: samples)
}
