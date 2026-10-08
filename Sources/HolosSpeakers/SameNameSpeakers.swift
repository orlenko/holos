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

    /// The name a stored speaker is joined by, from the journal's state alone: the name the user gave (`rename`,
    /// `newSpeaker`), else the channel speaker's own ("Me"), as `key` compares them. Nil for a speaker with neither:
    /// a "Speaker N", or one named only by a link or an automatic match. Links never join anyone: the rule is about
    /// names, and two speakers linked to one person under different names stay two.
    static func nameKey(of speaker: SpeakerProjection.SpeakerState) -> String? {
        let name = speaker.explicitName ?? (speaker.isChannel ? speaker.channelName ?? "Me" : nil)
        return name.flatMap(key)
    }

    /// Which stored speakers are shown as one, worked out on the journal's state alone (`speakers` and `turns` of
    /// `SpeakerProjection.State`): never links, the people store, recognition, the echo mask or talk time, so every
    /// reader of a meeting, and a change's preview and its save, join the same speakers into the same one.
    struct Joins: Sendable, Equatable {
        /// Joined stored speaker → the one it is shown as.
        var into: [String: String] = [:]
        /// The one shown → every stored speaker it shows, itself first, then by (ordinal, ID).
        var members: [String: [String]] = [:]
        /// The one shown → the person they are (`person(of:in:)`).
        var person: [String: String] = [:]
        /// Joined speakers linked to another person than `person`: their voice is that person's, so their turns stay
        /// out of voice learning.
        var otherPerson = Set<String>()

        var isEmpty: Bool { into.isEmpty }
    }

    /// The stored speakers with one name (`nameKey`), among those that hold a turn with words or were created by
    /// `newSpeaker`. The one shown is the lowest (ordinal, ID): fixed by the journal (a newer speaker never takes over
    /// an older one's place), whatever links, talk time or masks say.
    static func joins(_ speakers: [String: SpeakerProjection.SpeakerState],
                      turns: [SpeakerProjection.TurnState]) -> Joins {
        var holding = Set<String>()
        for turn in turns where !turn.spans.isEmpty { if let id = turn.speakerID { holding.insert(id) } }
        var byName: [String: [SpeakerProjection.SpeakerState]] = [:]
        for speaker in speakers.values where holding.contains(speaker.id) || speaker.isUserCreated {
            if let key = nameKey(of: speaker) { byName[key, default: []].append(speaker) }
        }
        var joins = Joins()
        for group in byName.values where group.count > 1 {
            let ordered = group.sorted(by: precedes)
            let shown = ordered[0]
            joins.members[shown.id] = ordered.map(\.id)
            let person = person(of: ordered, staying: shown)
            if let person { joins.person[shown.id] = person }
            for member in ordered.dropFirst() {
                joins.into[member.id] = shown.id
                if let linked = member.profileID, linked != person { joins.otherPerson.insert(member.id) }
            }
        }
        return joins
    }

    /// (ordinal, ID) order: the first of a group is the one that stays.
    static func precedes(_ left: SpeakerProjection.SpeakerState, _ right: SpeakerProjection.SpeakerState) -> Bool {
        (left.ordinal, left.id) < (right.ordinal, right.id)
    }

    /// The person a group of one name is: the link of the one that stays, else the link of the lowest (ordinal, ID)
    /// other one that has a link. Nil when none has one.
    static func person(of members: [SpeakerProjection.SpeakerState],
                       staying: SpeakerProjection.SpeakerState) -> String? {
        staying.profileID ?? members.sorted(by: precedes).lazy.compactMap(\.profileID).first
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
    /// The asked actions come first, naming the speaker listed for one shown joined with others (a merge of such a
    /// speaker also moves the others it shows). Then, worked out once on the labels after them, each group the batch
    /// touched becomes one stored speaker: the speakers of one name (`SameNameSpeakers.joins`), together with those a
    /// speaker the batch named, linked, rejected or merged into was shown joined with (renaming "Alice" renames all
    /// of her). The one that stays is the lowest (ordinal, ID). Its person is the one the batch itself linked any of
    /// them to (the last such link), else its own link, else the link of the lowest (ordinal, ID) other one that has
    /// a link. The lines added, at the end: `excludeFromEnrollment` of the turns of each of them linked to another
    /// person (their voice is that person's), the merges, then a `linkProfile` of the one that stays when its link is
    /// not that person.
    ///
    /// Every line is in the caller's batch, so one undo takes back the change and everything added for it. A batch
    /// with a `revert` (an undo) is returned as it is, and so is one this view refuses (the editor reports why).
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
        // The asked actions, naming listed speakers; the shown groups they act on are kept together below.
        var shownAs: [String: ProjectedSpeaker] = [:]
        for speaker in speakers where speaker.memberIDs.count > 1 {
            for member in speaker.memberIDs { shownAs[member] = speaker }
        }
        var together: [[String]] = []
        func listed(_ speakerID: String) -> String {
            guard let speaker = shownAs[speakerID] else { return speakerID }
            together.append(speaker.memberIDs)
            return speaker.id
        }
        var result: [(action: SpeakerEditAction, added: Bool)] = []
        var linked: [(speakerID: String, profileID: String)] = []
        var named = Set<String>()
        for action in actions {
            switch action {
            case .rename(let speakerID, let name):
                let id = listed(speakerID)
                named.insert(id)
                result.append((.rename(speakerID: id, name: name), false))
            case .linkProfile(let speakerID, let profileID):
                let id = listed(speakerID)
                named.insert(id)
                linked.append((id, profileID))
                result.append((.linkProfile(speakerID: id, profileID: profileID), false))
            case .rejectProfile(let speakerID, let profileID):
                result.append((.rejectProfile(speakerID: listed(speakerID), profileID: profileID), false))
            case .merge(let from, let into):
                let target = listed(into)
                named.insert(target)
                guard let source = shownAs[from] else {
                    result.append((.merge(from: from, into: target), false))
                    continue
                }
                // A speaker shown joined with others moves with them.
                if source.id == target, from != into {
                    together.append(source.memberIDs)
                    continue
                }
                result.append((.merge(from: source.id, into: target), false))
                for member in source.memberIDs.dropFirst() where member != target {
                    result.append((.merge(from: member, into: target), true))
                }
            case .newSpeaker(let speakerID, _, _):
                named.insert(speakerID)
                result.append((action, false))
            case .reassignTurns(_, let to):
                if let to { named.insert(to) }
                result.append((action, false))
            case .splitTurn, .excludeFromEnrollment, .revert:
                result.append((action, false))
            }
        }

        // The labels after them.
        var after = self
        for (action, _) in result {
            let id = UUID().uuidString
            after = after.applying(action, editID: id)
            if after.staleEdits.contains(where: { $0.editID == id }) { return result }
        }
        let stored = after.state.speakers
        // Groups: the speakers of one name, and the shown groups the batch acted on.
        let joins = SameNameSpeakers.joins(stored, turns: after.state.turns)
        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var id = id
            while let up = parent[id], up != id { id = up }
            return id
        }
        func unite(_ ids: [String]) {
            let present = ids.filter { stored[$0] != nil }
            guard let first = present.first else { return }
            for id in present { if parent[id] == nil { parent[id] = id } }
            for id in present.dropFirst() {
                let (a, b) = (root(first), root(id))
                if a != b { parent[b] = a }
            }
        }
        for members in joins.members.values { unite(members) }
        for members in together { unite(members) }
        var groups: [String: [SpeakerState]] = [:]
        for id in parent.keys { if let speaker = stored[id] { groups[root(id), default: []].append(speaker) } }
        let touched = named.union(together.joined())
        for members in groups.values.map({ $0.sorted(by: SameNameSpeakers.precedes) })
            .sorted(by: { SameNameSpeakers.precedes($0[0], $1[0]) })
        where members.count > 1 && members.contains(where: { touched.contains($0.id) }) {
            let stays = members[0]
            let ids = Set(members.map(\.id))
            let person = linked.last { ids.contains($0.speakerID) }?.profileID
                ?? SameNameSpeakers.person(of: members, staying: stays)
            for member in members {
                guard let link = member.profileID, link != person else { continue }
                let turns = after.state.voiceTurns(of: member.id)
                if !turns.isEmpty { result.append((.excludeFromEnrollment(turnIDs: turns), true)) }
            }
            for member in members.dropFirst() { result.append((.merge(from: member.id, into: stays.id), true)) }
            if let person, person != stays.profileID {
                result.append((.linkProfile(speakerID: stays.id, profileID: person), true))
            }
        }
        return result
    }
}

extension SpeakerProjection.State {
    /// The turns `speakerID` holds that voice learning could still use (with words, not kept out of it), run order.
    func voiceTurns(of speakerID: String) -> [String] {
        turns.filter { $0.speakerID == speakerID && !$0.spans.isEmpty && !$0.excluded }.map(\.id)
    }
}
