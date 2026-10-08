import Foundation
import HolosCore
import HolosSpeakers

/// One row of the review's turn list (docs/meeting-design.md §5.10): consecutive turns of one speaker, read as one
/// paragraph. It is only how the turns are shown: edits still name its turns, which it lists in time order.
public struct ReviewParagraph: Sendable, Equatable, Identifiable {
    /// Never empty.
    public let turns: [ProjectedTurn]

    public init(turns: [ProjectedTurn]) {
        precondition(!turns.isEmpty, "A paragraph has at least one turn.")
        self.turns = turns
    }

    /// Its first turn's ID: a paragraph keeps its ID while turns join or leave it after the first.
    public var id: String { turns[0].id }
    public var turnIDs: [String] { turns.map(\.id) }
    /// Its first turn's start.
    public var start: Double { turns[0].start }
    /// The latest end of its turns (a turn may end after the one following it starts).
    public var end: Double { turns.dropFirst().reduce(turns[0].end) { max($0, $1.end) } }
    /// Every turn of a paragraph has this speaker (nil: the unknown speaker).
    public var speakerID: String? { turns[0].speakerID }
    /// Some turn of it is uncertain.
    public var uncertain: Bool { turns.contains(where: \.uncertain) }
    /// Some turn of it overlaps another speaker.
    public var overlap: Bool { turns.contains(where: \.overlap) }
    /// Every turn's words, in order: what its text and its height are made of.
    public var spans: [WordSpan] { turns.flatMap(\.spans) }

    public func contains(turnID: String) -> Bool { turns.contains { $0.id == turnID } }
}

/// What "Split Turn" on a paragraph does at a chosen word (`ReviewParagraphs.split`).
public enum ReviewParagraphSplit: Sendable, Equatable {
    /// The word is inside a turn: that turn is split before it (an edit, undone like any other). The second part
    /// starts a paragraph of its own.
    case splitTurn(turnID: String, at: WordRef)
    /// The word starts a turn of the paragraph: there is no turn to split, so the paragraph only breaks before that
    /// turn, in this window. Nothing is saved, so Undo has nothing to take back.
    case breakBefore(turnID: String)
}

/// What joining a row to the row before it does (`ReviewParagraphs.join`): Backspace at the start of a row in edit
/// mode, forward Delete at the end of the row before, or Join With Previous Turn.
public struct ReviewParagraphJoin: Sendable, Equatable {
    /// The later row's turns, which take the earlier row's speaker (one change, as the row's speaker pop-up makes);
    /// empty when they have it already.
    public let reassign: [String]
    /// The earlier row's speaker (nil: the unknown speaker).
    public let speakerID: String?
    /// The later row's turns, in order (never empty): the window joins each to the paragraph before it
    /// (`ReviewParagraphBreaks.join`), so the rows read as one whatever kept them apart (a break, a split's second
    /// part, the time gap), and the later row stays whole through its new speaker (a named speaker's microphone and
    /// system-audio turns given to the unknown speaker would otherwise part by track).
    public let turnIDs: [String]

    /// The later row's first turn, where the rows meet.
    public var turnID: String { turnIDs[0] }

    public init(reassign: [String], speakerID: String?, turnIDs: [String]) {
        precondition(!turnIDs.isEmpty, "A join joins at least one turn.")
        self.reassign = reassign
        self.speakerID = speakerID
        self.turnIDs = turnIDs
    }
}

/// The paragraph breaks "Split Turn" made in the window without splitting a turn (`ReviewParagraphSplit.breakBefore`),
/// and the joins a row joined to the row before it made (`join`), never saved. They belong to the run they were made
/// on: a new run drops them (a relabel gives turn IDs such as "T1" to other turns), except one published while the
/// window reverts a word fix (`beginCarryOver`), which keeps the same turns (their estimated starts may move): there a
/// break or a join follows its turn by ID and track. Within a run, each goes with its turn. A turn has one mark at
/// most: the later one asked replaces the other. A join may name its owner (the window's join that set it), so taking
/// that join back removes only marks it set itself and that nothing replaced since (`takeBack`). Pure.
public struct ReviewParagraphBreaks: Sendable, Equatable {
    /// What a turn has before it in the window.
    public enum Mark: Sendable, Equatable {
        case breakBefore
        /// Joined to the paragraph before it; `owner` names the join that set it (nil: none to take it back).
        case join(owner: String?)
    }

    private struct Held: Sendable, Equatable {
        var track: String
        var mark: Mark
    }

    /// Turn ID → its mark and track, on `runID`.
    private var marks: [String: Held] = [:]
    private var runID: String?
    /// Word-fix reverts in flight.
    private var carryOvers = 0

