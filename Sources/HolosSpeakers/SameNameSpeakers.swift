import Foundation
import HolosCore

/// "Same name, same person" (docs/meeting-design.md §4.9, "Speakers with the same name"): within one meeting, two
/// speakers whose names compare equal under `key(_:)` are one speaker, always.
///
/// Two halves keep it true:
/// - Read side: `SpeakerProjection` lists such speakers as one (`joins`), so every reader of the projection (the
///   exports, Review, the CLI, summaries, voice learning) sees one person, also for journals saved before this rule
///   and for names carried over by Label Again. Nothing is written. What each stored speaker owns stays readable
///   (`SpeakerProjection.unjoinedSpeakers`, `unjoinedTurns`) for voice data, which belongs to the person each was
///   linked to.
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

    /// Which stored speakers are shown as one, worked out on the journal's state alone (`speakers` and `turns` of
    /// `SpeakerProjection.State`): never the people store, recognition, the echo mask or talk time, so every reader of
    /// a meeting, and a change's preview and its save, join the same speakers into the same one.
    struct Joins: Sendable, Equatable {
        /// Joined stored speaker → the one it is shown as.
        var into: [String: String] = [:]
        /// The one shown → every stored speaker it shows, itself first, then by (ordinal, ID).
        var members: [String: [String]] = [:]
        /// The one shown → the person they are: its own link, else the first link of the others (in `members` order).
        var person: [String: String] = [:]
        /// Joined speakers (the one shown never is) linked to another person than `person`: their voice is that
        /// person's, so their turns stay out of voice learning.
        var otherPerson = Set<String>()

        var isEmpty: Bool { into.isEmpty }
    }

    /// The stored speakers that share a key (`keys(of:)`), directly or through another, among those that hold a turn
    /// with words or were created by `newSpeaker`. The one shown is the lowest (ordinal, ID): fixed by the journal
    /// (a newer speaker never takes over an older one's place), whatever links, talk time or masks say.
    static func joins(_ speakers: [String: SpeakerProjection.SpeakerState],
                      turns: [SpeakerProjection.TurnState]) -> Joins {
        var holding = Set<String>()
        for turn in turns where !turn.spans.isEmpty { if let id = turn.speakerID { holding.insert(id) } }
        let candidates = speakers.values
            .filter { (holding.contains($0.id) || $0.isUserCreated) && !keys(of: $0).isEmpty }
            .sorted { ($0.ordinal, $0.id) < ($1.ordinal, $1.id) }
        var parent = Array(candidates.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var owner: [String: Int] = [:]
        for (index, speaker) in candidates.enumerated() {
            for key in keys(of: speaker) {
                if let other = owner[key] {
                    let (a, b) = (root(other), root(index))
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else {
                    owner[key] = index
                }
            }
        }
        var groups: [Int: [SpeakerProjection.SpeakerState]] = [:]
        for index in candidates.indices { groups[root(index), default: []].append(candidates[index]) }
        var joins = Joins()
        for group in groups.values where group.count > 1 {
            // `candidates` is in (ordinal, ID) order and so is each group: the first is the one shown.
            let shown = group[0]
            joins.members[shown.id] = group.map(\.id)
            let person = shown.profileID ?? group.lazy.compactMap(\.profileID).first
            if let person { joins.person[shown.id] = person }
            for member in group.dropFirst() {
                joins.into[member.id] = shown.id
                if let linked = member.profileID, linked != person { joins.otherPerson.insert(member.id) }
            }
        }
        return joins
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
    ///    into it — first merges the joined speakers into the one listed, at the start of the batch (linking it to the
    ///    group's person as shown, unless the batch links it), and names that one. Otherwise renaming "Alice" would
    ///    rename only one of her stored speakers and leave the other showing as a second "Alice".
    /// 2. After the batch, each speaker the batch named, linked, created, merged into, or gave turns to that is now
    ///    joined with others gets them merged into one, at the end of the batch: renaming a speaker "Alice" when
    ///    another one is called Alice, a new speaker named Alice, "This is me", or a confirmed suggestion all leave one
    ///    speaker. The one that stays is the one the labels after the batch show them as: the lowest (ordinal, ID)
    ///    (`SameNameSpeakers.joins`), so a preview and its save, and every reader, keep the same one.
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
        // The batch's own links of a listed speaker: it then says who that speaker is itself.
        var linkedHere = Set<String>()
        for action in actions {
            if case .linkProfile(let speakerID, _) = action { linkedHere.insert(shownAs[speakerID]?.id ?? speakerID) }
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
                // Shown with the person of the group (`SameNameSpeakers.Joins.person`), which a merge alone would
                // drop when only a joined speaker was linked; unless the batch links it itself.
                if let person = speaker.profileID, state.speakers[speaker.id]?.profileID != person,
                   !linkedHere.contains(speaker.id) {
                    prefix.append(.linkProfile(speakerID: speaker.id, profileID: person))
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
            // Who stays: the one the labels after the batch show them as, the lowest (ordinal, ID) of them
            // (`SameNameSpeakers.joins`), the same on any view, for a preview and its save alike.
            let members = group.memberIDs
            let stays = group.id
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
