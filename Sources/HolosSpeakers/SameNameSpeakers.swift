import Foundation
import HolosCore

/// "Same name, same person" (docs/meeting-design.md §4.9, "Speakers with the same name"): within one meeting, two
/// speakers whose names compare equal under `key(_:)` are one person.
///
/// Two halves keep it true:
/// - Read side: `SpeakerProjection` lists such speakers as one (`join`), so every reader of the projection (the
///   exports, Review, the CLI, summaries, voice learning) sees one person, also for journals saved before this rule
///   and for names carried over by Label Again. Nothing is written.
/// - Write side: `SpeakerEditor` saves a batch that names a speaker as another one is named together with the merges
///   that make them one stored speaker (`SpeakerProjection.joiningSameNames`), so the journal says what the meeting
///   shows, one undo takes it all back, and later edits of that person reach all of it.
public enum SameNameSpeakers {
    /// The form names are compared in: runs of whitespace (and control characters) become one space, the ends are
    /// trimmed, and case, diacritics and character width are ignored ("  Zoë  Smith" and "zoe smith" match). Nil when
    /// nothing is left.
    public static func key(_ name: String) -> String? {
        var collapsed = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in name.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                pendingSpace = !collapsed.isEmpty
                continue
            }
            if pendingSpace {
                collapsed.append(" ")
                pendingSpace = false
            }
            collapsed.append(scalar)
        }
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                         locale: nil)
    }

    /// Whether `speaker`'s name is a person's name the meeting stands by: one the user gave (`userRenamed`), a linked
    /// person's (`userConfirmed`), or the channel speaker's ("Me"). A "Speaker N" fallback names nobody, and an
    /// automatic match ("Jim (auto)") or a suggestion is a guess that nobody confirmed: neither joins anyone.
    public static func standsBy(_ speaker: ProjectedSpeaker) -> Bool {
        switch speaker.provenance {
        case .userRenamed, .userConfirmed, .channelAssumption: true
        case .diarizer, .recognized: false
        }
    }

    /// Which of two same-named speakers the other one joins (true when `left` stays): the one linked to a person (a
    /// merge keeps only the target's link, so the person and their voice samples stay with it), then the one with
    /// more talk time (the person's main voice in the meeting, and the spelling shown most), then the lower ordinal
    /// (first listed), then the ID.
    static func staysBefore(_ left: ProjectedSpeaker, _ right: ProjectedSpeaker) -> Bool {
        let leftLinked = left.profileID != nil
        let rightLinked = right.profileID != nil
        if leftLinked != rightLinked { return leftLinked }
        if left.talkSeconds != right.talkSeconds { return left.talkSeconds > right.talkSeconds }
        if left.ordinal != right.ordinal { return left.ordinal < right.ordinal }
        return left.id < right.id
    }

    /// `speakers` (listed order) with every group of same-named speakers shown as one, and `turns` with the joined
    /// speakers' turns given to it. The speaker that stays (`staysBefore`) keeps its ID, ordinal, name, link and
    /// rejections, exactly as a `merge` into it would; it takes the others' clusters (in list order) and their talk
    /// time and turns, and lists every joined ID in `memberIDs`. `into` maps each joined ID to the one that stays.
    static func join(_ speakers: [ProjectedSpeaker], turns: [ProjectedTurn])
        -> (speakers: [ProjectedSpeaker], turns: [ProjectedTurn], into: [String: String]) {
        var groups: [String: [ProjectedSpeaker]] = [:]
        for speaker in speakers where standsBy(speaker) {
            guard let key = key(speaker.name) else { continue }
            groups[key, default: []].append(speaker)
        }
        var into: [String: String] = [:]
        var joined: [String: ProjectedSpeaker] = [:]
        for members in groups.values where members.count > 1 {
            guard let stays = members.min(by: staysBefore) else { continue }
            var ordered = members
            ordered.removeAll { $0.id == stays.id }
            var clusters = stays.clusterIDs
            for member in ordered {
                into[member.id] = stays.id
                for cluster in member.clusterIDs where !clusters.contains(cluster) { clusters.append(cluster) }
            }
            joined[stays.id] = ProjectedSpeaker(
                id: stays.id, ordinal: stays.ordinal, name: stays.name, label: stays.label,
                explicitName: stays.explicitName, profileID: stays.profileID, provenance: stays.provenance,
                isAutomatic: stays.isAutomatic, suggestion: stays.suggestion,
                rejectedProfileIDs: stays.rejectedProfileIDs, clusterIDs: clusters,
                talkSeconds: members.reduce(0) { $0 + $1.talkSeconds },
                turnCount: members.reduce(0) { $0 + $1.turnCount },
                effectiveProfileID: stays.effectiveProfileID, memberIDs: [stays.id] + ordered.map(\.id))
        }
        guard !into.isEmpty else { return (speakers, turns, [:]) }
        let listed = speakers.compactMap { speaker in into[speaker.id] == nil ? joined[speaker.id] ?? speaker : nil }
        let shown = turns.map { turn in
            guard let speakerID = turn.speakerID, let target = into[speakerID] else { return turn }
            return turn.given(to: target)
        }
        return (listed, shown, into)
    }
}

