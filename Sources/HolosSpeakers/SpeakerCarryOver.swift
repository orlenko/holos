import Foundation
import HolosCore

/// Carries speaker-level labels (names, profile links, rejections) and the time kept out of voice learning from the
/// projection of a replaced head to a new run, so human edits survive relabelling (docs/contracts.md;
/// docs/meeting-design.md §4.9). Other turn-level edits stay in the journal under the old run and are only counted. Pure; the caller appends the actions with
/// `source: "carry"`, the new run as `baseRunID`, and one batch ID.
public enum SpeakerCarryOver {
    public struct Result: Sendable, Equatable {
        /// rename / linkProfile / rejectProfile actions on the new run's speakers, then at most one
        /// excludeFromEnrollment of the new run's turns.
        public var actions: [SpeakerEditAction]
        /// Old speakers with a name, link, or rejection that matched nothing (IDs only).
        public var unmatchedSpeakers: [String]
        /// Turn-level edits (reassign, split, new speaker) and merges that are not carried.
        public var droppedTurnEdits: Int

        public init(actions: [SpeakerEditAction] = [], unmatchedSpeakers: [String] = [], droppedTurnEdits: Int = 0) {
            self.actions = actions; self.unmatchedSpeakers = unmatchedSpeakers; self.droppedTurnEdits = droppedTurnEdits
        }
    }

