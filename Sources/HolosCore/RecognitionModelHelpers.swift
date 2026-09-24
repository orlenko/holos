import Foundation

// Helpers PR10 adds to the recognition types of the frozen contract file SpeakerModels.swift (docs/meeting-design.md
// §3.0 allows only new optional fields and new constants there, so these live in an extension here).

extension RecognitionThresholds {
    /// Why these thresholds cannot be used, or nil: every value is finite; both distances lie in -1 ..< 2 (a cosine
    /// distance is 0 … 2, a zero-norm vector's is 2 and must never match, and calibration may place a threshold just
    /// below 0 so that nothing is admitted); `likelyMaxDistance ≤ possibleMaxDistance`; the margin is 0 … 2; the
    /// minimum sample length is not negative.
    public var problem: String? {
        guard [likelyMaxDistance, likelyMinMargin, possibleMaxDistance, minSampleSeconds].allSatisfy(\.isFinite) else {
            return "a threshold is not a finite number"
        }
        guard (-1..<2).contains(likelyMaxDistance), (-1..<2).contains(possibleMaxDistance) else {
            return "a distance threshold is out of range"
        }
        guard likelyMaxDistance <= possibleMaxDistance else {
            return "the automatic-name threshold is above the suggestion threshold"
        }
        guard (0...2).contains(likelyMinMargin) else { return "the margin is out of range" }
        guard minSampleSeconds >= 0 else { return "the minimum sample length is negative" }
        return nil
    }
}

extension RecognitionResult {
    /// Removes every reference to the people `drop` selects: their matches, their merge suggestions, and their
    /// entries in `skippedProfiles` (the only fields that hold profile IDs). Every place that removes people from a
    /// result uses this, so a field added later is scrubbed everywhere at once. Returns whether anything was removed.
    @discardableResult
    public mutating func removeProfiles(where drop: (String) -> Bool) -> Bool {
        let before = (matches.count, mergeSuggestions.count, skippedProfiles.count)
        matches.removeAll { drop($0.profileID) }
        mergeSuggestions.removeAll { drop($0.profileID) }
        skippedProfiles.removeAll(where: drop)
        return before != (matches.count, mergeSuggestions.count, skippedProfiles.count)
    }
}
