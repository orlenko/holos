import AppKit
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import Testing
@testable import HolosApp

/// The meeting review's turn list laid out offscreen (the window is never shown), with synthetic turns: rows are
/// paragraphs (`ReviewParagraphs`), and what works per word or per turn keeps working inside one.
@MainActor
struct TurnListViewTests {
    /// T1 and T2 by S1 (a paragraph; T2's second word fixed), T3 by S2.
    static let turns = [
        turn("T1", "S1", 0, 2), turn("T2", "S1", 3, 5, uncertain: true), turn("T3", "S2", 6, 8),
    ]
    static let words: [String: [ReviewWord]] = [
        "T1": [word("T1", 0, "alpha", 0), word("T1", 1, "beta", 1)],
        "T2": [word("T2", 0, "gamma", 3),
               word("T2", 1, "delta", 4, fix: TranscriptWordFix(first: 1, end: 2, heard: "delt", kind: .correction))],
        "T3": [word("T3", 0, "epsilon", 6), word("T3", 1, "zeta", 7)],
    ]

    @Test func rowsAreParagraphsWithTheirTurnsTextJoined() throws {
        let list = Self.list()
        #expect(list.table.numberOfRows == 2)
        #expect(list.paragraphs.map(\.turnIDs) == [["T1", "T2"], ["T3"]])
        let cell = try Self.cell(list, row: 0)
        #expect(cell.bodyText.string == "alpha beta gamma delta")
        #expect(cell.timeButton.title == TimeFormat.clock(0))
        // A paragraph warns when one of its turns is uncertain.
        #expect(cell.warningLabel.stringValue == "⚠ unsure")
        #expect(try Self.cell(list, row: 1).warningLabel.stringValue.isEmpty)
    }

