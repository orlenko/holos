import Foundation
import Testing
import HolosCore
@testable import HolosSpeakers

// RecognitionCalibration (docs/meeting-design.md §4.10 "Calibration", `holos people calibrate`).

private let model = EmbeddingModelID(id: "fake", revision: "1")

/// A unit vector in the plane of axes 0 and `other`, at angle `degrees` from axis 0.
private func vector(_ degrees: Double, other: Int = 1) -> [Float] {
    var values = [Float](repeating: 0, count: 8)
    values[0] = Float(cos(degrees * .pi / 180))
    values[other] = Float(sin(degrees * .pi / 180))
    return values
}

private func sample(_ session: String, _ values: [Float]) -> VoiceprintSample {
    VoiceprintSample(sessionID: session, sessionName: "Meeting", speakerIDs: ["system:S1"], speechSeconds: 60,
                     embedding: FloatVector(values), condition: .call, weak: false)
}

private func person(_ id: String, _ samples: [VoiceprintSample]) -> SpeakerProfile {
    SpeakerProfile(id: id, displayName: id, embeddingModel: model, samples: samples)
}

@Test func calibrationNeedsThreeMeetings() {
    // Two meetings, two people with samples from both: not enough meetings.
    let two = SpeakerProfileDatabase(rememberVoices: true, profiles: [
        person("JIM", [sample("M1", vector(0)), sample("M2", vector(5))]),
        person("MARIA", [sample("M1", vector(80, other: 2)), sample("M2", vector(85, other: 2))]),
    ])
    let measured = RecognitionCalibration.distances(database: two, model: model)
    #expect(measured.meetings == 2)
    #expect(measured.repeatedPeople == 2)
    #expect(measured.samePerson.count == 2)
    #expect(measured.differentPerson.count == 4)
    #expect(RecognitionCalibration.calibration(database: two) == nil, "--apply is refused.")

    // Three meetings but only one person with samples from two of them: still refused.
    let onePerson = SpeakerProfileDatabase(rememberVoices: true, profiles: [
        person("JIM", [sample("M1", vector(0)), sample("M2", vector(5))]),
        person("MARIA", [sample("M3", vector(80, other: 2))]),
    ])
    #expect(RecognitionCalibration.calibration(database: onePerson) == nil)

    // Three meetings and two repeated people: allowed.
    let enough = SpeakerProfileDatabase(rememberVoices: true, profiles: [
        person("JIM", [sample("M1", vector(0)), sample("M2", vector(5)), sample("M3", vector(8))]),
        person("MARIA", [sample("M1", vector(80, other: 2)), sample("M3", vector(85, other: 2))]),
    ])
    let calibrated = RecognitionCalibration.calibration(database: enough)
    #expect(calibrated != nil)
    #expect(calibrated?.distances.samePerson.count == 4)
    #expect(calibrated?.model == model)
    #expect(calibrated?.distances.differentPerson.count == 6)
}

@Test func calibrationPercentiles() throws {
    // 100 different-person distances 0.01 … 1.00: at most 1 pair may be admitted for likely, 5 for possible.
    let different = (1...100).map { Double($0) / 100 }
    let thresholds = try #require(RecognitionCalibration.thresholds(differentPerson: different.shuffled()))
    #expect(abs(thresholds.likelyMaxDistance - 0.015) < 1e-12)
    #expect(abs(thresholds.possibleMaxDistance - 0.055) < 1e-12)
    #expect(different.filter { $0 <= thresholds.likelyMaxDistance }.count == 1)
    #expect(different.filter { $0 <= thresholds.possibleMaxDistance }.count == 5)
    #expect(thresholds.likelyMinMargin == SpeakerRecognizer.defaultThresholds.likelyMinMargin)
    #expect(thresholds.minSampleSeconds == SpeakerRecognizer.defaultThresholds.minSampleSeconds)

    // docs/speaker-evaluation.md: 37 different-person pairs from 0.421, 0.444 → the 5 % threshold is about 0.43.
    let measured = [0.421, 0.444] + (0..<35).map { 0.5 + Double($0) / 100 }
    #expect(abs(RecognitionCalibration.admitting(measured, rate: 0.05) - 0.4325) < 1e-12)

    // Fewer than 100 pairs: nothing may be admitted at 1 %, so likely sits halfway below the smallest.
    #expect(abs(RecognitionCalibration.admitting([0.4, 0.6], rate: 0.01) - 0.2) < 1e-12)
    // A tie at the boundary is refused together.
    #expect(RecognitionCalibration.admitting([0.1, 0.1, 0.1, 0.5], rate: 0.5) == 0.05)
    #expect(RecognitionCalibration.thresholds(differentPerson: []) == nil)
}

