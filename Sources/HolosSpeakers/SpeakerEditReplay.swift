import Foundation
import HolosCore

/// Carries a head's edits to a run rebuilt from the same transcript and diarization (`SpeakerRunBuilder.rebuild`),
/// where only removed echo words changed the turns (docs/meeting-design.md §5.11). Unlike `SpeakerCarryOver`, which
/// maps speakers by shared time after a new diarizer pass and drops turn-level edits, every speaker keeps its ID here,
/// so names, links, rejections and merges carry as they are, and turn-level edits (reassign, split, new speaker,
/// keep out of voice learning) carry by the words their turns hold. Pure.
public enum SpeakerEditReplay {
    public struct Result: Sendable, Equatable {
        /// Journal lines for the new run, in the old journal order: the same IDs, times and batches, source "carry",
        /// turn IDs mapped, and each line's fingerprint taken on the new run's state before it.
        public var edits: [SpeakerEdit]
        /// Effective edits of the old head that had no counterpart: every word of their turns is echo now, their turns
        /// now share a turn with words they did not hold, or the edit no longer applies (its speaker is gone).
        public var droppedEditIDs: [String]

        public init(edits: [SpeakerEdit] = [], droppedEditIDs: [String] = []) {
            self.edits = edits; self.droppedEditIDs = droppedEditIDs
        }
    }

    /// Replays, in journal order, the edits of `oldRun` that its projection applies (`effective`, the projection's
    /// `appliedEditIDs`; reverted edits and reverts are left out, as they never took effect) on `newRun`.
    ///
    /// Each edit's turns are the old projection's turns just before it (edits before it applied). They map to the new
    /// projection's turns that hold any of their words:
    /// - `reassignTurns` and `newSpeaker` carry only when each such new turn holds nothing but words of the listed
    ///   turns, so no other words change speaker;
    /// - `excludeFromEnrollment` carries to every such turn (keeping more out of voice learning is safe);
    /// - `splitTurn` splits the new turn holding the split word; when that word already starts a turn there is
    ///   nothing to do (not dropped either).
    /// An edit with no turn left, or that the new projection refuses, is dropped.
    public static func carry(edits: [SpeakerEdit], effective: [String], from oldRun: DiarizationRun,
                             to newRun: DiarizationRun, transcript: Transcript) -> Result {
        let effectiveIDs = Set(effective)
        var oldView = SpeakerProjection.make(run: oldRun, transcript: transcript, edits: [], recognition: nil,
                                             profileNames: [:])
        var newView = SpeakerProjection.make(run: newRun, transcript: transcript, edits: [], recognition: nil,
                                             profileNames: [:])
        var result = Result()
        for edit in edits where edit.baseRunID == oldRun.id && effectiveIDs.contains(edit.id) {
            let mapped = map(edit.action, old: oldView, new: newView)
            oldView = oldView.applying(edit.action, editID: edit.id)
            switch mapped {
            case .inEffect:
                continue
            case .dropped:
                result.droppedEditIDs.append(edit.id)
            case .action(let action):
                let expected = newView.fingerprint(for: action)
                let staleBefore = newView.staleEdits.count
                let next = newView.applying(action, editID: edit.id)
                guard next.appliedEditIDs.contains(edit.id), next.staleEdits.count == staleBefore else {
                    result.droppedEditIDs.append(edit.id)
                    continue
                }
                newView = next
                result.edits.append(SpeakerEdit(id: edit.id, baseRunID: newRun.id, at: edit.at, source: "carry",
                                                action: action, expected: expected, batchID: edit.batchID))
            }
        }
        return result
    }

    private enum Mapped {
        case action(SpeakerEditAction)
        /// Its effect already holds on the new run.
        case inEffect
        case dropped
    }

    private static func map(_ action: SpeakerEditAction, old: SpeakerProjection, new: SpeakerProjection) -> Mapped {
        switch action {
        case .rename, .linkProfile, .rejectProfile, .merge:
            return .action(action)
        case .revert:
            return .dropped
        case .reassignTurns(let turnIDs, let to):
            guard let mapped = turns(turnIDs, old: old, new: new, exact: true) else { return .dropped }
            return .action(.reassignTurns(turnIDs: mapped, to: to))
        case .newSpeaker(let speakerID, let name, let turnIDs):
            guard let mapped = turns(turnIDs, old: old, new: new, exact: true) else { return .dropped }
            return .action(.newSpeaker(speakerID: speakerID, name: name, turnIDs: mapped))
        case .excludeFromEnrollment(let turnIDs):
            guard let mapped = turns(turnIDs, old: old, new: new, exact: false) else { return .dropped }
            return .action(.excludeFromEnrollment(turnIDs: mapped))
        case .splitTurn(_, let at):
            guard let turn = new.turns.first(where: { words(of: $0).contains(at) }) else { return .dropped }
            if words(of: turn).first == at { return .inEffect }
            return .action(.splitTurn(turnID: turn.id, at: at))
        }
    }

    /// The new turns (in new projection order) holding words of the old turns `turnIDs`; nil when an old turn is
    /// missing, none is left, or (`exact`) a new turn also holds other words.
    private static func turns(_ turnIDs: [String], old: SpeakerProjection, new: SpeakerProjection,
                              exact: Bool) -> [String]? {
        var wanted = Set<WordRef>()
        for turnID in turnIDs {
            guard let turn = old.turns.first(where: { $0.id == turnID }) else { return nil }
            wanted.formUnion(words(of: turn))
        }
        var mapped: [String] = []
        for turn in new.turns {
            let held = words(of: turn)
            guard held.contains(where: wanted.contains) else { continue }
            if exact, !held.allSatisfy(wanted.contains) { return nil }
            mapped.append(turn.id)
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// A turn's words in span order.
    private static func words(of turn: ProjectedTurn) -> [WordRef] {
        turn.spans.flatMap { span in
            (span.first..<max(span.first, span.end)).map { WordRef(segmentID: span.segmentID, word: $0) }
        }
    }
}
