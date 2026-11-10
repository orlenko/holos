import HolosCore
import Testing

@Test func levelGrowsWithLoudnessAndStaysInRange() {
    #expect(DictationLevel.level(of: []) == 0)
    #expect(DictationLevel.level(of: [0, 0, 0]) == 0)
    #expect(DictationLevel.level(of: [Float](repeating: 0.0001, count: 100)) == 0, "Room noise moves nothing.")
    let quiet = DictationLevel.level(of: [Float](repeating: 0.01, count: 100))
    let speech = DictationLevel.level(of: [Float](repeating: 0.05, count: 100))
    #expect(quiet > 0 && speech > quiet && speech < 1)
    #expect(DictationLevel.level(of: [Float](repeating: 1, count: 100)) == 1)
    #expect(DictationLevel.level(of: [.nan, .infinity]) == 0)
}
