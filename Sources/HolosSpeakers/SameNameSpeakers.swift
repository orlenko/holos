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

    /// Which of two same-named speakers the other one joins on the read side (true when `left` stays): the one linked
    /// to a person who still exists (`people`: a merge keeps only the target's link, so the person and their voice
    /// samples stay with it; a link to a forgotten person counts for nothing), then the one with more talk time (the
    /// person's main voice in the meeting, and the spelling shown most), then the lower ordinal (first listed), then
    /// the ID.
    static func staysBefore(_ left: ProjectedSpeaker, _ right: ProjectedSpeaker, people: Set<String>) -> Bool {
        let leftLinked = left.profileID.map(people.contains) ?? false
        let rightLinked = right.profileID.map(people.contains) ?? false
        if leftLinked != rightLinked { return leftLinked }
        if left.talkSeconds != right.talkSeconds { return left.talkSeconds > right.talkSeconds }
        if left.ordinal != right.ordinal { return left.ordinal < right.ordinal }
        return left.id < right.id
    }

    /// `speakers` (listed order) with every group of same-named speakers shown as one, and `turns` with the joined
    /// speakers' turns given to it. The speaker that stays (`staysBefore`; `people` are the IDs of people who still
    /// exist) keeps its ID, ordinal, name, link and rejections, exactly as a `merge` into it would; it takes the
    /// others' clusters (in list order) and their talk time and turns, and lists every joined ID in `memberIDs`. `into`
    /// maps each joined ID to the one that stays. Speakers of one name are split by person first (`byPerson`).
    static func join(_ speakers: [ProjectedSpeaker], turns: [ProjectedTurn], people: Set<String>)
        -> (speakers: [ProjectedSpeaker], turns: [ProjectedTurn], into: [String: String]) {
        var named: [String: [ProjectedSpeaker]] = [:]
        for speaker in speakers where standsBy(speaker) {
            guard let key = key(speaker.name) else { continue }
            named[key, default: []].append(speaker)
        }
        var into: [String: String] = [:]
        var joined: [String: ProjectedSpeaker] = [:]
        for members in named.values.filter({ $0.count > 1 }).flatMap({ byPerson($0, people: people) })
        where members.count > 1 {
            guard let stays = members.min(by: { staysBefore($0, $1, people: people) }) else { continue }
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

    /// Speakers of one name (listed order) as the people they are. Same name is the same person, unless the user
    /// said otherwise: speakers linked to two different people who exist (`people`) are two people of one name and
    /// stay apart, since an explicit link is stronger evidence than a name. So:
    /// - nobody linked to an existing person: one group;
    /// - one such person: their speakers and every other speaker of the name that did not say "Not <them>";
    /// - several: one group per person, and one of the speakers linked to nobody who exists (whose person is
    ///   unknown); a speaker that said "Not <them>" to the only person is in that last group too.
    static func byPerson(_ members: [ProjectedSpeaker], people: Set<String>) -> [[ProjectedSpeaker]] {
        func person(_ speaker: ProjectedSpeaker) -> String? { speaker.profileID.flatMap { people.contains($0) ? $0 : nil } }
        var persons: [String] = []
        for member in members {
            if let person = person(member), !persons.contains(person) { persons.append(person) }
        }
        guard !persons.isEmpty else { return [members] }
        var groups: [String: [ProjectedSpeaker]] = [:]
        var unknown: [ProjectedSpeaker] = []
        for member in members {
            if let person = person(member) {
                groups[person, default: []].append(member)
            } else if persons.count == 1, !member.rejectedProfileIDs.contains(persons[0]) {
                groups[persons[0], default: []].append(member)
            } else {
                unknown.append(member)
            }
        }
        return persons.compactMap { groups[$0] } + [unknown]
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
    ///    all leave one speaker. The one that stays is the speaker this view already lists under that name, when it
    ///    is in the group (decided before the batch, so the batch's own links never change it); for a name nobody had,
    ///    the read side's choice (`SameNameSpeakers.staysBefore`). When the batch linked one of them to a person, or
    ///    the one that stays has no link to a person who still exists and another one has, a `linkProfile` of the
    ///    one that stays follows the merges, so the person and their voice stay with the meeting.
    ///
    /// The lines added are merges at the start, and merges then links at the end (`SpeakerEditor.saved(_:asAsked:)`).
    /// Every line is in the caller's batch, so one undo takes back the change and its merges together. A batch with a
    /// `revert` (an undo) is returned as it is, and so is one this view refuses (the editor reports why).
    ///
    /// Speakers linked to two different people who exist stay apart (`SameNameSpeakers.byPerson`); a person the batch
    /// links counts as existing (it may be created by the same change).
    public func joiningSameNames(_ actions: [SpeakerEditAction]) -> [SpeakerEditAction] {
        joiningSameNamesMarked(actions).map(\.action)
    }

    /// `joiningSameNames`, each line marked `added` when it is one of the merges or links added for same-named
    /// speakers rather than one of `actions` (possibly naming the speaker listed instead of one joined into it).
    public func joiningSameNamesMarked(_ actions: [SpeakerEditAction])
        -> [(action: SpeakerEditAction, added: Bool)] {
        guard !actions.contains(where: { if case .revert = $0 { true } else { false } }) else {
            return actions.map { ($0, false) }
        }
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
        var result = prefix.map { ($0, true) } + body.map { ($0, false) }

        // Step 2: speakers the batch names that now share a name with others, on the labels after the batch, where a
        // person the batch links counts as one who exists.
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
        var linking = context
        linking.linkedPeople = Set(links.map(\.profileID))
        var after = Self.replay(context: linking, journal: journal, otherRunEditCount: otherRunEditCount)
        for (action, _) in result {
            let id = UUID().uuidString
            after = after.applying(action, editID: id)
            if after.staleEdits.contains(where: { $0.editID == id }) { return result.map { ($0.0, $0.1) } }
        }
        let people = linking.people
        for group in after.speakers where group.memberIDs.count > 1 && !named.isDisjoint(with: group.memberIDs) {
            let members = group.memberIDs
            // Who stays is decided on this view, before the batch: the speaker it already lists under that name (the
            // person as shown now), when that one is in the group. The batch's own links never decide it, so a change
            // shown before it is saved (Review shows a link to a person being created as a rename) merges the same way
            // as the batch saved. Only a name nobody had before the batch falls back to the read side's choice.
            let key = SameNameSpeakers.key(group.name)
            let stays = speakers.first {
                members.contains($0.id) && SameNameSpeakers.standsBy($0) && SameNameSpeakers.key($0.name) == key
            }?.id ?? group.id
            result += members.filter { $0 != stays }.map { (.merge(from: $0, into: stays), true) }
            // The person stays linked: the newest link this batch made to any of them; else, when the one that stays
            // has no link to a person who exists, such a link of another one (a merge keeps only the target's link).
            let current = after.state.speakers[stays]?.profileID
            var keep = links.last { members.contains($0.speakerID) }?.profileID
            if keep == nil, current.map(people.contains) != true {
                keep = members.compactMap { after.state.speakers[$0]?.profileID }.first(where: people.contains)
            }
            if let keep, keep != current { result.append((.linkProfile(speakerID: stays, profileID: keep), true)) }
        }
        return result.map { ($0.0, $0.1) }
    }
}
