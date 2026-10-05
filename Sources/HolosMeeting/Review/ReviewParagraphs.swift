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

/// How the review shows turns as paragraphs (docs/meeting-design.md §5.10). Pure.
///
/// A turn joins the paragraph before it when it has the same speaker and starts less than `gapSeconds` after the
/// latest end of the paragraph's turns; an unknown speaker's turns join only on the same track (as in the exports), so
/// an unknown microphone turn never joins an unknown system-audio one, nor a named speaker's. A named speaker's
/// microphone and system-audio turns do join. A turn starts a paragraph of its own when it is the second part of a
/// split ("T5/…"), when the window was asked to break before it (`breaks`), or when its start or the paragraph's end
/// is not a number.
public enum ReviewParagraphs {
    /// Turns of one speaker this many seconds apart or more are separate paragraphs.
    public static let gapSeconds = 3.0

    /// `turns` (in the projection's order, which is time order) as paragraphs, in the same order.
    public static func group(_ turns: [ProjectedTurn], breaks: Set<String> = [],
                             gapSeconds: Double = gapSeconds) -> [ReviewParagraph] {
        var paragraphs: [ReviewParagraph] = []
        var open: [ProjectedTurn] = []
        var openEnd = 0.0
        for turn in turns {
            if let first = open.first, let last = open.last, first.speakerID == turn.speakerID,
               turn.speakerID != nil || last.track == turn.track,
               !turn.id.contains("/"), !breaks.contains(turn.id),
               turn.start.isFinite, openEnd.isFinite, turn.start - openEnd < gapSeconds {
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
    /// latest turn started by then. Nil before the paragraph's first word. `starts` are each turn's word starts.
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
            if let current = latest, paragraph.turns[current].start > turn.start { continue }
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
}