extension ProjectedTurn {
    /// This turn shown as `speakerID`'s (a speaker it was joined into by name, `SameNameSpeakers.join`).
    func given(to speakerID: String) -> ProjectedTurn {
        ProjectedTurn(id: id, track: track, start: start, end: end, speakerID: speakerID, clusterID: clusterID,
                      spans: spans, overlap: overlap, otherClusters: otherClusters, assignmentScore: assignmentScore,
                      timing: timing, reassigned: reassigned, modified: modified,
                      excludedFromEnrollment: excludedFromEnrollment, uncertain: uncertain, cutByEcho: cutByEcho,
                      interjection: interjection)
    }
}

extension SpeakerProjection {
    /// The listed speaker that is the person called `name`: its name matches under `SameNameSpeakers.key` and stands
    /// for a person (`SameNameSpeakers.standsBy`). Nil when none is. Naming new speakers by it ("New Speaker…" with a
    /// name already in the meeting) gives the turns to that speaker instead of making a second one.
    public func speaker(named name: String) -> ProjectedSpeaker? {
        guard let key = SameNameSpeakers.key(name) else { return nil }
        return speakers.first { SameNameSpeakers.standsBy($0) && SameNameSpeakers.key($0.name) == key }
    }

    /// `actions` as `SpeakerEditor` saves them on this view (the caller's), so that a meeting never keeps two stored
    /// speakers for one name (docs/meeting-design.md §4.9, "Speakers with the same name"):
    ///
    /// 1. An action on a speaker this view shows joined with same-named ones (`ProjectedSpeaker.memberIDs`: a journal
    ///    saved before this rule, or names carried over by Label Again) — a rename, a link, a rejection, or a merge
    ///    from or into it — first merges the joined speakers into the one listed, at the start of the batch, and
    ///    names that one. Otherwise renaming "Alice" would rename only one of her stored speakers and leave the other
    ///    showing as a second "Alice".
    /// 2. After the batch, each listed speaker the batch named, linked, created, merged into, or gave turns to that is
    ///    now joined with same-named speakers gets them merged into it, at the end of the batch: renaming a speaker
    ///    "Alice" when another one is called Alice, a new speaker named Alice, "This is me", or a confirmed suggestion
    ///    all leave one speaker. Which one stays follows the read side (`SameNameSpeakers.staysBefore`).
    ///
    /// Every line is in the caller's batch, so one undo takes back the change and its merges together. A batch with a
    /// `revert` (an undo) is returned as it is, and so is one this view refuses (the editor reports why).
    public func joiningSameNames(_ actions: [SpeakerEditAction]) -> [SpeakerEditAction] {
        guard !actions.contains(where: { if case .revert = $0 { true } else { false } }) else { return actions }
        // Step 1: the joined groups the batch acts on, merged first.
        var shownAs: [String: ProjectedSpeaker] = [:]
        for speaker in speakers where speaker.memberIDs.count > 1 {
            for member in speaker.memberIDs { shownAs[member] = speaker }
        }
        var prefix: [SpeakerEditAction] = []
        var opened = Set<String>()
        func listed(_ speakerID: String) -> String {
            guard let speaker = shownAs[speakerID] else { return speakerID }
            if opened.insert(speaker.id).inserted {
                prefix += speaker.memberIDs.dropFirst().map { .merge(from: $0, into: speaker.id) }
            }
            return speaker.id
        }
        var body: [SpeakerEditAction] = []
        for action in actions {
            switch action {
            case .rename(let speakerID, let name):
                body.append(.rename(speakerID: listed(speakerID), name: name))
            case .linkProfile(let speakerID, let profileID):
                body.append(.linkProfile(speakerID: listed(speakerID), profileID: profileID))
            case .rejectProfile(let speakerID, let profileID):
                body.append(.rejectProfile(speakerID: listed(speakerID), profileID: profileID))
            case .merge(let from, let into):
                let source = listed(from)
                let target = listed(into)
                // Two speakers already shown as one: the merges of step 1 made them one stored speaker too. A merge
                // of a speaker into itself stays, so the editor refuses it as before.
                if source != target || from == into { body.append(.merge(from: source, into: target)) }
            case .reassignTurns, .splitTurn, .newSpeaker, .excludeFromEnrollment, .revert:
                body.append(action)
            }
        }
        var result = prefix + body

        // Step 2: speakers the batch names that now share a name with others.
        var after = self
        for action in result {
            let id = UUID().uuidString
            after = after.applying(action, editID: id)
            if after.staleEdits.contains(where: { $0.editID == id }) { return result }
        }
        var named = Set<String>()
        for action in result {
            switch action {
            case .rename(let speakerID, _), .linkProfile(let speakerID, _):
                named.insert(speakerID)
            case .merge(_, let into):
                named.insert(into)
            case .newSpeaker(let speakerID, _, _):
                named.insert(speakerID)
            case .reassignTurns(_, let to):
                if let to { named.insert(to) }
            case .rejectProfile, .splitTurn, .excludeFromEnrollment, .revert:
                break
            }
        }
        for speaker in after.speakers where speaker.memberIDs.count > 1 && !named.isDisjoint(with: speaker.memberIDs) {
            result += speaker.memberIDs.dropFirst().map { .merge(from: $0, into: speaker.id) }
        }
        return result
    }
}