    public init() {}

    public var isEmpty: Bool { marks.isEmpty }

    /// The turns joined to the paragraph before them (`ReviewParagraphs.group`'s `joins`), as of the last `active`.
    public var joins: Set<String> {
        Set(marks.compactMap { id, held in
            if case .join = held.mark { return id }
            return nil
        })
    }

    /// Breaks the paragraph before `turn` of run `runID` (a join before it goes).
    public mutating func insert(before turn: ProjectedTurn, runID: String?) {
        start(runID)
        marks[turn.id] = Held(track: turn.track, mark: .breakBefore)
    }

    /// Joins `turn` of run `runID` to the paragraph before it (a break before it goes): it reads on in that paragraph
    /// while it has that paragraph's speaker, whatever the time gap, and also as a split's second part. `owner`: the
    /// join that sets it, which alone may take it back.
    public mutating func join(_ turn: ProjectedTurn, runID: String?, owner: String? = nil) {
        start(runID)
        marks[turn.id] = Held(track: turn.track, mark: .join(owner: owner))
    }

    /// The mark before `turnID` (nil: none).
    public func mark(of turnID: String) -> Mark? { marks[turnID]?.mark }

    /// Takes back the join `owner` set before `turn`, putting back what the turn had before it (`before`), only while
    /// that join is still the turn's mark: a mark set since (a later join, a break) is never undone by it.
    public mutating func takeBack(_ owner: String, before: Mark?, of turn: ProjectedTurn) {
        guard marks[turn.id]?.mark == .join(owner: owner) else { return }
        marks[turn.id] = before.map { Held(track: turn.track, mark: $0) }
    }

    /// A break or join made on another run than the ones held starts afresh.
    private mutating func start(_ runID: String?) {
        guard runID != self.runID else { return }
        marks = [:]
        self.runID = runID
    }

    /// A word-fix revert starts: the runs it publishes keep the turns.
    public mutating func beginCarryOver() { carryOvers += 1 }

    /// A word-fix revert ended (however it ended): with `turns` of `runID` as they now are, the breaks are taken over
    /// once more, then no longer carried over unless another revert is in flight.
    public mutating func endCarryOver(turns: [ProjectedTurn], runID: String?) {
        _ = active(in: turns, runID: runID)
        carryOvers = max(0, carryOvers - 1)
    }