    @Test func aWordOfALaterTurnPlaysFromItsOwnStart() throws {
        let list = Self.list()
        let text = try Self.cell(list, row: 0).bodyText
        let rect = try #require(text.rect(ofWord: 3))
        #expect(text.wordStart(at: NSPoint(x: rect.midX, y: rect.midY)) == 4)
        // VoiceOver: a "Play from" action per word of the paragraph, and the fixed word's revert.
        let names = (text.accessibilityCustomActions() ?? []).map(\.name)
        #expect(names.filter { $0.hasPrefix("Play from") }.count == 4)
        #expect(names.contains("Revert to “delt”"))
        // The fixed word is underlined in the paragraph's text.
        let storage = try #require(text.textStorage)
        let delta = (storage.string as NSString).range(of: "delta")
        #expect(storage.attribute(.underlineStyle, at: delta.location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.toolTip, at: delta.location, effectiveRange: nil) as? String
            == TurnTextView.fixDescription(TranscriptWordFix(first: 1, end: 2, heard: "delt", kind: .correction)))
    }

    @Test func selectingARowSelectsEveryTurnOfIt() {
        let list = Self.list()
        list.select(["T2"], scroll: false)
        #expect(list.table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(list.selectedTurnIDs == ["T1", "T2"])
        list.select(["T1", "T3"], scroll: false)
        #expect(list.selectedTurnIDs == ["T1", "T2", "T3"])
        #expect(list.rowCount(of: ["T1", "T2"]) == 1)
        #expect(list.shows(turnID: "T3") && !list.shows(turnID: "T9"))
    }

    @Test func aRowsSpeakerPopUpAssignsEveryTurnOfIt() throws {
        let list = Self.list()
        var assigned: [([String], ReviewAssignTarget)] = []
        list.onAssign = { assigned.append(($0, $1)) }
        let popUp = try Self.cell(list, row: 0).speakerPopUp
        let index = try #require(popUp.itemArray.firstIndex {
            ($0.representedObject as? AssignChoice)?.kind == .target(.speaker("S2"))
        })
        popUp.selectItem(at: index)
        _ = popUp.sendAction(popUp.action, to: popUp.target)
        #expect(assigned.map(\.0) == [["T1", "T2"]])
        #expect(assigned.map(\.1) == [.speaker("S2")])
    }

    @Test func theParagraphAndWordPlayingAreTintedThroughAPause() throws {
        let list = Self.list()
        let text = try Self.cell(list, row: 0).bodyText
        let storage = try #require(text.textStorage)
        func tinted(_ word: String) -> Bool {
            let range = (storage.string as NSString).range(of: word)
            return text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location,
                                                          effectiveRange: nil) != nil
        }
        list.showPlaying(turnID: "T2", at: 4.2)
        #expect(list.playingParagraphID == "T1")
        #expect(tinted("delta") && !tinted("gamma"))
        // The pause between T1 and T2: still the same paragraph, its last word spoken.
        list.showPlaying(turnID: nil, at: 2.5)
        #expect(list.playingParagraphID == "T1")
        #expect(tinted("beta") && !tinted("delta"))
        // Silence between paragraphs.
        list.showPlaying(turnID: nil, at: 5.5)
        #expect(list.playingParagraphID == nil)
        #expect(!tinted("beta"))
        list.showPlaying(turnID: "T3", at: 6.5)
        #expect(list.playingParagraphID == "T3")
        list.clearPlaying()
        #expect(list.playingParagraphID == nil)
    }

    @Test func aHintInAParagraphGivesItsOwnTurn() throws {
        let hint = MeetingTurnHint(turnID: "T2", speakerID: "S2", profileID: "P", name: "Sam", distance: 0.1,
                                   ownDistance: 0.5)
        let list = Self.list(hints: ["T2": hint])
        var accepted: [String] = []
        list.onAcceptHint = { accepted.append($0) }
        let button = try Self.cell(list, row: 0).hintButton
        #expect(!button.isHidden && button.title == "⚠ Sam?")
        _ = button.sendAction(button.action, to: button.target)
        #expect(accepted == ["T2"])
    }

    @Test func aTurnJoiningAParagraphKeepsTheSelectionOnItsTurns() {
        let list = Self.list()
        list.select(["T3"], scroll: false)
        // T3 given to S1: it joins the paragraph before it.
        var moved = Self.turns
        moved[2] = Self.turn("T3", "S1", 6, 8)
        Self.update(list, turns: moved)
        #expect(list.table.numberOfRows == 1)
        #expect(list.selectedTurnIDs == ["T1", "T2", "T3"])
    }

    // MARK: - Helpers

    static func turn(_ id: String, _ speaker: String?, _ start: Double, _ end: Double,
                     uncertain: Bool = false) -> ProjectedTurn {
        ProjectedTurn(id: id, track: "system", start: start, end: end, speakerID: speaker, clusterID: speaker,
                      spans: [WordSpan(segmentID: id, first: 0, end: 2)], overlap: false, otherClusters: [],
                      assignmentScore: uncertain ? 0.4 : 1, timing: .measured, reassigned: false, modified: false,
                      excludedFromEnrollment: false, uncertain: uncertain)
    }

    static func word(_ segment: String, _ index: Int, _ text: String, _ start: Double,
                     fix: TranscriptWordFix? = nil) -> ReviewWord {
        ReviewWord(ref: WordRef(segmentID: segment, word: index), text: text, start: start, fix: fix)
    }

    static func speaker(_ id: String, _ ordinal: Int) -> ProjectedSpeaker {
        ProjectedSpeaker(id: id, ordinal: ordinal, name: "Speaker \(ordinal)", label: "Speaker \(ordinal)",
                         explicitName: nil, profileID: nil, provenance: .diarizer, isAutomatic: false,
                         suggestion: nil, rejectedProfileIDs: [], clusterIDs: [id], talkSeconds: 4, turnCount: 2)
    }

    /// The list in a 900 × 600 window that is never shown, laid out with `turns`.
    static func list(hints: [String: MeetingTurnHint] = [:]) -> TurnListView {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let list = TurnListView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = list
        windows.append(window)
        update(list, turns: turns, hints: hints)
        return list
    }

    static func update(_ list: TurnListView, turns: [ProjectedTurn], hints: [String: MeetingTurnHint] = [:]) {
        list.update(paragraphs: ReviewParagraphs.group(turns), speakers: [speaker("S1", 1), speaker("S2", 2)],
                    people: [], editable: true, hints: hints,
                    text: { turn in (words[turn.id] ?? []).map(\.text).joined(separator: " ") },
                    words: { turn in words[turn.id] ?? [] }, resolve: { $0 })
        list.layoutSubtreeIfNeeded()
        list.table.layoutSubtreeIfNeeded()
    }

    static func cell(_ list: TurnListView, row: Int) throws -> TurnCellView {
        let cell = try #require(list.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TurnCellView)
        cell.layoutSubtreeIfNeeded()
        if let layout = cell.bodyText.layoutManager, let container = cell.bodyText.textContainer {
            layout.ensureLayout(for: container)
        }
        return cell
    }

    static var windows: [NSWindow] = []
}
