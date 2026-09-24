import Foundation
import Testing
@testable import HolosSpeakers

private func intervals(_ items: (String, Double, Double)...) -> [LabelledInterval] {
    items.map { LabelledInterval(speaker: $0.0, start: $0.1, end: $0.2) }
}

private func near(_ value: Double, _ expected: Double) -> Bool {
    abs(value - expected) < 1e-9
}

// MARK: - DER

@Test func derZeroForIdentical() {
    let reference = intervals(("A", 0, 10), ("B", 10, 20), ("A", 22, 30.5))
    let same = DiarizationScoring.der(reference: reference, hypothesis: reference)
    #expect(same.der == 0)
    #expect(same.missSeconds == 0 && same.falseAlarmSeconds == 0 && same.confusionSeconds == 0)
    #expect(same.mapping == ["A": "A", "B": "B"])
    // Collar 0.25 around 0, 10, 20, 22, and 30.5: scored 0.25–9.75, 10.25–19.75, 22.25–30.25.
    #expect(near(same.referenceSeconds, 27))

    let renamed = reference.map { LabelledInterval(speaker: $0.speaker == "A" ? "S2" : "S1", start: $0.start, end: $0.end) }
    let relabelled = DiarizationScoring.der(reference: reference, hypothesis: renamed)
    #expect(relabelled.der == 0)
    #expect(relabelled.mapping == ["A": "S2", "B": "S1"])
    #expect(relabelled.referenceSpeakers == 2 && relabelled.hypothesisSpeakers == 2)
}

@Test func derCountsConfusionAfterMapping() {
    let score = DiarizationScoring.der(reference: intervals(("A", 0, 10), ("B", 10, 20)),
                                       hypothesis: intervals(("X", 0, 12), ("Y", 12, 20)))
    #expect(score.mapping == ["A": "X", "B": "Y"])
    // 10.25–12 s is B heard as X; 9.75–10.25 s is inside the collar.
    #expect(near(score.confusionSeconds, 1.75))
    #expect(score.missSeconds == 0 && score.falseAlarmSeconds == 0)
    #expect(near(score.referenceSeconds, 19))
    #expect(near(score.der, 1.75 / 19))
}

@Test func collarExcludesBoundary() {
    let reference = intervals(("A", 0, 10), ("B", 10, 20))
    let hypothesis = intervals(("X", 0, 10.2), ("Y", 10.2, 20))
    let collared = DiarizationScoring.der(reference: reference, hypothesis: hypothesis, collar: 0.25)
    #expect(collared.der == 0)
    let exact = DiarizationScoring.der(reference: reference, hypothesis: hypothesis, collar: 0)
    #expect(near(exact.confusionSeconds, 0.2))
    #expect(near(exact.referenceSeconds, 20))
    #expect(near(exact.der, 0.01))
}

@Test func derCountsMissAndFalseAlarm() {
    let score = DiarizationScoring.der(reference: intervals(("A", 0, 10)),
                                       hypothesis: intervals(("X", 0, 8), ("Y", 9, 12)), collar: 0)
    #expect(score.mapping == ["A": "X"])
    #expect(near(score.missSeconds, 1))            // 8–9: nobody in the hypothesis
    #expect(near(score.confusionSeconds, 1))       // 9–10: A heard as Y
    #expect(near(score.falseAlarmSeconds, 2))      // 10–12: Y where the reference is silent
    #expect(near(score.der, 0.4))
}

@Test func derCountsOverlappingReferenceSpeakers() {
    let score = DiarizationScoring.der(reference: intervals(("A", 0, 10), ("B", 5, 10)),
                                       hypothesis: intervals(("X", 0, 10)), collar: 0)
    #expect(score.mapping == ["A": "X"])
    #expect(near(score.referenceSeconds, 15))
    #expect(near(score.missSeconds, 5))
    #expect(score.confusionSeconds == 0)
    #expect(near(score.der, 5.0 / 15))
}

@Test func hungarianMappingBeatsGreedy() {
    // Shared time: A–X 10 s, A–Y 9 s, B–X 9 s. Greedy would take A→X (10 s correct); the optimum is A→Y, B→X.
    let score = DiarizationScoring.der(reference: intervals(("A", 0, 19), ("B", 19, 28)),
                                       hypothesis: intervals(("X", 0, 10), ("Y", 10, 19), ("X", 19, 28)), collar: 0)
    #expect(score.mapping == ["A": "Y", "B": "X"])
    #expect(near(score.confusionSeconds, 10))
    #expect(near(score.der, 10.0 / 28))
}

@Test func moreReferenceThanHypothesisSpeakers() {
    let score = DiarizationScoring.der(reference: intervals(("A", 0, 10), ("B", 10, 20), ("C", 20, 35)),
                                       hypothesis: intervals(("X", 0, 10), ("Y", 10, 35)), collar: 0)
    #expect(score.mapping == ["A": "X", "C": "Y"])
    #expect(near(score.confusionSeconds, 10))
    #expect(near(score.der, 10.0 / 35))
}

