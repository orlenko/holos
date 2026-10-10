import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// Where "Assign to…" (and a turn's speaker pop-up) sends turns.
public enum ReviewAssignTarget: Sendable, Equatable {
    /// A speaker of this meeting.
    case speaker(String)
    /// The unknown speaker.
    case unknown
    /// A new speaker of this meeting, optionally named; a name a listed speaker already has gives the turns to that
    /// speaker instead (same name, same person).
    case newSpeaker(name: String?)
    /// A known person: the meeting's speaker linked to them, else the one called their name, else a new speaker linked
    /// to them.
    case person(profileID: String)
}

/// What the window showed when the person acted (an edit field opened, a split or a join asked for), as
/// `ReviewSession.revision` gave it then: handed back with the command, so the review follows the words to where they
/// are now through the word moves saved since, or refuses the command when the words or the labels were changed
/// elsewhere.
public struct ReviewRevision: Sendable, Equatable {
    /// How many of the review's word moves (`ReviewSession.wordMoves`) the words shown follow.
    public var moves: Int
    /// `ReviewSession.wordsEpoch`: words changed elsewhere since (no word move says where they went) cannot be
    /// followed.
    public var wordsEpoch: Int
    /// The speaker labels' run the turns were shown from (`SpeakerProjection.runID`): labelled again since (a new run
    /// that did not keep them), a turn ID may name another turn.
    public var runID: String?

    public init(moves: Int = 0, wordsEpoch: Int = 0, runID: String? = nil) {
        self.moves = moves
        self.wordsEpoch = wordsEpoch
        self.runID = runID
    }
}

/// Where a split at a word falls (`ReviewSession.splitPlace`).
public enum ReviewSplitPlace: Sendable, Equatable {
    /// Inside a turn: it splits before `word`.
    case inside(turnID: String, word: WordRef)
    /// At the turn's first word: no turn splits; a row may break before it.
    case turnStart(turnID: String)
    /// After the turn's last word: no turn splits; a row may break after it.
    case turnEnd(turnID: String)
}

/// A word edit saved in Review (`ReviewSession.editWords`).
public struct ReviewWordEdit: Sendable, Equatable {
    /// What the recognizer wrote over the edited span.
    public let heard: String
    /// The span's new text.
    public let meant: String
    /// The words were deleted: merged into a neighbour, which `meant` is, or removed with their whole segment (`meant`
    /// is empty).
    public let deletion: Bool
    /// The shown words just before and after the span in its segment, when there are some.
    public let before: String?
    public let after: String?
    /// What the recognizer wrote for `before` and `after`, when a fix changed them (an automatic correction made
    /// "cloud" "Claude"): the heard side of a learned correction is the recognizer's text throughout ("as cloud" →
    /// "ask Claude"), as corrections are matched against it. Nil: as shown.
    public let heardBefore: String?
    public let heardAfter: String?
    /// What was typed for the selected words (`meant` also holds any word the edit took in around them, the rest of
    /// an automatic fix: "New Yorkshire" when only "York" of "New York" became "Yorkshire"); nil when not known.
    public let typed: String?
    /// What the recognizer wrote for exactly the selected words; nil when the edit took in others (it is then not
    /// known for them alone).
    public let typedHeard: String?

    public init(heard: String, meant: String, deletion: Bool = false, before: String? = nil, after: String? = nil,
                heardBefore: String? = nil, heardAfter: String? = nil, typed: String? = nil,
                typedHeard: String? = nil) {
        self.heard = heard; self.meant = meant; self.deletion = deletion; self.before = before; self.after = after
        self.heardBefore = heardBefore; self.heardAfter = heardAfter; self.typed = typed; self.typedHeard = typedHeard
    }
}

/// One word of a turn, for choosing where to split it.
public struct ReviewWord: Sendable, Equatable {
    public let ref: WordRef
    public let text: String
    /// Session time.
    public let start: Double
    /// For a word the meeting word-fix stage changed or the person edited here (`TranscriptSegment.fixes`): what the
    /// recognizer wrote there, and what made the change. Nil for every other word.
    public let fix: TranscriptWordFix?
    /// `fix` can be reverted (and the word edited) here. False for words edited together that a relabel (Find More
    /// Speakers, Label Speakers on My Microphone) has since put in two turns: their Revert, and any edit of them (it
    /// takes in the whole mark), would be an edit across turns and refused. The other words of each turn can be edited.
    public let revertible: Bool
    /// The word as the transcript shows it (`TranscriptWordEdit.shownText`: with the punctuation the recognizer did not
    /// time, "Hello." for a timed "Hello"): what an edit of it expects to find (`editWords(expecting:)`).
    public let shown: String