@Test func zeroBudgetRefusesZeroDistances() throws {
    // Two separate people with an identical sample: distance 0. Nothing may be admitted, not even that pair.
    for distances in [[0.0, 0.6], [0.0, 0.0, 0.7], [0.0]] {
        let threshold = RecognitionCalibration.admitting(distances, rate: 0.01)
        #expect(threshold < 0)
        #expect(distances.filter { $0 <= threshold }.isEmpty)
    }
    // A tie at 0 that the budget would otherwise split is refused together.
    let tie = RecognitionCalibration.admitting([0, 0, 0.3, 0.5], rate: 0.25)
    #expect([0, 0, 0.3, 0.5].filter { $0 <= tie }.isEmpty)
    let thresholds = try #require(RecognitionCalibration.thresholds(differentPerson: [0, 0.2, 0.4]))
    #expect(thresholds.likelyMaxDistance < 0)
    #expect(thresholds.possibleMaxDistance < 0)
    // Adjacent values: the threshold stays below the first refused one.
    let low = 0.3
    let adjacent = RecognitionCalibration.admitting([low, low.nextUp], rate: 0.5)
    #expect(adjacent < low.nextUp)
    #expect(adjacent >= low)
}

@Test func calibrationComparesOnlyOneModelAndDifferentMeetings() {
    var other = person("OTHER", [sample("M1", vector(0)), sample("M2", vector(1))])
    other.embeddingModel = EmbeddingModelID(id: "other", revision: "2")
    let database = SpeakerProfileDatabase(rememberVoices: true, profiles: [
        person("JIM", [sample("M1", vector(0)), sample("M2", vector(10))]),
        other,
    ])
    let measured = RecognitionCalibration.distances(database: database, model: model)
    #expect(measured.differentPerson.isEmpty, "Samples of another model are never compared.")
    #expect(measured.samePerson.count == 1)
    #expect(RecognitionCalibration.distances(database: database, model: other.embeddingModel!).samePerson.count == 1)
    #expect(RecognitionCalibration.models(database) == [model, other.embeddingModel!].sorted { $0.id < $1.id })
}

@Test func calibrationIsRefusedWithSamplesOfSeveralModels() throws {
    // Enough data for the first model on its own…
    var database = SpeakerProfileDatabase(rememberVoices: true, profiles: [
        person("JIM", [sample("M1", vector(0)), sample("M2", vector(5)), sample("M3", vector(8))]),
        person("MARIA", [sample("M1", vector(80, other: 2)), sample("M3", vector(85, other: 2))]),
    ])
    let calibration = try #require(RecognitionCalibration.calibration(database: database))
    #expect(calibration.model == model)
    #expect(calibration.thresholds.problem == nil)
    // …but a person with samples of another model makes the pooled thresholds meaningless for both: refused.
    var other = person("SAM", [sample("M4", vector(40, other: 3))])
    other.embeddingModel = EmbeddingModelID(id: "other", revision: "2")
    database.profiles.append(other)
    #expect(RecognitionCalibration.models(database).count == 2)
    #expect(RecognitionCalibration.calibration(database: database) == nil)
}

@Test func percentileInterpolates() {
    #expect(RecognitionCalibration.percentile([], 0.5) == nil)
    #expect(RecognitionCalibration.percentile([3, 1, 2], 0.5) == 2)
    #expect(RecognitionCalibration.percentile([0, 10], 0.25) == 2.5)
    #expect(RecognitionCalibration.percentile([0, 10], 1) == 10)
}
