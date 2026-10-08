import Foundation
import HolosCore

/// "Same name, same person" (docs/meeting-design.md §4.9, "Speakers with the same name"): within one meeting, two
/// speakers whose names compare equal under `key(_:)` are one speaker, always.
///
/// Two halves keep it true:
/// - Read side: `SpeakerProjection` lists such speakers as one (`join`), so every reader of the projection (the
///   exports, Review, the CLI, summaries, voice learning) sees one person, also for journals saved before this rule
///   and for names carried over by Label Again. Nothing is written.
/// - Write side: `SpeakerEditor` saves a batch that names a speaker as another one is named together with the merges
///   that make them one stored speaker (`SpeakerProjection.joiningSameNames`), so the journal says what the meeting
///   shows, one undo takes it all back, and later edits of that person reach all of it.
///
/// Both read only the journal's state (names given, links, the channel's name), never the people store, so every
/// projection of a meeting joins the same speakers the same way whoever builds it.
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
    /// automatic match ("Jim (auto)") or a suggestion is a guess that nobody confirmed. For finding the speaker a
    /// typed name means (`SpeakerProjection.speaker(named:)`).
    public static func standsBy(_ speaker: ProjectedSpeaker) -> Bool {
        switch speaker.provenance {
        case .userRenamed, .userConfirmed, .channelAssumption: true
        case .diarizer, .recognized: false
        }
    }

    /// What makes a stored speaker the same person as another, from the journal's state alone: its name (the name the
    /// user gave, or the channel speaker's own, "Me"), as `name:<key>`, and the person it is linked to, as
    /// `person:<ID>` (speakers linked to one person are that person, whatever names they show). Empty for a speaker
    /// with neither: a "Speaker N", or one named only by an automatic match.
    static func keys(of speaker: SpeakerProjection.SpeakerState) -> [String] {
        var keys: [String] = []
        let name = speaker.explicitName ?? (speaker.isChannel ? speaker.channelName ?? "Me" : nil)
        if let name, let key = key(name) { keys.append("name:" + key) }
        if let profileID = speaker.profileID { keys.append("person:" + profileID) }
        return keys
    }

    /// Which of two same-named speakers the other one joins on the read side (true when `left` stays): the one linked
    /// to a person (a merge keeps only the target's link, so the person stays with it), then the one with more talk
    /// time (the person's main voice in the meeting, and the spelling shown most), then the lower ordinal (first
    /// listed), then the ID. Read from the projection alone.
    static func staysBefore(_ left: ProjectedSpeaker, _ right: ProjectedSpeaker) -> Bool {
        let leftLinked = left.profileID != nil
        let rightLinked = right.profileID != nil
        if leftLinked != rightLinked { return leftLinked }
        if left.talkSeconds != right.talkSeconds { return left.talkSeconds > right.talkSeconds }
        if left.ordinal != right.ordinal { return left.ordinal < right.ordinal }
        return left.id < right.id
    }

    /// Groups of `speakers` (listed order kept within each) that share a key (`keys(of:)`, given per speaker ID in
    /// `keys`), directly or through another speaker; only groups of two or more.
    static func groups(_ speakers: [ProjectedSpeaker], keys: [String: [String]]) -> [[ProjectedSpeaker]] {
        var parent = Array(speakers.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var owner: [String: Int] = [:]
        for (index, speaker) in speakers.enumerated() {
            for key in keys[speaker.id] ?? [] {
                if let other = owner[key] {
                    let (a, b) = (root(other), root(index))
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else {
                    owner[key] = index
                }
            }
        }
        var members: [Int: [ProjectedSpeaker]] = [:]
        for index in speakers.indices { members[root(index), default: []].append(speakers[index]) }
        return members.keys.sorted().compactMap { members[$0]!.count > 1 ? members[$0] : nil }
    }

    /// `speakers` (listed order) with every group of same-named speakers (`groups`) shown as one, and `turns` with the
    /// joined speakers' turns given to it. The speaker that stays (`staysBefore`) keeps its ID, ordinal, name, link and
    /// rejections, exactly as a `merge` into it would; it takes the others' clusters (in list order) and their talk
    /// time and turns, and lists every joined ID in `memberIDs`. A joined speaker linked to another person than the one
    /// that stays keeps that person's voice: its turns show as kept out of voice learning, so no voice sample moves
    /// from one person to another. `into` maps each joined ID to the one that stays.
    static func join(_ speakers: [ProjectedSpeaker], turns: [ProjectedTurn], keys: [String: [String]])
        -> (speakers: [ProjectedSpeaker], turns: [ProjectedTurn], into: [String: String]) {
        var into: [String: String] = [:]
        var otherPerson = Set<String>()
        var joined: [String: ProjectedSpeaker] = [:]
        for members in groups(speakers, keys: keys) {
            guard let stays = members.min(by: staysBefore) else { continue }
            let others = members.filter { $0.id != stays.id }
            var clusters = stays.clusterIDs
            for member in others {
                into[member.id] = stays.id
                if let person = member.profileID, person != stays.profileID { otherPerson.insert(member.id) }
                for cluster in member.clusterIDs where !clusters.contains(cluster) { clusters.append(cluster) }
            }
            joined[stays.id] = ProjectedSpeaker(
                id: stays.id, ordinal: stays.ordinal, name: stays.name, label: stays.label,
                explicitName: stays.explicitName, profileID: stays.profileID, provenance: stays.provenance,
                isAutomatic: stays.isAutomatic, suggestion: stays.suggestion,
                rejectedProfileIDs: stays.rejectedProfileIDs, clusterIDs: clusters,
                talkSeconds: members.reduce(0) { $0 + $1.talkSeconds },
                turnCount: members.reduce(0) { $0 + $1.turnCount },
                effectiveProfileID: stays.effectiveProfileID, memberIDs: [stays.id] + others.map(\.id))
        }
        guard !into.isEmpty else { return (speakers, turns, [:]) }
        let listed = speakers.compactMap { speaker in into[speaker.id] == nil ? joined[speaker.id] ?? speaker : nil }
        let shown = turns.map { turn in
            guard let speakerID = turn.speakerID, let target = into[speakerID] else { return turn }
            return turn.given(to: target, excluded: turn.excludedFromEnrollment || otherPerson.contains(speakerID))
        }
        return (listed, shown, into)
    }
}

extension ProjectedTurn {
    /// This turn shown as `speakerID`'s (a speaker it was joined into by name, `SameNameSpeakers.join`).
    func given(to speakerID: String, excluded: Bool) -> ProjectedTurn {
        ProjectedTurn(id: id, track: track, start: start, end: end, speakerID: speakerID, clusterID: clusterID,
                      spans: spans, overlap: overlap, otherClusters: otherClusters, assignmentScore: assignmentScore,
                      timing: timing, reassigned: reassigned, modified: modified,
                      excludedFromEnrollment: excluded, uncertain: uncertain, cutByEcho: cutByEcho,
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

    /// `actions` as `SpeakerEditor` saves them on this view, so that a meeting never keeps two stored speakers for one
    /// name (docs/meeting-design.md §4.9, "Speakers with the same name"). `SpeakerEditor` works it out under the
    /// speaker lock on the current labels; Review shows its queued changes through it on the labels shown.
    ///
    /// 1. An action on a speaker this view shows joined with others (`ProjectedSpeaker.memberIDs`: a journal saved
    ///    before this rule, or names carried over by Label Again) — a rename, a link, a rejection, or a merge from or
    ///    into it — first merges the joined speakers into the one listed, at the start of the batch, and names that
    ///    one. Otherwise renaming "Alice" would rename only one of her stored speakers and leave the other showing as a
    ///    second "Alice".
    /// 2. After the batch, each speaker the batch named, linked, created, merged into, or gave turns to that is now
    ///    joined with others gets them merged into one, at the end of the batch: renaming a speaker "Alice" when
    ///    another one is called Alice, a new speaker named Alice, "This is me", or a confirmed suggestion all leave one
    ///    speaker. The one that stays is decided on this view, before the batch: the speaker it already lists under
    ///    that name or person, when one is in the group (the batch's own links never change it), else the read side's
    ///    choice (`SameNameSpeakers.staysBefore`).
    ///
    /// The one that stays is linked to the newest person the batch linked any of them to, else keeps its own link,
    /// else takes the first link of the others. A merged speaker (or the one that stays) linked to another person
    /// than that has its turns kept out of voice learning first (`excludeFromEnrollment`), so no voice sample moves
    /// from one person to another.
    ///
    /// The lines added are merges and exclusions at the start, and exclusions, merges and a link at the end
    /// (`SpeakerEditor.saved(_:asAsked:)`). Every line is in the caller's batch, so one undo takes back the change
    /// and everything added for it. A batch with a `revert` (an undo) is returned as it is, and so is one this view
    /// refuses (the editor reports why).
    public func joiningSameNames(_ actions: [SpeakerEditAction]) -> [SpeakerEditAction] {
        joiningSameNamesMarked(actions).map(\.action)
    }

    /// `joiningSameNames`, each line marked `added` when it is one of the lines added for same-named speakers rather
    /// than one of `actions` (possibly naming the speaker listed instead of one joined into it).
    public func joiningSameNamesMarked(_ actions: [SpeakerEditAction])
        -> [(action: SpeakerEditAction, added: Bool)] {
        guard !actions.contains(where: { if case .revert = $0 { true } else { false } }) else {
            return actions.map { ($0, false) }
        }
        // Step 1: the joined groups the batch acts on, merged first, as the read side shows them.
        var shownAs: [String: ProjectedSpeaker] = [:]
        for speaker in speakers where speaker.memberIDs.count > 1 {
            for member in speaker.memberIDs { shownAs[member] = speaker }
        }
        var prefix: [SpeakerEditAction] = []
        var opened = Set<String>()
        func listed(_ speakerID: String) -> String {
            guard let speaker = shownAs[speakerID] else { return speakerID }
            if opened.insert(speaker.id).inserted {
                for member in speaker.memberIDs.dropFirst() {
                    if let person = state.speakers[member]?.profileID, person != speaker.profileID {
                        let turns = state.voiceTurns(of: member)
                        if !turns.isEmpty { prefix.append(.excludeFromEnrollment(turnIDs: turns)) }
                    }
                    prefix.append(.merge(from: member, into: speaker.id))
                }
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
        var result = prefix.map { ($0, true) } + body.map { ($0, false) }

        // Step 2: speakers the batch names that now share a name (or a person) with others.
        var links: [(speakerID: String, profileID: String)] = []
        var named = Set<String>()
        for (action, _) in result {
            switch action {
            case .rename(let speakerID, _):
                named.insert(speakerID)
            case .linkProfile(let speakerID, let profileID):
                named.insert(speakerID)
                links.append((speakerID, profileID))
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
        var after = self
        for (action, _) in result {
            let id = UUID().uuidString
            after = after.applying(action, editID: id)
            if after.staleEdits.contains(where: { $0.editID == id }) { return result.map { ($0.0, $0.1) } }
        }
        for group in after.speakers where group.memberIDs.count > 1 && !named.isDisjoint(with: group.memberIDs) {
            let members = group.memberIDs
            // Who stays: the speaker this view already lists under one of the group's names or people, when one is in
            // the group; else the read side's choice.
            let groupKeys = Set(members.flatMap { after.state.speakers[$0].map(SameNameSpeakers.keys(of:)) ?? [] })
            let stays = speakers.first { speaker in
                members.contains(speaker.id) && state.speakers[speaker.id].map {
                    !groupKeys.isDisjoint(with: SameNameSpeakers.keys(of: $0))
                } == true
            }?.id ?? group.id
            // The person they are: the newest the batch linked any of them to, else the one that stays is linked to,
            // else the first another one is linked to.
            let current = after.state.speakers[stays]?.profileID
            let kept = links.last { members.contains($0.speakerID) }?.profileID
                ?? current ?? members.lazy.compactMap { after.state.speakers[$0]?.profileID }.first
            // Linked to another person: its voice is that person's, so its turns stay out of voice learning.
            for member in members {
                guard let person = after.state.speakers[member]?.profileID, person != kept else { continue }
                let turns = after.state.voiceTurns(of: member)
                if !turns.isEmpty { result.append((.excludeFromEnrollment(turnIDs: turns), true)) }
            }
            result += members.filter { $0 != stays }.map { (.merge(from: $0, into: stays), true) }
            if let kept, kept != current { result.append((.linkProfile(speakerID: stays, profileID: kept), true)) }
        }
        return result.map { ($0.0, $0.1) }
    }
}

extension SpeakerProjection.State {
    /// The turns `speakerID` holds that voice learning could still use (with words, not kept out of it), run order.
    func voiceTurns(of speakerID: String) -> [String] {
        turns.filter { $0.speakerID == speakerID && !$0.spans.isEmpty && !$0.excluded }.map(\.id)
    }
}
