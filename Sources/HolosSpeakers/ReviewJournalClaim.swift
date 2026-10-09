import HolosCore

/// Which lines a reread of the speaker journal adds are the review window's own (`ReviewSession.adopt`,
/// docs/meeting-design.md §5.10). The new lines (those whose IDs `known` lacks) are grouped by batch, in the order
/// their first lines appear. Each matcher, in order, claims the newest group not yet claimed whose every line has one
/// of `sources` and which the matcher accepts. Lines no matcher claimed are changes made elsewhere.
public enum ReviewJournalClaim {
    public struct Outcome: Equatable, Sendable {
        /// One entry per matcher, in order: the group it claimed, nil when none.
        public var batches: [[SpeakerEdit]?]
        /// How many lines the reread adds.
        public var added: Int
        /// How many of them the matchers claimed.
        public var claimed: Int

        public init(batches: [[SpeakerEdit]?], added: Int, claimed: Int) {
            self.batches = batches
            self.added = added
            self.claimed = claimed
        }

        /// Lines added that no matcher claimed: changes made elsewhere.
        public var unclaimed: Int { added - claimed }
    }

    /// The claim of `fresh` (the journal as reread) against `known` (the IDs of the lines read before), for
    /// `matchers` in order.
    public static func claim(_ matchers: [([SpeakerEdit]) -> Bool], known: Set<String>, fresh: [SpeakerEdit],
                             sources: Set<String>) -> Outcome {
        let added = fresh.filter { !known.contains($0.id) }
        var groups: [[SpeakerEdit]] = []
        var keys: [String: Int] = [:]
        for edit in added {
            let key = edit.batchID ?? edit.id
            if let index = keys[key] {
                groups[index].append(edit)
            } else {
                keys[key] = groups.count
                groups.append([edit])
            }
        }
        var taken = Set<Int>()
        let batches = matchers.map { matching -> [SpeakerEdit]? in
            guard let index = groups.indices.last(where: { index in
                !taken.contains(index) && groups[index].allSatisfy { sources.contains($0.source) }
                    && matching(groups[index])
            }) else { return nil }
            taken.insert(index)
            return groups[index]
        }
        return Outcome(batches: batches, added: added.count, claimed: taken.reduce(0) { $0 + groups[$1].count })
    }
}