    /// The turns of `turns` (of run `runID`) to break before (`ReviewParagraphs.group`); the joins kept are `joins`
    /// then. A new run that is not carried over drops every break and join; otherwise each stays while a turn with
    /// its ID and track does. `keepsTurnsOf` says whether `runID` replaced a given earlier run keeping its turns (a
    /// word edit in Review, or its undo, `ReviewSession.keepsTurns`): the breaks and joins of that run are carried
    /// over too. `resolve` gives the ID a turn held now has (`ReviewSession.resolvedTurnID`): a break or join made on
    /// a split's second part while the split was still saving names its temporary ID, which the saved split replaces.
    public mutating func active(in turns: [ProjectedTurn], runID: String?,
                                keepsTurnsOf: (String) -> Bool = { _ in false },
                                resolve: (String) -> String = { $0 }) -> Set<String> {
        guard !isEmpty else {
            self.runID = runID
            return []
        }
        if runID != self.runID {
            let kept = self.runID.map(keepsTurnsOf) ?? false
            self.runID = runID
            guard carryOvers > 0 || kept else {
                marks = [:]
                return []
            }
        }
        let held = Dictionary(marks.map { (resolve($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        var kept: [String: Held] = [:]
        for turn in turns {
            if let mark = held[turn.id], mark.track == turn.track { kept[turn.id] = mark }
        }
        marks = kept
        return Set(kept.compactMap { $0.value.mark == .breakBefore ? $0.key : nil })
    }
}

/// How the review shows turns as paragraphs (docs/meeting-design.md §5.10). Pure.
///
/// A turn joins the paragraph before it when it has the same speaker and starts less than `gapSeconds` after the
/// latest end of the paragraph's turns; an unknown speaker's turns join only on the same track (as in the exports), so
/// an unknown microphone turn never joins an unknown system-audio one, nor a named speaker's. A named speaker's
/// microphone and system-audio turns do join. A turn starts a paragraph of its own when it is the second part of a
/// split ("T5/…"), when the window was asked to break before it (`breaks`), or when its start or the paragraph's end
/// is not a number. A turn the window joined to the paragraph before it (`joins`, a row joined to the row before)
/// joins it whenever it has the same speaker, whatever else would keep it apart.
public enum ReviewParagraphs {
    /// Turns of one speaker this many seconds apart or more are separate paragraphs.
    public static let gapSeconds = 3.0

    /// `turns` (in the projection's order, which is time order) as paragraphs, in the same order.
    public static func group(_ turns: [ProjectedTurn], breaks: Set<String> = [], joins: Set<String> = [],
                             gapSeconds: Double = gapSeconds) -> [ReviewParagraph] {
        var paragraphs: [ReviewParagraph] = []
        var open: [ProjectedTurn] = []
        var openEnd = 0.0
        for turn in turns {
            if let first = open.first, let last = open.last, first.speakerID == turn.speakerID,
               joins.contains(turn.id) || (turn.speakerID != nil || last.track == turn.track)
                   && !turn.id.contains("/") && !breaks.contains(turn.id)
                   && turn.start.isFinite && openEnd.isFinite && turn.start - openEnd < gapSeconds {
                open.append(turn)
                openEnd = max(openEnd, turn.end)
                continue
            }
            if !open.isEmpty { paragraphs.append(ReviewParagraph(turns: open)) }
            open = [turn]
            openEnd = turn.end
        }
        if !open.isEmpty { paragraphs.append(ReviewParagraph(turns: open)) }
        return paragraphs
    }

    /// The paragraph shown for time `time` when no turn is being spoken: the one whose span (its first start to its
    /// latest end) holds it, so a pause inside a paragraph keeps it the one playing. Nil in silence between
    /// paragraphs.
    public static func index(at time: Double, in paragraphs: [ReviewParagraph]) -> Int? {
        ReviewTimeline.turnIndex(at: time, turns: paragraphs.map { ($0.start, $0.end) })
    }

    /// The paragraph's word (an index into its turns' words, in order) playing at `time`.
    ///
    /// With `turnID` (the turn being spoken) one of the paragraph's turns: its word being spoken, or the word before
    /// it when that turn has not reached its first word. Otherwise (a pause inside the paragraph): the last word of the
    /// turn that finished last by then (of the turns started by then, the latest end; ties to the later turn), so a
    /// short turn inside a long one never takes over once the long one ends. Nil before the paragraph's first word.
    /// `starts` are each turn's word starts.
    public static func playingWord(in paragraph: ReviewParagraph, turnID: String?, at time: Double,
                                   starts: [[Double]]) -> Int? {
        var offsets: [Int] = []
        var total = 0
        for index in paragraph.turns.indices {
            offsets.append(total)
            total += index < starts.count ? starts[index].count : 0
        }
        if let turnID, let turn = paragraph.turns.firstIndex(where: { $0.id == turnID }) {
            let within = turn < starts.count ? ReviewTimeline.wordIndex(at: time, starts: starts[turn]) : nil
            let word = offsets[turn] + (within ?? -1)
            return word >= 0 ? word : nil
        }
        var latest: Int?
        for (index, turn) in paragraph.turns.enumerated() where turn.start <= time {
            if let current = latest, paragraph.turns[current].end > turn.end { continue }
            latest = index
        }
        guard let latest else { return nil }
        let end = offsets[latest] + (latest < starts.count ? starts[latest].count : 0)
        return end > 0 ? end - 1 : nil
    }

    /// "Split Turn" on `paragraph` before its word `index` (into its turns' words in order; `words` are each turn's
    /// words): splits the turn holding that word, or breaks the paragraph before the turn it starts. Nil for the
    /// paragraph's first word or an index past its words.
    public static func split(_ paragraph: ReviewParagraph, words: [[ReviewWord]], at index: Int) -> ReviewParagraphSplit? {
        guard index > 0 else { return nil }
        var offset = 0
        for (turnIndex, turn) in paragraph.turns.enumerated() {
            let turnWords = turnIndex < words.count ? words[turnIndex] : []
            if index < offset + turnWords.count {
                let word = index - offset
                return word == 0 ? .breakBefore(turnID: turn.id) : .splitTurn(turnID: turn.id, at: turnWords[word].ref)
            }
            offset += turnWords.count
        }
        return nil
    }

    /// Joins `later` to `earlier`, the paragraph shown just before it, as removing the line break between two
    /// paragraphs of text does: every turn of `later` takes `earlier`'s speaker (nothing to change when it has it), and
    /// `later`'s first turn is joined to the paragraph before it, so whatever kept them apart (a break the window made,
    /// a split's second part, the time gap) no longer does.
    public static func join(_ later: ReviewParagraph, to earlier: ReviewParagraph) -> ReviewParagraphJoin {
        ReviewParagraphJoin(reassign: later.speakerID == earlier.speakerID ? [] : later.turnIDs,
                            speakerID: earlier.speakerID, turnIDs: later.turnIDs)
    }
}