@Test func manySpeakersUseGreedyMapping() {
    let names = (0..<25).map { String(format: "%02d", $0) }
    let reference = names.enumerated().map { LabelledInterval(speaker: "R\($1)", start: Double($0) * 10, end: Double($0) * 10 + 10) }
    let hypothesis = reference.map { LabelledInterval(speaker: "H" + $0.speaker.dropFirst(), start: $0.start, end: $0.end) }
    let score = DiarizationScoring.der(reference: reference, hypothesis: hypothesis)
    #expect(score.der == 0)
    #expect(score.mapping.count == 25)
    #expect(score.mapping.allSatisfy { $0.key.dropFirst() == $0.value.dropFirst() })
    #expect(score.referenceSpeakers == 25 && score.hypothesisSpeakers == 25)
}

@Test func invalidIntervalsAreIgnored() {
    let reference = intervals(("A", .nan, 1), ("B", 5, 5), ("C", 3, 2), ("D", 0, .infinity), ("E", 0, 1))
    let score = DiarizationScoring.der(reference: reference, hypothesis: [])
    #expect(score.referenceSpeakers == 1 && score.hypothesisSpeakers == 0)
    #expect(near(score.referenceSeconds, 0.5))      // collars around 0 and 1
    #expect(near(score.missSeconds, 0.5))
    #expect(score.der == 1)
    #expect(score.mapping.isEmpty)
}

@Test func emptyReferenceScores() {
    let nothing = DiarizationScoring.der(reference: [], hypothesis: [])
    #expect(nothing == DiarizationScore(referenceSeconds: 0, missSeconds: 0, falseAlarmSeconds: 0, confusionSeconds: 0,
                                        der: 0, mapping: [:], referenceSpeakers: 0, hypothesisSpeakers: 0))
    let onlyHypothesis = DiarizationScoring.der(reference: [], hypothesis: intervals(("X", 0, 1)))
    #expect(near(onlyHypothesis.falseAlarmSeconds, 1))
    #expect(onlyHypothesis.der == 1)
}

@Test func extremeTimesDoNotTrap() {
    let reference = intervals(("A", -1e300, 5), ("B", 5, 1e300))
    let score = DiarizationScoring.der(reference: reference, hypothesis: reference)
    #expect(score.der == 0)
    #expect(score.mapping == ["A": "A", "B": "B"])
}

@Test func scoreAndIntervalsPrintNoSpeakerLabels() {
    let reference = intervals(("Private Ref", 0, 10))
    let score = DiarizationScoring.der(reference: reference, hypothesis: intervals(("Private Hyp", 0, 10)))
    #expect(score.mapping == ["Private Ref": "Private Hyp"])
    var dumped = ""
    dump(score, to: &dumped)
    dump(reference, to: &dumped)
    for text in [String(describing: score), String(reflecting: score), "\(score)", "\(reference)",
                 String(reflecting: reference), dumped] {
        #expect(!text.contains("Private"))
    }
    #expect(String(describing: score).contains("mappedPairs: 1"))
}

// MARK: - Agreement

@Test func agreementComparesOnlyWhereBothSidesSpeak() {
    // Otter-like reference turns cover the silence the hypothesis leaves out.
    let result = DiarizationScoring.agreement(reference: intervals(("A", 0, 10), ("B", 10, 20)),
                                              hypothesis: intervals(("X", 1, 4), ("Y", 12, 15), ("X", 16, 18)))
    #expect(result.mapping == ["A": "X", "B": "Y"])
    #expect(near(result.comparedSeconds, 8))
    #expect(near(result.confusion, 0.25))           // 16–18 s: B heard as X
}

@Test func agreementCountsAFrameAsAgreeingWhenTheMappedSpeakerIsAmongOverlaps() {
    let result = DiarizationScoring.agreement(reference: intervals(("A", 0, 10)),
                                              hypothesis: intervals(("X", 0, 10), ("Y", 4, 6)), collar: 0)
    #expect(result.mapping == ["A": "X"])
    #expect(near(result.comparedSeconds, 10))
    #expect(result.confusion == 0)
}

@Test func agreementWithNothingComparedIsZero() {
    let result = DiarizationScoring.agreement(reference: intervals(("A", 0, 10)), hypothesis: [])
    #expect(result.confusion == 0 && result.comparedSeconds == 0 && result.mapping.isEmpty)
}

// MARK: - Assignment

@Test func hungarianMatchesBruteForce() {
    var numbers = SeededNumbers(seed: 7)
    for _ in 0..<300 {
        let rows = numbers.next(in: 1...5)
        let columns = numbers.next(in: rows...6)
        let cost = (0..<rows).map { _ in (0..<columns).map { _ in numbers.next(in: -50...50) } }
        let assignment = FrameTimeline.hungarian(cost: cost)
        #expect(Set(assignment).count == rows)
        #expect(assignment.allSatisfy { (0..<columns).contains($0) })
        let total = assignment.enumerated().reduce(0) { $0 + cost[$1.offset][$1.element] }
        #expect(total == bruteForceMinimum(cost))
    }
}

private func bruteForceMinimum(_ cost: [[Int]]) -> Int {
    func search(_ row: Int, _ used: Set<Int>) -> Int {
        guard row < cost.count else { return 0 }
        var best = Int.max
        for column in cost[row].indices where !used.contains(column) {
            best = min(best, cost[row][column] + search(row + 1, used.union([column])))
        }
        return best
    }
    return search(0, [])
}

/// A small deterministic generator (SplitMix64), so failures reproduce.
private struct SeededNumbers {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return range.lowerBound + Int(z % UInt64(range.count))
    }
}
