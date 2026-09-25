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

    /// Points every reference to a person in `to` at the person they were merged into (their `to` value): their
    /// matches, their merge suggestions, and their `skippedProfiles` entries. A speaker that then has two matches of
    /// one person keeps the nearer one (the nearer distance, then the stronger tier), a merge suggestion keeps the
    /// speakers of both, and `skippedProfiles` keeps one entry per person; the order of what was there is otherwise
    /// kept. The names are left as they were: the projection shows the person's current one. Returns whether
    /// anything changed.
    @discardableResult
    public mutating func retargetProfiles(_ to: [String: String]) -> Bool {
        guard !to.isEmpty else { return false }
        let before = self
        var kept: [SpeakerMatch] = []
        for var match in matches {
            match.profileID = to[match.profileID] ?? match.profileID
            if let at = kept.firstIndex(where: { $0.speakerID == match.speakerID && $0.profileID == match.profileID }) {
                // Nearer first, then the stronger tier: an automatic name beats a suggestion at the same distance,
                // so `likely` sorts before `possible` and must therefore rank lower here.
                if (match.distance, match.tier == .likely ? 0 : 1)
                    < (kept[at].distance, kept[at].tier == .likely ? 0 : 1) {
                    kept[at] = match
                }
            } else {
                kept.append(match)
            }
        }
        matches = kept
        var suggestions: [MergeSuggestion] = []
        for var suggestion in mergeSuggestions {
            suggestion.profileID = to[suggestion.profileID] ?? suggestion.profileID
            if let at = suggestions.firstIndex(where: { $0.profileID == suggestion.profileID }) {
                var speakers = suggestions[at].speakerIDs
                speakers += suggestion.speakerIDs.filter { !speakers.contains($0) }
                suggestions[at].speakerIDs = speakers
            } else {
                suggestions.append(suggestion)
            }
        }
        mergeSuggestions = suggestions
        var skipped: [String] = []
        for id in skippedProfiles.map({ to[$0] ?? $0 }) where !skipped.contains(id) { skipped.append(id) }
        skippedProfiles = skipped
        return self != before
    }
}
