import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

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

/// A word edit saved in Review (`ReviewSession.editWords`).
/// Where a split at a word falls (`ReviewSession.splitPlace`).
public enum ReviewSplitPlace: Sendable, Equatable {
    /// Inside a turn: it splits before `word`.
    case inside(turnID: String, word: WordRef)
    /// At the turn's first word: no turn splits; a row may break before it.
    case turnStart(turnID: String)
    /// After the turn's last word: no turn splits; a row may break after it.
    case turnEnd(turnID: String)
}

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

/// The review window's model (docs/meeting-design.md §5.10): one meeting's speaker labels, edited through
/// `SpeakerEditor` and `VoiceProfileService`, with the window's undo, playback clips, previews, and search. No AppKit.
///
/// Edits are optimistic and serial. Each change is shown at once in `projection` (`SpeakerProjection.applying` on
/// top of the saved labels), queued, and saved in order off the main actor; the saved result then replaces the
/// optimistic one. Every save is a compare-and-append against the labels the change was made on: a change made while
/// earlier ones were still saving is saved on their result only if nothing else changed the labels meanwhile, and a
/// refused change reloads the labels from disk and throws. Turns a pending split created are renamed to their saved
/// IDs (`resolvedTurnID`).
///
/// Exports are regenerated `exportDelay` after the last change (and at `close`), not on every edit. Voice samples
/// learned from this meeting are brought in step after changes that affect them, in the background and off the edit
/// queue (`sampleDelay` after the last change, a running one cancelled by a newer change, and at `close`), so a name
/// is saved at once. Nothing here logs transcript text, names, or voice data.
///
/// With `analyseVoices`, the window also works out every turn's voice once, in the background, into an in-memory
/// `MeetingVoiceCache` (docs/meeting-design.md §4.10, "Voices within one meeting"): it serves voice learning, and
/// `voiceMatches` compares the meeting's unnamed speakers and turns with the people named in it.
@MainActor public final class ReviewSession {
    private nonisolated static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "review")
    /// `SpeakerEdit.source` of the window's edits.
    nonisolated static let source = "app"
    /// Said when a change was refused because the labels changed outside this window (the window then shows them).
    public nonisolated static let changedElsewhere = "The speaker labels changed outside this window, so that change "
        + "was not saved. The window now shows the current labels."

    public let session: URL
    public let profiles: SpeakerProfileStore?
    private let maintenance: MaintenanceLauncher?
    /// The extractor voice learning uses: the voice cache, falling back to `baseExtractor`.
    private let extractor: (any VoiceSampleExtractor)?
    /// The extractor as given (or the bundled tool): one pass per call.
    private let baseExtractor: (any VoiceSampleExtractor)?
    private let exportDelay: Duration
    private let sampleDelay: Duration
    private let analyseVoices: Bool
    /// This meeting's turn embeddings while the window is open (`analyseVoices`); memory only.
    let voiceCache: MeetingVoiceCache

    /// The saved labels, as last loaded from disk.
    public private(set) var snapshot: SpeakerSessionSnapshot
    /// What the window shows: updated at once by each edit (`SpeakerProjection.applying`), then replaced by the
    /// editor's result.
    public private(set) var projection: SpeakerProjection {
        // Which words one turn shows: the dry runs (`checks`) are made again.
        didSet { checks.removeAll() }
    }
    /// Review's "Show Short Interjections": the turn list and Next Uncertain show the short interjections
    /// `projection.shownTurns` leaves out (docs/meeting-design.md §5.10). The exports never show them.
    public var showsShortInterjections = false
    /// The turns the window lists, in time order: `projection.shownTurns`, with the hidden interjections when
    /// `showsShortInterjections`.
    public var shownTurns: [ProjectedTurn] { projection.shownTurns(includingHidden: showsShortInterjections) }
    public var onChange: (() -> Void)?
    /// Called with true when a relabel (Find More Speakers, Label Speakers on My Microphone, Label Again) starts and
    /// false when it ends, so the app can show it in Meetings.
    public var onRelabelChange: ((Bool) -> Void)?
    /// "Learn voices of people I name in this meeting"; defaults to the global "Remember voices" setting.
    public var learnVoices: Bool
    /// The global "Remember voices" setting when the window opened (or last reloaded people).
    public private(set) var rememberVoices: Bool
    /// What the window is doing right now ("Saving…"), nil when idle.
    public private(set) var activity: String?
    /// When this window last saved a change.
    public private(set) var lastSavedAt: Date?
    /// Hand-edited export files moved aside since the window opened (names in `exports/`).
    public private(set) var movedAsideExports: [String] = []
    /// A change was saved and `exports/` has not been rewritten since.
    public private(set) var exportsPending = false
    /// Why the last export regeneration failed, until one succeeds.
    public private(set) var exportProblem: String?
    /// The labels on disk may differ from the ones shown (a change was saved, or they changed elsewhere, and they
    /// could not be reread), so the review is read-only until `reload` rereads them. Nil otherwise.
    public private(set) var reloadProblem: String?

    /// Where working out the meeting's voices is (`analyseVoices`).
    public enum VoiceAnalysis: Sendable, Equatable {
        /// Not asked for, no extractor, no audio, or no track split into speakers.
        case off
        /// `done` of `total` tracks finished.
        case running(done: Int, total: Int)
        case ready
        /// Voices cannot be compared in this meeting (why).
        case failed(String)
    }

    public private(set) var voiceAnalysis: VoiceAnalysis = .off
    /// Speakers and turns whose voice matches a person named in this meeting, on the shown labels.
    public private(set) var voiceMatches: MeetingVoiceMatches = .empty
    /// "Merge matching voices automatically": after a name is given, speakers whose voice is all but the same as a
    /// named person's (`MeetingVoiceSuggestion.mergeable`) are merged into them as one change. Off by default.
    public var autoMergeVoices = false
    /// The speaker whose name field has the keyboard in the window, asked when merges are worked out: never merged
    /// automatically meanwhile, so the name the user is typing still has its speaker when they press Return.
    public var speakerBeingNamed: (() -> String?)?
    /// A voice sample learned from this meeting could not be learned or brought in step (why), until one is.
    public private(set) var voiceProblem: String?
    /// Voice samples are being learned or brought in step in the background.
    public private(set) var isSyncingSamples = false

    /// Test seam: awaited off the main actor before each change is written, so a test can hold a save back.
    var beforeEdit: (@Sendable () async -> Void)?
    /// Test seam: called once a word edit or its undo is committed, before the labels are reread; throwing makes the
    /// reread fail.
    var beforeWordChangeReread: (() throws -> Void)?
    /// Test seam: called before a word edit, its undo, or a repair publishes a speaker head
    /// (`SpeakerTranscriptRetarget.beforePublishHead`, set inside the window's detached publications); throwing makes
    /// the publication fail.
    var beforeHeadPublish: (@Sendable () throws -> Void)?
    /// Test seam: called once a word edit, its undo, or a revert wrote its speaker head
    /// (`SpeakerTranscriptRetarget.afterHeadWritten`); throwing is a failure after the rename.
    var afterHeadWritten: (@Sendable () throws -> Void)?
    /// A word edit, its undo, or an automatic fix's revert made its transcript current, but its speaker head could not
    /// be published, nor repaired at once: the transcript it was made on, the head run then, and which change (each
    /// has its own repair). The review is held read-only until a reread finds the labels on the current transcript;
    /// `.reload` repairs the head first (`repairOwedHead`).
    private var owedHead: (transcriptID: String, runID: String, revert: Bool)?
    /// What was typed in every word edit not saved yet, in the order they were queued: those handed over by Return or
    /// Tab and still waiting or saving, and the one the field held when the review began closing. Quitting logs them
    /// all when it cannot wait any longer, so no edit is dropped without what was typed.
    public var unsavedWordEdits: [String] {
        queue.compactMap { op in
            guard !op.finished, case .editWords(let request, _) = op.kind else { return nil }
            return Self.typed(request)
        }
    }

    /// The word edits not saved yet when the review began closing (`close`), the field's included.
    private var closingWordEdits: [Operation] = []
    /// The field's edit at close, refused before it could be queued.
    private var refusedAtClose: (typed: String, reason: String)?

    /// The word edits not saved yet when the review began closing that were then refused or failed, each with what was
    /// typed and why, in the order they were queued. Their windows close, so quitting logs them (timeout or not):
    /// none is dropped without what was typed. A Restore of deleted words is among them (`restoreDescription`).
    public var failedWordEditsAtClose: [(typed: String, reason: String)] {
        closingWordEdits.compactMap { op -> (typed: String, reason: String)? in
            guard op.finished, op.wordEditResult == nil, case .failure(let error)? = op.result,
                  !(error is CancellationError), case .editWords(let request, _) = op.kind else { return nil }
            return (Self.typed(request), error.localizedDescription)
        } + (refusedAtClose.map { [$0] } ?? [])
    }

    /// What was typed for `request`, as the close's lists say it; for a Restore, which it is.
    private nonisolated static func typed(_ request: TranscriptWordEdit.Request) -> String {
        request.restoresRemoved ? restoreDescription(request.segmentID) : TranscriptWordEdit.cleaned(request.text)
    }

    /// The corrections one word edit teaches (the app: `TranscriptEditLearning`).
    public var correctionsToLearn: ((ReviewWordEdit) -> [Correction])?
    /// Changes the corrections list as saved (the app: corrections.json loaded, changed by `change`, and saved, under
    /// its own file lock); throws when it cannot be read or written. A close runs it off the main actor, inside the
    /// meeting's speaker lock, so the labels it learned from are read again, then the rules and what the meeting taught
    /// changed in one save (`CorrectionList.learnFromReview`).
    public typealias CorrectionsUpdate = @Sendable (_ change: (inout CorrectionList) throws -> Void) throws -> Void

    /// Asked for at close, on the main actor: the corrections update (`CorrectionsUpdate`), nil when the list cannot be
    /// written now (the next review's close learns from the same edits, which stay in the transcript).
    public var correctionsWriter: (() -> CorrectionsUpdate?)?

    /// The corrections list was written by a close (on the main actor, after the locks are released): the app takes
    /// it again.
    public var correctionsWritten: (() -> Void)?

    private var savedProjection: SpeakerProjection
    private var people: [SpeakerProfile]
    private var profileNames: [String: String]
    private var segments: [String: TranscriptSegment]
    private var textCache: [String: (spans: [WordSpan], text: String)] = [:]
    private var wordCache: [String: (spans: [WordSpan], words: [ReviewWord])] = [:]
    private var knownEditedExports: Set<String>

    private var queue: [Operation] = []
    private var draining = false
    /// Saved batches this window can undo, oldest first; one entry per user change (a change may save two batches).
    /// An undo takes its entry off at once and puts it back in its place when it saves nothing.
    private var undoStack: [UndoEntry] = []
    /// `UndoEntry.order` of the next entry.
    private var undoOrder = 0
    /// Changes whose lines were saved but whose labels could not be reread (`reloadProblem`), oldest first: still
    /// shown on the saved labels, and claimed (their batches found, their undo entry made) by the next labels read.
    private var unreloaded: [Operation] = []
    /// Bumped whenever `snapshot` is replaced.
    private var savedVersion = 0
    /// The last `savedVersion` that brought changes not made by this window's queue (a reload, a relabel, another
    /// process's edits). Changes made on a view older than it are refused.
    private var externalVersion = 0
    /// Optimistic split edit ID → the ID the editor gave it, so a turn created by a pending split keeps working.
    private var editIDMap: [String: String] = [:]
    /// A transcript a word edit was made on → the copy of it its undo made current (`currentStandIn`).
    private var restoredCopies: [String: String] = [:]
    /// Head runs this window's word edits and undos published, each → the run it replaced keeping its turns.
    private var turnKeepingRuns: [String: String] = [:]
    /// How this window's saved word edits and undos moved words, oldest first: an edit waiting in the queue, and the
    /// window's open edit field, follow their words through them.
    public private(set) var wordMoves: [ReviewWordMove] = []
    /// How many of `wordMoves` the words shown (`segments`) are after: a word change saved but not reread yet (its
    /// labels could not be, `reloadProblem`) moved words the transcript shown does not have. A word edit is checked
    /// against the words shown when it was asked for, from there.
    private var movesRead = 0

    /// The word moves the words shown are after (`wordMoves` up to `movesRead`): what an edit field or a Split Turn
    /// sheet over the words shown follows, and counts as seen. A move saved but not reread yet is not in them (its
    /// words are not shown yet); followed by the field, it would put the field on the word that has its index now.
    public var shownWordMoves: [ReviewWordMove] { Array(wordMoves.prefix(movesRead)) }

    /// How many transcripts this window has read that it did not make (another process changed the words: a word fix
    /// run, a recovery). Their changes have no word moves, so words chosen before one cannot be followed onto the
    /// words as they are now: an edit field opened before it is not put back on its words (`TurnListView`).
    public private(set) var wordsEpoch = 0
    /// The transcripts this window's own word changes made current (edits, their undos, reverts).
    private var ownTranscripts: Set<String> = []

    /// Applied optimistic edit IDs → the queued change that made them, for counting changes.
    private var optimisticOwner: [String: ObjectIdentifier] = [:]
    private var exportTimer: Task<Void, Never>?
    private var closed = false
    /// Maintenance commands holding the review read-only, by `pause` key, oldest first.
    private var pauses: [(hold: ReviewMaintenance.Hold, reason: String)] = []

    /// Recognition's thresholds as the people store gives them (calibrated only for their model), for
    /// `voiceThresholds`.
    private var calibration: (thresholds: RecognitionThresholds, model: EmbeddingModelID)?
    /// The voice pass for the head run: its task, its cache epoch, and the embeddings it stored (by turn ID).
    private var voiceTask: Task<Void, Never>?
    private var voiceEpoch = 0
    private var voiceRunID: String?
    private(set) var voiceEmbeddings: [String: TurnEmbedding] = [:]
    /// What `voiceMatches` was last worked out from.
    private var voiceMatchKey: VoiceMatchKey?
    /// A pass a maintenance pause stopped, until its child has exited.
    private var stoppedPass: Task<Void, Never>?
    /// `stopBackgroundWork` was called (the app is quitting): no pass or sample sync starts again.
    private var backgroundStopped = false
    /// A name was given since automatic merging last looked (`autoMergeVoices`).
    private var mergeArmed = false
    /// Voice samples owe a sync (`syncSamples`), for these people to enrol besides; `sampleRequests` counts
    /// requests, so a sync that ends knows whether another one came in meanwhile.
    private var samplesOwed = false
    private var sampleEnroll: [String: EnrollRequest] = [:]
    private var sampleRequests = 0
    /// Waits `sampleDelay`, then starts `sampleRun`.
    private var sampleTimer: Task<Void, Never>?
    /// The running sync.
    private var sampleRun: Task<Void, Never>?
    /// The running sync learns somebody's voice (not only brings samples in step).
    private var syncLearning = false
    /// Where a sync this review could not finish is recorded for the meeting's next review, and read from when this
    /// one opens (`PendingVoiceSamples`); nil records nothing.
    private let pendingVoices: PendingVoiceSamples?

    // MARK: - Opening

    /// Loads the snapshot off the main actor. `exportDelay` debounces export regeneration; `sampleDelay` debounces
    /// voice sample learning after a change.
    ///
    /// `extractor` learns voices (`VoiceSampleExtractor`); nil uses the bundled `voiceislocal` tool
    /// (`SubprocessVoiceSampleExtractor`) when `maintenance` is given, else no voice is learned. `analyseVoices` works
    /// out every turn's voice with it in the background (once per track split into speakers) for `voiceMatches` and
    /// for voice learning. A sync an earlier review recorded in `pendingVoices` runs again, and the footer says so.
    /// Throws `HolosError.unavailable` when the meeting has no usable speaker labels.
    public init(session: URL, profiles: SpeakerProfileStore?, maintenance: MaintenanceLauncher?,
                exportDelay: Duration = .seconds(2), extractor: (any VoiceSampleExtractor)? = nil,
                analyseVoices: Bool = false, sampleDelay: Duration = .milliseconds(1500),
                pendingVoices: PendingVoiceSamples? = nil) async throws {
        let loaded = try await Self.detached { try Self.load(session: session, profiles: profiles) }
        guard let projection = loaded.snapshot.projection else {
            throw HolosError.unavailable(loaded.snapshot.runProblem
                ?? "This meeting's speakers are not labelled yet. Label its speakers first.")
        }
        // The word checks are read with the labels the review opens on (later reads run in the background).
        let opened = loaded.snapshot
        wordChecks = try await Self.detached { try WordChecks.read(opened, session: session) }
        wordChecksReads = 1
        self.session = session
        self.profiles = profiles
        self.maintenance = maintenance
        let base = extractor ?? maintenance.map { SubprocessVoiceSampleExtractor(executable: $0.executable) }
        baseExtractor = base
        let cache = MeetingVoiceCache()
        voiceCache = cache
        self.extractor = base.map { CachedVoiceSampleExtractor(cache: cache, fallback: $0) }
        self.exportDelay = exportDelay
        self.sampleDelay = sampleDelay
        self.analyseVoices = analyseVoices
        self.pendingVoices = pendingVoices
        snapshot = loaded.snapshot
        self.projection = projection
        savedProjection = projection
        people = loaded.people
        profileNames = loaded.profileNames
        rememberVoices = loaded.rememberVoices
        learnVoices = loaded.rememberVoices
        calibration = loaded.calibration
        segments = Self.segmentIndex(loaded.snapshot.transcript)
        knownEditedExports = loaded.editedExports
        Self.log.info("Session \(loaded.snapshot.manifest.id, privacy: .public): review opened on run \(projection.runID, privacy: .public) (\(projection.speakers.count, privacy: .public) speakers, \(projection.turns.count, privacy: .public) turns)")
        resumePendingSamples()
        startVoiceAnalysis()
    }

    // MARK: - Reading

    public var sessionName: String { snapshot.manifest.name }

    /// Seconds from the session start to the end of the last saved chunk.
    public var durationSeconds: Double {
        max(snapshot.manifest.chunks.map(\.end).max() ?? 0, projection.turns.map(\.end).max() ?? 0)
    }

    /// Edits can be made: the labels are usable and known to be the saved ones (`reloadProblem`), no relabel is queued
    /// or running, no maintenance command holds the review (`pause`), and the window is open.
    public var isEditable: Bool {
        !closed && snapshot.projection != nil && reloadProblem == nil && !isRelabelling && pauses.isEmpty
    }

    /// Why the review is read-only while a maintenance command works on the meeting (`pause`), nil otherwise.
    public var pauseReason: String? { pauses.last?.reason }

    /// Words can be edited (and fixes reverted): the review is editable, its labels were made on the current
    /// transcript (after the transcript changed, every edit would be refused: the labels must be made again first),
    /// and every speaker change can be read (each edit carries them all over to its new labels).
    public var canEditWords: Bool { isEditable && wordEditingBlocked == nil }

    /// Why words cannot be edited while the review is otherwise editable, for the edit-mode banner and the Edit Words
    /// button; nil when they can.
    public var wordEditingBlocked: String? {
        guard isEditable else { return nil }
        if snapshot.transcriptChanged { return Self.labelAgainFirst.localizedDescription }
        if !snapshot.journal.isComplete { return Self.speakerChangesUnreadable.localizedDescription }
        if !baseReadable { return Self.baseUnreadable.localizedDescription }
        // Two segments sharing an ID: which words are meant cannot be told (`hasRepeatedSegmentIDs`).
        if readyChecks?.repeatedIDs == true { return TranscriptWordEdit.damagedMarks.localizedDescription }
        return nil
    }

    public nonisolated static let baseUnreadable = HolosError.invalidInput(
        "The transcript revision this one was fixed from cannot be read (missing or damaged), so words cannot be "
            + "edited or fixes reverted here: what the recognizer wrote under each fix is kept there.")

    /// The transcript shown is unfixed, or the revision it was fixed from can be read (`WordChecks`; until they are read
    /// for the labels shown, taken as readable: the save reads it and says so).
    private var baseReadable: Bool {
        snapshot.transcript.fixedFrom == nil || readyChecks.map { !$0.baseUnreadable } ?? true
    }

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

    /// The word checks for the labels shown; nil while they are being read (a click then opens a field, and the save
    /// decides).
    private var wordChecks: WordChecks?
    /// The read of `wordChecks` in flight: at most one at a time (`readWordChecks`).
    private var wordChecksRead: Task<Void, Never>?
    /// The labels were read again while a read was in flight: once it ends, one more is made, for the labels then.
    private var wordChecksStale = false
    /// How many reads of the word checks were started (tests: once per labels read at most, never per click).
    private(set) var wordChecksReads = 0
    /// What a read does (`WordChecks.read`; tests hold it to see reads coalesce).
    var wordChecksReader: @Sendable (SpeakerSessionSnapshot, URL) async throws -> WordChecks = { snapshot, session in
        try WordChecks.read(snapshot, session: session)
    }

    private var readyChecks: WordChecks? {
        wordChecks.flatMap { $0.key == WordChecks.key(of: snapshot) ? $0 : nil }
    }

    /// The labels were read: the word checks are read again for them, off the main actor; they apply once read, if
    /// the labels are still those (`readyChecks`), and the window is told. Reads are coalesced: while one is in flight,
    /// a new request only marks it stale, and when it ends exactly one more is made, for the labels then (a burst of
    /// rereads makes at most two reads, never one per reread).
    private func readWordChecks() {
        // Not ready until read again: the unfixed revision may be back, gone, or another, with the same labels.
        wordChecks = nil
        guard wordChecksRead == nil else {
            wordChecksStale = true
            return
        }
        startWordChecksRead()
    }

    private func startWordChecksRead() {
        let snapshot = self.snapshot
        let session = self.session
        let key = WordChecks.key(of: snapshot)
        let reader = wordChecksReader
        wordChecksStale = false
        wordChecksReads += 1
        wordChecksRead = Task { [weak self] in
            let result = await Self.cancellableResult { try await reader(snapshot, session) }
            guard let self else { return }
            self.wordChecksRead = nil
            // Closed meanwhile (the read was cancelled): nothing more is read.
            guard !self.closed else { return }
            if self.wordChecksStale {
                self.startWordChecksRead()
                return
            }
            guard case .success(let read) = result, WordChecks.key(of: self.snapshot) == key else { return }
            self.wordChecks = read
            self.checks.removeAll()
            self.notify()
        }
    }

    /// Returns once the word checks for the labels shown are read (tests, and anything that must not race them).
    func wordChecksSettled() async {
        while let running = wordChecksRead {
            await running.value
            if wordChecksRead == running { break }
        }
    }

    public nonisolated static let labelAgainFirst = HolosError.invalidInput(
        "The transcript changed after speakers were labelled, so words cannot be edited here yet. Use Label Again "
            + "first, then edit words.")

    public nonisolated static let speakerChangesUnreadable = HolosError.invalidInput(
        "Some of this meeting's speaker changes cannot be read (damaged, or saved by a newer Voice is Local), so words "
            + "cannot be edited here: the speaker labels could not be kept on the edited words.")

    /// Why words `refs` (consecutive words of one segment) cannot be edited, known before a field opens over them; nil
    /// when an edit can be tried. It is the save's own checks, made as a dry run in memory on the transcript and labels
    /// shown (`wordEditRequest`, then `SessionWordEdit.edited`, which `SessionWordEdit.run` makes), with the unfixed
    /// revision read for these labels (`WordChecks`) and a placeholder for the text: whatever they refuse for these
    /// words, this refuses with the same message (a word corrected while recording, overlapping turns, an older or
    /// newer fix, a damaged revision). It reads no file and makes no plan of the labels: what only the labels' plan, or
    /// the text typed (a deletion's neighbour), can refuse is known at the save, which keeps what was typed. Nil while
    /// the word checks are being read (the save decides). Made once per selection and labels read (`checks`).
    public func wordEditRefusal(_ refs: [WordRef]) -> String? {
        guard let first = refs.first, let ready = readyChecks else { return nil }
        let indices = refs.map(\.word)
        let key = "edit\u{1f}\(first.segmentID)\u{1f}\(indices.min() ?? 0)\u{1f}\(indices.max() ?? 0)\u{1f}\(indices.count)"
        return checked(key) {
            var (request, segment) = try wordEditRequest(refs, text: "")
            request.text = Self.placeholder(over: segment, first: request.first, end: request.end)
            _ = try SessionWordEdit.edited(request, in: snapshot.transcript,
                                           base: try ready.shownBase(fixed: snapshot.transcript.fixedFrom != nil),
                                           projection: snapshot.projection)
        }
    }

    /// Why the fix on `word` cannot be reverted, known before Revert is offered (context menu, VoiceOver) and checked
    /// again when it is asked for; nil when it can be tried. It is the revert's own checks, made as a dry run in memory
    /// on the transcript shown (`SessionWordFixRevert.reverted`, which the revert makes; for a Review edit, the edit
    /// back to what the recognizer wrote, made as `wordEditRefusal` makes one), then what the labels refuse across the
    /// whole transcript (`WordChecks.revertRefusal`, read once per labels read), so it refuses what the revert would,
    /// with the same message. No file is read and no plan made here. Nil while the word checks are being read. Made
    /// once per word and labels read (`checks`).
    public func revertRefusal(_ word: WordRef) -> String? {
        guard let ready = readyChecks else { return nil }
        let fixed = snapshot.transcript.fixedFrom != nil
        return checked("revert\u{1f}\(word.segmentID)\u{1f}\(word.word)") {
            if let segment = segments[word.segmentID], let edit = (segment.fixes ?? []).first(where: {
                $0.kind == .reviewEdit && $0.first <= word.word && word.word < $0.end
            }) {
                let refs = (edit.first..<edit.end).map { WordRef(segmentID: word.segmentID, word: $0) }
                let (request, _) = try wordEditRequest(refs, text: edit.heard, verbatim: true)
                _ = try SessionWordEdit.edited(request, in: snapshot.transcript, base: try ready.shownBase(fixed: fixed),
                                               projection: snapshot.projection)
                return
            }
            // As `revertWordFix` asks before it queues the revert.
            guard let segment = segments[word.segmentID], (segment.fixes ?? []).contains(where: {
                ($0.kind == .correction || $0.kind == .term) && $0.first <= word.word && word.word < $0.end
            }) else {
                throw Self.notFixedAutomatically
            }
            _ = try SessionWordFixRevert.reverted(word, in: snapshot.transcript, to: try ready.shownBase(fixed: fixed))
            if let refusal = ready.revertRefusal { throw HolosError.invalidInput(refusal) }
        }
    }

    nonisolated static let notFixedAutomatically = HolosError.invalidInput("That word was not fixed automatically.")

    /// The dry runs' results (`wordEditRefusal`, `revertRefusal`), by selection or word, for the transcript and labels
    /// shown: cleared when they are read again (`adopt`) or the labels shown change (`projection`).
    private var checks: [String: String?] = [:]

    private func checked(_ key: String, _ dryRun: () throws -> Void) -> String? {
        if let known = checks[key] { return known }
        let refusal: String?
        do {
            try dryRun()
            refusal = nil
        } catch {
            refusal = error.localizedDescription
        }
        checks[key] = .some(refusal)
        return refusal
    }

    /// Text that changes words `[first, end)` of `segment` for a dry run: one word unlike what they show.
    nonisolated static func placeholder(over segment: TranscriptSegment, first: Int, end: Int) -> String {
        let shown = TranscriptWordEdit.shownText(of: segment, first: first, end: end) ?? ""
        return TranscriptWordEdit.cleaned(shown) == "x" ? "y" : "x"
    }

    /// Words `indices` of `segment` with every fix mark they touch taken in, as an edit takes them
    /// (`TranscriptWordEdit.editing`: a mark is never split), so what is checked before an edit is what it changes.
    /// Only sound marks (`TranscriptWordEdit.isSound`) are taken in, so the range never runs past the segment's words
    /// (a segment with a damaged one is refused by the edit itself, `isDamaged`).
    nonisolated static func takingInMarks(_ indices: [Int], of segment: TranscriptSegment) -> Range<Int> {
        guard let lowest = indices.min(), let highest = indices.max() else { return 0..<0 }
        let count = WordTiming.effectiveWords(of: segment).count
        let marks = (segment.fixes ?? []).filter { TranscriptWordEdit.isSound($0, wordCount: count) }
        var lower = lowest
        var upper = highest + 1
        var grew = true
        while grew {
            grew = false
            for fix in marks where fix.first < upper && lower < fix.end {
                if fix.first < lower { lower = fix.first; grew = true }
                if fix.end > upper { upper = fix.end; grew = true }
            }
        }
        return lower..<upper
    }

    /// The text words `refs` (consecutive words of one segment) show in the transcript, as an edit field over them
    /// starts (`TranscriptWordEdit.shownText`: with the punctuation the recognizer did not time, without the space
    /// some recognizers put at a word's front). Nil when they are not such words.
    public func shownText(of refs: [WordRef]) -> String? {
        guard let first = refs.first, refs.allSatisfy({ $0.segmentID == first.segmentID }),
              let segment = segments[first.segmentID] else { return nil }
        let indices = refs.map(\.word).sorted()
        guard let lowest = indices.first, let highest = indices.last, highest - lowest + 1 == indices.count else {
            return nil
        }
        return TranscriptWordEdit.shownText(of: segment, first: lowest, end: highest + 1)
    }

    /// Find More Speakers, Label Speakers on My Microphone, or Label Again is queued or running.
    public var isRelabelling: Bool {
        queue.contains { if case .relabel = $0.kind { true } else { false } }
    }

    /// Something is queued or saving.
    public var isWorking: Bool { !queue.isEmpty }

    /// Changes and tasks queued or saving (tests).
    var queuedOperations: Int { queue.count }

    public var canUndo: Bool { !undoStack.isEmpty || queue.contains { $0.isUndoable && !$0.undone } }

    /// Changes to this meeting's labels in effect (a batch counts once; linking a person is one change).
    public var changeCount: Int {
        var batchOf: [String: String] = [:]
        for edit in snapshot.journal.edits where edit.baseRunID == savedProjection.runID {
            batchOf[edit.id] = edit.batchID ?? edit.id
        }
        var keys = Set<String>()
        for id in projection.appliedEditIDs {
            if let batch = batchOf[id] {
                keys.insert("b:" + batch)
            } else if let owner = optimisticOwner[id] {
                keys.insert("o:\(owner.hashValue)")
            } else {
                keys.insert("e:" + id)
            }
        }
        return keys.count
    }

    /// Journal lines of this run that could not be applied.
    public var staleEditCount: Int { projection.staleEdits.count }

    /// Known people, most recently used first (the name combo box and the turn pop-up).
    public func knownPeople() -> [SpeakerProfile] { people }

    public func speaker(_ speakerID: String) -> ProjectedSpeaker? {
        projection.speakers.first { $0.id == speakerID }
    }

    /// The turn a window-held ID now names: a turn made by a split that was pending when the ID was taken gets its
    /// saved ID once the split is saved.
    public func resolvedTurnID(_ turnID: String) -> String {
        guard turnID.contains("/") else { return turnID }
        return turnID.split(separator: "/", omittingEmptySubsequences: false)
            .map { editIDMap[String($0)] ?? String($0) }.joined(separator: "/")
    }

    public func turn(_ turnID: String) -> ProjectedTurn? {
        let id = resolvedTurnID(turnID)
        return projection.turns.first { $0.id == id }
    }

    /// The text the window shows for a turn: its words in the transcript the head run was built from.
    ///
    /// Every place the window reads turn text goes through here (rows, search, previews, the split sheet), and turns
    /// keep referring to words by span, so a later per-turn language choice can supply another transcript's text
    /// for a turn here, keyed by turn ID, without changing `ProjectedTurn` or the edit journal.
    public func text(of turn: ProjectedTurn) -> String {
        if let cached = textCache[turn.id], cached.spans == turn.spans { return cached.text }
        let text = Self.text(of: turn.spans, segments: segments, transcript: snapshot.transcript)
        textCache[turn.id] = (turn.spans, text)
        return text
    }

    /// Turns whose text contains `query`, ignoring case (and diacritics), in time order. Every turn for an empty query.
    public func turns(matching query: String) -> [ProjectedTurn] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return projection.turns }
        return projection.turns.filter {
            text(of: $0).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The next uncertain turn after `turnID` in time order, wrapping around to the first; the first uncertain turn
    /// when `turnID` is nil or not shown. Nil when no turn is uncertain. Only turns the window lists (`shownTurns`):
    /// a hidden interjection is skipped, and one attached to a neighbour is uncertain only when it overlaps.
    public func nextUncertain(after turnID: String?) -> ProjectedTurn? {
        let turns = shownTurns
        guard !turns.isEmpty else { return nil }
        let current = turnID.map(resolvedTurnID).flatMap { id in turns.firstIndex { $0.id == id } }
        let start = current.map { $0 + 1 } ?? 0
        for offset in 0..<turns.count {
            let turn = turns[(start + offset) % turns.count]
            if turn.uncertain { return turn }
        }
        return nil
    }

    /// Up to three clips from the speaker's longest non-overlapped turns:
    /// [start + 0.25, min(end, start + 4.25)], or the whole turn when shorter.
    ///
    /// "Shorter" is a turn of at most 4 s. Clips are ordered longest turn first (ties by time).
    public func sampleClips(for speakerID: String) -> [ClosedRange<Double>] {
        longest(of: speakerID) { !$0.overlap && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .prefix(3).map { turn in
            guard turn.end - turn.start > Self.clipSeconds else { return turn.start...turn.end }
            return (turn.start + Self.clipLead)...min(turn.end, turn.start + Self.clipLead + Self.clipSeconds)
        }
    }

    /// The first 60 characters of the speaker's two longest turns.
    ///
    /// Longest first; runs of whitespace become one space; turns without text are skipped.
    public func previews(for speakerID: String) -> [String] {
        var previews: [String] = []
        for turn in longest(of: speakerID, where: { _ in true }) {
            let text = Self.oneLine(text(of: turn))
            guard !text.isEmpty else { continue }
            previews.append(String(text.prefix(Self.previewCharacters)))
            if previews.count == 2 { break }
        }
        return previews
    }

    /// The words of a turn, in order, for choosing where to split it (a split goes before a word other than the
    /// first).
    public func words(of turnID: String) -> [ReviewWord] {
        guard let turn = turn(turnID) else { return [] }
        return words(of: turn)
    }

    /// The words of a shown turn, cached by turn ID and checked against its spans (a split keeps an ID and changes
    /// its words), for playing from a word and following playback word by word.
    public func words(of turn: ProjectedTurn) -> [ReviewWord] {
        if let cached = wordCache[turn.id], cached.spans == turn.spans { return cached.words }
        var words: [ReviewWord] = []
        // Each segment's words, text and fixes are walked once (a segment can hold many thousands of words).
        let turnSpans = projection.turns.map(\.spans)
        for span in turn.spans {
            guard let segment = segments[span.segmentID] else { continue }
            let effective = WordTiming.effectiveWords(of: segment)
            guard span.first >= 0, span.first < span.end, span.end <= effective.count else { continue }
            let utf16 = Array(segment.text.utf16)
            func shown(_ first: Int, _ end: Int) -> String? {
                TranscriptWordEdit.shownText(first: first, end: end, words: effective, utf16: utf16)
            }
            // A segment with a damaged mark shows none (no Revert is offered; its marks cannot be trusted), and its
            // words are not edited (`wordEditRefusal` says why). Marks never overlap otherwise.
            let damaged = TranscriptWordEdit.isDamaged(segment)
            // Automatic fixes, and edits made here that changed what the recognizer wrote (an edit back to it is not
            // marked as a change).
            let fixes = damaged ? [] : (segment.fixes ?? []).filter { fix in
                if fix.kind == .correction || fix.kind == .term { return true }
                guard fix.kind == .reviewEdit else { return false }
                // As shown, with the punctuation the recognizer did not time ("Hello." edited to "Hello?" is a change).
                return shown(fix.first, fix.end).map {
                    TranscriptWordEdit.cleaned(fix.heard) != TranscriptWordEdit.cleaned($0)
                } ?? true
            }
            // Each word of the span's fix, and whether each fix can be reverted here, worked out once per fix.
            var fixOf: [Int: Int] = [:]
            var revertibleFix: [Bool] = []
            for (number, fix) in fixes.enumerated() {
                for index in max(fix.first, span.first)..<max(min(fix.end, span.end), max(fix.first, span.first)) {
                    fixOf[index] = number
                }
                // Words edited together are reverted together, by one edit: only while this turn shows them all.
                // Their Revert is refused too when overlapping turns hold only some of them (it could not be undone
                // exactly), as any edit of them is.
                // (Marks never overlap here, so an edit of the fix's words takes in that fix alone.)
                revertibleFix.append(fix.kind != .reviewEdit || ((fix.first..<fix.end).allSatisfy { word in
                    turn.spans.contains { $0.segmentID == span.segmentID && $0.first <= word && word < $0.end }
                } && TranscriptWordEdit.sameOwners(fix.first..<fix.end, segmentID: span.segmentID,
                                                   turns: turnSpans)))
            }
            for index in span.first..<span.end {
                let word = effective[index]
                let number = fixOf[index]
                words.append(ReviewWord(ref: WordRef(segmentID: span.segmentID, word: index), text: word.text,
                                        start: word.start, fix: number.map { fixes[$0] },
                                        revertible: number.map { revertibleFix[$0] } ?? true,
                                        shown: shown(index, index + 1)))
            }
        }
        wordCache[turn.id] = (turn.spans, words)
        return words
    }

    /// The person a speaker is named after automatically ("Jim (auto)"), for "Not Jim". Nil when the speaker's name
    /// is not automatic.
    public func automaticProfileID(for speakerID: String) -> String? {
        guard let speaker = speaker(speakerID), speaker.isAutomatic else { return nil }
        return snapshot.recognition?.matches.first {
            $0.speakerID == speakerID && $0.tier == .likely && profileNames[$0.profileID] != nil
                && !speaker.rejectedProfileIDs.contains($0.profileID)
        }?.profileID
    }

    /// The suggestion shown for a speaker ("Maybe Jim", Confirm / Not Jim): a voice matched in this meeting to a
    /// person named in it (`voiceMatches`) before recognition's, since it compares the same recording. Voice matches
    /// need people (confirming one links the person).
    public func suggestion(for speakerID: String) -> SpeakerMatch? {
        guard let speaker = speaker(speakerID) else { return nil }
        return voiceSuggestion(for: speakerID)?.match ?? speaker.suggestion
    }

    /// The speaker's suggestion when it comes from a voice matched in this meeting.
    public func voiceSuggestion(for speakerID: String) -> MeetingVoiceSuggestion? {
        guard profiles != nil else { return nil }
        return voiceMatches.suggestion(for: speakerID)
    }

    /// Speakers with a suggestion (Confirm All).
    public var suggestionCount: Int { projection.speakers.filter { suggestion(for: $0.id) != nil }.count }

    /// "⚠ sounds like Jim" for a turn whose voice matches a person named in this meeting better than its speaker.
    public func turnHint(_ turnID: String) -> MeetingTurnHint? {
        guard profiles != nil else { return nil }
        return voiceMatches.turnHints[resolvedTurnID(turnID)]
    }

    /// Find More Speakers is possible: exactly one track was split into speakers (a minimum speaker count cannot be
    /// asked of two tracks at once).
    public var canFindMoreSpeakers: Bool { diarizedTrack != nil && maintenance != nil }

    /// The speaker count Find More Speakers asks for at least: one more than the diarizer found on its track.
    public var findMoreSpeakersMinimum: Int? { diarizedTrack.map { $0.clusters.count + 1 } }

    /// Label Speakers on My Microphone is possible: a call whose microphone was taken as one speaker ("Me").
    public var canLabelMicrophoneSpeakers: Bool {
        maintenance != nil && snapshot.meeting.mode == .call
            && snapshot.run?.tracks.contains { $0.track == "mic" && Self.isChannel($0.policy) } == true
    }

    // MARK: - Editing

    /// Edits run in order on a serial queue off the main actor (SpeakerEditor, regenerateExports: false).
    /// A refused edit reloads the snapshot and throws. Pushes undo; schedules exports.
    ///
    /// Names are saved as `SpeakerEditor.cleanName` gives them. A batch that changes nothing returns at once and
    /// saves nothing; one that is not valid on the shown labels throws `invalidInput` and saves nothing.
    public func apply(_ actions: [SpeakerEditAction]) async throws {
        try await apply(actions, requireCompleteJournal: false)
    }

    /// `requireCompleteJournal`: refused under the speaker lock when the edit journal has a line this build cannot
    /// read (an automatic change made from matches that such a line may contradict).
    private func apply(_ actions: [SpeakerEditAction], requireCompleteJournal: Bool) async throws {
        try requireEditable()
        let resolved = actions.map { Self.cleaned(resolve($0)) }
        guard !resolved.isEmpty else { return }
        try validate(resolved)
        if SpeakerEditor.changesNothing(resolved, on: projection) { return }
        try await enqueue(.edit(resolved, requireCompleteJournal: requireCompleteJournal), optimistic: resolved)
    }

    /// This window's newest change: a queued one is dropped (or reverted once saved), else the newest saved batch is
    /// reverted. Undo never reaches changes made outside the window. Throws `invalidInput` when there is none.
    public func undo() async throws {
        try requireEditable()
        if let op = queue.last(where: { $0.isUndoable && !$0.undone }) {
            op.undone = true
            if !op.started {
                queue.removeAll { $0 === op }
                op.finish(.success(()))
                recomputeProjection()
                notify()
                Self.log.info("Session \(self.sessionID, privacy: .public): dropped an unsaved change (undo)")
                return
            }
            try await enqueue(.undo(.operation(op)), optimistic: [])
            return
        }
        // Put back (`restoreUndo`) when the undo saves nothing.
        guard let entry = undoStack.popLast() else {
            throw HolosError.invalidInput("There is no change in this window to undo.")
        }
        try await enqueue(.undo(.saved(entry)), optimistic: [])
    }

    /// Links the speaker to a known person or a new one; the person's name becomes the speaker's. Learns the voice
    /// when `learnVoices` is on (and Remember voices).
    public func link(speakerID: String, to target: ProfileTarget) async throws {
        try await link(speakerID: speakerID, to: target, byName: false)
    }

    /// `byName`: the name field asked for "the person called this" (`setName`), so a `.new` target that a person of
    /// that name exists for by the time the change is saved (one created by an earlier change still saving) links
    /// that person instead of creating a second one.
    private func link(speakerID: String, to target: ProfileTarget, byName: Bool) async throws {
        try requireEditable()
        try requirePeople()
        guard projection.speakers.contains(where: { $0.id == speakerID }) else { throw Self.noSpeaker(speakerID) }
        var optimistic: [SpeakerEditAction] = []
        switch target {
        case .existing(let profileID):
            guard let person = people.first(where: { $0.id == profileID }) else {
                throw HolosError.invalidInput("That person is not known to Voice is Local any more; reopen the window.")
            }
            optimistic = [.linkProfile(speakerID: speakerID, profileID: profileID),
                          .rename(speakerID: speakerID, name: person.displayName)]
        case .new(let name):
            guard let clean = SpeakerEditor.cleanName(name) else {
                throw HolosError.invalidInput("A new person needs a name.")
            }
            optimistic = [.rename(speakerID: speakerID, name: clean)]
        }
        mergeArmed = true
        try await enqueue(.link(speakerID: speakerID, target: target, learnVoice: learnVoices, byName: byName),
                          optimistic: optimistic)
    }

    /// The name field's Return: an empty name clears the speaker's name (and unlinks the person it is linked to, or
    /// rejects the person its automatic name comes from, in this meeting); a known person's name (ignoring case) links the speaker to them (the
    /// most recently used one when two share it); any other name creates that person and links the speaker. A name
    /// whose person is still being created by an earlier change links that person once it is saved. Without a people
    /// store the name is only set on the speaker.
    public func setName(_ text: String, speakerID: String) async throws {
        try requireEditable()
        guard let speaker = speaker(speakerID) else { throw Self.noSpeaker(speakerID) }
        guard let name = SpeakerEditor.cleanName(text) else {
            var actions: [SpeakerEditAction] = [.rename(speakerID: speakerID, name: nil)]
            // A linked person, or the person an automatic name ("Jim (auto)") comes from, as "Not Jim" does: either
            // would otherwise keep showing its name.
            if let profileID = speaker.profileID ?? automaticProfileID(for: speakerID) {
                actions.append(.rejectProfile(speakerID: speakerID, profileID: profileID))
            }
            try await apply(actions)
            return
        }
        guard profiles != nil else {
            try await apply([.rename(speakerID: speakerID, name: name)])
            return
        }
        if let person = person(named: name) {
            if speaker.profileID == person.id, speaker.name == person.displayName { return }
            try await link(speakerID: speakerID, to: .existing(profileID: person.id), byName: true)
        } else {
            // Return pressed again while this speaker's link to that new name is still waiting or saving.
            if speaker.name == name, pendingLinkByName(speakerID: speakerID, name: name) { return }
            try await link(speakerID: speakerID, to: .new(name: name), byName: true)
        }
    }

    /// The known person called `name` (compared as `SameNameSpeakers.key` does: ignoring case, accents and extra
    /// spaces), the most recently used one when two share it.
    private func person(named name: String) -> SpeakerProfile? {
        guard let key = SameNameSpeakers.key(name) else { return nil }
        return people.first { SameNameSpeakers.key($0.displayName) == key }
    }

    /// A name-field link of `speakerID` to a new person called `name` is queued or saving and not undone.
    private func pendingLinkByName(speakerID: String, name: String) -> Bool {
        queue.contains { op in
            guard !op.undone, case .link(let id, .new(let pending), _, true) = op.kind else { return false }
            return id == speakerID && SameNameSpeakers.key(pending) == SameNameSpeakers.key(name)
        }
    }

    /// Moves turns to a speaker, the unknown speaker, a new speaker, or a person, as one change.
    public func assign(_ turnIDs: [String], to target: ReviewAssignTarget) async throws {
        try requireEditable()
        var seen = Set<String>()
        let ids = turnIDs.map(resolvedTurnID).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        switch target {
        case .speaker(let speakerID):
            try await apply([.reassignTurns(turnIDs: ids, to: speakerID)])
        case .unknown:
            try await apply([.reassignTurns(turnIDs: ids, to: nil)])
        case .newSpeaker(let name):
            // Same name, same person: a name a listed speaker already has gives the turns to that speaker.
            if let name, let speaker = projection.speaker(named: name) {
                try await apply([.reassignTurns(turnIDs: ids, to: speaker.id)])
                return
            }
            try await apply([.newSpeaker(speakerID: Self.newSpeakerID(), name: name, turnIDs: ids)])
        case .person(let profileID):
            if let speaker = projection.speakers.first(where: { $0.profileID == profileID }) {
                try await apply([.reassignTurns(turnIDs: ids, to: speaker.id)])
                return
            }
            try requirePeople()
            guard let person = people.first(where: { $0.id == profileID }) else {
                throw HolosError.invalidInput("That person is not known to Voice is Local any more; reopen the window.")
            }
            // A listed speaker already called this person's name is them (same name, same person): the turns go to
            // it, and it is linked to the person in the same change unless it is linked to someone else or said
            // "Not <person>".
            if let speaker = projection.speaker(named: person.displayName) {
                let move = SpeakerEditAction.reassignTurns(turnIDs: ids, to: speaker.id)
                guard speaker.profileID == nil, !speaker.rejectedProfileIDs.contains(profileID) else {
                    try await apply([move])
                    return
                }
                try validate([move])
                mergeArmed = true
                try await enqueue(.assignPerson(create: move, speakerID: speaker.id, profileID: profileID,
                                                learnVoice: learnVoices),
                                  optimistic: [move, .linkProfile(speakerID: speaker.id, profileID: profileID)])
                return
            }
            let speakerID = Self.newSpeakerID()
            let create = SpeakerEditAction.newSpeaker(speakerID: speakerID, name: person.displayName, turnIDs: ids)
            try validate([create])
            mergeArmed = true
            try await enqueue(.assignPerson(create: create, speakerID: speakerID, profileID: profileID,
                                            learnVoice: learnVoices),
                              optimistic: [create, .linkProfile(speakerID: speakerID, profileID: profileID)])
        }
    }

    /// Splits a turn before `word` (a word of the turn other than its first). Never inside words edited together here
    /// (a `reviewEdit` mark): their edit, and its Revert, belong to one turn.
    ///
    /// `seenMoves`: how many of `wordMoves` `word` follows (the Split Turn sheet's, as it opened): a word edit saved
    /// since moves it there first, as an edit field's words; one that replaced it refuses the split.
    ///
    /// `seenEpoch`: `wordsEpoch` when the sheet opened: words changed elsewhere since cannot be followed, and refuse it.
    ///
    /// `seenRun`: the labels run the turn was chosen on (`splitRunRefusal`): labelled again since, it is refused.
    ///
    /// Returns the word it split before, as it is now (moved by a word edit saved since, `seenMoves`): the second
    /// part's first word.
    @discardableResult
    public func split(turnID: String, at word: WordRef, seenMoves: Int? = nil,
                      seenEpoch: Int? = nil, seenRun: String? = nil) async throws -> WordRef {
        if let refusal = splitRunRefusal(seenRun: seenRun) { throw HolosError.invalidInput(refusal) }
        let word = try splitWord(word, seenMoves: seenMoves, seenEpoch: seenEpoch)
        try await apply([splitAction(turnID: turnID, at: word)])
        return word
    }

    /// Why a split chosen on the turns of labels run `seenRun` cannot be made on the labels shown now: labelled again
    /// since (Label Again, a refresh from elsewhere), a turn ID may name another turn. The same run, or one this
    /// window's word edit, its undo or a revert published from it keeping its turns (`keepsTurns`), lets it be made;
    /// so does nil (no run known). Nil when it can be made.
    public func splitRunRefusal(seenRun: String?) -> String? {
        guard let seenRun, seenRun != projection.runID, !keepsTurns(of: seenRun, in: projection.runID) else {
            return nil
        }
        return "The speakers were labelled again since; choose where to split again."
    }

    /// `word`, chosen when `seenMoves` of `wordMoves` were seen and `wordsEpoch` was `seenEpoch`, where it is in the
    /// words shown now: a word edit saved since moves it; one that replaced it, or words changed elsewhere (no move
    /// says where they went), refuse the split.
    private func splitWord(_ word: WordRef, seenMoves: Int?, seenEpoch: Int?) throws -> WordRef {
        if let seenEpoch, seenEpoch != wordsEpoch {
            throw HolosError.invalidInput("The words were changed elsewhere while the split was being chosen; choose "
                                          + "where to split again.")
        }
        let seen = seenMoves ?? movesRead
        guard seen != movesRead else { return word }
        let moves = seen < movesRead ? wordMoves[seen..<movesRead]
            : ArraySlice(wordMoves[movesRead..<min(seen, wordMoves.count)].reversed().map(\.inverse))
        let followed = Self.follow([word], through: moves)
        guard !followed.replaced, let moved = followed.refs.first else {
            throw HolosError.invalidInput("That word was edited while the split was being chosen; choose where to "
                                          + "split again.")
        }
        return moved
    }

    /// Where a split at `word` falls, in the words and labels shown now (`word` as `splitWord` follows it from when it
    /// was chosen): `after` false, before it; true, after it. Inside a turn, that turn splits there; at a turn's first
    /// word (or after its last), the place is that turn's start (end), where only the window's rows can break. Nil
    /// when no shown turn holds the word. Throws when the word cannot be followed (`splitWord`). `turnID`: the turn the
    /// word was chosen in (turns may overlap: a word two turns hold splits the one it was chosen in); nil, the first
    /// turn holding it. A turn that no longer holds it gives nil.
    public func splitPlace(at word: WordRef, after: Bool, in turnID: String? = nil, seenMoves: Int?,
                           seenEpoch: Int?) throws -> ReviewSplitPlace? {
        let word = try splitWord(word, seenMoves: seenMoves, seenEpoch: seenEpoch)
        let wanted = turnID.map(resolvedTurnID)
        guard let turn = projection.turns.first(where: { turn in
            (wanted == nil || turn.id == wanted)
                && turn.spans.contains { $0.segmentID == word.segmentID && $0.first <= word.word && word.word < $0.end }
        }) else { return nil }
        let shown = words(of: turn)
        guard let index = shown.firstIndex(where: { $0.ref == word }) else { return nil }
        if after {
            return index + 1 < shown.count ? .inside(turnID: turn.id, word: shown[index + 1].ref)
                : .turnEnd(turnID: turn.id)
        }
        return index > 0 ? .inside(turnID: turn.id, word: word) : .turnStart(turnID: turn.id)
    }

    /// Why `turnID` cannot be split before `word` now, known before a split is offered or made (the context menu's
    /// Split Turn Here, Return at a word's start in edit mode): the split's own checks, made on the labels shown
    /// (`splitAction`), with the same message. Nil when it can be made.
    public func splitRefusal(turnID: String, at word: WordRef) -> String? {
        do {
            _ = try splitAction(turnID: turnID, at: word)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The split `split` queues, checked as it is checked when queued: the review editable, never inside words edited
    /// together (their edit, and its Revert, belong to one turn), and the split one the labels shown can make
    /// (`validate`: the word inside the turn, not its first).
    private func splitAction(turnID: String, at word: WordRef) throws -> SpeakerEditAction {
        try requireEditable()
        if let segment = segments[word.segmentID], (segment.fixes ?? []).contains(where: {
            $0.kind == .reviewEdit && $0.first < word.word && word.word < $0.end
        }) {
            throw HolosError.invalidInput("That word is part of words you edited together; split before or after them.")
        }
        let action = SpeakerEditAction.splitTurn(turnID: resolvedTurnID(turnID), at: word)
        try validate([Self.cleaned(resolve(action))])
        return action
    }

    /// Changes the automatic fix covering `word` back to what the recognizer heard. The other word fixes and the
    /// current speaker edits stay; this publishes a new transcript and speaker head, so it is not part of speaker
    /// edit undo.
    public func revertWordFix(_ word: WordRef) async throws {
        try requireEditable()
        if let blocked = wordEditingBlocked { throw HolosError.invalidInput(blocked) }
        // Before any fix's words are walked, and before anything is queued.
        if let refusal = revertRefusal(word) { throw HolosError.invalidInput(refusal) }
        // An edit made here goes back to what the recognizer wrote by another edit, undone like any other.
        if let segment = segments[word.segmentID], let edit = (segment.fixes ?? []).first(where: {
            $0.kind == .reviewEdit && $0.first <= word.word && word.word < $0.end
        }) {
            // Written back exactly as the recognizer wrote it (`verbatim`: two spaces, a line break).
            guard let op = try queuedWordEdit((edit.first..<edit.end).map { WordRef(segmentID: word.segmentID, word: $0) },
                                              to: edit.heard, seenMoves: nil, verbatim: true) else { return }
            try await wait(for: op)
            return
        }
        guard let segment = segments[word.segmentID], (segment.fixes ?? []).contains(where: {
            ($0.kind == .correction || $0.kind == .term) && $0.first <= word.word && word.word < $0.end
        }) else {
            throw Self.notFixedAutomatically
        }
        // `word` is of the words shown (`segments`, after `movesRead` moves): a word change saved but not reread yet
        // moves it, so the revert follows every move from there.
        let op = queued(.revertWordFix(word), optimistic: [])
        op.movesSeen = movesRead
        try await wait(for: op)
    }

    /// Every segment whose every word was deleted (here, or in an earlier review: `TranscriptSegment.removed`) that a
    /// Restore can bring back, in time order, whether or not a turn is listed near it (Edit ▸ Restore Deleted Words
    /// lists them all, so none is out of reach when every turn around it went too). Only while words can be edited,
    /// and only those whose turns the labels record (`DiarizationRun.removedSegments`; not after the speakers were
    /// labelled again).
    public func deletedWords() -> [ReviewDeletedWords] {
        guard canEditWords, let run = snapshot.run, let records = run.removedSegments, !records.isEmpty else {
            return []
        }
        let fixed = snapshot.transcript.fixedFrom != nil
        var found: [ReviewDeletedWords] = []
        for record in records {
            guard let segment = segments[record.segmentID], segment.removed != nil,
                  SpeakerTranscriptRetarget.canRestore(record.segmentID, in: run),
                  let text = TranscriptWordEdit.removedText(of: segment, fixed: fixed), !text.isEmpty else { continue }
            found.append(ReviewDeletedWords(segmentID: segment.id, text: text, start: segment.start,
                                            end: segment.end, track: segment.track))
        }
        return found.sorted { $0.start < $1.start }
    }

    /// `deletedWords()` offered from turn `turnID` (its row's menu, VoiceOver). Each is offered from one listed turn:
    /// the one nearest it in time, of its own track when that track has one listed (the turn that held it may be gone
    /// with it).
    public func deletedWords(near turnID: String) -> [ReviewDeletedWords] {
        let all = deletedWords()
        guard !all.isEmpty else { return [] }
        let id = resolvedTurnID(turnID)
        let listed = shownTurns
        guard listed.contains(where: { $0.id == id }) else { return [] }
        return all.filter { deleted in
            // Its own track first, then the time between them (none when they overlap); the earlier turn on a tie.
            func distance(_ turn: ProjectedTurn) -> (Int, Double) {
                (turn.track == deleted.track ? 0 : 1,
                 max(0, turn.start - deleted.end, deleted.start - turn.end))
            }
            return listed.min(by: { distance($0) < distance($1) })?.id == id
        }
    }

    /// Brings back the words of segment `segmentID`, all deleted earlier (`deletedWords(near:)`), as they were (their
    /// text, times, and fixes) and to the turns that held them: a word edit like any other (new transcript revisions,
    /// a speaker head with every speaker edit carried over), one undo takes it back.
    public func restoreDeletedWords(segmentID: String) async throws {
        _ = try await queueRestoreDeletedWords(segmentID: segmentID)()
    }

    /// `restoreDeletedWords` with its change queued before this returns, exactly as `queueWordEdit` queues an edit: a
    /// close or a quit right after finds it there (it is saved before the review closes, and a failure then is
    /// reported with the other word edits, `failedWordEditsAtClose`), and `committed` is called once it is saved, also
    /// when it then throws because the labels could not be reread (the words are back). Returns the wait for it (what
    /// was restored); throws when it is refused before it is queued.
    public func queueRestoreDeletedWords(segmentID: String, committed: ((ReviewWordEdit) -> Void)? = nil) throws
        -> @MainActor () async throws -> ReviewWordEdit? {
        try requireEditable()
        if let blocked = wordEditingBlocked { throw HolosError.invalidInput(blocked) }
        guard let segment = segments[segmentID], segment.removed != nil else {
            throw HolosError.invalidInput("Those words are no longer deleted; reload and try again.")
        }
        guard SpeakerTranscriptRetarget.canRestore(segmentID, in: snapshot.run) else {
            throw SpeakerTranscriptRetarget.notRestorable
        }
        let op = queued(.editWords(.restoring(segmentID: segmentID), segment: segment), optimistic: [])
        op.movesSeen = movesRead
        return waitForWordEdit(op, committed: committed)
    }

    /// The wait for queued word edit `op` (an edit or a Restore): what it saved, or why not; `committed` is called
    /// once it is saved, also when it then throws (its labels could not be reread: the change stands).
    private func waitForWordEdit(_ op: Operation, committed: ((ReviewWordEdit) -> Void)?)
        -> @MainActor () async throws -> ReviewWordEdit? {
        { [self] in
            do {
                try await wait(for: op)
            } catch {
                if let edit = op.wordEditResult { committed?(edit) }
                throw error
            }
            if let edit = op.wordEditResult { committed?(edit) }
            return op.wordEditResult
        }
    }

    /// How a queued Restore is named where an edit says what was typed (`unsavedWordEdits`, `failedWordEditsAtClose`):
    /// nothing was typed.
    nonisolated static func restoreDescription(_ segmentID: String) -> String {
        "(restore of deleted words, segment \(segmentID))"
    }

    /// Replaces shown words with `text` (docs/meeting-design.md §5.10, "Editing words"): `words` are consecutive words
    /// of one segment, all shown in one turn (never a word the echo mask hides); `text` may have more or fewer words,
    /// or none (a deletion). Publishes new transcript revisions and a speaker head with every speaker edit carried
    /// over; one undo takes it back. What it teaches is learned when the window closes, if it is still there. Returns
    /// what was edited, nil when the text would not change. Throws `invalidInput` with a message for the person when
    /// the words cannot be edited together.
    ///
    /// `seenMoves`: how many of `wordMoves` the caller's `words` already follow (an edit field opened before an earlier
    /// edit of the segment was saved); they are moved through the rest first.
    @discardableResult
    ///
    /// `committed`: called with what was edited once the edit is saved, also when it then throws because the labels
    /// could not be refreshed after it (the edit stands: what follows from it, such as adding its word-list term, still
    /// applies).
    ///
    /// `whileUnread`: the edit of a field open when the review turned read-only because its labels could not be reread
    /// (`reloadProblem`): queued all the same, it waits for the reread as the changes queued before it do, so what
    /// was typed is never dropped.
    ///
    /// `expecting`: each of `words`' text as the caller showed it (the edit field's words): a change made elsewhere
    /// and read since may have kept a word's place but changed it, and an edit is never made over words other than
    /// those the person saw. Refused then, saying what was typed.
    ///
    /// `seenEpoch`: `wordsEpoch` when the words were chosen: words changed elsewhere since cannot be followed (no word
    /// move says where they went), and refuse the edit, saying what was typed.
    public func editWords(_ words: [WordRef], to text: String, seenMoves: Int? = nil, whileUnread: Bool = false,
                          expecting: [String]? = nil, seenEpoch: Int? = nil,
                          committed: ((ReviewWordEdit) -> Void)? = nil) async throws -> ReviewWordEdit? {
        guard let saved = try queueWordEdit(words, to: text, seenMoves: seenMoves, whileUnread: whileUnread,
                                            expecting: expecting, seenEpoch: seenEpoch, committed: committed) else {
            return nil
        }
        return try await saved()
    }

    /// `editWords` with its change queued before this returns: the window hands an edit over on Return or Tab this
    /// way, so a close or a quit right after finds it in the queue (it is saved before the review closes, and
    /// `unsavedWordEdits` lists it meanwhile). Returns the wait for it (what was edited, or why it was not), nil when
    /// there is nothing to edit; throws when it is refused before it is queued.
    public func queueWordEdit(_ words: [WordRef], to text: String, seenMoves: Int? = nil, whileUnread: Bool = false,
                              expecting: [String]? = nil, seenEpoch: Int? = nil,
                              committed: ((ReviewWordEdit) -> Void)? = nil) throws
        -> (@MainActor () async throws -> ReviewWordEdit?)? {
        guard let op = try queuedWordEdit(words, to: text, seenMoves: seenMoves, whileUnread: whileUnread,
                                          expecting: expecting, seenEpoch: seenEpoch) else {
            return nil
        }
        return waitForWordEdit(op, committed: committed)
    }

    /// `editWords` up to its change being queued (no wait); nil when there is nothing to edit.
    private func queuedWordEdit(_ words: [WordRef], to text: String, seenMoves: Int?,
                                whileUnread: Bool = false, expecting: [String]? = nil,
                                seenEpoch: Int? = nil, verbatim: Bool = false) throws -> Operation? {
        try requireEditable(whileUnread: whileUnread)
        if let seenEpoch, seenEpoch != wordsEpoch {
            throw HolosError.invalidInput("The words were changed elsewhere while you edited them; edit them again"
                                          + TranscriptWordEdit.typedAside(text) + ".")
        }
        guard !snapshot.transcriptChanged else { throw Self.labelAgainFirst }
        guard snapshot.journal.isComplete else { throw Self.speakerChangesUnreadable }
        guard baseReadable else { throw Self.baseUnreadable }
        // The words as the transcript shown has them (`segments`, after `movesRead` moves; without `seenMoves`, the
        // words were taken from it): a word change saved but not reread moved words it does not show yet, so words
        // that followed that move are taken back through it. Checked against these words when it is saved, from
        // there (`saveWordEdit`).
        var words = words
        let seen = seenMoves ?? movesRead
        if seen != movesRead {
            let moves = seen < movesRead ? wordMoves[seen..<movesRead]
                : ArraySlice(wordMoves[movesRead..<min(seen, wordMoves.count)].reversed().map(\.inverse))
            let followed = Self.follow(words, through: moves)
            guard !followed.replaced else {
                throw HolosError.invalidInput("Those words changed while you edited them; edit them again"
                                              + TranscriptWordEdit.typedAside(text) + ".")
            }
            words = followed.refs
        }
        guard !words.isEmpty else { return nil }
        let (request, segment) = try wordEditRequest(words, text: text, verbatim: verbatim) { segment in
            // The words still read as the person saw them, punctuation included (`ReviewWord.shown`: a change made
            // elsewhere may keep a word's place and change only its untimed punctuation, "Hello." to "Hello?").
            if let expecting {
                guard expecting.count == words.count, zip(words, expecting).allSatisfy({ word, shown in
                    TranscriptWordEdit.shownText(of: segment, first: word.word, end: word.word + 1) == shown
                }) else {
                    throw HolosError.invalidInput("Those words were changed elsewhere while you edited them; edit "
                                                  + "them again" + TranscriptWordEdit.typedAside(text) + ".")
                }
            }
        }
        let op = queued(.editWords(request, segment: segment), optimistic: [])
        // Its words are those of `segment`: it follows every move since (it runs later, never before this returns).
        op.movesSeen = movesRead
        return op
    }

    /// The request for an edit of shown words `words` (of the transcript shown) to `text`, and their segment: what
    /// `editWords` queues and what the field check (`wordEditRefusal`) makes a dry run of. Throws, saying why, when
    /// they are not consecutive words of one segment that one turn shows all of, or words of overlapping turns.
    /// `shownAsSeen` runs once the segment is known.
    private func wordEditRequest(_ words: [WordRef], text: String, verbatim: Bool = false,
                                 shownAsSeen: (TranscriptSegment) throws -> Void = { _ in })
        throws -> (TranscriptWordEdit.Request, TranscriptSegment) {
        guard let first = words.first else {
            throw HolosError.invalidInput("Those words are no longer in the transcript; reload and try again.")
        }
        guard words.allSatisfy({ $0.segmentID == first.segmentID }) else {
            throw HolosError.invalidInput("Words of two segments cannot be edited together yet; edit each part on its "
                                          + "own.")
        }
        let indices = words.map(\.word).sorted()
        guard let lowest = indices.first, let highest = indices.last, highest - lowest + 1 == indices.count else {
            throw HolosError.invalidInput("Words hidden as echo lie between these words; edit them one at a time.")
        }
        guard let segment = segments[first.segmentID] else {
            throw HolosError.invalidInput("Those words are no longer in the transcript; reload and try again.")
        }
        try shownAsSeen(segment)
        func holds(_ turn: ProjectedTurn, _ index: Int) -> Bool {
            turn.spans.contains { $0.segmentID == first.segmentID && $0.first <= index && index < $0.end }
        }
        guard indices.allSatisfy({ index in projection.turns.contains { holds($0, index) } }) else {
            throw HolosError.invalidInput("Some of these words are not shown (hidden as echo); edit the words you see.")
        }
        // One turn must hold every word (turns may overlap: two holding a word each is not one holding them all).
        guard projection.turns.contains(where: { turn in indices.allSatisfy { holds(turn, $0) } }) else {
            throw HolosError.invalidInput("Words of two turns cannot be edited together yet; edit each turn's words "
                                          + "on its own.")
        }
        guard TranscriptWordEdit.sameOwners(Self.takingInMarks(indices, of: segment), segmentID: first.segmentID,
                                            turns: projection.turns.map(\.spans)) else {
            throw TranscriptWordEdit.overlappingTurns
        }
        return (TranscriptWordEdit.Request(segmentID: first.segmentID, first: lowest, end: highest + 1, text: text,
                                           verbatim: verbatim), segment)
    }

    /// Moves every turn of `speakerID` to `target`; `speakerID` disappears. `target` keeps its name.
    public func merge(_ speakerID: String, into target: String) async throws {
        try await apply([.merge(from: speakerID, into: target)])
    }

    /// Links every suggestion ("Maybe Jim") to its person as one change (one undo), learning voices when
    /// `learnVoices` is on.
    public func confirmAllSuggestions() async throws {
        try requireEditable()
        try requirePeople()
        let known = Set(people.map(\.id))
        var chosen: [String: String] = [:]
        let optimistic = projection.speakers.flatMap { speaker -> [SpeakerEditAction] in
            guard let suggestion = suggestion(for: speaker.id), known.contains(suggestion.profileID) else { return [] }
            chosen[speaker.id] = suggestion.profileID
            let name = people.first { $0.id == suggestion.profileID }?.displayName ?? suggestion.profileName
            return [.linkProfile(speakerID: speaker.id, profileID: suggestion.profileID),
                    .rename(speakerID: speaker.id, name: name)]
        }
        guard !optimistic.isEmpty else { throw HolosError.invalidInput("There are no suggested names to confirm.") }
        mergeArmed = true
        try await enqueue(.confirmAll(learnVoices: learnVoices, suggestions: chosen), optimistic: optimistic)
    }

    /// Gives a turn flagged "sounds like Jim" (`turnHint`) to Jim's speaker, as one change.
    public func acceptTurnHint(_ turnID: String) async throws {
        guard let hint = turnHint(turnID) else {
            throw HolosError.invalidInput("That turn no longer sounds like someone else in this meeting.")
        }
        try await assign([hint.turnID], to: .speaker(hint.speakerID))
    }

    /// "This is me": links the speaker to you (the one `isSelf` person, created on first use). Passes `learnVoices`
    /// to `VoiceProfileService.markSelf`.
    public func markSelf(speakerID: String) async throws {
        try requireEditable()
        try requirePeople()
        guard projection.speakers.contains(where: { $0.id == speakerID }) else { throw Self.noSpeaker(speakerID) }
        let optimistic: [SpeakerEditAction]
        if let me = people.first(where: \.isSelf) {
            optimistic = [.linkProfile(speakerID: speakerID, profileID: me.id),
                          .rename(speakerID: speakerID, name: me.displayName)]
        } else {
            optimistic = [.rename(speakerID: speakerID, name: VoiceProfileService.selfName)]
        }
        mergeArmed = true
        try await enqueue(.markSelf(speakerID: speakerID, learnVoice: learnVoices), optimistic: optimistic)
    }

    /// "Not Maria" for the speaker's suggestion, or "Not Jim" for its automatic name, in this meeting only.
    ///
    /// `profileID`: the person the window showed ("Not Jim"), which the suggestion may no longer name by the time the
    /// click arrives (a voice match can replace recognition's); without it, the current suggestion's.
    public func rejectSuggestion(speakerID: String, profileID shown: String? = nil) async throws {
        guard let speaker = speaker(speakerID) else { throw Self.noSpeaker(speakerID) }
        guard let profileID = shown ?? suggestion(for: speaker.id)?.profileID ?? automaticProfileID(for: speakerID)
        else {
            throw HolosError.invalidInput("This speaker has no suggested name to reject.")
        }
        try await apply([.rejectProfile(speakerID: speakerID, profileID: profileID)])
    }

    /// `voiceislocal session diarize --keep-transcript --force --min-speakers <current + 1>`; names carry over
    /// (§4.9). The transcript under review is kept: a meeting's languages are not detected again.
    ///
    /// "Current" is the number of speakers the diarizer found on the one track it split. Turn-level changes are not
    /// carried; the window's undo history ends here. Throws when the relabel fails (`unavailable`) or finished with
    /// a warning (`incomplete`, with its message); the labels are reloaded either way.
    public func findMoreSpeakers() async throws {
        try requireEditable()
        guard let minimum = findMoreSpeakersMinimum, maintenance != nil else {
            throw HolosError.invalidInput("Find More Speakers works when one track of the meeting was split into "
                                          + "speakers.")
        }
        try await relabel(Self.relabelArguments(session: session, force: true, minimumSpeakers: minimum,
                                                othersInRoom: othersInRoomFlag))
    }

    /// `voiceislocal session diarize --keep-transcript --force --others-in-room` (call recordings).
    public func labelMicrophoneSpeakers() async throws {
        try requireEditable()
        guard canLabelMicrophoneSpeakers else {
            throw HolosError.invalidInput("Only a call whose microphone was labelled as you alone can be labelled "
                                          + "again with the people in the room.")
        }
        try await relabel(Self.relabelArguments(session: session, force: true, minimumSpeakers: nil,
                                                othersInRoom: true))
    }

    /// Labels the speakers again after the transcript changed (`voiceislocal session diarize --keep-transcript`);
    /// names carry over.
    public func labelAgain() async throws {
        try requireEditable()
        guard maintenance != nil else { throw HolosError.unavailable("Speakers cannot be labelled from here.") }
        try await relabel(Self.relabelArguments(session: session, force: false, minimumSpeakers: nil,
                                                othersInRoom: othersInRoomFlag))
    }

    /// One export format of the labels as saved once every queued change is saved (Save As…, Copy as Markdown).
    /// Written nowhere; `exports/` is brought up to date on the way when it is behind.
    public func render(_ format: ExportFormat) async throws -> Data {
        guard !closed else { throw Self.closedError }
        _ = try? await enqueue(.exports, optimistic: [])
        let session = self.session
        let names = profileNames
        let store = profiles
        return try await Self.detached {
            try SessionExports.render(format, session: session, profileNames: names,
                                      applyRecognition: Self.recognitionAllowed(store))
        }
    }

    /// Rereads the people and then the labels from disk (after a change made elsewhere, such as Delete Audio or a
    /// relabel from Meetings, or to leave the read-only state of `reloadProblem`). Changes still queued in this window
    /// that were made on the older labels are refused.
    public func reload() async {
        guard !closed else { return }
        await rereadLabels()
        // Read again on request: the word checks too (off the main actor), before it returns.
        await wordChecksSettled()
    }

    /// `reload` without waiting for the word checks (tests).
    func rereadLabels() async {
        guard !closed else { return }
        _ = try? await enqueue(.reload, optimistic: [])
    }

    /// What the window's open edit field holds, handed over when it closes for a pause or the window's close: its
    /// words, what was typed, the word moves they follow (`editWords(seenMoves:)`), and their text as the field showed
    /// it (`editWords(expecting:)`), so every path checks it the same way.
    public struct TypedEdit: Sendable, Equatable {
        public var words: [WordRef]
        public var text: String
        public var seenMoves: Int
        public var expected: [String]?
        /// `wordsEpoch` when the words were chosen (`editWords(seenEpoch:)`).
        public var seenEpoch: Int?

        public init(words: [WordRef], text: String, seenMoves: Int, expected: [String]? = nil,
                    seenEpoch: Int? = nil) {
            self.words = words; self.text = text; self.seenMoves = seenMoves; self.expected = expected
            self.seenEpoch = seenEpoch
        }
    }

    /// A maintenance command is about to work on the meeting (`ReviewMaintenance`): the review turns read-only at
    /// once (`pauseReason` says why; changes are refused), and this returns once every change made before is saved
    /// and the transcript files are written, so the command starts from them. `hold` is this run of the command (each
    /// run has its own); pausing again with a hold already held only waits for those saves.
    ///
    /// `typed`: what the window's open edit field holds (a command makes the review read-only, so the field closes):
    /// queued as `editWords` before the review turns read-only, and waited for like every change before. Returns, when
    /// it is not saved (refused, or still waiting), why, with what was typed; nil otherwise.
    @discardableResult
    public func pause(_ hold: ReviewMaintenance.Hold, reason: String,
                      typed: TypedEdit? = nil) async -> String? {
        guard !closed else { return nil }
        var typedEdit: Operation?
        var refusal: (any Error)?
        if let typed, !pauses.contains(where: { $0.hold == hold }) {
            do {
                typedEdit = try queuedWordEdit(typed.words, to: typed.text, seenMoves: typed.seenMoves,
                                               expecting: typed.expected, seenEpoch: typed.seenEpoch)
            } catch {
                refusal = error
            }
        }
        if !pauses.contains(where: { $0.hold == hold }) {
            pauses.append((hold, reason))
            exportTimer?.cancel()
            exportTimer = nil
            // The command may delete the audio or forget voices: no pass reads the audio meanwhile, and a sample sync
            // running is stopped and waited for (it runs again once the review resumes).
            if case .running = voiceAnalysis {
                stoppedPass = voiceTask
                dropVoices()
            }
            holdSampleSync()
            notify()
            Self.log.info("Session \(self.sessionID, privacy: .public): review paused for a maintenance command")
        }
        // Their children have exited (and deleted their renders) before the command starts.
        if let stopped = stoppedPass {
            await stopped.value
            stoppedPass = nil
        }
        if let running = sampleRun { await running.value }
        _ = try? await enqueue(.exports, optimistic: [])
        // The edit was queued before the exports, so it has run (or waits behind labels that could not be reread).
        guard let typed else { return nil }
        if case .failure(let error)? = typedEdit?.result { refusal = error }
        if let refusal { return TranscriptWordEdit.withTyped(refusal.localizedDescription, typed.text) }
        if let typedEdit, !typedEdit.finished {
            return "The edit waits until the speaker labels are reread." + TranscriptWordEdit.typedNote(typed.text)
        }
        return nil
    }

    /// The command run `hold` paused for has ended: the review rereads the transcript, the labels, and the people, then
    /// is editable again when no other hold remains (a command started while this reread runs keeps its own).
    /// Transcript files still waiting are written `exportDelay` later.
    public func resume(_ hold: ReviewMaintenance.Hold) async {
        guard pauses.contains(where: { $0.hold == hold }) else { return }
        if !closed { _ = try? await enqueue(.reload, optimistic: []) }
        pauses.removeAll { $0.hold == hold }
        if exportsPending, pauses.isEmpty { scheduleExports() }
        if pauses.isEmpty {
            updateVoiceAnalysis()
            scheduleSampleSync()
        }
        notify()
        Self.log.info("Session \(self.sessionID, privacy: .public): review resumed after a maintenance command")
    }

    /// The transcript files are known to be older than the saved labels (rewriting them failed when an earlier
    /// review closed, `PendingExports`): they are rewritten `exportDelay` from now, or at `close`.
    public func markExportsPending() {
        guard !closed else { return }
        exportsPending = true
        scheduleExports()
    }

    /// Regenerates exports now if an edit is pending. Call when the window closes. When that fails, `exportsPending`
    /// stays true and `exportProblem` says why, so the caller can tell the user and try again later.
    ///
    /// Waits for queued changes to be saved first; later edits are refused.
    ///
    /// `typed`: what the window's open edit field holds (closing a window ends no editing): queued as `editWords`
    /// before the review closes, so it is saved and learned like any edit, or refused (logged) as one would be.
    public func close(typed: TypedEdit? = nil) async {
        guard !closed else { return }
        var typedEdit: Operation?
        if let typed {
            do {
                typedEdit = try queuedWordEdit(typed.words, to: typed.text, seenMoves: typed.seenMoves,
                                               expecting: typed.expected, seenEpoch: typed.seenEpoch)
            } catch {
                Self.log.error("Session \(self.sessionID, privacy: .public): the edit open at close was not saved (\(ProcessSpawner.logCategory(error), privacy: .public))")
                refusedAtClose = (TranscriptWordEdit.cleaned(typed.text), error.localizedDescription)
            }
        }
        // Every word edit still to save, the field's with them: one that fails now is known with what was typed.
        closingWordEdits = queue.filter { op in
            guard !op.finished, case .editWords = op.kind else { return false }
            return true
        }
        closed = true
        exportTimer?.cancel()
        exportTimer = nil
        // A read of the word checks in flight is of no use now: it stops at its next segment or turn.
        wordChecksRead?.cancel()
        do {
            try await enqueue(.exports, optimistic: [])
        } catch {
            Self.log.error("Session \(self.sessionID, privacy: .public): exports not rewritten at close (\(ProcessSpawner.logCategory(error), privacy: .public))")
        }
        // Changes still waiting for labels that were never reread (`drain`) end here; a word edit says what it held.
        // (A relabel waiting behind them goes too: it runs only after them.)
        let held = queue.filter { !$0.started && !runsAhead($0) }
        queue.removeAll { op in held.contains { $0 === op } }
        for op in held {
            var message = "The review closed before the speaker labels could be reread, so a change was not saved."
            if case .editWords(let request, _) = op.kind {
                message = "The review closed before the speaker labels could be reread, so an edit was not saved"
                    + TranscriptWordEdit.typedAside(request.text) + "."
            }
            op.finish(.failure(HolosError.unavailable(message)))
        }
        // Queued before the exports, it has run (or was held, above).
        if case .failure(let error)? = typedEdit?.result {
            Self.log.error("Session \(self.sessionID, privacy: .public): the edit open at close was not saved (\(ProcessSpawner.logCategory(error), privacy: .public))")
        }
        recomputeProjection()
        await learnFromEdits()
        // A voice pass still running stops; a sample sync still owed runs now (from what the pass stored, or with a
        // pass of its own), and then the meeting's voices are dropped from memory.
        let pass = voiceTask
        stopVoicePass()
        await flushSamples()
        dropVoices()
        // The pass's child has exited (and deleted its render) before the window reports it closed.
        await pass?.value
        Self.log.info("Session \(self.sessionID, privacy: .public): review closed")
    }

    /// The app is quitting without waiting for `close` any longer: the voice pass and a sample sync stop now, so their
    /// children exit (deleting their renders) rather than outlive the app. A voice not learned yet is not learned; the
    /// names are saved.
    public func stopBackgroundWork() {
        // A sync still owed (waiting, running, or not started) is recorded, so the meeting's next review runs it.
        if samplesOwed, profiles != nil {
            pendingVoices?.mark(sessionID, PendingVoiceSamples.Entry(enroll: sampleEnroll.mapValues(\.epoch),
                                                                     problem: nil))
        }
        backgroundStopped = true
        sampleTimer?.cancel()
        sampleTimer = nil
        sampleRun?.cancel()
        stopVoicePass()
    }

    // MARK: - Relabel arguments

    /// `session diarize <path> --keep-transcript [--force] [--min-speakers N] [--others-in-room | --no-others-in-room]
    /// --json`. The review window's relabels label the speakers of the transcript under review: `--keep-transcript`
    /// keeps a meeting's languages from being detected again (docs/meeting-design.md §4.14), which would transcribe
    /// the meeting again and replace that transcript.
    nonisolated static func relabelArguments(session: URL, force: Bool, minimumSpeakers: Int?,
                                             othersInRoom: Bool?) -> [String] {
        var arguments = ["session", "diarize", session.path, "--keep-transcript"]
        if force { arguments.append("--force") }
        if let minimumSpeakers { arguments += ["--min-speakers", String(minimumSpeakers)] }
        if let othersInRoom { arguments.append(othersInRoom ? "--others-in-room" : "--no-others-in-room") }
        arguments.append("--json")
        return arguments
    }

    // MARK: - Queue

    /// One change of the window's undo: the batches it saved, newest last. `order` keeps entries in the order their
    /// changes were saved when one is put back.
    private struct UndoEntry {
        let order: Int
        let batches: [String]
        /// A word edit's undo (it saved no batch).
        var wordEdit: WordEditUndo? = nil
    }

    /// How to take back a saved word edit: make `previous` current again while `edited` is.
    private struct WordEditUndo {
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
    @MainActor private final class Operation {
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
        var started = false
        /// Undone before it was saved: not shown, and an undo reverts what it saves.
        var undone = false
        /// Labels were adopted while it ran (its own result, or a reload after a refusal): the saved labels now
        /// show whatever it did, so its optimistic actions are no longer shown.
        var superseded = false
        /// The labels reread while it ran have a head made elsewhere (a relabel or a replacement landed between its
        /// save and the reread): the undo stack was emptied for it, and it gets no undo entry either, since its own
        /// head is no longer the current one.
        var overtaken = false
        var finished = false
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

        func finish(_ result: Result<Void, any Error>) {
            finished = true
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    @discardableResult
    private func enqueue(_ kind: Operation.Kind, optimistic: [SpeakerEditAction]) async throws -> Operation {
        let op = queued(kind, optimistic: optimistic)
        try await wait(for: op)
        return op
    }

    /// Queues a change at once (it runs once the changes before it ran); `wait` for its outcome.
    ///
    /// Every change is shown at once as `SpeakerEditor` will save it (an edit, a link, "This is me", Confirm All, an
    /// assignment to a person): its actions with the merges that keep one speaker per name
    /// (`SpeakerProjection.joiningSameNames`, which the editor applies to the saved batch too), worked out on the
    /// labels shown now. Otherwise a rename of a speaker shown joined by name would show its other stored speaker
    /// again until the save, and a change queued on that row meanwhile would name a speaker the save merges away.
    private func queued(_ kind: Operation.Kind, optimistic: [SpeakerEditAction]) -> Operation {
        let shown = optimistic.isEmpty ? [] : projection.joiningSameNames(optimistic)
        let op = Operation(kind: kind, basis: savedVersion, runID: snapshot.run?.id, optimistic: shown)
        op.movesSeen = wordMoves.count
        // A newer change: voice samples wait for it (`holdSampleSync`); exports alone change no label.
        if case .exports = kind {} else { holdSampleSync() }
        queue.append(op)
        recomputeProjection()
        updateActivity()
        notify()
        startDraining()
        return op
    }

    private func wait(for op: Operation) async throws {
        if let result = op.result { return try result.get() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            op.continuation = continuation
        }
    }

    private func startDraining() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    /// Runs the queue in order. While the labels shown may not be the saved ones (`reloadProblem`, after a change
    /// whose labels could not be reread), every change waits, still queued: run now it would be refused as made on
    /// other labels, and lost. Only the reread runs ahead (a reload), and the transcript files; a relabel runs only
    /// once the changes queued before it have run (its labels would make them stale, and they would be refused); the
    /// reread that ends that state lets the rest run, a word edit on the words where the earlier edit moved them.
    private func drain() async {
        while let op = queue.first(where: { reloadProblem == nil || runsAhead($0) }) {
            op.started = true
            activity = activityText(op)
            notify()
            let result: Result<Void, any Error>
            do {
                try await run(op)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            queue.removeAll { $0 === op }
            if op.savedUnreloaded {
                // Still shown; its undo entry is made once labels read from disk show what it saved (`adopt`).
                unreloaded.append(op)
            } else if op.isUndoable, !op.undone, !op.overtaken, op.savedUndoable {
                pushUndo(op.batches, wordEdit: op.wordEdit)
            }
            if case .failure(let error) = result { restoreUndo(after: op, error: error) }
            op.finish(result)
            recomputeProjection()
            updateActivity()
            notify()
        }
        draining = false
        updateVoiceAnalysis()
        scheduleSampleSync()
        considerAutoMerge()
    }

    /// `op` may run while the labels could not be reread (`drain`): the reread (a reload) and the transcript files
    /// always; a relabel only with no change waiting before it, so the queue stays in order for every change.
    private func runsAhead(_ op: Operation) -> Bool {
        switch op.kind {
        case .reload, .exports: true
        case .relabel: !queue.prefix(while: { $0 !== op }).contains { !$0.runsWhileUnread }
        default: false
        }
    }

    private func pushUndo(_ batches: [String], wordEdit: WordEditUndo? = nil) {
        undoStack.append(UndoEntry(order: undoOrder, batches: batches, wordEdit: wordEdit))
        undoOrder += 1
    }

    /// An undo that failed: what it was to take back is undoable again, unless it saved its reverts (`incomplete`:
    /// the reverts are on disk) or the labels were replaced by a new labelling meanwhile (undo does not reach past
    /// one). A multi-batch entry is put back whole; batches it did revert are no longer in effect and are skipped by
    /// the next undo.
    private func restoreUndo(after op: Operation, error: any Error) {
        guard case .undo(let target) = op.kind, !op.savedUnreloaded, !Self.isIncomplete(error) else { return }
        // The labels are still those the undo was asked on, or this window's own word changes retargeted them since
        // (an edit saved while the undo waited keeps the turns: `keepsTurns`); a new labelling is neither.
        var sameLabels = snapshot.run?.id == op.runID
        if !sameLabels, let current = snapshot.run?.id, let asked = op.runID {
            sameLabels = keepsTurns(of: asked, in: current)
        }
        // A word edit's undo needs its own transcript current (`undoWordEdit`): once another change replaced it (a
        // revert saved while the undo waited), it can never be made, and put back it would block every undo before it.
        let stillUndoable = { (edit: WordEditUndo?) in
            edit.map { self.snapshot.transcript.id == self.currentStandIn(for: $0.edited) } ?? true
        }
        switch target {
        case .saved(let entry):
            guard sameLabels, stillUndoable(entry.wordEdit) else { return }
            let index = undoStack.firstIndex { $0.order > entry.order } ?? undoStack.endIndex
            undoStack.insert(entry, at: index)
        case .operation(let earlier):
            // The earlier change stays in effect on disk, so it is shown again and can be undone again.
            earlier.undone = false
            guard !earlier.savedUnreloaded, earlier.savedUndoable, sameLabels, stillUndoable(earlier.wordEdit) else {
                return
            }
            pushUndo(earlier.batches, wordEdit: earlier.wordEdit)
        }
        Self.log.info("Session \(self.sessionID, privacy: .public): an undo failed; the change can be undone again")
    }

    private nonisolated static func isIncomplete(_ error: any Error) -> Bool {
        if case .incomplete? = error as? HolosError { return true }
        return false
    }

    private func run(_ op: Operation) async throws {
        switch op.kind {
        case .edit(let actions, let requireCompleteJournal):
            try requireBasis(op)
            let sent = actions.map(resolve)
            try await saveEdit(sent, op: op, requireCompleteJournal: requireCompleteJournal) { batch in
                SpeakerEditor.saved(batch.map(\.action), asAsked: sent)
            }
        case .link(let speakerID, let asked, let learnVoice, let byName):
            try requireBasis(op)
            var resolved = asked
            if byName, case .new(let name) = asked {
                // An earlier change still saving when this one was made may have created the person since.
                await reloadPeople()
                if let person = person(named: name) { resolved = .existing(profileID: person.id) }
            }
            let target = resolved
            let view = savedProjection
            try await savePeopleChange(op, matching: Self.linkBatch(speakerID),
                                       learn: learnVoice) { session, store, extractor, deferred in
                try await VoiceProfileService.link(session: session, speakerID: speakerID, to: target, view: view,
                                                   learnVoice: learnVoice, extractor: extractor, store: store,
                                                   deferSamples: deferred)
            }
        case .assignPerson(let create, let speakerID, let profileID, let learnVoice):
            try requireBasis(op)
            let sent = resolve(create)
            try await saveEdit([sent], op: op) { batch in SpeakerEditor.saved(batch.map(\.action), asAsked: [sent]) }
            let view = savedProjection
            try await savePeopleChange(op, matching: Self.linkBatch(speakerID),
                                       learn: learnVoice) { session, store, extractor, deferred in
                try await VoiceProfileService.link(session: session, speakerID: speakerID,
                                                   to: .existing(profileID: profileID), view: view,
                                                   learnVoice: learnVoice, extractor: extractor, store: store,
                                                   deferSamples: deferred)
            }
        case .confirmAll(let learnVoices, let chosen):
            try requireBasis(op)
            let view = savedProjection
            try await savePeopleChange(op, matching: Self.confirmBatch,
                                       learn: learnVoices) { session, store, extractor, deferred in
                try await VoiceProfileService.confirmAll(session: session, view: view, learnVoices: learnVoices,
                                                         extractor: extractor, store: store, suggestions: chosen,
                                                         deferSamples: deferred)
            }
        case .markSelf(let speakerID, let learnVoice):
            try requireBasis(op)
            let view = savedProjection
            try await savePeopleChange(op, matching: Self.linkBatch(speakerID),
                                       learn: learnVoice) { session, store, extractor, deferred in
                try await VoiceProfileService.markSelf(session: session, speakerID: speakerID, view: view,
                                                       learnVoice: learnVoice, extractor: extractor, store: store,
                                                       deferSamples: deferred)
            }
        case .undo(let target):
            let batches: [String]
            let wordEdit: WordEditUndo?
            switch target {
            case .saved(let entry):
                batches = entry.batches
                wordEdit = entry.wordEdit
            case .operation(let earlier):
                // Its lines are saved but not reread yet, so which lines to revert is not known: refused, and the
                // change is shown again (`restoreUndo`).
                if earlier.savedUnreloaded { throw HolosError.unavailable(reloadProblem ?? Self.notReread) }
                batches = earlier.batches
                wordEdit = earlier.wordEdit
            }
            if let wordEdit { try await undoWordEdit(wordEdit) }
            for batch in batches.reversed() {
                try await undoBatch(batch, op: op)
            }
        case .editWords(let request, let asked):
            try requireBasis(op)
            try await saveWordEdit(request, segment: asked, op: op)
        case .revertWordFix(let asked):
            try requireBasis(op)
            // A word edit of the segment saved since it was asked for moves the fix's words: it is found where they
            // are now; an edit that replaced the fixed word leaves nothing to revert.
            let followed = Self.follow([asked], through: wordMoves.dropFirst(op.movesSeen))
            guard !followed.replaced, let word = followed.refs.first else {
                throw HolosError.invalidInput("That word was edited meanwhile, so its fix is no longer there to revert.")
            }
            guard let runID = snapshot.run?.id else {
                throw HolosError.invalidInput("The speaker labels cannot be kept on the reverted words.")
            }
            let session = self.session
            let transcriptID = snapshot.transcript.id
            let hook = beforeEdit
            let headHook = beforeHeadPublish
            let writtenHook = afterHeadWritten
            let outcome = await Self.detachedResult {
                if let hook { await hook() }
                return try await SpeakerTranscriptRetarget.$beforePublishHead.withValue(headHook) {
                    try await SpeakerTranscriptRetarget.$afterHeadWritten.withValue(writtenHook) {
                        try await SessionWordFixRevert.run(session: session, word: word,
                                                           expectedTranscriptID: transcriptID, expectedRunID: runID)
                    }
                }
            }
            switch outcome {
            case .success(let published):
                // This window's own change, as a word edit is: its run keeps the turns, and changes queued meanwhile
                // follow its word move instead of being refused as made elsewhere.
                revertCommitted(published)
                turnKeepingRuns[published.runID] = runID
                do {
                    adopt(try await loadSnapshot(), op: nil, matching: nil)
                } catch {
                    holdUnreread(matching: nil, problem: "The word fix was reverted, but the window could not "
                                 + "reread the speaker labels: \(error.localizedDescription)")
                    changesSaved(exportsWritten: false)
                    throw HolosError.incomplete("The word fix was reverted, but the review could not be refreshed.")
                }
                changesSaved(exportsWritten: false)
            case .failure(let error):
                if error is CancellationError { throw error }
                if let incomplete = error as? SessionWordFixRevert.IncompletePublication {
                    if let published = incomplete.outcome {
                        revertCommitted(published)
                        // Its run is this window's, as a word edit's is: head.json may name it already (the rename was
                        // done, a later step failed), and then no repair publishes another.
                        turnKeepingRuns[published.runID] = runID
                    }
                    // Owed until a reread finds the labels on the current transcript (`adopt`), as a word edit's is; a
                    // reload repairs it.
                    owedHead = (transcriptID, runID, true)
                    do {
                        try await repairOwedHead()
                        let fresh = try await loadSnapshot()
                        guard fresh.projection != nil, !fresh.transcriptChanged else {
                            throw HolosError.unavailable("The new speaker head is incomplete.")
                        }
                        adopt(fresh, op: nil, matching: nil)
                        changesSaved(exportsWritten: false)
                        return
                    } catch let reread {
                        holdUnreread(matching: nil, problem: "The word fix was reverted, but its speaker labels could "
                                     + "not be saved or reread (\(reread.localizedDescription)); Reload tries again.")
                    }
                    changesSaved(exportsWritten: false)
                    throw error
                }
                do {
                    adopt(try await loadSnapshot(), op: nil, matching: nil, external: true)
                } catch {
                    Self.log.error("Session \(self.sessionID, privacy: .public): labels not reread after a word-fix refusal (\(ProcessSpawner.logCategory(error), privacy: .public))")
                }
                throw error
            }
        case .relabel(let arguments):
            try await runRelabel(arguments)
        case .reload:
            // A speaker head still owed (a word edit, its undo, or a revert) is repaired first: until the labels read
            // are on the current transcript, the review stays held (labels made on the words as they were would let
            // an undo fail and Label Again drop the turn edits).
            var repairProblem: String?
            if owedHead != nil {
                do { try await repairOwedHead() } catch { repairProblem = error.localizedDescription }
            }
            // `loadSnapshot` rereads the people first, so the labels are built with their current names.
            let fresh = try await loadSnapshot()
            if owedHead != nil, fresh.projection == nil || fresh.transcriptChanged {
                holdUnreread(matching: nil, problem: "The words were changed, but their speaker labels could not be "
                             + "saved (\(repairProblem ?? "the new speaker head is incomplete")); Reload tries again.")
                return
            }
            adopt(fresh, op: nil, matching: nil)
        case .exports:
            try await regenerateExports()
        }
    }

    // MARK: - Saving

    /// Saves `actions` with `SpeakerEditor` on the saved labels, then adopts the result (built with the people's
    /// names as reread just before).
    private func saveEdit(_ actions: [SpeakerEditAction], op: Operation, requireCompleteJournal: Bool = false,
                          matching: @escaping ([SpeakerEdit]) -> Bool) async throws {
        await reloadPeople()
        let view = savedProjection
        let session = self.session
        let names = profileNames
        let store = profiles
        let hook = beforeEdit
        let outcome = await Self.detachedResult { () throws -> SpeakerEditResult? in
            if let hook { await hook() }
            // Whether the batch changes anything is decided on the current labels under the speaker lock: the check
            // on the shown labels (`apply`) cannot see a change saved elsewhere meanwhile that already made it.
            return try SpeakerEditor.applyUnlessUnchanged(actions, view: view, session: session, source: Self.source,
                                                          regenerateExports: false, profileNames: names,
                                                          profiles: store,
                                                          requireCompleteJournal: requireCompleteJournal)
        }
        switch outcome {
        case .success(let result?):
            if adopt(result.snapshot, op: op, matching: matching) { changesSaved(exportsWritten: false) }
            if result.needsSampleRefresh { oweSamples() }
        case .success(nil):
            // Nothing saved (no undo step is used up): the labels on disk already read as the change asked. They are
            // reread so the window shows them; when that fails, the saved labels shown stay as they were.
            Self.log.info("Session \(self.sessionID, privacy: .public): a change would leave the labels as they are; not saved")
            if let fresh = try? await loadSnapshot() { adopt(fresh, op: op, matching: matching) }
        case .failure(let error):
            try await handleFailure(error, op: op, refreshSamples: true, matching: matching)
        }
    }

    /// Saves a word edit (`SessionWordEdit.run`) on the transcript and labels shown, then adopts the retargeted labels
    /// as this window's own change. As soon as it is committed, the edit's undo and what it was are kept on `op`, its
    /// word move is recorded (`wordMoves`), even when the labels cannot be reread afterwards. An earlier edit of the same segment saved since this one was asked for (Tab moves
    /// on before a save ends) moves its words: it is made on them where they now are. Refused when its own words were
    /// replaced meanwhile, or the segment changed otherwise.
    private func saveWordEdit(_ asked: TranscriptWordEdit.Request, segment: TranscriptSegment,
                              op: Operation) async throws {
        // What was typed is said, so a refused edit never loses it.
        let typed = TranscriptWordEdit.cleaned(asked.text)
        let changed = HolosError.invalidInput("Those words changed while the edit waited to be saved; edit them again"
            + TranscriptWordEdit.typedAside(typed) + ".")
        var request = asked
        let moves = wordMoves.dropFirst(op.movesSeen).filter { $0.segmentID == asked.segmentID }
        if asked.restoresRemoved {
            // A Restore names no word: the segment must hold the deleted words still, as it did when asked.
            guard moves.isEmpty, segments[asked.segmentID] == segment else {
                throw HolosError.invalidInput("Those deleted words changed meanwhile; reload and try again.")
            }
        } else if moves.isEmpty {
            guard segments[asked.segmentID] == segment else { throw changed }
        } else {
            // Moved, the words must still read as they did, and none of them may be one an earlier edit replaced.
            let span = [WordRef(segmentID: asked.segmentID, word: asked.first),
                        WordRef(segmentID: asked.segmentID, word: asked.end - 1)]
            let followed = Self.follow(span, through: moves[...])
            let moved = followed.refs
            // Compared as shown: a neighbour a deletion merged into keeps its text, not the space Apple's recognizer
            // put at the front of its range.
            guard let current = segments[asked.segmentID], !followed.replaced,
                  moved[1].word - moved[0].word == asked.end - 1 - asked.first, moved[0].word >= 0,
                  Self.shownWords(of: current, moved[0].word..<(moved[1].word + 1))
                    == Self.shownWords(of: segment, asked.first..<asked.end) else {
                throw changed
            }
            request.first = moved[0].word
            request.end = moved[1].word + 1
        }
        guard let runID = snapshot.run?.id else {
            throw HolosError.invalidInput("The speaker labels cannot be kept on the edited words.")
        }
        let session = self.session
        let transcriptID = snapshot.transcript.id
        let hook = beforeEdit
        let sent = request
        let published = try await publishWordChange(
            what: "The words were edited", transcriptID: transcriptID, runID: runID,
            recover: { (incomplete: SessionWordEdit.IncompletePublication) -> SessionWordEdit.Outcome?? in
                incomplete.outcome.map { .some($0) }
            },
            committed: { [weak self] (published: SessionWordEdit.Outcome??) in
                guard let self, let saved = published ?? nil else { return }
                self.turnKeepingRuns[saved.runID] = runID
                self.ownTranscripts.insert(saved.transcriptID)
                // The span is exactly the selection unless it took in words around it (its move then differs). What
                // was heard holding deleted words (an earlier deletion taken in) is no "often heard as" either.
                let exact = saved.move == saved.labelsMove && !saved.holdsDeleted
                let edit = ReviewWordEdit(heard: saved.heard, meant: saved.meant, deletion: saved.deletion,
                                          before: saved.before, after: saved.after,
                                          typed: TranscriptWordEdit.cleaned(sent.text),
                                          typedHeard: exact ? saved.heard : nil)
                op.wordEditResult = edit
                op.wordEdit = WordEditUndo(previous: transcriptID, edited: saved.transcriptID,
                                           segmentID: sent.segmentID, move: saved.move,
                                           labelsMove: saved.labelsMove)
                self.wordMoves.append(saved.move)
                self.refuseQueuedSplits(in: sent.segmentID)
            }) {
            if let hook { await hook() }
            return try await SessionWordEdit.run(session: session, request: sent,
                                                 expectedTranscriptID: transcriptID, expectedRunID: runID)
        }
        if published.flatMap({ $0 }) == nil {
            Self.log.info("Session \(self.sessionID, privacy: .public): a word edit would leave the words as they are; not saved")
        } else {
            Self.log.info("Session \(self.sessionID, privacy: .public): words edited in review")
        }
    }

    /// Takes back a saved word edit (`SessionWordEdit.restore`) while its transcript is still current. As soon as the
    /// restored words are committed (before the labels are reread), its word
    /// move undone.
    private func undoWordEdit(_ edit: WordEditUndo) async throws {
        guard snapshot.transcript.id == currentStandIn(for: edit.edited) else {
            throw HolosError.invalidInput("The transcript changed after that edit, so it cannot be undone.")
        }
        guard let runID = snapshot.run?.id else {
            throw HolosError.invalidInput("The speaker labels cannot be kept on the words as they were.")
        }
        let session = self.session
        let hook = beforeEdit
        let current = snapshot.transcript.id
        _ = try await publishWordChange(
            what: "The edit was undone", transcriptID: current, runID: runID,
            recover: { $0.restored },
            committed: { [weak self] restored in
                guard let self else { return }
                if let restored {
                    // The copy now stands for the transcript the edit was made on, which an earlier edit's undo
                    // expects.
                    self.restoredCopies[edit.previous] = restored.transcriptID
                    self.turnKeepingRuns[restored.runID] = runID
                    self.ownTranscripts.insert(restored.transcriptID)
                }
                self.wordMoves.append(edit.move.inverse)
                self.refuseQueuedSplits(in: edit.segmentID)
            }) {
            if let hook { await hook() }
            return try await SessionWordEdit.restore(session: session, previousTranscriptID: edit.previous,
                                                     expectedTranscriptID: current, expectedRunID: runID,
                                                     move: edit.labelsMove.inverse)
        }
    }

    /// Each of words `range` of `segment` as shown (`TranscriptWordEdit.shownText`); nil for one that is not there.
    nonisolated static func shownWords(of segment: TranscriptSegment, _ range: Range<Int>) -> [String?] {
        range.map { TranscriptWordEdit.shownText(of: segment, first: $0, end: $0 + 1) }
    }

    /// At close: learns what every word edited in the meeting's transcript, as it is now, teaches (`ReviewLearning`).
    /// Edits undone or reverted are not in it, so they teach nothing. Only what the meeting has not taught yet is
    /// taught, and recorded as the meeting's in the same corrections.json save (`CorrectionList.learnFromReview`); a
    /// write that fails is logged, and the next review's close makes it again.
    private func learnFromEdits() async {
        guard let writer = correctionsWriter, let teach = correctionsToLearn else { return }
        let session = self.session
        // The transcript, and the unfixed revision it was fixed from (what the recognizer wrote around a fixed word).
        let read = await Self.detachedResult { () throws -> (Transcript, Transcript?)? in
            guard let current = try SessionFiles.currentTranscript(session: session) else { return nil }
            let base = current.fixedFrom.flatMap { try? SessionFiles.transcript(id: $0, session: session) }
            return (current, base)
        }
        guard case .success(let loaded?) = read else {
            Self.log.error("Session \(self.sessionID, privacy: .public): the transcript could not be read to learn from its edits")
            return
        }
        let (current, base) = loaded
        // Context only from the edited word's own turn as shown (never another speaker's word, nor hidden echo): the
        // labels on this very transcript say which. Labels shown on another transcript (they could not be reread
        // after an edit) are read again. When that fails, or the labels are still not on this transcript (a speaker
        // head still owed, or the transcript changed under them), nothing is learned now: the edits stay in the
        // transcript, and a later close learns them.
        var labels = snapshot
        if labels.transcript.id != current.id || reloadProblem != nil {
            do {
                labels = try await loadSnapshot()
            } catch {
                Self.log.error("Session \(self.sessionID, privacy: .public): the speaker labels could not be reread to learn from the edits; a later close learns them")
                return
            }
        }
        guard labels.transcript.id == current.id, let turns = labels.projection?.turns else {
            Self.log.error("Session \(self.sessionID, privacy: .public): the speaker labels are not on the current transcript; a later close learns from the edits")
            return
        }
        let edits = ReviewLearning.edits(in: current, turns: turns.map(\.spans), base: base)
        let corrections = ReviewLearning.corrections(edits, teach: teach)
        guard !corrections.isEmpty else { return }
        guard let update = writer() else {
            Self.log.error("Session \(self.sessionID, privacy: .public): the corrections list cannot be written now; the next review's close learns from the edits")
            return
        }
        // One hold of the speaker lock, off the main actor. The labels are read again in it (transcript, head run, and
        // speaker-change journal): what is taught must be what they give (the edits learned from, which make the
        // corrections), so nothing changed since (a replacement, a relabel, a split) is taught from; the next close
        // learns from them as they are then. Then the corrections list is changed under its own lock (taken inside
        // this one: nothing takes them the other way round): the rules and what the meeting taught
        // (`CorrectionList.reviewTaught`) in one atomic save, so no close stopped part way can leave them apart.
        let transcriptID = current.id
        let meeting = sessionID
        let outcome = await Self.detachedResult { () throws -> LearnOutcome in
            try SessionArchive.withSpeakerLock(at: session) {
                let fresh = try SpeakerSessionSnapshot.load(session: session)
                guard try SessionArchive.currentTranscriptID(at: session) == transcriptID,
                      fresh.transcript.id == transcriptID, !fresh.transcriptChanged,
                      let freshTurns = fresh.projection?.turns,
                      ReviewLearning.edits(in: current, turns: freshTurns.map(\.spans), base: base) == edits else {
                    return .changed
                }
                var applied: [Correction] = []
                do {
                    try update { list in applied = list.learnFromReview(corrections, meeting: meeting) }
                } catch {
                    return .notWritten(ProcessSpawner.logCategory(error))
                }
                return .learned(applied: applied.count)
            }
        }
        switch outcome {
        case .success(.learned(let applied)):
            guard applied > 0 else { return }
            Self.log.info("Session \(self.sessionID, privacy: .public): learned \(applied, privacy: .public) of \(corrections.count, privacy: .public) corrections of review edits")
            correctionsWritten?()
        case .success(.changed):
            Self.log.error("Session \(self.sessionID, privacy: .public): the transcript or its speaker labels changed while learning from its edits; a later close learns them")
        case .success(.notWritten(let why)):
            Self.log.error("Session \(self.sessionID, privacy: .public): corrections from review edits not saved (\(why, privacy: .public)); the next review's close tries again")
        case .failure(let error):
            Self.log.error("Session \(self.sessionID, privacy: .public): nothing learned from the edits (\(ProcessSpawner.logCategory(error), privacy: .public)); a later close learns them")
        }
    }

    /// How close-time learning ended (`learnFromEdits`).
    private enum LearnOutcome: Sendable {
        case learned(applied: Int)
        case changed
        case notWritten(String)
    }

    /// `refs` where `moves` took them, and whether one of them was among the words a move replaced (its text may have
    /// changed under it).
    public nonisolated static func follow(_ refs: [WordRef], through moves: ArraySlice<ReviewWordMove>)
        -> (refs: [WordRef], replaced: Bool) {
        var result = refs
        var replaced = false
        for move in moves {
            for index in result.indices {
                let moved = move.map(result[index])
                result[index] = moved.ref
                replaced = replaced || moved.replaced
            }
        }
        return (result, replaced)
    }

    /// The transcript that stands for `transcriptID` now: an undone edit makes a copy of the transcript it was made on
    /// current (`TranscriptWordEdit.restoring`), with the same words under a new ID.
    private func currentStandIn(for transcriptID: String) -> String {
        var id = transcriptID
        var seen: Set<String> = [id]
        while let copy = restoredCopies[id], seen.insert(copy).inserted { id = copy }
        return id
    }

    /// Whether head run `runID` replaced `oldRunID` (directly or through others) keeping its turns: a word edit or its
    /// undo published it from this window. Paragraph breaks made on `oldRunID` stay on such a run.
    public func keepsTurns(of oldRunID: String, in runID: String) -> Bool {
        var id = runID
        var seen: Set<String> = [id]
        while let previous = turnKeepingRuns[id], seen.insert(previous).inserted {
            if previous == oldRunID { return true }
            id = previous
        }
        return false
    }

    /// Runs one publication of the transcript (a word edit or its undo) off the main actor. Once it is committed (the
    /// transcript current), `committed` records it, whatever happens next (with the run it published, in
    /// `turnKeepingRuns`); then the labels reread are adopted as this window's own change when their run is that one
    /// (`adopt`): the turns and edit IDs are the same, so the undo history stays. A head
    /// that could not be published is repaired from the old one, as a word-fix revert's is (`recover` gives what was
    /// committed). Labels that cannot be reread make the review read-only until they are (a reread then still knows the
    /// new run keeps the turns). Any other failure rereads the labels and throws.
    private func publishWordChange<T: Sendable>(
        what: String, transcriptID: String, runID: String,
        recover: @escaping (SessionWordEdit.IncompletePublication) -> T?,
        committed: (T?) -> Void,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        let headHook = beforeHeadPublish
        let writtenHook = afterHeadWritten
        switch await Self.detachedResult({
            try await SpeakerTranscriptRetarget.$beforePublishHead.withValue(headHook) {
                try await SpeakerTranscriptRetarget.$afterHeadWritten.withValue(writtenHook) { try await body() }
            }
        }) {
        case .success(let value):
            committed(value)
            changesSaved(exportsWritten: false)
            do {
                try beforeWordChangeReread?()
                // The labels reread are this change's only when their run is the one it published (`committed` noted
                // it in `turnKeepingRuns`); a relabel made elsewhere since is a change made elsewhere.
                adopt(try await loadSnapshot(), op: nil, matching: nil)
            } catch {
                holdUnreread(matching: nil, problem: "\(what), but the window could not reread the speaker labels: "
                             + error.localizedDescription)
                throw HolosError.incomplete("\(what), but the review could not be refreshed.")
            }
            return value
        case .failure(let error):
            if error is CancellationError { throw error }
            if let incomplete = error as? SessionWordEdit.IncompletePublication {
                // The transcript is current: what it did is kept, whether or not its head can be finished now.
                let value = recover(incomplete)
                committed(value)
                changesSaved(exportsWritten: false)
                // Owed until a reread finds the labels on the current transcript (`adopt`); a reload repairs it.
                owedHead = (transcriptID, runID, false)
                do {
                    try await repairOwedHead()
                    let fresh = try await loadSnapshot()
                    guard fresh.projection != nil, !fresh.transcriptChanged else {
                        throw HolosError.unavailable("The new speaker head is incomplete.")
                    }
                    adopt(fresh, op: nil, matching: nil)
                    return value
                } catch let reread {
                    holdUnreread(matching: nil, problem: "\(what), but its speaker labels could not be saved or "
                                 + "reread (\(reread.localizedDescription)); Reload tries again.")
                }
                throw HolosError.incomplete(incomplete.message)
            }
            do {
                adopt(try await loadSnapshot(), op: nil, matching: nil, external: true)
            } catch {
                Self.log.error("Session \(self.sessionID, privacy: .public): labels not reread after a refused word edit (\(ProcessSpawner.logCategory(error), privacy: .public))")
            }
            throw error
        }
    }

    /// An automatic fix's revert was committed (its transcript is current): changes queued in the window follow its
    /// word move (the fix's words became the recognizer's own), a queued split in the segment is refused, and word
    /// edits' undo entries go (each needs its own transcript current, which it no longer is).
    private func revertCommitted(_ published: SessionWordFixRevert.Outcome) {
        if let transcriptID = published.transcriptID { ownTranscripts.insert(transcriptID) }
        wordMoves.append(published.move)
        refuseQueuedSplits(in: published.move.segmentID)
        undoStack.removeAll { $0.wordEdit != nil }
    }

    /// Publishes the speaker head owed since a word edit, its undo, or a revert (`owedHead`), retargeted from the old
    /// one (`SessionWordEdit.repairCurrentHead`, `SessionWordFixRevert.repairCurrentHead`). Only the run it published
    /// keeps the turns; a head published elsewhere meanwhile is not this window's.
    private func repairOwedHead() async throws {
        guard let owed = owedHead else { return }
        let session = self.session
        let hook = beforeHeadPublish
        let repaired = try await Self.detachedResult {
            try await SpeakerTranscriptRetarget.$beforePublishHead.withValue(hook) {
                owed.revert
                    ? try await SessionWordFixRevert.repairCurrentHead(
                        session: session, expectedTranscriptID: owed.transcriptID, expectedRunID: owed.runID)
                    : try await SessionWordEdit.repairCurrentHead(
                        session: session, expectedTranscriptID: owed.transcriptID, expectedRunID: owed.runID)
            }
        }.get()
        if let repaired { turnKeepingRuns[repaired] = owed.runID }
    }

    /// Queued splits not started yet whose word is in `segmentID`, which a word edit or its undo just changed: their
    /// word index may name another word now, so they are refused.
    private func refuseQueuedSplits(in segmentID: String) {
        let stale = queue.filter { op in
            guard !op.started, case .edit(let actions, _) = op.kind else { return false }
            return actions.contains { action in
                if case .splitTurn(_, let at) = action { return at.segmentID == segmentID }
                return false
            }
        }
        guard !stale.isEmpty else { return }
        queue.removeAll { op in stale.contains { $0 === op } }
        for op in stale {
            op.finish(.failure(HolosError.invalidInput("The words of that turn changed; split it again.")))
        }
    }

    /// Runs a `VoiceProfileService` change (it saves the journal and rewrites the exports itself, and leaves the voice
    /// samples to this window: `deferSamples`), then adopts the labels it returns (loaded with the people store's
    /// names, which are the window's) and rereads the people. Once its lines are saved, the samples are owed a sync
    /// in the background, enrolling the people the change itself linked (`DeferredSamples`) when `learn`.
    private func savePeopleChange(
        _ op: Operation, matching: @escaping ([SpeakerEdit]) -> Bool, learn: Bool,
        _ change: @escaping @Sendable (URL, SpeakerProfileStore, (any VoiceSampleExtractor)?, DeferredSamples)
            async throws -> SpeakerSessionSnapshot
    ) async throws {
        guard let store = profiles else { throw Self.noPeople }
        let session = self.session
        let extractor = self.extractor
        let hook = beforeEdit
        let deferred = DeferredSamples()
        // The voices are asked for now: a forget that lands before they are learned wins (`syncSamples`).
        let epoch = await Self.detachedValue { (try? store.load())?.forgetEpoch ?? 0 }
        let outcome = await Self.detachedResult { () throws -> SpeakerSessionSnapshot in
            if let hook { await hook() }
            return try await change(session, store, extractor, deferred)
        }
        switch outcome {
        case .success(let returned):
            await reloadPeople()
            // A link that changed nothing saved nothing and rewrote no export.
            if adopt(returned, op: op, matching: matching) { changesSaved(exportsWritten: true) }
            // Even then: an earlier run of this link may have saved its lines and not its sample.
            owe(deferred.linkedPeople ?? [], learn: learn, since: epoch, batch: op.batches.last)
        case .failure(let error):
            await reloadPeople()
            do {
                try await handleFailure(error, op: op, matching: matching)
            } catch let thrown {
                // Saved, then something after failed: the labels were reread, and the samples are still owed.
                if Self.isIncomplete(thrown) {
                    owe(deferred.linkedPeople ?? [], learn: learn, since: epoch, batch: op.batches.last)
                }
                throw thrown
            }
        }
    }

    /// A request to learn a person's voice from this meeting that has not run yet: the store's forget epoch when it
    /// was last asked for, and the saved batches (links) that asked (`""` for one whose batch is not known), so undoing
    /// one link takes back only its own request.
    private struct EnrollRequest: Equatable {
        var epoch: Int
        var batches: Set<String>
    }

    /// A saved link owes a sync: learning the voices of the `people` it linked when `learn`, else withdrawing any
    /// request to learn them that has not run yet (the newest link of a person says whether their voice is learned).
    private func owe(_ people: Set<String>, learn: Bool, since epoch: Int, batch: String?) {
        if learn {
            for profileID in people {
                var request = sampleEnroll[profileID] ?? EnrollRequest(epoch: epoch, batches: [])
                // Requests made before a forget that has landed since are not carried by this newer one: undoing
                // this link must not leave them standing under its epoch.
                if request.epoch != epoch { request = EnrollRequest(epoch: epoch, batches: []) }
                request.batches.insert(batch ?? "")
                sampleEnroll[profileID] = request
            }
            oweSamples()
        } else {
            for profileID in people { sampleEnroll[profileID] = nil }
            oweSamples()
        }
    }

    /// A save that threw. `incomplete` means its lines were saved and something after failed (reloading, the
    /// exports, or a voice sample): the labels are reloaded, the lines kept as the window's, and the error is
    /// thrown. Anything else refused the change: the labels are reloaded (queued changes made on the older labels are
    /// then refused too) and the error is thrown, with `changedElsewhere` for a stale view.
    ///
    /// `refreshSamples`: the change was saved by `SpeakerEditor` here, so on `incomplete` this meeting's voice samples
    /// are owed a sync (`needsSampleRefresh` was lost with the error); `savePeopleChange` owes its own.
    private func handleFailure(_ error: any Error, op: Operation?, refreshSamples: Bool = false,
                               matching: @escaping ([SpeakerEdit]) -> Bool) async throws {
        if error is CancellationError { throw error }
        if case .incomplete? = error as? HolosError {
            do {
                adopt(try await loadSnapshot(), op: op, matching: matching)
            } catch let reread {
                // The lines are saved but cannot be shown as saved: the change stays shown and the review is
                // read-only until the labels are reread.
                holdUnreread(matching: matching, problem: "The change was saved, but the window could not reread "
                             + "the speaker labels: \(reread.localizedDescription)")
            }
            changesSaved(exportsWritten: false)
            Self.log.error("Session \(self.sessionID, privacy: .public): a change was saved, then failed (\(ProcessSpawner.logCategory(error), privacy: .public))")
            if refreshSamples { oweSamples() }
            throw error
        }
        Self.log.notice("Session \(self.sessionID, privacy: .public): a change was refused (\(ProcessSpawner.logCategory(error), privacy: .public)); reloading")
        let stale: Bool
        if case .unavailable(let message)? = error as? HolosError, message == SpeakerEditor.changedMessage {
            stale = true
        } else {
            stale = false
        }
        do {
            adopt(try await loadSnapshot(), op: nil, matching: nil, external: true)
        } catch let reread where stale {
            // Known to be out of date and not rereadable: nothing more is saved on these labels.
            holdUnreread(matching: nil, problem: "The speaker labels changed outside this window, and the window "
                         + "could not reread them: \(reread.localizedDescription)")
        } catch {
            // Nothing was saved and nothing says the labels changed: the window keeps showing them.
            Self.log.error("Session \(self.sessionID, privacy: .public): labels not reread after a refusal (\(ProcessSpawner.logCategory(error), privacy: .public))")
        }
        if stale { throw HolosError.unavailable(Self.changedElsewhere) }
        throw error
    }

    /// The labels on disk may differ from the ones shown and could not be reread: the review is read-only
    /// (`reloadProblem`) until labels are read from disk again. `matching`: the running change saved lines that
    /// batch finds; it stays shown (`unreloaded`) until then.
    private func holdUnreread(matching: (([SpeakerEdit]) -> Bool)?, problem: String) {
        if let matching, let running = queue.first, running.started {
            running.savedUnreloaded = true
            running.claims.append(matching)
        }
        reloadProblem = problem + " " + Self.rereadSuffix
        notify()
        Self.log.error("Session \(self.sessionID, privacy: .public): labels could not be reread; review read-only until they are")
    }

    /// Follows `reloadProblem`.
    public nonisolated static let rereadSuffix = "The review is read-only until they are reread."
    private static let notReread = "The speaker labels could not be reread. " + rereadSuffix

    /// Reverts one saved batch of this window: `undoLast` when it is the newest batch, else reverts of its lines in
    /// effect (refused when that would change other edits).
    private func undoBatch(_ batch: String, op: Operation) async throws {
        await reloadPeople()
        let view = savedProjection
        let lines = snapshot.journal.edits
            .filter { $0.baseRunID == view.runID && ($0.batchID ?? $0.id) == batch }.map(\.id)
        let applied = Set(view.appliedEditIDs).intersection(lines)
        guard !applied.isEmpty else {
            Self.log.notice("Session \(self.sessionID, privacy: .public): the change to undo is no longer in effect")
            return
        }
        let session = self.session
        let store = profiles
        let names = profileNames
        let hook = beforeEdit
        let ordered = lines.filter(applied.contains)
        let newest = view.lastUndoableBatchID == batch
        // A link taken back takes back its own request to learn the voice, if that has not run yet: a later link of
        // the same person with learning off must not learn it on the strength of this one. Other links' requests
        // for the same person stay.
        let unlinked = snapshot.journal.edits.filter { ordered.contains($0.id) }.compactMap { edit -> String? in
            if case .linkProfile(_, let profileID) = edit.action { return profileID }
            return nil
        }
        let outcome = await Self.detachedResult { () throws -> SpeakerEditResult in
            if let hook { await hook() }
            if newest {
                return try SpeakerEditor.undoLast(view: view, session: session, source: Self.source,
                                                  regenerateExports: false, profiles: store)
            }
            return try SpeakerEditor.apply(ordered.map { .revert(editID: $0) }, view: view, session: session,
                                           source: Self.source, regenerateExports: false, profileNames: names,
                                           profiles: store)
        }
        let matching: ([SpeakerEdit]) -> Bool = { lines in
            let targets = Set(lines.compactMap { line -> String? in
                if case .revert(let editID) = line.action { return editID }
                return nil
            })
            return targets.count == lines.count && applied.isSubset(of: targets)
        }
        switch outcome {
        case .success(let result):
            // `undoLast` loads its result without people's names; the window's labels need them.
            let fresh = newest ? ((try? await loadSnapshot()) ?? result.snapshot) : result.snapshot
            if adopt(fresh, op: nil, matching: matching) { changesSaved(exportsWritten: false) }
            withdraw(batch, people: unlinked)
            if result.needsSampleRefresh { oweSamples() }
        case .failure(let error):
            // `incomplete`: the reverts are saved.
            if Self.isIncomplete(error) { withdraw(batch, people: unlinked) }
            try await handleFailure(error, op: nil, refreshSamples: true, matching: matching)
        }
    }

    // MARK: - Voice samples (background)

    /// The requests to learn `people`'s voices that the link saved as `batch` made are taken back (it was undone).
    private func withdraw(_ batch: String, people: [String]) {
        for profileID in people {
            sampleEnroll[profileID]?.batches.remove(batch)
            if sampleEnroll[profileID]?.batches.isEmpty == true { sampleEnroll[profileID] = nil }
        }
    }

    /// A saved change may have moved speech a voice sample of this meeting holds, or linked a person whose voice is
    /// to be learned (`enroll`): the samples are brought in step (`VoiceProfileService.syncSamples`) `sampleDelay`
    /// after the queue is idle, off the edit queue. A newer change cancels a sync that is waiting or running, and the
    /// sync runs again after it; `close` runs any sync still owed. Without people nothing is owed. Whose voices are
    /// learned is kept in `sampleEnroll` (`owe`).
    private func oweSamples() {
        guard profiles != nil else { return }
        samplesOwed = true
        sampleRequests += 1
        scheduleSampleSync()
    }

    /// Starts the delay before an owed sync, when the queue is idle, no sync runs, and no command holds the review.
    private func scheduleSampleSync() {
        sampleTimer?.cancel()
        sampleTimer = nil
        guard samplesOwed, !closed, !backgroundStopped, pauses.isEmpty, queue.isEmpty, sampleRun == nil else { return }
        let delay = sampleDelay
        sampleTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.sampleTimer = nil
            self.startSampleSync()
        }
    }

    /// A change is about to be saved: a sync waiting or running is stopped (it runs again once the queue is idle).
    private func holdSampleSync() {
        sampleTimer?.cancel()
        sampleTimer = nil
        sampleRun?.cancel()
    }

    private func startSampleSync() {
        guard samplesOwed, sampleRun == nil, !backgroundStopped, let store = profiles else { return }
        let enroll = sampleEnroll
        let request = sampleRequests
        let session = self.session
        let extractor = self.extractor
        isSyncingSamples = true
        syncLearning = !enroll.isEmpty
        notify()
        sampleRun = Task { [weak self] in
            let result = await Self.cancellableResult {
                try await VoiceProfileService.syncSamples(session: session, extractor: extractor, store: store,
                                                          enroll: Set(enroll.keys),
                                                          enrollEpochs: enroll.mapValues(\.epoch))
            }
            self?.sampleSyncEnded(result, enroll: enroll, request: request)
        }
    }

    private func sampleSyncEnded(_ result: Result<Void, any Error>, enroll: [String: EnrollRequest], request: Int) {
        sampleRun = nil
        isSyncingSamples = false
        syncLearning = false
        /// What this sync was asked to learn is done with, unless asked for again meanwhile.
        func settle() {
            for (profileID, sent) in enroll where sampleEnroll[profileID] == sent {
                sampleEnroll[profileID] = nil
            }
            if sampleRequests == request { samplesOwed = false }
        }
        switch result {
        case .success:
            voiceProblem = nil
            settle()
            if !samplesOwed { pendingVoices?.clear(sessionID) }
        case .failure(let error) where error is CancellationError:
            // Still owed: it runs again after the change that stopped it.
            Self.log.info("Session \(self.sessionID, privacy: .public): voice sample sync stopped for a newer change")
        case .failure(let error):
            settle()
            voiceProblem = (enroll.isEmpty ? "A voice sample learned from this meeting could not be updated: "
                : "The name was saved, but the voice could not be learned: ") + error.localizedDescription
            Self.log.error("Session \(self.sessionID, privacy: .public): voice samples not brought in step (\(ProcessSpawner.logCategory(error), privacy: .public))")
            if closed, !Self.isForgetWin(error) {
                // Nobody sees the footer of a window that is closing: the next review of the meeting says so and
                // runs it again. A forget that landed meanwhile wins for good, so that is not run again.
                pendingVoices?.mark(sessionID, PendingVoiceSamples.Entry(enroll: enroll.mapValues(\.epoch),
                                                                         problem: error.localizedDescription))
                Self.log.error("Session \(self.sessionID, privacy: .public): voice sample sync failed while the review closed; recorded for the next review")
            } else {
                // The footer says why; confirming the person again asks again.
                pendingVoices?.clear(sessionID)
            }
        }
        scheduleSampleSync()
        notify()
    }

    /// Runs the sync still owed now, after one already running, and waits for both (`close`, `pause`).
    private func flushSamples() async {
        sampleTimer?.cancel()
        sampleTimer = nil
        if let running = sampleRun { await running.value }
        guard samplesOwed, sampleRun == nil else { return }
        startSampleSync()
        if let running = sampleRun { await running.value }
    }

    /// The batch a request carried over from an earlier review is kept under: no link of this window made it, so
    /// undoing one does not withdraw it (linking the person again with the footer box off still does).
    static let earlierReviewBatch = "earlier-review"

    /// A sync an earlier review of this meeting could not finish (`PendingVoiceSamples`) is owed again, with the
    /// requests it held under the forget epochs they were made at, and the footer says why until it runs. Stays
    /// recorded until a sync ends with this window open (the footer then shows how it went) or a later close records
    /// it again.
    private func resumePendingSamples() {
        guard profiles != nil, let entry = pendingVoices?.entry(sessionID) else { return }
        for (profileID, epoch) in entry.enroll {
            sampleEnroll[profileID] = EnrollRequest(epoch: epoch, batches: [Self.earlierReviewBatch])
        }
        let what = entry.enroll.isEmpty ? "the voice samples learned from this meeting could not be updated"
            : "a voice could not be learned"
        let why = entry.problem.map { " " + $0 } ?? ""
        voiceProblem = "When this meeting's review last closed, \(what); trying again.\(why)"
        Self.log.notice("Session \(self.sessionID, privacy: .public): running a voice sample sync an earlier review could not finish")
        oweSamples()
    }

    /// The sync failed because voices were forgotten after they were asked for: the forget is the later request.
    private static func isForgetWin(_ error: any Error) -> Bool {
        if case HolosError.unavailable(let message) = error {
            return message == VoiceProfileService.forgottenWhileLearning
        }
        return false
    }

    // MARK: - Voices within the meeting

    /// One pass of the extractor per track split into speakers, over every turn `analysable` lets through, into
    /// `voiceCache`; then `voiceMatches` is worked out. Replaces whatever the cache held. Nothing when voices are not
    /// analysed, there is no extractor, the audio was deleted, or a command holds the review.
    private func startVoiceAnalysis() {
        dropVoices()
        guard analyseVoices, !closed, !backgroundStopped, pauses.isEmpty, !isRelabelling, let base = baseExtractor,
              let run = snapshot.run,
              let projection = snapshot.projection, !snapshot.audioDeleted else { return }
        var parts: [(track: String, turns: [TurnRef])] = []
        let asked = Self.voicePassTurns(projection, run: run)
        for track in Set(asked.map(\.track)).sorted() {
            parts.append((track, asked.filter { $0.track == track }.map(TurnRef.init)))
        }
        guard !parts.isEmpty else { return }
        let epoch = voiceCache.begin(session: session, runID: projection.runID)
        voiceEpoch = epoch
        voiceRunID = projection.runID
        voiceAnalysis = .running(done: 0, total: parts.count)
        Self.log.info("Session \(self.sessionID, privacy: .public): working out the voices of \(parts.reduce(0) { $0 + $1.turns.count }, privacy: .public) turns on \(parts.count, privacy: .public) tracks")
        let session = self.session
        let cache = voiceCache
        voiceTask = Task { [weak self] in
            var failure: (any Error)?
            for (index, part) in parts.enumerated() {
                do {
                    let found = try await Self.cancellable {
                        try await base.turnEmbeddings(session: session, track: part.track, turns: part.turns)
                    }
                    cache.store(found, asked: part.turns, track: part.track, epoch: epoch)
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        cache.finish(epoch: epoch)
                        return
                    }
                    failure = error
                }
                guard let owner = self, owner.voiceEpoch == epoch else {
                    cache.finish(epoch: epoch)
                    return
                }
                owner.voiceAnalysis = .running(done: index + 1, total: parts.count)
                owner.notify()
            }
            cache.finish(epoch: epoch)
            self?.voiceAnalysisEnded(epoch: epoch, failure: failure)
        }
        notify()
    }

    private func voiceAnalysisEnded(epoch: Int, failure: (any Error)?) {
        guard epoch == voiceEpoch, let runID = voiceRunID else { return }
        voiceTask = nil
        voiceMatchKey = nil
        if let failure {
            // All or nothing: matching on the tracks that worked would leave out every match on the one that failed
            // (and merge on half the picture) with nothing said. What the other passes stored stays in the cache for
            // voice learning, which asks about turns it covers only.
            voiceEmbeddings = [:]
            voiceAnalysis = .failed(failure.localizedDescription)
            Self.log.error("Session \(self.sessionID, privacy: .public): voices not worked out (\(ProcessSpawner.logCategory(failure), privacy: .public))")
        } else {
            voiceEmbeddings = voiceCache.embeddings(runID: runID, turns: projection.turns.map(TurnRef.init))
            voiceAnalysis = .ready
            Self.log.info("Session \(self.sessionID, privacy: .public): voices worked out for \(self.voiceEmbeddings.count, privacy: .public) of \(self.voiceCache.coveredTurns, privacy: .public) turns")
        }
        refreshVoiceMatches()
        considerAutoMerge()
        notify()
    }

    /// Stops a running pass; what it stored stays (a sample sync waiting for it goes on with that, or its own pass).
    private func stopVoicePass() {
        guard let task = voiceTask else { return }
        task.cancel()
        voiceTask = nil
        voiceCache.finish(epoch: voiceEpoch)
        voiceEpoch = 0
        if case .running = voiceAnalysis { voiceAnalysis = .off }
    }

    /// Forgets the meeting's voices (memory only; nothing was written).
    private func dropVoices() {
        stopVoicePass()
        voiceCache.clear()
        voiceEmbeddings = [:]
        voiceMatchKey = nil
        voiceRunID = nil
        voiceMatches = .empty
        voiceAnalysis = .off
    }

    /// After labels were read: voices of another run, or of a meeting whose audio is gone, are dropped, and worked
    /// out again when they can be.
    private func updateVoiceAnalysis() {
        guard analyseVoices else { return }
        if snapshot.audioDeleted {
            if voiceRunID != nil || voiceAnalysis != .off { dropVoices() }
            return
        }
        // Closing: what the pass stored serves the last sample sync (`close` drops it afterwards); no new pass.
        guard !closed, voiceRunID != snapshot.run?.id || voiceAnalysis == .off else { return }
        startVoiceAnalysis()
    }

    /// The turns a voice pass asks about: those worth a voice (`analysable`) on a microphone or system track split into
    /// speakers.
    nonisolated static func voicePassTurns(_ projection: SpeakerProjection, run: DiarizationRun) -> [ProjectedTurn] {
        let diarized = Set(run.tracks.filter { $0.policy == .diarized }.map(\.track))
        return projection.turns.filter { turn in
            (turn.track == "mic" || turn.track == "system") && diarized.contains(turn.track) && analysable(turn)
        }
    }

    /// Whether a turn is worth a voice: long enough to learn from, and not cut by a split (its times are its own).
    nonisolated static func analysable(_ turn: ProjectedTurn) -> Bool {
        !turn.modified && turn.start.isFinite && turn.end.isFinite
            && turn.end - turn.start >= VoiceEnrollment.minimumTurnSeconds - 1e-9
    }

    /// `voiceMatches` on the shown labels (people needed: a match is confirmed by linking the person, so only people
    /// the store still holds are matched). Nothing while the edit journal has a line this build cannot read: the
    /// labels may miss a rejection or a reassignment the matches would contradict, as recognition's are not used then.
    private func refreshVoiceMatches() {
        guard profiles != nil, !voiceEmbeddings.isEmpty, voiceRunID == projection.runID,
              snapshot.journal.isComplete else {
            if voiceMatches != .empty { voiceMatches = .empty }
            voiceMatchKey = nil
            return
        }
        // Worked out again only when something it reads changed: the projection is rebuilt on every queue step,
        // and on a 3-hour meeting the comparison is thousands of 256-value vectors.
        let people = Set(profileNames.keys)
        let thresholds = voiceThresholds
        let key = VoiceMatchKey(
            runID: projection.runID, people: people, thresholds: thresholds, embeddings: voiceEmbeddings.count,
            turns: projection.turns.map {
                VoiceMatchKey.Turn(id: $0.id, speakerID: $0.speakerID,
                                   usable: MeetingVoiceMatcher.usable($0), track: $0.track)
            },
            speakers: projection.speakers.map {
                VoiceMatchKey.Speaker(id: $0.id, name: $0.name, profileID: $0.profileID,
                                      candidate: MeetingVoiceMatcher.isCandidate($0),
                                      rejected: $0.rejectedProfileIDs)
            })
        guard key != voiceMatchKey else { return }
        voiceMatchKey = key
        voiceMatches = MeetingVoiceMatcher.match(projection: projection, embeddings: voiceEmbeddings,
                                                 thresholds: thresholds, people: people)
    }

    /// Everything `MeetingVoiceMatcher.match` reads, for `refreshVoiceMatches` to skip a match that would come out
    /// the same.
    private struct VoiceMatchKey: Equatable {
        struct Turn: Equatable {
            let id: String
            let speakerID: String?
            let usable: Bool
            let track: String
        }

        struct Speaker: Equatable {
            let id: String
            let name: String
            let profileID: String?
            let candidate: Bool
            let rejected: [String]
        }

        let runID: String
        let people: Set<String>
        let thresholds: MeetingVoiceThresholds
        let embeddings: Int
        let turns: [Turn]
        let speakers: [Speaker]
    }

    /// `MeetingVoiceThresholds` from the people store's calibration when it was measured on this run's model.
    var voiceThresholds: MeetingVoiceThresholds {
        guard let calibration, let model = snapshot.run?.engine?.embeddingModel, calibration.model == model else {
            return .defaults
        }
        return .derived(from: calibration.thresholds, calibrated: true)
    }

    /// After a name was given (`mergeArmed`), with `autoMergeVoices` on and the queue idle: merges every speaker whose
    /// voice suggestion is `mergeable` into the named speaker it matched, as one change (one undo).
    private func considerAutoMerge() {
        guard mergeArmed else { return }
        guard autoMergeVoices else {
            mergeArmed = false
            return
        }
        guard case .ready = voiceAnalysis, queue.isEmpty, isEditable else { return }
        mergeArmed = false
        guard !autoMergeActions().isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            // Worked out again as the merge is queued, on the labels as they are then: a speaker named or rejected
            // meanwhile is no longer a candidate, and a change still queued makes it wait for the queue again.
            guard self.queue.isEmpty else {
                self.mergeArmed = true
                return
            }
            let actions = self.autoMergeActions()
            guard !actions.isEmpty else { return }
            Self.log.info("Session \(self.sessionID, privacy: .public): merging speakers with a matching voice (\(actions.count, privacy: .public) actions)")
            do {
                // Refused when the journal has a line this build cannot read: the matches may contradict it.
                try await self.apply(actions, requireCompleteJournal: true)
            } catch {
                self.voiceProblem = "Speakers with the same voice could not be merged: " + error.localizedDescription
                self.notify()
            }
        }
    }

    /// The automatic merges, as one batch: each mergeable suggestion's speaker merged into the named speaker it
    /// matched, its turns first kept out of voice learning (`excludeFromEnrollment`), since nobody confirmed them and
    /// a voice sample never comes from an automatic match (§4.10).
    private func autoMergeActions() -> [SpeakerEditAction] {
        var actions: [SpeakerEditAction] = []
        let focused = speakerBeingNamed?()
        for suggestion in voiceMatches.suggestions where suggestion.mergeable && suggestion.speakerID != focused {
            let turns = projection.turns
                .filter { $0.speakerID == suggestion.speakerID && !$0.excludedFromEnrollment }.map(\.id)
            if !turns.isEmpty { actions.append(.excludeFromEnrollment(turnIDs: turns)) }
            actions.append(.merge(from: suggestion.speakerID, into: suggestion.anchorSpeakerID))
        }
        return actions
    }

    /// Replaces the saved labels with `fresh` (read from disk, so `reloadProblem` ends). The window's own batch (the
    /// newest new batch `matching` accepts) is recorded on `op`, with the saved IDs of turns its splits made, and so
    /// are the batches of changes saved but not reread (`unreloaded`), which get their undo entries here; any other
    /// new line, or a new head run, is a change made elsewhere. Returns whether the window's batch was found.
    ///
    /// A head run this window's word edit (or its undo) published from the run shown (`turnKeepingRuns`) keeps every
    /// turn, turn ID, and edit ID of the old one: the undo history, the split IDs, and the voices worked out stay, and
    /// it is not a change made elsewhere.
    @discardableResult
    private func adopt(_ fresh: SpeakerSessionSnapshot, op: Operation?, matching: (([SpeakerEdit]) -> Bool)?,
                       external forced: Bool = false) -> Bool {
        // A speaker head still owed (`owedHead`): labels not on the current transcript are not taken, and the review
        // stays held (a relabel that could not repair it first left them so); labels on it end the debt.
        if owedHead != nil {
            guard fresh.projection != nil, !fresh.transcriptChanged else {
                Self.log.error("Session \(self.sessionID, privacy: .public): labels reread while a speaker head is owed are not on the current transcript; review stays read-only")
                return false
            }
            owedHead = nil
        }
        let known = Set(snapshot.journal.edits.map(\.id))
        let added = fresh.journal.edits.filter { !known.contains($0.id) }
        var groups: [[SpeakerEdit]] = []
        var keys: [String] = []
        for edit in added {
            let key = edit.batchID ?? edit.id
            if let index = keys.firstIndex(of: key) {
                groups[index].append(edit)
            } else {
                keys.append(key)
                groups.append([edit])
            }
        }
        // The window writes with source "app"; `VoiceProfileService` names its own ("app" inside VoiceIsLocal.app).
        let sources: Set<String> = [Self.source, VoiceProfileService.editSource]
        var claimed = Set<Int>()
        /// The newest unclaimed group `matching` accepts, claimed.
        func claim(_ matching: ([SpeakerEdit]) -> Bool) -> [SpeakerEdit]? {
            guard let index = groups.indices.last(where: { index in
                !claimed.contains(index) && groups[index].allSatisfy { sources.contains($0.source) }
                    && matching(groups[index])
            }) else { return nil }
            claimed.insert(index)
            return groups[index]
        }
        let rereadOps = unreloaded
        unreloaded.removeAll()
        for pending in rereadOps {
            pending.savedUnreloaded = false
            for matching in pending.claims {
                guard let batch = claim(matching), let first = batch.first else { continue }
                pending.batches.append(first.batchID ?? first.id)
                recordSplits(of: pending, lines: batch)
            }
            pending.claims.removeAll()
        }
        var ours: [SpeakerEdit] = []
        if let matching, let batch = claim(matching) {
            ours = batch
            if let op, let first = batch.first {
                op.batches.append(first.batchID ?? first.id)
                recordSplits(of: op, lines: batch)
            }
        }
        let windowLines = claimed.reduce(0) { $0 + groups[$1].count }
        if let running = queue.first, running.started { running.superseded = true }
        let previousRunID = snapshot.run?.id
        // Also a reread after one of this window's word edits whose labels could not be reread at once.
        let keptFrom = fresh.run.flatMap { turnKeepingRuns[$0.id] }
        let retargeted = keptFrom != nil && keptFrom == previousRunID
        let headChanged = fresh.run?.id != previousRunID && !retargeted
        // A head made elsewhere: the change running (whose own head it replaced) gets no undo entry once it ends,
        // as the entries before it go below.
        if headChanged, let running = queue.first, running.started { running.overtaken = true }
        let external = forced || headChanged || added.count > windowLines
        let transcriptChanged = fresh.transcript.id != snapshot.transcript.id
        var voicesMoved = false
        if retargeted, let previousRunID, let newRunID = fresh.run?.id, voiceRunID == previousRunID {
            // The same turns: the voices worked out for those still at the same times hold; the others are dropped.
            let turns = (fresh.projection?.turns ?? []).map(TurnRef.init)
            let before = Dictionary((snapshot.projection?.turns ?? []).map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
            // A turn worth a voice whose times moved (an untimed segment spreads its words again): a pass running
            // would store it at its old times, which are never served, so a new pass works the voices out again.
            voicesMoved = (fresh.projection?.turns ?? []).contains { turn in
                Self.analysable(turn) && before[turn.id].map {
                    abs($0.start - turn.start) > 1e-6 || abs($0.end - turn.end) > 1e-6
                } ?? true
            }
            if voiceCache.moveRun(from: previousRunID, to: newRunID, turns: turns) {
                voiceRunID = newRunID
                voiceMatchKey = nil
                if !voiceEmbeddings.isEmpty {
                    voiceEmbeddings = voiceCache.embeddings(runID: newRunID, turns: turns)
                }
            }
        }
        snapshot = fresh
        // Labels read again: the word checks are read again, off the main actor (the unfixed revision may be back, or
        // gone, or another).
        checks.removeAll()
        readWordChecks()
        if let projection = fresh.projection { savedProjection = projection }
        savedVersion += 1
        reloadProblem = nil
        if !headChanged {
            for pending in rereadOps where pending.isUndoable && !pending.undone && !pending.batches.isEmpty {
                pushUndo(pending.batches)
            }
        }
        if transcriptChanged {
            segments = Self.segmentIndex(fresh.transcript)
            // Read after every word change saved so far: their moves are in it.
            movesRead = wordMoves.count
            // Words this window did not change: nothing chosen before can be followed onto them (`wordsEpoch`).
            if !ownTranscripts.contains(fresh.transcript.id) { wordsEpoch += 1 }
            textCache.removeAll()
            wordCache.removeAll()
        }
        if headChanged {
            undoStack.removeAll()
            editIDMap.removeAll()
            textCache.removeAll()
            wordCache.removeAll()
        }
        // The current transcript is no longer the one the labels are on (another process replaced it): a word edit's
        // undo, which needs its own transcript current, can never be made, so it goes; undo reaches the speaker
        // changes before it.
        if fresh.transcriptChanged { undoStack.removeAll { $0.wordEdit != nil } }
        noteMovedAside(Self.editedExports(session: session))
        if external {
            externalVersion = savedVersion
            refuseStaleQueuedChanges()
            Self.log.info("Session \(self.sessionID, privacy: .public): labels changed elsewhere (\(added.count - windowLines, privacy: .public) other lines, head changed: \(headChanged, privacy: .public))")
        }
        updateVoiceAnalysis()
        // Turns whose times a word edit moved: the voices are worked out again on the new run (a pass running is
        // replaced, its results at the old times dropped).
        if voicesMoved, voiceRunID == fresh.run?.id, !closed { startVoiceAnalysis() }
        recomputeProjection()
        notify()
        return !ours.isEmpty
    }

    /// Queued changes not started yet and made on labels older than the last change from elsewhere: refused.
    private func refuseStaleQueuedChanges() {
        let stale = queue.filter { !$0.started && $0.isUndoable && $0.basis < externalVersion }
        guard !stale.isEmpty else { return }
        queue.removeAll { op in stale.contains { $0 === op } }
        for op in stale { op.finish(.failure(staleRefusal(op))) }
    }

    /// A queued change refused because the labels changed elsewhere; a word edit's says what was typed, never lost
    /// silently.
    private func staleRefusal(_ op: Operation) -> HolosError {
        guard case .editWords(let request, _) = op.kind else { return .unavailable(Self.changedElsewhere) }
        return .unavailable(Self.changedElsewhere + TranscriptWordEdit.typedNote(request.text))
    }

    /// Records the saved IDs of the turns a change's splits created (its lines are its actions, in order).
    private func recordSplits(of op: Operation, lines: [SpeakerEdit]) {
        guard case .edit = op.kind, lines.count == op.optimistic.count else { return }
        for (index, action) in op.optimistic.enumerated() {
            guard case .splitTurn = action, case .splitTurn = lines[index].action else { continue }
            editIDMap[op.optimisticIDs[index]] = lines[index].id
        }
    }

    private func requireBasis(_ op: Operation) throws {
        guard op.basis >= externalVersion else { throw staleRefusal(op) }
    }

    // MARK: - Relabel

    private func relabel(_ arguments: [String]) async throws {
        // A voice pass is another full diarization of the audio, and of labels about to be replaced: it stops, and the
        // relabel waits for its child to exit (`runRelabel`). A new pass starts on the new labels afterwards.
        if case .running = voiceAnalysis {
            stoppedPass = voiceTask
            dropVoices()
        }
        try await enqueue(.relabel(arguments), optimistic: [])
    }

    private func runRelabel(_ arguments: [String]) async throws {
        guard let maintenance else { throw HolosError.unavailable("Speakers cannot be labelled from here.") }
        if let stopped = stoppedPass {
            await stopped.value
            stoppedPass = nil
        }
        onRelabelChange?(true)
        defer { onRelabelChange?(false) }
        let folder = FileManager.default.temporaryDirectory
        let output = folder.appendingPathComponent("holos-command-\(UUID().uuidString).out", isDirectory: false)
        let errors = folder.appendingPathComponent("holos-command-\(UUID().uuidString).err", isDirectory: false)
        defer {
            ProcessSpawner.removeRegularFile(output)
            ProcessSpawner.removeRegularFile(errors)
        }
        Self.log.notice("Session \(self.sessionID, privacy: .public): relabelling from the review window")
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            do {
                try maintenance.run(arguments, standardOutput: output, standardError: errors) { code in
                    continuation.resume(returning: code)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let message = Self.commandMessage(output: output, errors: errors)
        Self.log.notice("Session \(self.sessionID, privacy: .public): relabel ended with \(code, privacy: .public)")
        do {
            adopt(try await loadSnapshot(), op: nil, matching: nil, external: true)
        } catch {
            // The command may have labelled the meeting again: nothing more is saved on the labels shown.
            holdUnreread(matching: nil, problem: "The window could not reread the speaker labels after labelling "
                         + "them again: \(error.localizedDescription)")
        }
        // 0 and 3 rewrote the exports from the labels now saved; any other code wrote none, so a change of this
        // window still waiting for its exports keeps waiting (they follow `exportDelay` later, or at `close`).
        if code == 0 || code == 3 {
            exportsPending = false
            exportProblem = nil
            exportTimer?.cancel()
            exportTimer = nil
        } else if exportsPending {
            scheduleExports()
        }
        switch code {
        case 0: return
        case 3: throw HolosError.incomplete(message ?? "The speakers were not labelled again.")
        default: throw HolosError.unavailable(message ?? "Voice is Local could not label the speakers again (code \(code)).")
        }
    }

    /// `message` or `summary` of the command's JSON output, else its last stderr line.
    private nonisolated static func commandMessage(output: URL, errors: URL) -> String? {
        if let data = try? AtomicFile.readIfPresent(output, maxBytes: 4 << 20),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["message", "summary"] {
                if let text = object[key] as? String, !text.isEmpty { return text }
            }
        }
        return ProcessSpawner.lastLine(of: errors)
    }

    // MARK: - Exports

    /// A change was saved. `exportsWritten`: its writer rewrote the exports from the saved labels (a
    /// `VoiceProfileService` change); otherwise (`regenerateExports: false`) they follow `exportDelay` later.
    private func changesSaved(exportsWritten: Bool) {
        lastSavedAt = Date()
        if exportsWritten {
            exportsPending = false
            exportProblem = nil
            exportTimer?.cancel()
            exportTimer = nil
        } else {
            scheduleExports()
        }
    }

    private func scheduleExports() {
        exportsPending = true
        exportTimer?.cancel()
        exportTimer = nil
        // Paused: `resume` schedules them once the command ended.
        guard !closed, pauses.isEmpty else { return }
        let delay = exportDelay
        exportTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.exportTimer = nil
            _ = try? await self.enqueue(.exports, optimistic: [])
        }
    }

    private func regenerateExports() async throws {
        guard exportsPending else { return }
        activity = "Updating the transcript files…"
        notify()
        let session = self.session
        let names = profileNames
        let store = profiles
        do {
            let result = try await Self.detached {
                try SessionExports.regenerate(session: session, profileNames: names,
                                              applyRecognition: Self.recognitionAllowed(store))
            }
            exportsPending = false
            exportProblem = nil
            noteMovedAside(Set(result.movedAside.map(\.lastPathComponent)))
        } catch {
            exportProblem = "The transcript files could not be updated: \(error.localizedDescription)"
            Self.log.error("Session \(self.sessionID, privacy: .public): exports not rewritten (\(ProcessSpawner.logCategory(error), privacy: .public))")
            throw error
        }
    }

    private func noteMovedAside(_ names: Set<String>) {
        let new = names.subtracting(knownEditedExports).sorted()
        guard !new.isEmpty else { return }
        knownEditedExports.formUnion(new)
        movedAsideExports += new
    }

    // MARK: - Projection

    /// The saved labels with every queued change shown.
    private func recomputeProjection() {
        var display = savedProjection
        var owners: [String: ObjectIdentifier] = [:]
        for op in unreloaded + queue {
            let owner = ObjectIdentifier(op)
            for (action, id) in displayActions(op) {
                let next = display.applying(action, editID: id)
                // A change saved but not reread may be partly shown already (a first batch that was reread): what
                // the saved labels already show is not applied twice.
                if op.savedUnreloaded, next.staleEdits.contains(where: { $0.editID == id }) { continue }
                display = next
                owners[id] = owner
            }
        }
        projection = display
        optimisticOwner = owners
        refreshVoicesForProjection()
        refreshVoiceMatches()
    }

    /// The labels shown changed (an undo puts back a turn a split had cut, say): the voices are those of the turns as
    /// they are now (`MeetingVoiceCache.embeddings` checks their times); a turn worth a voice that no pass covered at
    /// these times sends a new pass, as a turn a word edit moved does.
    private func refreshVoicesForProjection() {
        guard voiceAnalysis == .ready, let runID = voiceRunID, runID == projection.runID, !closed,
              let run = snapshot.run, let saved = snapshot.projection else { return }
        // The saved labels' turns a pass asks about (never a change still waiting to save, which no pass can cover).
        if Self.voicePassTurns(saved, run: run).contains(where: { !voiceCache.covers(runID: runID, turn: TurnRef($0)) }) {
            startVoiceAnalysis()
            return
        }
        let current = voiceCache.embeddings(runID: runID, turns: projection.turns.map(TurnRef.init))
        guard Set(current.keys) != Set(voiceEmbeddings.keys) else { return }
        voiceEmbeddings = current
        voiceMatchKey = nil
    }

    /// What a queued change shows: its actions (with turn IDs of saved splits resolved), nothing once undone, and for
    /// an undo the reverts of the batches it takes back.
    private func displayActions(_ op: Operation) -> [(SpeakerEditAction, String)] {
        // A change saved but not reread is shown until labels read from disk show it, even after an earlier batch
        // of it was reread.
        guard !op.superseded || op.savedUnreloaded else { return [] }
        switch op.kind {
        case .undo(.saved(let entry)):
            return reverts(of: entry.batches).map { ($0, UUID().uuidString) }
        case .undo(.operation(let earlier)):
            // Until the earlier change is saved its effect is simply not shown (it is `undone`).
            guard earlier.finished || earlier.superseded else { return [] }
            return reverts(of: earlier.batches).map { ($0, UUID().uuidString) }
        case .revertWordFix, .editWords, .relabel, .reload, .exports:
            return []
        case .edit, .link, .assignPerson, .confirmAll, .markSelf:
            guard !op.undone else { return [] }
            return zip(op.optimistic.map(resolve), op.optimisticIDs).map { ($0, $1) }
        }
    }

    /// Reverts of the saved lines in effect of `batches`, newest batch first.
    private func reverts(of batches: [String]) -> [SpeakerEditAction] {
        let applied = Set(savedProjection.appliedEditIDs)
        return batches.reversed().flatMap { batch in
            snapshot.journal.edits
                .filter { ($0.batchID ?? $0.id) == batch && applied.contains($0.id) }
                .map { SpeakerEditAction.revert(editID: $0.id) }
        }
    }

    // MARK: - Helpers

    private var sessionID: String { snapshot.manifest.id }

    /// The one track the run split into speakers, when exactly one was.
    private var diarizedTrack: TrackDiarization? {
        let diarized = snapshot.run?.tracks.filter { $0.policy == .diarized } ?? []
        return diarized.count == 1 ? diarized.first : nil
    }

    /// Keeps a call's choice about the people in the room when relabelling: the microphone was split into speakers
    /// (true) or taken as you (false). Nil for an in-person meeting or when the run does not say.
    private var othersInRoomFlag: Bool? {
        guard snapshot.meeting.mode == .call,
              let microphone = snapshot.run?.tracks.first(where: { $0.track == "mic" }) else { return nil }
        if microphone.policy == .diarized { return true }
        if Self.isChannel(microphone.policy) { return false }
        return nil
    }

    private nonisolated static func isChannel(_ policy: TrackPolicy) -> Bool {
        if case .channel = policy { return true }
        return false
    }

    /// The speaker's turns matching `condition`, longest first (ties by time).
    private func longest(of speakerID: String, where condition: (ProjectedTurn) -> Bool) -> [ProjectedTurn] {
        projection.turns.enumerated()
            .filter { $0.element.speakerID == speakerID && condition($0.element) }
            .sorted { left, right in
                let a = left.element.end - left.element.start
                let b = right.element.end - right.element.start
                return a != b ? a > b : left.offset < right.offset
            }
            .map(\.element)
    }

    private func resolve(_ action: SpeakerEditAction) -> SpeakerEditAction {
        switch action {
        case .reassignTurns(let turnIDs, let to):
            .reassignTurns(turnIDs: turnIDs.map(resolvedTurnID), to: to)
        case .splitTurn(let turnID, let at):
            .splitTurn(turnID: resolvedTurnID(turnID), at: at)
        case .newSpeaker(let speakerID, let name, let turnIDs):
            .newSpeaker(speakerID: speakerID, name: name, turnIDs: turnIDs.map(resolvedTurnID))
        case .excludeFromEnrollment(let turnIDs):
            .excludeFromEnrollment(turnIDs: turnIDs.map(resolvedTurnID))
        case .rename, .linkProfile, .rejectProfile, .merge, .revert:
            action
        }
    }

    /// Names as `SpeakerEditor` saves them, so the shown projection matches the saved one.
    private nonisolated static func cleaned(_ action: SpeakerEditAction) -> SpeakerEditAction {
        switch action {
        case .rename(let speakerID, let name):
            .rename(speakerID: speakerID, name: SpeakerEditor.cleanName(name))
        case .newSpeaker(let speakerID, let name, let turnIDs):
            .newSpeaker(speakerID: speakerID, name: SpeakerEditor.cleanName(name), turnIDs: turnIDs)
        case .linkProfile, .rejectProfile, .merge, .reassignTurns, .splitTurn, .excludeFromEnrollment, .revert:
            action
        }
    }

    /// Throws what the editor would refuse on the shown labels, before anything is queued.
    private func validate(_ actions: [SpeakerEditAction]) throws {
        var state = projection
        for action in actions {
            if case .revert = action {
                throw HolosError.invalidInput("Use Undo to take back a change.")
            }
            let id = UUID().uuidString
            let next = state.applying(action, editID: id)
            if let stale = next.staleEdits.first(where: { $0.editID == id }) {
                throw SpeakerEditor.refusal(action, reason: stale.reason, on: state)
            }
            state = next
        }
    }

    /// `whileUnread`: the change may also be queued while the labels could not be reread (`reloadProblem`): it then
    /// waits, still queued, for the reread, as changes queued before it do.
    private func requireEditable(whileUnread: Bool = false) throws {
        guard !closed else { throw Self.closedError }
        guard snapshot.projection != nil else {
            throw HolosError.unavailable(snapshot.runProblem ?? "This meeting's speaker labels cannot be used.")
        }
        if let reloadProblem, !whileUnread { throw HolosError.unavailable(reloadProblem) }
        guard !isRelabelling else {
            throw HolosError.unavailable("Voice is Local is labelling this meeting's speakers again; wait until it finishes.")
        }
        if let reason = pauseReason {
            throw HolosError.unavailable(reason + " " + Self.pausedSuffix)
        }
    }

    /// Follows `pauseReason` wherever the review says it is read-only.
    public nonisolated static let pausedSuffix = "The review is read-only until it finishes."

    private func requirePeople() throws {
        guard profiles != nil else { throw Self.noPeople }
    }

    /// Idle: nil. Otherwise what the first queued task is doing (a running one may say more, such as updating a
    /// voice sample).
    private func updateActivity() {
        guard let first = queue.first else {
            activity = nil
            return
        }
        if !first.started { activity = activityText(first) }
    }

    private func activityText(_ op: Operation) -> String? {
        switch op.kind {
        case .relabel: "Labelling speakers again…"
        case .exports: exportsPending ? "Updating the transcript files…" : nil
        case .reload: nil
        // Voices are learned afterwards, in the background (`voiceStatus`).
        case .link, .assignPerson, .markSelf, .confirmAll, .edit, .undo, .revertWordFix, .editWords: "Saving…"
        }
    }

    /// What the window is doing with voices right now, nil when nothing: learning or updating samples, or working out
    /// the meeting's voices.
    public var voiceStatus: String? {
        // A refresh that finds the samples in step takes no time; only learning is worth a word.
        if isSyncingSamples, syncLearning, rememberVoices { return "Learning voices…" }
        if case .running(let done, let total) = voiceAnalysis {
            return total > 1 ? "Comparing voices (\(done + 1) of \(total))…" : "Comparing voices…"
        }
        return nil
    }

    private func notify() { onChange?() }

    /// Rereads the people, then the labels built with their names, in one step off the main actor (every reload of
    /// the labels goes through here). The window's people are replaced with them, so the labels adopted next and the
    /// names the window offers agree; when reading fails, neither changes.
    private func loadSnapshot() async throws -> SpeakerSessionSnapshot {
        let session = self.session
        let store = profiles
        let loaded = try await Self.detached { try Self.load(session: session, profiles: store) }
        if store != nil {
            people = loaded.people
            profileNames = loaded.profileNames
            rememberVoices = loaded.rememberVoices
            calibration = loaded.calibration
        }
        return loaded.snapshot
    }

    private func reloadPeople() async {
        guard let store = profiles else { return }
        let loaded = await Self.detachedValue { Self.people(store: store) }
        people = loaded.people
        profileNames = loaded.names
        rememberVoices = loaded.remember
        calibration = loaded.calibration
    }

    private static let closedError = HolosError.unavailable("The review window is closed.")
    private static let noPeople = HolosError.unavailable("People are not available here.")

    private static func noSpeaker(_ speakerID: String) -> HolosError {
        HolosError.invalidInput("There is no speaker \(speakerID) in this meeting's labels any more.")
    }

    private nonisolated static func newSpeakerID() -> String { "user:" + UUID().uuidString }

    /// Seconds before a sample clip starts in a long turn, and a clip's length.
    private static let clipLead = 0.25
    private static let clipSeconds = 4.0
    private static let previewCharacters = 60

    private nonisolated static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// linkProfile + rename of `speakerID` (a link, "This is me"), with the merges of same-named speakers the editor
    /// may add around them (`SpeakerEditor.saved(_:asAsked:)`).
    private nonisolated static func linkBatch(_ speakerID: String) -> ([SpeakerEdit]) -> Bool {
        { saved in
            let batch = withoutMerges(saved)
            guard batch.count == 2,
                  case .linkProfile(let linked, _) = batch[0].action, linked == speakerID,
                  case .rename(let renamed, _) = batch[1].action, renamed == speakerID else { return false }
            return true
        }
    }

    /// linkProfile + rename pairs (Confirm All), with the merges of same-named speakers the editor may add.
    private nonisolated static func confirmBatch(_ saved: [SpeakerEdit]) -> Bool {
        let batch = withoutMerges(saved)
        guard !batch.isEmpty, batch.count % 2 == 0 else { return false }
        return stride(from: 0, to: batch.count, by: 2).allSatisfy { index in
            guard case .linkProfile(let linked, _) = batch[index].action,
                  case .rename(let renamed, _) = batch[index + 1].action else { return false }
            return linked == renamed
        }
    }

    /// A saved link batch without the editor's joins of same-named speakers around it (`SpeakerEditor.withoutJoins`):
    /// merges before it, merges and the kept person's link after it.
    private nonisolated static func withoutMerges(_ batch: [SpeakerEdit]) -> [SpeakerEdit] {
        SpeakerEditor.withoutJoins(batch, action: \.action)
    }

    // MARK: - Loading (off the main actor)

    private struct Loaded: Sendable {
        var snapshot: SpeakerSessionSnapshot
        var people: [SpeakerProfile]
        var profileNames: [String: String]
        var rememberVoices: Bool
        var calibration: (thresholds: RecognitionThresholds, model: EmbeddingModelID)?
        var editedExports: Set<String>
    }

    /// What one read of the people store gives the window.
    struct KnownPeople: Sendable {
        var people: [SpeakerProfile] = []
        var names: [String: String] = [:]
        var remember = false
        /// Calibrated recognition thresholds and the model they were measured on, when calibrated.
        var calibration: (thresholds: RecognitionThresholds, model: EmbeddingModelID)?
    }

    private nonisolated static func load(session: URL, profiles: SpeakerProfileStore?) throws -> Loaded {
        let known = profiles.map { people(store: $0) } ?? KnownPeople()
        let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: known.names,
                                                       applyRecognition: recognitionAllowed(profiles))
        return Loaded(snapshot: snapshot, people: known.people, profileNames: known.names,
                      rememberVoices: known.remember, calibration: known.calibration,
                      editedExports: editedExports(session: session))
    }

    /// Whether the meeting's stored recognition result may be shown and exported, decided as every other reader of
    /// the labels decides it (`VoiceProfileService.recognitionAllowed`: Remember voices on and no forget still owed);
    /// without a people store (tests), as `SpeakerEditor` does, it is.
    nonisolated static func recognitionAllowed(_ profiles: SpeakerProfileStore?) -> Bool {
        profiles.map { VoiceProfileService.recognitionAllowed(store: $0) } ?? true
    }

    private nonisolated static func people(store: SpeakerProfileStore) -> KnownPeople {
        people(loading: store.load)
    }

    /// The people offered, their names, Remember voices, and the calibration, all from one read of the store, so a
    /// rewrite of `profiles.json` in between cannot mix two versions. Nothing (and Remember voices off) when it cannot
    /// be read.
    nonisolated static func people(loading load: () throws -> SpeakerProfileDatabase) -> KnownPeople {
        do {
            let database = try load()
            let calibration = database.calibratedModel.flatMap { model in
                database.calibratedThresholds(for: model).map { (thresholds: $0, model: model) }
            }
            return KnownPeople(people: VoiceProfileService.knownPeople(in: database),
                               names: VoiceProfileService.profileNames(in: database),
                               remember: database.rememberVoices, calibration: calibration)
        } catch {
            log.error("Cannot read people: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return KnownPeople()
        }
    }

    /// Names of the hand-edited exports moved aside so far (`exports/edited-*`).
    private nonisolated static func editedExports(session: URL) -> Set<String> {
        let folder = SessionPaths.exports(session)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return Set(names.filter { $0.hasPrefix("edited-") })
    }

    private nonisolated static func segmentIndex(_ transcript: Transcript) -> [String: TranscriptSegment] {
        var index: [String: TranscriptSegment] = [:]
        for segment in transcript.segments where index[segment.id] == nil { index[segment.id] = segment }
        return index
    }

    /// The exports' text of `spans`, reading only the segments they name.
    private nonisolated static func text(of spans: [WordSpan], segments: [String: TranscriptSegment],
                                         transcript: Transcript) -> String {
        var seen = Set<String>()
        let named = spans.compactMap { span -> TranscriptSegment? in
            guard seen.insert(span.segmentID).inserted else { return nil }
            return segments[span.segmentID]
        }
        let part = Transcript(id: transcript.id, createdAt: transcript.createdAt, source: transcript.source,
                              locale: transcript.locale, backend: transcript.backend, segments: named)
        return TranscriptExporter.text(of: spans, in: part)
    }

    private nonisolated static func detached<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: body).value
    }

    /// `body` off the main actor, cancelled when the calling task is (a detached task does not inherit it).
    private nonisolated static func cancellable<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func cancellableResult<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        do {
            return .success(try await cancellable(body))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func detachedValue<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: body).value
    }

    private nonisolated static func detachedResult<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        await Task.detached(priority: .userInitiated) { () -> Result<T, any Error> in
            do {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }.value
    }
}