    public init(ref: WordRef, text: String, start: Double, fix: TranscriptWordFix? = nil, revertible: Bool = true,
                shown: String? = nil) {
        self.ref = ref; self.text = text; self.start = start; self.fix = fix; self.revertible = revertible
        self.shown = shown ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A segment whose every word was deleted in Review (`TranscriptSegment.removed`), as the window offers to restore it
/// (`ReviewSession.deletedWords(near:)`).
public struct ReviewDeletedWords: Sendable, Equatable {
    public let segmentID: String
    /// The words as they showed before they were deleted.
    public let text: String
    /// Session times and track of the segment.
    public let start: Double
    public let end: Double
    public let track: String?

    public init(segmentID: String, text: String, start: Double, end: Double? = nil, track: String? = nil) {
        self.segmentID = segmentID; self.text = text; self.start = start; self.end = end ?? start
        self.track = track
    }
}

extension ReviewSession {
    /// What the word checks need of the whole meeting, read once per labels read, off the main actor
    /// (`WordChecks.read`, started by `adopt`; the review opens with them read): the unfixed revision the transcript
    /// was fixed from, whether a segment ID is used twice, and whether the labels can be mapped by time across the
    /// whole transcript (what every revert's labels need: a segment damaged anywhere refuses it). A click then reads
    /// no file and makes no plan (`wordEditRefusal`, `revertRefusal`).
    struct WordChecks: Sendable {
        /// The labels read these are for (`key(of:)`).
        var key: String
        /// The revision the transcript was fixed from; nil when it is unfixed, or when it cannot be read
        /// (`baseUnreadable`).
        var base: Transcript?
        var baseUnreadable = false
        var repeatedIDs = false
        /// Why no automatic fix can be reverted: the labels' plan onto the transcript itself, mapped by time as a
        /// revert's is (`SpeakerTranscriptRetarget.plan`: a damaged segment anywhere, fix counts that do not hold, a
        /// speaker change that cannot be carried over), refused. Nil when it is made.
        var revertRefusal: String?

        nonisolated static func key(of snapshot: SpeakerSessionSnapshot) -> String {
            "\(snapshot.transcript.id)\u{1f}\(snapshot.run?.id ?? "")\u{1f}\(snapshot.journal.edits.count)"
        }

        /// Reads files and walks every turn: off the main actor only. Throws `CancellationError` when its task is
        /// cancelled (checked between the steps, and per segment and turn inside the labels' plan).
        nonisolated static func read(_ snapshot: SpeakerSessionSnapshot, session: URL) throws -> WordChecks {
            var checks = WordChecks(key: key(of: snapshot))
            if let id = snapshot.transcript.fixedFrom {
                checks.base = try? SessionFiles.transcript(id: id, session: session)
                checks.baseUnreadable = checks.base == nil
            }
            try Task.checkCancellation()
            checks.repeatedIDs = TranscriptWordEdit.hasRepeatedSegmentIDs(snapshot.transcript)
            do {
                if try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: snapshot.transcript,
                                                      unfixed: checks.base, voiceData: false) == nil {
                    checks.revertRefusal = SessionWordFixRevert.labelsNotKept.localizedDescription
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                checks.revertRefusal = error.localizedDescription
            }
            return checks
        }

        /// The revision the transcript was fixed from, as a save reads it; nil when it is unfixed. Throws
        /// `baseUnreadable` when it cannot be read.
        func shownBase(fixed: Bool) throws -> Transcript? {
            guard fixed else { return nil }
            guard let base else { throw ReviewSession.baseUnreadable }
            return base
        }
    }

    /// One change of the window's undo: the batches it saved, newest last. `order` keeps entries in the order their
    /// changes were saved when one is put back.
    struct UndoEntry {
        let order: Int
        let batches: [String]
        /// A word edit's undo (it saved no batch).
        var wordEdit: WordEditUndo? = nil
    }

    /// How to take back a saved word edit: make `previous` current again while `edited` is.
    struct WordEditUndo {
        /// The transcript the edit was made on.
        let previous: String
        /// The transcript the edit published.
        let edited: String
        /// The segment it edited (a split waiting in the queue there is refused once it is undone).
        let segmentID: String
        /// How it moved the segment's words (undone by its inverse).
        let move: ReviewWordMove
        /// The move its speaker labels were mapped by, whose inverse maps them back.
        let labelsMove: ReviewWordMove
    }

    /// One queued change or task.
    ///
    /// Invariants:
    /// 1. `lifecycle` only moves forward, through `start` and `finish`: queued, then running, then finished; or queued,
    ///    then finished without running (dropped by an undo, refused as stale, held at close: `finished(ran: false)`).
    /// 2. The states that combine stay separate fields, never folded into `lifecycle`: `undone` (an undo asked while
    ///    it was queued or running; cleared when that undo fails), `superseded` and `overtaken` (set together by
    ///    `adopted(headChanged:)`, only while it runs; both can be set), and `savedUnreloaded` (set while it runs when
    ///    its saved lines cannot be reread; cleared by the reread that shows them).
    /// 3. `finish` records the result and resumes whoever waits, once (the continuation is cleared).
    @MainActor final class Operation {
        enum Lifecycle: Equatable {
            /// Waiting in the queue.
            case queued
            /// Running now (the one operation that does: `ReviewSession` invariant 2).
            case running
            /// Out of the queue; `ran`: it had started.
            case finished(ran: Bool)
        }

        enum UndoTarget {
            /// An entry taken off the undo stack.
            case saved(UndoEntry)
            /// Whatever an earlier queued change saves.
            case operation(Operation)
        }

        enum Kind {
            case edit([SpeakerEditAction], requireCompleteJournal: Bool = false)
            /// `byName`: from the name field; a `.new` target is linked to a person of that name existing at save time.
            case link(speakerID: String, target: ProfileTarget, learnVoice: Bool, byName: Bool)
            /// `create` gives the turns to `speakerID` (a new speaker, or a listed one already called the person's
            /// name), which is then linked to the person; one change.
            case assignPerson(create: SpeakerEditAction, speakerID: String, profileID: String, learnVoice: Bool)
            case confirmAll(learnVoices: Bool, suggestions: [String: String])
            case markSelf(speakerID: String, learnVoice: Bool)
            case undo(UndoTarget)
            case revertWordFix(WordRef)
            /// `segment`: the segment as it was when the edit was asked for; the edit is refused when it changed.
            case editWords(TranscriptWordEdit.Request, segment: TranscriptSegment)
            case relabel([String])
            case reload
            case exports
        }

        let kind: Kind
        /// `savedVersion` when the change was made.
        let basis: Int
        /// The head run of the saved labels when the change was made.
        let runID: String?
        /// Actions shown at once (turn IDs as the window had them) and their optimistic edit IDs.
        let optimistic: [SpeakerEditAction]
        let optimisticIDs: [String]
        /// Where it is in its life (invariant 1).
        private(set) var lifecycle = Lifecycle.queued
        /// Undone before it was saved: not shown, and an undo reverts what it saves.
        var undone = false
        /// Labels were adopted while it ran (its own result, or a reload after a refusal): the saved labels now
        /// show whatever it did, so its optimistic actions are no longer shown.
        private(set) var superseded = false
        /// The labels reread while it ran have a head made elsewhere (a relabel or a replacement landed between its
        /// save and the reread): the undo stack was emptied for it, and it gets no undo entry either, since its own
        /// head is no longer the current one.
        private(set) var overtaken = false
        /// Batches it saved.
        var batches: [String] = []
        /// It saved lines that could not be reread: kept in `unreloaded` until labels read from disk show them.
        var savedUnreloaded = false
        /// How to find the batches it saved but could not reread (`adopt`).
        var claims: [([SpeakerEdit]) -> Bool] = []
        /// A word edit it saved: how to undo it, and what was edited.
        var wordEdit: WordEditUndo?
        var wordEditResult: ReviewWordEdit?
        /// `wordMoves.count` when it was queued: a word edit follows its words through the moves saved since.
        var movesSeen = 0
        var continuation: CheckedContinuation<Void, any Error>?
        /// How it finished, for a change nobody waits on yet (`queued`).
        var result: Result<Void, any Error>?
        /// Called as it finishes (`ReviewSession.operationFinished`, a test seam).
        var onFinish: ((Operation) -> Void)?

        init(kind: Kind, basis: Int, runID: String?, optimistic: [SpeakerEditAction]) {
            self.kind = kind
            self.basis = basis
            self.runID = runID
            self.optimistic = optimistic
            optimisticIDs = optimistic.map { _ in UUID().uuidString }
        }

        /// A change of the labels the window's undo can take back.
        var isUndoable: Bool {
            switch kind {
            case .edit, .link, .assignPerson, .confirmAll, .markSelf, .editWords: true
            case .undo, .revertWordFix, .relabel, .reload, .exports: false
            }
        }

        /// Something it saved can be undone.
        var savedUndoable: Bool { !batches.isEmpty || wordEdit != nil }

        /// It may run while the labels could not be reread: it rereads them, or it changes no label.
        var runsWhileUnread: Bool {
            switch kind {
            case .reload, .relabel, .exports: true
            case .edit, .link, .assignPerson, .confirmAll, .markSelf, .undo, .revertWordFix, .editWords: false
            }
        }

        var isQueued: Bool { lifecycle == .queued }
        var isRunning: Bool { lifecycle == .running }
        var isFinished: Bool { if case .finished = lifecycle { true } else { false } }
        /// It has started: running now, or finished after running.
        var ran: Bool { lifecycle == .running || lifecycle == .finished(ran: true) }

        /// The queue runs it now (invariant 1).
        func start() {
            guard isQueued else { return }
            lifecycle = .running
        }

        /// Labels were adopted while it runs (`ReviewSession.adopt`); `headChanged`: their head was made elsewhere
        /// (invariant 2). Nothing once it is not running.
        func adopted(headChanged: Bool) {
            guard isRunning else { return }
            superseded = true
            if headChanged { overtaken = true }
        }

        func finish(_ result: Result<Void, any Error>) {
            lifecycle = .finished(ran: ran)
            self.result = result
            onFinish?(self)
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
