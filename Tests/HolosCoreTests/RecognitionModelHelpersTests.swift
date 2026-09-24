import Foundation
import HolosCore
import Testing

// The PR10 helpers on the recognition types (Sources/HolosCore/RecognitionModelHelpers.swift), kept out of the frozen
// contract file SpeakerModels.swift (docs/meeting-design.md §3.0).

@Test func thresholdProblemNamesEachBrokenRule() {
    func thresholds(likely: Double = 0.2, margin: Double = 0.1, possible: Double = 0.4,
                    minimum: Double = 20) -> RecognitionThresholds {
        RecognitionThresholds(likelyMaxDistance: likely, likelyMinMargin: margin, possibleMaxDistance: possible,
                              minSampleSeconds: minimum)
    }
    #expect(thresholds().problem == nil)
    #expect(thresholds(likely: -Double.ulpOfOne, possible: -Double.ulpOfOne / 2).problem == nil)
    #expect(thresholds(likely: .nan).problem == "a threshold is not a finite number")
    #expect(thresholds(possible: 2).problem == "a distance threshold is out of range")
    #expect(thresholds(likely: 0.5, possible: 0.4).problem
            == "the automatic-name threshold is above the suggestion threshold")
    #expect(thresholds(margin: 2.5).problem == "the margin is out of range")
    #expect(thresholds(minimum: -1).problem == "the minimum sample length is negative")
}

@Test func removeProfilesScrubsEveryFieldThatNamesAPerson() {
    let model = EmbeddingModelID(id: "fake", revision: "1")
    var result = RecognitionResult(
        runID: "RUN", embeddingModel: model,
        thresholds: RecognitionThresholds(likelyMaxDistance: 0, likelyMinMargin: 0.1, possibleMaxDistance: 0.4,
                                          minSampleSeconds: 20),
        matches: [SpeakerMatch(speakerID: "mic:S1", profileID: "JIM", profileName: "Jim", distance: 0.2,
                               tier: .possible),
                  SpeakerMatch(speakerID: "mic:S2", profileID: "MARIA", profileName: "Maria", distance: 0.3,
                               tier: .possible)],
        mergeSuggestions: [MergeSuggestion(speakerIDs: ["mic:S1", "mic:S3"], profileID: "JIM")],
        skippedProfiles: ["JIM", "SAM"])
    #expect(result.removeProfiles { $0 == "JIM" })
    #expect(result.matches.map(\.profileID) == ["MARIA"])
    #expect(result.mergeSuggestions.isEmpty)
    #expect(result.skippedProfiles == ["SAM"])
    #expect(!result.removeProfiles { $0 == "JIM" }, "Nothing left to remove.")
}

@Test func retargetingProfilesJoinsWhatTheMergeMadeTheSamePerson() throws {
    let model = EmbeddingModelID(id: "fake", revision: "1")
    let thresholds = RecognitionThresholds(likelyMaxDistance: 0.2, likelyMinMargin: 0.1, possibleMaxDistance: 0.4,
                                           minSampleSeconds: 20)
    var result = RecognitionResult(
        runID: "R1", embeddingModel: model, thresholds: thresholds,
        matches: [SpeakerMatch(speakerID: "mic:S1", profileID: "A", profileName: "Al", distance: 0.30,
                               tier: .possible),
                  SpeakerMatch(speakerID: "mic:S1", profileID: "B", profileName: "Bea", distance: 0.10,
                               tier: .likely),
                  SpeakerMatch(speakerID: "mic:S2", profileID: "A", profileName: "Al", distance: 0.25,
                               tier: .possible),
                  SpeakerMatch(speakerID: "mic:S2", profileID: "C", profileName: "Cy", distance: 0.35,
                               tier: .possible)],
        mergeSuggestions: [MergeSuggestion(speakerIDs: ["mic:S1"], profileID: "A"),
                           MergeSuggestion(speakerIDs: ["mic:S1", "mic:S3"], profileID: "B")],
        skippedProfiles: ["A", "D", "B"])

    let changed = result.retargetProfiles(["A": "B"])
    #expect(changed)

    // One person per speaker: the nearer match wins where both named the same person after the merge.
    #expect(result.matches.map { "\($0.speakerID)/\($0.profileID)/\($0.distance)" }
            == ["mic:S1/B/0.1", "mic:S2/B/0.25", "mic:S2/C/0.35"])
    #expect(result.mergeSuggestions.count == 1)
    #expect(result.mergeSuggestions.first?.profileID == "B")
    #expect(result.mergeSuggestions.first?.speakerIDs == ["mic:S1", "mic:S3"])
    #expect(result.skippedProfiles == ["B", "D"])
    let again = result.retargetProfiles(["A": "B"])
    #expect(!again, "Nothing left to point anywhere: repeating it changes nothing.")
    let empty = result.retargetProfiles([:])
    #expect(!empty)
}
