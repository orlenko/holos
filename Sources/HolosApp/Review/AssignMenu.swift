import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers

/// A choice in a speaker menu (a turn's pop-up, "Assign to…").
final class AssignChoice: NSObject {
    enum Kind: Equatable {
        case target(ReviewAssignTarget)
        /// "New Speaker…": asks for an optional name first.
        case newSpeaker
    }

    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }
}

/// The first item of a row's speaker pop-up when a turn of it sounds like a person named in the meeting
/// ("Jim (suggested)"): choosing it gives that turn alone to that person's speaker (`ReviewSession.acceptTurnHint`).
final class HintChoice: NSObject {
    let turnID: String
    init(turnID: String) { self.turnID = turnID }
}

/// The items of a speaker menu: the meeting's speakers, the known people without a speaker in it, "Unknown", and
/// "New Speaker…". Menu items are made directly (never by title), so two speakers with one name stay apart.
@MainActor
enum AssignMenu {
    static func items(speakers: [ProjectedSpeaker], people: [SpeakerProfile], unknownTitle: String = "Unknown")
        -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for speaker in speakers {
            items.append(item(title(of: speaker), .target(.speaker(speaker.id))))
        }
        let linked = Set(speakers.compactMap(\.profileID))
        let others = people.filter { !linked.contains($0.id) }
        if !others.isEmpty {
            items.append(.separator())
            items.append(.sectionHeader(title: "People"))
            for person in others {
                items.append(item(person.displayName + (person.isSelf ? " (you)" : ""),
                                  .target(.person(profileID: person.id))))
            }
        }
        items.append(.separator())
        items.append(item(unknownTitle, .target(.unknown)))
        items.append(item("New Speaker…", .newSpeaker))
        return items
    }

    /// "Jim", "Speaker 3", "Jim (auto)", with the number key that assigns to it ("2 · Maria") for speakers 1–9.
    static func title(of speaker: ProjectedSpeaker) -> String {
        (1...9).contains(speaker.ordinal) ? "\(speaker.ordinal) · \(speaker.label)" : speaker.label
    }

    /// What a row's pop-up lists before its speakers when a turn of the row sounds like a person named in the meeting
    /// (`hint`, the row's first such turn): "Jim (suggested)", or in a row of several turns "Jim (suggested for the
    /// part from 00:12:03)", since it gives that turn alone, then a separator.
    static func suggestion(_ hint: MeetingTurnHint, in paragraph: ReviewParagraph) -> [NSMenuItem] {
        let turn = paragraph.turns.count > 1 ? paragraph.turns.first { $0.id == hint.turnID } : nil
        let part = turn.map { "the part from \(TimeFormat.clock($0.start))" }
        let item = NSMenuItem(title: hint.name + (part.map { " (suggested for \($0))" } ?? " (suggested)"),
                              action: nil, keyEquivalent: "")
        item.representedObject = HintChoice(turnID: hint.turnID)
        item.toolTip = suggestionHelp(hint, in: paragraph)
        return [item, .separator()]
    }

    /// "This turn sounds like Jim, whom you named in this meeting. Choose Jim (suggested) in the speaker menu to give
    /// it to Jim." (the item's tooltip, and the pop-up's).
    static func suggestionHelp(_ hint: MeetingTurnHint, in paragraph: ReviewParagraph) -> String {
        let turn = paragraph.turns.count > 1 ? paragraph.turns.first { $0.id == hint.turnID } : nil
        let what = turn.map { "The part from \(TimeFormat.clock($0.start))" } ?? "This turn"
        return "\(what) sounds like \(hint.name), whom you named in this meeting. Choose \(hint.name) (suggested) in "
            + "the speaker menu to give it to \(hint.name)."
    }

    private static func item(_ title: String, _ kind: AssignChoice.Kind) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = AssignChoice(kind)
        return item
    }
}
