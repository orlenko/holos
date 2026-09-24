import Foundation
import Testing
@testable import HolosSpeakers

@Test func cosineDistanceMeasuresAngle() {
    #expect(abs(VectorMath.cosineDistance([1, 0], [2, 0])) < 1e-12)
    #expect(abs(VectorMath.cosineDistance([1, 0], [0, 3]) - 1) < 1e-12)
    #expect(abs(VectorMath.cosineDistance([1, 0], [-1, 0]) - 2) < 1e-12)
    #expect(abs(VectorMath.cosineDistance([1, 1], [1, 0]) - (1 - 1 / 2.0.squareRoot())) < 1e-7)
}

@Test func cosineDistanceIsTwoForZeroNormOrSizeMismatch() {
    #expect(VectorMath.cosineDistance([0, 0], [1, 0]) == 2)
    #expect(VectorMath.cosineDistance([1, 0], [0, 0]) == 2)
    #expect(VectorMath.cosineDistance([1, 0], [1, 0, 0]) == 2)
    #expect(VectorMath.cosineDistance([], []) == 2)
    #expect(VectorMath.cosineDistance([.nan, 0], [1, 0]) == 2)
}

@Test func normalizedHasUnitLengthAndKeepsZeroVectors() {
    let unit = VectorMath.normalized([3, 4])
    #expect(abs(unit[0] - 0.6) < 1e-6)
    #expect(abs(unit[1] - 0.8) < 1e-6)
    #expect(VectorMath.normalized([0, 0]) == [0, 0])
    #expect(VectorMath.normalized([]) == [])
}

@Test func weightedMeanWeighsEachVector() throws {
    let mean = try #require(VectorMath.weightedMean([([1, 0], 3), ([0, 1], 1)]))
    #expect(abs(mean[0] - 0.75) < 1e-6)
    #expect(abs(mean[1] - 0.25) < 1e-6)
    // Entries without a positive weight contribute nothing.
    #expect(VectorMath.weightedMean([([1, 0], 2), ([0, 1], 0), ([5, 5], -1)]) == [1, 0])
}

@Test func weightedMeanIsNilWithoutUsableInput() {
    #expect(VectorMath.weightedMean([]) == nil)
    #expect(VectorMath.weightedMean([([1, 0], 0)]) == nil)
    #expect(VectorMath.weightedMean([([1, 0], 1), ([1, 0, 0], 1)]) == nil)
    #expect(VectorMath.weightedMean([([], 1)]) == nil)
}
