import HolosCore

/// People who repeatedly share meetings with someone confirmed in the current review.
public enum SpeakerGroupSuggestions {
    /// `people` is in the picker's usual order. It breaks ties after the number of matching anchors and their
    /// average overlap. A pair needs two distinct shared meetings before it contributes.
    public static func rankedIDs(people: [SpeakerProfile], confirmed: Set<String>, present: Set<String>,
                                 sessionID: String) throws -> [String] {
        let anchors = people.compactMap { person -> Set<String>? in
            guard confirmed.contains(person.id), !person.isSelf, person.provisional != true else { return nil }
            let sessions = pastSessions(of: person, excluding: sessionID)
            return sessions.count >= 2 ? sessions : nil
        }
        guard !anchors.isEmpty else { return [] }
        let ranked = try people.enumerated().compactMap { index, person -> Match? in
            try Task.checkCancellation()
            guard !present.contains(person.id), !confirmed.contains(person.id), !person.isSelf,
                  person.recognitionEnabled, person.provisional != true else { return nil }
            let sessions = pastSessions(of: person, excluding: sessionID)
            var overlaps: [Double] = []
            for anchor in anchors {
                let shared = sessions.intersection(anchor).count
                if shared >= 2 {
                    overlaps.append(Double(shared) / Double(sessions.count + anchor.count - shared))
                }
            }
            guard !overlaps.isEmpty else { return nil }
            return Match(id: person.id, anchors: overlaps.count,
                         overlap: overlaps.reduce(0, +) / Double(overlaps.count), order: index)
        }
        return ranked.sorted {
            if $0.anchors != $1.anchors { return $0.anchors > $1.anchors }
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            return $0.order < $1.order
        }.prefix(5).map(\.id)
    }

    private struct Match {
        let id: String
        let anchors: Int
        let overlap: Double
        let order: Int
    }

    private static func pastSessions(of person: SpeakerProfile, excluding sessionID: String) -> Set<String> {
        Set(person.samples.lazy.map(\.sessionID).filter { $0 != sessionID })
    }
}
