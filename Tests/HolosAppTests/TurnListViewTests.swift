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
        // No warning column: a row is its time, its speaker pop-up, and its text, uncertain or not.
        #expect(cell.subviews.count == 3)
        #expect(cell.subviews.allSatisfy { $0 === cell.timeButton || $0 === cell.speakerPopUp || $0 === cell.bodyText })
        // VoiceOver hears that a turn of the paragraph is uncertain on its pop-up, and the tooltip says why.
        #expect(cell.speakerPopUp.accessibilityLabel() == "Speaker, uncertain")
        #expect(cell.speakerPopUp.toolTip == "The speaker is uncertain here.")
        #expect(try Self.cell(list, row: 1).speakerPopUp.accessibilityLabel() == "Speaker")
        #expect(try Self.cell(list, row: 1).speakerPopUp.toolTip == nil)
    }

    @Test func voiceOverHearsAnOverlapAndAnUnknownSpeakerAsUncertain() throws {
        let list = Self.list()
        Self.update(list, turns: [Self.turn("T1", "S1", 0, 2),
                                  Self.turn("T2", "S1", 3, 5, uncertain: true, overlap: true),
                                  Self.turn("T3", nil, 6, 8, uncertain: true)])
        let overlap = try Self.cell(list, row: 0)
        #expect(overlap.speakerPopUp.accessibilityLabel() == "Speaker, overlap")
        #expect(overlap.speakerPopUp.toolTip == "Someone else spoke at the same time.")
        let unknown = try Self.cell(list, row: 1)
        #expect(unknown.speakerPopUp.titleOfSelectedItem == "Unknown")
        #expect(unknown.speakerPopUp.accessibilityLabel() == "Speaker, uncertain")
        #expect(unknown.speakerPopUp.toolTip == "No speaker was found for this text.")
        #expect(unknown.subviews.count == 3)
    }

    @Test func nextUncertainStillSelectsAndShowsAnUncertainRowWithNothingMarkingIt() throws {
        // 30 rows, the uncertain one (an overlap) last and off screen: the window's Next Uncertain selects its turn
        // (`ReviewSession.nextUncertain`, then `select(_:scroll:)`), which selects the row and brings it into view.
        let list = Self.list()
        var turns: [ProjectedTurn] = []
        for index in 0..<30 {
            let speaker = index.isMultiple(of: 2) ? "S1" : "S2"
            turns.append(Self.turn("A\(index)", speaker, Double(index) * 10, Double(index) * 10 + 2,
                                   uncertain: index == 29, overlap: index == 29))
        }
        Self.update(list, turns: turns)
        #expect(!list.table.visibleRect.intersects(list.table.rect(ofRow: 29)))
        list.select(["A29"], scroll: true)
        #expect(list.table.selectedRowIndexes == IndexSet(integer: 29))
        #expect(list.table.visibleRect.intersects(list.table.rect(ofRow: 29)))
        let cell = try Self.cell(list, row: 29)
        #expect(cell.speakerPopUp.accessibilityLabel() == "Speaker, overlap")
        #expect(cell.subviews.count == 3)
        // The uncertain row is as tall as any one-line row: nothing is stacked beside its text.
        #expect(list.table.rect(ofRow: 29).height == list.table.rect(ofRow: 28).height)
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

    @Test func aHintIsTheFirstItemOfThePopUpAndChoosingItGivesItsTurnAlone() throws {
        // T2 (the second turn of row 0) sounds like Sam: the pop-up offers Sam first, naming the part it gives.
        let hint = MeetingTurnHint(turnID: "T2", speakerID: "S2", profileID: "P", name: "Sam", distance: 0.1,
                                   ownDistance: 0.5)
        let list = Self.list(hints: ["T2": hint])
        var accepted: [String] = []
        var assigned: [[String]] = []
        list.onAcceptHint = { accepted.append($0) }
        list.onAssign = { ids, _ in assigned.append(ids) }
        let popUp = try Self.cell(list, row: 0).speakerPopUp
        let first = try #require(popUp.itemArray.first)
        #expect(first.title == "Sam (suggested for the part from \(TimeFormat.clock(3)))")
        #expect((first.representedObject as? HintChoice)?.turnID == "T2")
        #expect(first.toolTip?.hasPrefix("The part from \(TimeFormat.clock(3)) sounds like Sam") == true)
        #expect(popUp.itemArray[1].isSeparatorItem)
        // The row's own speaker stays the one shown.
        #expect(popUp.titleOfSelectedItem == "1 · Speaker 1")
        #expect(popUp.accessibilityLabel() == "Speaker, sounds like Sam")
        // Chosen, even with both rows selected: the hinted turn alone is given (`onAcceptHint`, which the window
        // sends to `ReviewSession.acceptTurnHint`, as the old "⚠ Sam?" button did), never the row or the selection.
        list.select(["T1", "T3"], scroll: false)
        popUp.selectItem(at: 0)
        _ = popUp.sendAction(popUp.action, to: popUp.target)
        #expect(accepted == ["T2"])
        #expect(assigned.isEmpty)
        // Until the change comes back, the row shows its speaker again rather than the suggestion.
        #expect(try Self.cell(list, row: 0).speakerPopUp.titleOfSelectedItem == "1 · Speaker 1")
    }

    @Test func aOneTurnRowsHintIsJustSuggested() throws {
        let hint = MeetingTurnHint(turnID: "T3", speakerID: "S1", profileID: "P", name: "Sam", distance: 0.1,
                                   ownDistance: 0.5)
        let list = Self.list(hints: ["T3": hint])
        let popUp = try Self.cell(list, row: 1).speakerPopUp
        #expect(popUp.itemArray.first?.title == "Sam (suggested)")
        #expect(popUp.itemArray.first?.toolTip?.hasPrefix("This turn sounds like Sam") == true)
        // A row without a hint lists its speakers first, as before.
        let other = try Self.cell(list, row: 0).speakerPopUp
        #expect(!other.itemArray.contains { $0.representedObject is HintChoice })
        #expect(other.itemArray.first?.title == "1 · Speaker 1")
        // Read-only: the suggestion is there, the pop-up is not enabled (as the old button was not).
        Self.update(list, turns: Self.turns, hints: ["T3": hint], editable: false)
        #expect(try !Self.cell(list, row: 1).speakerPopUp.isEnabled)
    }

    @Test func aHintKeepsTheUncertaintyOfTheParagraphsOtherTurns() throws {
        // T1 sounds like Sam; T2 (the same row) is uncertain: VoiceOver hears both; nothing is stacked on the row.
        let hint = MeetingTurnHint(turnID: "T1", speakerID: "S2", profileID: "P", name: "Sam", distance: 0.1,
                                   ownDistance: 0.5)
        let list = Self.list(hints: ["T1": hint])
        let cell = try Self.cell(list, row: 0)
        #expect(cell.speakerPopUp.accessibilityLabel() == "Speaker, uncertain, sounds like Sam")
        #expect(cell.speakerPopUp.toolTip?.hasPrefix("The speaker is uncertain here. The part from") == true)
        #expect(cell.subviews.count == 3)
        let text = cell.bodyText.string
        #expect(list.table.rect(ofRow: 0).height - list.table.intercellSpacing.height
            == max(28, ceil(TurnTextView.height(of: text, width: cell.bodyText.frame.width)) + 10))
        // The hinted turn's own uncertainty gives way to its hint.
        let own = Self.list(hints: ["T2": MeetingTurnHint(turnID: "T2", speakerID: "S2", profileID: "P", name: "Sam",
                                                          distance: 0.1, ownDistance: 0.5)])
        #expect(try Self.cell(own, row: 0).speakerPopUp.accessibilityLabel() == "Speaker, sounds like Sam")
    }

    @Test func theTextTakesTheRowRightAfterThePopUp() throws {
        // A long paragraph: it starts right after the pop-up and runs to the row's end, no column reserved between.
        let list = Self.list()
        let long = (0..<60).map { Self.word("T3", $0, "word\($0)", 6 + Double($0) * 0.1) }
        let words: (ProjectedTurn) -> [ReviewWord] = { turn in (turn.id == "T3" ? long : Self.words[turn.id]) ?? [] }
        list.update(paragraphs: ReviewParagraphs.group(Self.turns),
                    speakers: [Self.speaker("S1", 1), Self.speaker("S2", 2)], people: [], editable: true,
                    text: { words($0).map(\.text).joined(separator: " ") }, words: words, resolve: { $0 })
        list.layoutSubtreeIfNeeded()
        let cell = try Self.cell(list, row: 1)
        #expect(TurnCellView.textX == 4 + TurnCellView.timeWidth + TurnCellView.gap + TurnCellView.popUpWidth
            + TurnCellView.gap)
        #expect(cell.bodyText.frame.minX == cell.speakerPopUp.frame.maxX + TurnCellView.gap + TurnCellView.textInset)
        #expect(abs(cell.bodyText.frame.maxX - (cell.bounds.width - 4 - TurnCellView.textInset)) < 0.5)
        // The row is as tall as its text wrapped at that width, so it wraps into the reclaimed width.
        let height = TurnTextView.height(of: cell.bodyText.string, width: cell.bodyText.frame.width)
        #expect(list.table.rect(ofRow: 1).height - list.table.intercellSpacing.height == max(28, ceil(height) + 10))
        #expect(height > 20, "The paragraph wraps.")
        // Edit mode: the field over the first word starts where the text does.
        list.editingWords = true
        list.table.handleWordClick(row: 1, word: 0, through: 0, extend: false)
        let first = try #require(cell.bodyText.rect(ofWord: 0))
        let wordX = list.table.convert(first, from: cell.bodyText).minX
        #expect(abs(wordX - list.table.convert(cell.bodyText.bounds, from: cell.bodyText).minX) < 0.5)
        #expect(abs(list.editField.frame.minX - (wordX - 4)) < 0.5)
    }

    @Test func aSpokenTurnASearchHidesTintsNoRow() {
        // T1 (shown) is interrupted by T9, which the search left out.
        let list = Self.list()
        let shown = [Self.turn("T1", "S1", 0, 10)]
        list.update(paragraphs: ReviewParagraphs.group(shown), speakers: [Self.speaker("S1", 1)], people: [],
                    editable: true, text: { _ in "alpha beta" }, words: { Self.words[$0.id] ?? [] },
                    resolve: { $0 })
        list.showPlaying(turnID: "T9", at: 4)
        #expect(list.playingParagraphID == nil)
        list.showPlaying(turnID: "T1", at: 1)
        #expect(list.playingParagraphID == "T1")
    }

    @Test func aTurnJoiningAParagraphNeverWidensTheSelection() {
        let list = Self.list()
        list.select(["T3"], scroll: false)
        // T3 given to S1: it joins the paragraph before it. That row holds turns that were not selected, so the
        // selection does not grow to them (a next assignment would move them too); it is cleared.
        var moved = Self.turns
        moved[2] = Self.turn("T3", "S1", 6, 8)
        Self.update(list, turns: moved)
        #expect(list.table.numberOfRows == 1)
        #expect(list.selectedTurnIDs.isEmpty)
        // A selected row that keeps its turns stays selected through an update.
        Self.update(list, turns: Self.turns)
        list.select(["T1"], scroll: false)
        #expect(list.selectedTurnIDs == ["T1", "T2"])
        var renamed = Self.turns
        renamed[2] = Self.turn("T3", "S2", 6, 8.5)
        Self.update(list, turns: renamed)
        #expect(list.selectedTurnIDs == ["T1", "T2"])
    }

    @Test func aPausedSeekFromAPauseToAPauseInAnotherParagraphReportsTheMove() {
        // 30 paragraphs, each two turns of one speaker with a pause between them; the last ones are off screen.
        let list = Self.list()
        var turns: [ProjectedTurn] = []
        for index in 0..<30 {
            let speaker = index.isMultiple(of: 2) ? "S1" : "S2"
            let start = Double(index) * 20
            turns.append(Self.turn("A\(index)", speaker, start, start + 2))
            turns.append(Self.turn("B\(index)", speaker, start + 4, start + 6))
        }
        Self.update(list, turns: turns)
        #expect(list.table.numberOfRows == 30)
        // In the pause of the first paragraph: no turn is spoken, the move is reported.
        #expect(list.showPlaying(turnID: nil, at: 3))
        #expect(!list.showPlaying(turnID: nil, at: 3.5), "Still the same paragraph: nothing moved.")
        let last = list.table.rect(ofRow: 29)
        #expect(!list.table.visibleRect.intersects(last))
        // A seek into the pause of the last paragraph: still no turn spoken at either end, yet the move is reported,
        // and following it brings that paragraph into view.
        #expect(list.showPlaying(turnID: nil, at: 29 * 20 + 3))
        #expect(list.playingParagraphID == "A29")
        list.scrollToPlaying()
        #expect(list.table.visibleRect.intersects(list.table.rect(ofRow: 29)))
    }

    @Test func aPausedSeekWithinATallParagraphReportsTheMoveAndFollowsTheWord() throws {
        // One speaker's 150 turns, each half a second apart: one paragraph far taller than the list.
        let list = Self.list()
        let turns = (0..<150).map { Self.turn("T\($0)", "S1", Double($0) * 2, Double($0) * 2 + 1.5) }
        let words = Dictionary(uniqueKeysWithValues: turns.map { turn in
            (turn.id, (0..<5).map { Self.word(turn.id, $0, "\(turn.id)w\($0)", turn.start + Double($0) * 0.25) })
        })
        list.update(paragraphs: ReviewParagraphs.group(turns), speakers: [Self.speaker("S1", 1)], people: [],
                    editable: true, text: { (words[$0.id] ?? []).map(\.text).joined(separator: " ") },
                    words: { words[$0.id] ?? [] }, resolve: { $0 })
        list.layoutSubtreeIfNeeded()
        #expect(list.table.numberOfRows == 1)
        #expect(list.table.rect(ofRow: 0).height > list.table.visibleRect.height)
        #expect(list.showPlaying(turnID: "T0", at: 0.1))
        list.scrollToPlaying()
        #expect(!list.showPlaying(turnID: "T0", at: 0.15), "Same word: nothing moved.")
        // A seek far down the same paragraph, while paused: only the word moved, and the list follows it.
        #expect(list.showPlaying(turnID: "T140", at: 280.6))
        list.scrollToPlaying()
        let cell = try Self.cell(list, row: 0)
        let word = try #require(cell.bodyText.rect(ofWord: 140 * 5 + 2))
        #expect(list.table.visibleRect.intersects(list.table.convert(word, from: cell.bodyText)))
    }

    // MARK: - Helpers

    static func turn(_ id: String, _ speaker: String?, _ start: Double, _ end: Double,
                     uncertain: Bool = false, overlap: Bool = false) -> ProjectedTurn {
        ProjectedTurn(id: id, track: "system", start: start, end: end, speakerID: speaker, clusterID: speaker,
                      spans: [WordSpan(segmentID: id, first: 0, end: 2)], overlap: overlap, otherClusters: [],
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

    static func update(_ list: TurnListView, turns: [ProjectedTurn], hints: [String: MeetingTurnHint] = [:],
                       editable: Bool = true) {
        list.update(paragraphs: ReviewParagraphs.group(turns), speakers: [speaker("S1", 1), speaker("S2", 2)],
                    people: [], editable: editable, hints: hints,
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
