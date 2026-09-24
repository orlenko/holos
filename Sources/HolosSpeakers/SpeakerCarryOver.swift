import Foundation
import HolosCore

/// Carries speaker-level labels (names, profile links, rejections) from the projection of a replaced head to a new
/// run, so human edits survive relabelling (docs/contracts.md; docs/meeting-design.md §4.9). Turn-level edits stay
/// in the journal under the old run and are only counted. Pure; the caller appends the actions with
/// `source: "carry"`, the new run as `baseRunID`, and one batch ID.
public enum SpeakerCarryOver {
    public struct Result: Sendable, Equatable {
        /// rename / linkProfile / rejectProfile actions on the new run's speakers.
        public var actions: [SpeakerEditAction]
        /// Old speakers with a name, link, or rejection that matched nothing (IDs only).
        public var unmatchedSpeakers: [String]
        /// Turn-level edits (reassign, split, new speaker, exclude) and merges that are not carried.
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
    /// - Actions follow the old projection's speaker order; per speaker: `rename` (explicit name), `linkProfile`,
    ///   then one `rejectProfile` per rejection in the order they were made. Automatic (recognized) names are not
    ///   carried: the new run gets its own recognition.
    /// - `droppedTurnEdits` counts the old projection's applied turn-level edits and merges; reverted and stale
    ///   ones never took effect and are not counted. A merge only shapes which new speaker the name maps to.
    public static func carry(from old: SpeakerProjection, to new: DiarizationRun) -> Result {
        let labelled = old.speakers.filter {
            $0.explicitName != nil || $0.profileID != nil || !$0.rejectedProfileIDs.isEmpty
        }
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
            guard let target = mapping[speaker.id] else {
                unmatched.append(speaker.id)
                continue
            }
            if let name = speaker.explicitName { actions.append(.rename(speakerID: target, name: name)) }
            if let profileID = speaker.profileID { actions.append(.linkProfile(speakerID: target, profileID: profileID)) }
            for profileID in speaker.rejectedProfileIDs {
                actions.append(.rejectProfile(speakerID: target, profileID: profileID))
            }
        }
        return Result(actions: actions, unmatchedSpeakers: unmatched, droppedTurnEdits: old.appliedTurnEditCount)
    }

    /// Shared time must be at least this share of the smaller talk time.
    static let minimumSharedFraction = 0.5
}