    /// Maps each old projected speaker with an explicit name, link, or rejection to the new run's speaker with
    /// the most shared speech time on the same track (one-to-one, greedy by shared seconds, ties by ID),
    /// accepted only when the shared time is at least 50% of the smaller of the two talk times.
    ///
    /// Details:
    /// - Old speech is the old projection's turns (edits applied, so reassigned and merged turns count for the
    ///   speaker the user chose); new speech is the new run's machine turns. Shared time is the overlap of the
    ///   two speakers' turn intervals, summed over tracks, and must be positive. Talk times are
    ///   `ProjectedSpeaker.talkSeconds` and the sum of the new speaker's turn durations.
    /// - Greedy runs over every pair with shared time, largest shared time first, ties by old then new speaker ID.
    ///   A pair whose old speaker is decided or whose new speaker is taken is skipped, so an old speaker can take
    ///   its next choice when its best one went to someone else. The first pair left for an old speaker decides
    ///   it: mapped when the pair passes the 50% rule, unmatched otherwise (a smaller speaker further down is not
    ///   tried, and the failing new speaker stays free for others).
    /// - Stored speakers are matched one by one (`SpeakerProjection.unjoined`); one shown joined with same-named ones
    ///   carries the group's identity (`identities`), and is not reported unmatched when another of the group was
    ///   matched.
    /// - Actions follow the old projection's speaker order; per speaker: `rename` (explicit name), `linkProfile`,
    ///   then one `rejectProfile` per rejection in the order they were made. Automatic (recognized) names are not
    ///   carried: the new run gets its own recognition.
    /// - `droppedTurnEdits` counts the old projection's applied turn-level edits and merges; reverted and stale
    ///   ones never took effect and are not counted. A merge only shapes which new speaker the name maps to.
    public static func carry(from shown: SpeakerProjection, to new: DiarizationRun) -> Result {
        // Each stored speaker as itself (`SpeakerProjection.unjoined`), so each one's speech finds its own new
        // speaker; one shown joined with same-named ones carries the identity of the group it is shown as.
        let old = shown.unjoined
        let identities = identities(old: old, shown: shown)
        let labelled = old.speakers.filter { identities[$0.id]?.isEmpty == false }
        let labelledIDs = Set(labelled.map(\.id))

        var oldRanges: [String: [String: [SecondsRange]]] = [:]
        for turn in old.turns {
            guard let speakerID = turn.speakerID, labelledIDs.contains(speakerID) else { continue }
            oldRanges[speakerID, default: [:]][turn.track, default: []].append(SecondsRange(start: turn.start, end: turn.end))
        }
        var newRanges: [String: [String: [SecondsRange]]] = [:]
        var newTalk: [String: Double] = [:]
        for turn in new.turns {
            guard let speakerID = turn.speakerID else { continue }
            newRanges[speakerID, default: [:]][turn.track, default: []].append(SecondsRange(start: turn.start, end: turn.end))
            newTalk[speakerID, default: 0] += max(0, turn.end - turn.start)
        }
        let oldUnions = oldRanges.mapValues { $0.mapValues(Intervals.union) }
        let newUnions = newRanges.mapValues { $0.mapValues(Intervals.union) }

        var candidates: [(old: String, new: String, shared: Double, passes: Bool)] = []
        for speaker in labelled {
            guard let tracks = oldUnions[speaker.id] else { continue }
            for (newID, newTracks) in newUnions {
                var shared = 0.0
                for (track, ranges) in tracks {
                    guard let other = newTracks[track] else { continue }
                    for range in ranges { shared += Intervals.overlap(other, start: range.start, end: range.end) }
                }
                guard shared > timeEpsilon else { continue }
                let smaller = min(speaker.talkSeconds, newTalk[newID] ?? 0)
                candidates.append((speaker.id, newID, shared, shared + timeEpsilon >= minimumSharedFraction * smaller))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.shared != rhs.shared { return lhs.shared > rhs.shared }
            return (lhs.old, lhs.new) < (rhs.old, rhs.new)
        }

        var mapping: [String: String] = [:]
        var decided = Set<String>()
        var taken = Set<String>()
        for candidate in candidates where !decided.contains(candidate.old) && !taken.contains(candidate.new) {
            decided.insert(candidate.old)
            guard candidate.passes else { continue }
            mapping[candidate.old] = candidate.new
            taken.insert(candidate.new)
        }

        var actions: [SpeakerEditAction] = []
        var unmatched: [String] = []
        for speaker in labelled {
            guard let identity = identities[speaker.id] else { continue }
            guard let target = mapping[speaker.id] else {
                // Not one whose group-mate carried the same identity to a new speaker.
                if !identity.members.contains(where: { mapping[$0] != nil }) { unmatched.append(speaker.id) }
                continue
            }
            if let name = identity.name { actions.append(.rename(speakerID: target, name: name)) }
            if let profileID = identity.profileID { actions.append(.linkProfile(speakerID: target, profileID: profileID)) }
            for profileID in identity.rejected { actions.append(.rejectProfile(speakerID: target, profileID: profileID)) }
        }
        let excluded = excludedTurnIDs(from: old, to: new)
        if !excluded.isEmpty { actions.append(.excludeFromEnrollment(turnIDs: excluded)) }
        return Result(actions: actions, unmatchedSpeakers: unmatched, droppedTurnEdits: old.appliedTurnEditCount)
    }

    /// What each stored speaker carries: its own name, link and rejections, or, shown joined with same-named ones
    /// (`ProjectedSpeaker.memberIDs`), the group's: the first name given among them, their one link (a joined group
    /// has at most one), and all their rejections. So whichever of them a new speaker's speech comes from, it gets the
    /// whole identity, and two new speakers matched by two of them both get it.
    struct Identity {
        var name: String?
        var profileID: String?
        var rejected: [String]
        var members: [String]
        var isEmpty: Bool { name == nil && profileID == nil && rejected.isEmpty }
    }

    static func identities(old: SpeakerProjection, shown: SpeakerProjection) -> [String: Identity] {
        var stored: [String: ProjectedSpeaker] = [:]
        for speaker in old.speakers where stored[speaker.id] == nil { stored[speaker.id] = speaker }
        var result: [String: Identity] = [:]
        for speaker in old.speakers {
            result[speaker.id] = Identity(name: speaker.explicitName, profileID: speaker.profileID,
                                          rejected: speaker.rejectedProfileIDs, members: [speaker.id])
        }
        for group in shown.speakers where group.memberIDs.count > 1 {
            let members = group.memberIDs.compactMap { stored[$0] }
            let profileID = members.lazy.compactMap(\.profileID).first
            var rejected: [String] = []
            for member in members {
                for id in member.rejectedProfileIDs where id != profileID && !rejected.contains(id) { rejected.append(id) }
            }
            let identity = Identity(name: members.lazy.compactMap(\.explicitName).first, profileID: profileID,
                                    rejected: rejected, members: group.memberIDs)
            for member in group.memberIDs { result[member] = identity }
        }
        return result
    }

    /// The new run's turns (in run order) that share speech time with a turn the old projection keeps out of voice
    /// learning, on the same track. A turn kept out of voice learning (by the user, or by an automatic merge nobody
    /// confirmed) stays out after relabelling, whichever speaker its speech lands in: its time is kept out, and a new
    /// turn that takes in any of it is kept out whole.
    static func excludedTurnIDs(from old: SpeakerProjection, to new: DiarizationRun) -> [String] {
        var ranges: [String: [SecondsRange]] = [:]
        for turn in old.turns where turn.excludedFromEnrollment {
            ranges[turn.track, default: []].append(SecondsRange(start: turn.start, end: turn.end))
        }
        guard !ranges.isEmpty else { return [] }
        let unions = ranges.mapValues(Intervals.union)
        return new.turns.filter { turn in
            guard let union = unions[turn.track] else { return false }
            return Intervals.overlap(union, start: turn.start, end: turn.end) > timeEpsilon
        }.map(\.id)
    }

    /// Shared time must be at least this share of the smaller talk time.
    static let minimumSharedFraction = 0.5
}
