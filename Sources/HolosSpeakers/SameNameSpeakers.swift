import Foundation
import HolosCore

/// "Same name, same person" (docs/meeting-design.md §4.9, "Speakers with the same name"): within one meeting, two
/// speakers whose names compare equal under `key(_:)` are shown as one speaker, unless the journal links them to two
/// or more different people (then they are those people, shown apart).
///
/// It is display only. `SpeakerProjection` lists such speakers as one (`joins`), so every reader of the projection
/// (the exports, Review, the CLI, summaries) shows one person, also for journals saved before this rule and for names
/// carried over by Label Again. Nothing is ever merged automatically: the journal keeps every stored speaker with its
/// own link and its own voice (`SpeakerProjection.unjoined`, which voice data reads). An edit of a speaker shown joined
/// reaches each stored speaker it shows (`SpeakerProjection.fanningOut`), so they stay alike.
///
/// The joins read only the journal (the names given, the channel's, and whether the links differ), never the people
/// store, so every projection of a meeting joins the same speakers the same way whoever builds it.
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
        /// The one shown → the person shown for them (`person(of:staying:)`).
        var person: [String: String] = [:]

        var isEmpty: Bool { into.isEmpty }
    }

    /// The stored speakers with one name (`nameKey`), among those that hold a turn with words or were created by
    /// `newSpeaker`, when they are linked to at most one person between them (in the journal; never the people
    /// store): speakers of one name linked to two different people are two people, shown apart. The one shown is the
    /// lowest (ordinal, ID): fixed by the journal (a newer speaker never takes over an older one's place), whatever
    /// talk time or masks say; its person is the one link of the group, if any.
    static func joins(_ speakers: [String: SpeakerProjection.SpeakerState],
                      turns: [SpeakerProjection.TurnState]) -> Joins {
        var holding = Set<String>()
        for turn in turns where !turn.spans.isEmpty { if let id = turn.speakerID { holding.insert(id) } }
        var byName: [String: [SpeakerProjection.SpeakerState]] = [:]
        for speaker in speakers.values where holding.contains(speaker.id) || speaker.isUserCreated {
            if let key = nameKey(of: speaker) { byName[key, default: []].append(speaker) }
        }
        var joins = Joins()
        // Linked to two or more different people, speakers of one name are those people (the journal says so): they
        // are shown apart, as linked, and nothing reaches from one to another.
        for group in byName.values where group.count > 1 && Set(group.compactMap(\.profileID)).count <= 1 {
            let ordered = group.sorted(by: precedes)
            let shown = ordered[0]
            joins.members[shown.id] = ordered.map(\.id)
            let person = person(of: ordered, staying: shown)
            if let person { joins.person[shown.id] = person }
            for member in ordered.dropFirst() { joins.into[member.id] = shown.id }
        }
        return joins
    }

    /// (ordinal, ID) order: the first of a group is the one that stays.
    static func precedes(_ left: SpeakerProjection.SpeakerState, _ right: SpeakerProjection.SpeakerState) -> Bool {
        (left.ordinal, left.id) < (right.ordinal, right.id)
    }

    /// The person shown for a group of one name: the link of the one shown, else the link of the lowest (ordinal, ID)
    /// other one that has a link. Nil when none has one. Display only: each stored speaker keeps its own link, and its
    /// voice stays that person's.
    static func person(of members: [SpeakerProjection.SpeakerState],
                       staying: SpeakerProjection.SpeakerState) -> String? {
        staying.profileID ?? members.sorted(by: precedes).lazy.compactMap(\.profileID).first
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
    /// The listed speaker shown under `name` as same-named speakers are joined: the name it is joined by in the journal
    /// (`SameNameSpeakers.nameKey`: the name the user gave, else the channel speaker's own, "Me", linked or not)
    /// matches under `SameNameSpeakers.key`. Since the display joins every speaker of that name, there is at most one;
    /// a name shown only through a link or an automatic match is not one, so it is never picked among speakers it does
    /// not join. Nil when none is. Naming new speakers by it ("New Speaker…" with a name already in the meeting) gives
    /// the turns to that speaker instead of making a second one.
    public func speaker(named name: String) -> ProjectedSpeaker? {
        guard let key = SameNameSpeakers.key(name) else { return nil }
        let matching = speakers.filter { speaker in
            state.speakers[speaker.id].flatMap(SameNameSpeakers.nameKey(of:)) == key
        }
        return matching.count == 1 ? matching[0] : nil
    }

    /// `actions` as `SpeakerEditor` saves them on this view: an edit of any stored speaker of a same-name group
    /// (`SameNameSpeakers.joins` on the journal's state: the speaker shown, or any it shows) also made to each other
    /// stored speaker of that group, so they stay alike. `SpeakerEditor` works it out under the speaker lock on the
    /// current labels; Review shows its queued changes through it on the labels shown, so what it shows is what is
    /// saved. Keyed by the group, not by which speaker is shown: an edit made on a view where another speaker has since
    /// joined the group, and is shown now, still reaches all of it.
    ///
    /// - A rename (or clearing the name), a link, or a rejection ("Not Jim") of one of them is made to each of the
    ///   others, in the order asked, one stored speaker after another.
    /// - A merge of one of them into another speaker moves each of them into it (as merging a speaker always did).
    /// - Everything else (turns given to the speaker shown, new speakers, splits, exclusions) is left as it is: turns
    ///   given to the speaker shown go to the one shown.
    ///
    /// Nothing is merged otherwise: naming a speaker as another is named only renames it, and the display joins them.
    /// The lines added follow the asked ones, in the batch; one undo takes all of them back. A batch with a `revert`
    /// (an undo) is returned as it is.
    public func fanningOut(_ actions: [SpeakerEditAction]) -> [SpeakerEditAction] {
        fanningOutMarked(actions).map(\.action)
    }

    /// `fanningOut`, each line marked `added` when it is one of the lines added for the stored speakers a joined speaker
    /// shows, rather than one of `actions`.
    public func fanningOutMarked(_ actions: [SpeakerEditAction]) -> [(action: SpeakerEditAction, added: Bool)] {
        let asked = actions.map { (action: $0, added: false) }
        guard !actions.contains(where: { if case .revert = $0 { true } else { false } }) else { return asked }
        // The groups as the journal's state has them (`SameNameSpeakers.joins`): every stored speaker of a name,
        // whichever one is shown and whatever the echo mask hides, so an edit made on a view where another speaker
        // has since joined the group (and is now the one shown) still reaches all of it.
        let joins = SameNameSpeakers.joins(state.speakers, turns: state.turns)
        var group: [String: [String]] = [:]
        for members in joins.members.values { for member in members { group[member] = members } }
        guard !group.isEmpty else { return asked }
        // Per stored speaker edited, its edits to repeat on the others of its group.
        var repeated: [String: [SpeakerEditAction]] = [:]
        var order: [String] = []
        var merges: [SpeakerEditAction] = []
        for action in actions {
            switch action {
            case .rename(let speakerID, _), .linkProfile(let speakerID, _), .rejectProfile(let speakerID, _):
                guard group[speakerID] != nil else { continue }
                if repeated[speakerID] == nil { order.append(speakerID) }
                repeated[speakerID, default: []].append(action)
            case .merge(let from, let into):
                guard let members = group[from] else { continue }
                let target = joins.into[into] ?? into
                merges += members.filter { $0 != from && $0 != target }.map { .merge(from: $0, into: target) }
            case .reassignTurns, .splitTurn, .newSpeaker, .excludeFromEnrollment, .revert:
                break
            }
        }
        var added: [SpeakerEditAction] = []
        for edited in order {
            for member in group[edited] ?? [] where member != edited {
                for action in repeated[edited] ?? [] {
                    switch action {
                    case .rename(_, let name): added.append(.rename(speakerID: member, name: name))
                    case .linkProfile(_, let profileID): added.append(.linkProfile(speakerID: member, profileID: profileID))
                    case .rejectProfile(_, let profileID):
                        added.append(.rejectProfile(speakerID: member, profileID: profileID))
                    default: break
                    }
                }
            }
        }
        return asked + (added + merges).map { (action: $0, added: true) }
    }
}
