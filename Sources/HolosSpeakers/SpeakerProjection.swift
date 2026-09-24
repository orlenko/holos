import Foundation
import HolosCore

// MARK: - Projected values

/// A speaker as the UI and every export show it: the run's speaker with the edit journal and recognition applied
/// (docs/meeting-design.md §4.9).
public struct ProjectedSpeaker: Sendable, Equatable, Identifiable {
    public let id: String
    /// N in "Speaker N": the run's ordinal, or max + 1 for a speaker created by `newSpeaker`. Edits never renumber.
    public let ordinal: Int
    /// Plain name: explicit name, else linked profile name, else automatic (likely) profile name,
    /// else "Me" for the channel speaker, else "Speaker N".
    public let name: String
    /// What the UI and every export show: `name`, plus " (auto)" when `isAutomatic` ("Jim (auto)").
    public let label: String
    /// Set by `rename` or `newSpeaker`; trimmed and never empty.
    public let explicitName: String?
    /// Linked by an edit (a confirmed label).
    public let profileID: String?
    public let provenance: LabelProvenance
    /// A `likely` match applied automatically and not confirmed.
    public let isAutomatic: Bool
    /// A `possible` match, not applied; the UI shows "Maybe Maria — Confirm". Never exported.
    /// `profileName` is the profile's current name.
    public let suggestion: SpeakerMatch?
    /// "Not Jim" edits, in the order they were made.
    public let rejectedProfileIDs: [String]
    public let clusterIDs: [String]
    /// Sum of the speaker's turn durations.
    public let talkSeconds: Double
    public let turnCount: Int

    public init(id: String, ordinal: Int, name: String, label: String, explicitName: String?, profileID: String?,
                provenance: LabelProvenance, isAutomatic: Bool, suggestion: SpeakerMatch?,
                rejectedProfileIDs: [String], clusterIDs: [String], talkSeconds: Double, turnCount: Int) {
        self.id = id; self.ordinal = ordinal; self.name = name; self.label = label
        self.explicitName = explicitName; self.profileID = profileID; self.provenance = provenance
        self.isAutomatic = isAutomatic; self.suggestion = suggestion; self.rejectedProfileIDs = rejectedProfileIDs
        self.clusterIDs = clusterIDs; self.talkSeconds = talkSeconds; self.turnCount = turnCount
    }
}

/// A turn after the edit journal is applied. Text and timing stay in the transcript; spans reference words.
public struct ProjectedTurn: Sendable, Equatable, Identifiable {
    /// The run's "T<n>", or "<parent>/<editID>" for the second part of a split.
    public let id: String
    public let track: String
    public let start: Double
    public let end: Double
    public let speakerID: String?          // nil = unknown speaker
    /// The diarizer cluster that won the words (never changed by edits); nil for channel or unknown turns.
    public let clusterID: String?
    public let spans: [WordSpan]
    public let overlap: Bool
    public let otherClusters: [String]
    public let assignmentScore: Double
    public let timing: WordTimingQuality
    /// The speaker differs from the machine's and the turn's cluster is not one of the speaker's clusters
    /// (a merge adds clusters, so merged turns are not reassigned). Channel turns: speaker differs.
    public let reassigned: Bool
    /// Produced or trimmed by `splitTurn`, including the part that keeps the parent ID.
    public let modified: Bool
    public let excludedFromEnrollment: Bool
    /// assignmentScore < 0.6, overlap, or unknown speaker.
    public let uncertain: Bool

    public init(id: String, track: String, start: Double, end: Double, speakerID: String?, clusterID: String?,
                spans: [WordSpan], overlap: Bool, otherClusters: [String], assignmentScore: Double,
                timing: WordTimingQuality, reassigned: Bool, modified: Bool, excludedFromEnrollment: Bool,
                uncertain: Bool) {
        self.id = id; self.track = track; self.start = start; self.end = end; self.speakerID = speakerID
        self.clusterID = clusterID; self.spans = spans; self.overlap = overlap; self.otherClusters = otherClusters
        self.assignmentScore = assignmentScore; self.timing = timing; self.reassigned = reassigned
        self.modified = modified; self.excludedFromEnrollment = excludedFromEnrollment; self.uncertain = uncertain
    }
}

/// A journal line of this run that was not applied, with a short reason for logs and the UI.
public struct StaleEdit: Sendable, Equatable {
    public let editID: String
    /// "changed since the edit was made", "speaker not found", "turn not found", "cannot revert an undo", …
    public let reason: String

    public init(editID: String, reason: String) { self.editID = editID; self.reason = reason }
}

// MARK: - Projection

/// The run with its edit journal applied: the one view of speakers and turns that exports (PR7b), the CLI (PR8),
/// the review window (PR9), and enrollment (PR10) use (docs/meeting-design.md §4.9). A pure value; build it with
/// `make` and extend it with `applying`.
///
/// Every journal line of this run ends up in exactly one of: `appliedEditIDs` (in effect), `revertedEditIDs`
/// (undone by a later revert), `staleEdits` (refused), or an effective revert, which is listed nowhere and shows
/// only through the edit it undid. Lists are in journal order.
public struct SpeakerProjection: Sendable, Equatable {
    public let runID: String
    /// The transcript the run's spans reference (`run.transcriptID`).
    public let transcriptID: String
    public let speakers: [ProjectedSpeaker]      // ordinal order
    public let turns: [ProjectedTurn]            // (start, track, id) order
    public let appliedEditIDs: [String]
    public let revertedEditIDs: [String]
    public let staleEdits: [StaleEdit]
    /// Edits whose baseRunID is another run; counted, not applied.
    public let otherRunEditCount: Int
    /// Journal lines with baseRunID == runID when this projection was built.
    public let editCount: Int
    /// batchID of the newest applied batch that is not an undo, for undo. An edit without a batchID is a batch of
    /// its own, named by its edit ID (edits added with `applying` have none).
    public let lastUndoableBatchID: String?
    /// Groups of two or more listed speakers that are, or may be, one person: speakers linked (or automatically
    /// matched) to the same profile, plus recognition's suggestions for speakers that still exist and have neither
    /// rejected that profile nor been linked to another. Speaker IDs in list order; groups by first speaker.
    public let mergeSuggestions: [MergeSuggestion]

    /// The inputs, the journal, and the state before names are derived, so `applying`, `fingerprint`, and
    /// `SpeakerCarryOver` need nothing else.
    let context: Context
    let journal: [JournalEntry]
    let outcomes: [Outcome]
    let state: State

    /// Builds the projection (§4.9 application order):
    /// 1. Start from `run.speakers` and `run.turns`. A turn whose speaker is missing from `run.speakers` gets a
    ///    diarizer speaker with the next ordinal, so every turn's speaker is listed.
    /// 2. Apply `recognition` only if `recognition.runID == run.id`, ignoring matches for profiles not in
    ///    `profileNames` (forgotten people; blank names count as missing): `likely` matches become an automatic
    ///    profile link, `possible` matches become `suggestion`. Neither applies to a speaker that has an explicit
    ///    name or a link, or that rejected the profile.
    /// 3. Collect reverts in file order: a revert undoes an earlier edit of this run unless that edit is itself a
    ///    revert ("cannot revert an undo"), is already undone ("already reverted"), or does not precede it
    ///    ("edit not found"); such a revert is stale. There is no redo.
    /// 4. Apply every other edit of this run in file order: a referenced speaker or turn that does not exist makes
    ///    it stale ("speaker not found" / "turn not found"); so does `expected != nil` differing from
    ///    `fingerprint(for:)` on the state so far ("changed since the edit was made"), or an action that cannot
    ///    apply (a split at the turn's first word, a merge into itself, a `newSpeaker` ID that exists or does not
    ///    start with "user:", …). Stale edits change nothing.
    /// 5. Derive names and provenance: explicit name → `userRenamed`; linked profile → `userConfirmed`; automatic
    ///    likely match not rejected → `recognized`; channel → `channelAssumption`; else `diarizer`.
    ///
    /// Listed speakers: every speaker with at least one turn, plus speakers created by `newSpeaker`.
    /// `recognition` matches whose profileID is not in `profileNames` (forgotten people) are ignored.
    public static func make(run: DiarizationRun, transcript: Transcript, edits: [SpeakerEdit],
                            recognition: RecognitionResult?, profileNames: [String: String]) -> SpeakerProjection {
        let context = Context(run: run, transcript: transcript, recognition: recognition, profileNames: profileNames)
        var journal: [JournalEntry] = []
        var otherRunEditCount = 0
        for edit in edits {
            if edit.baseRunID == run.id {
                journal.append(JournalEntry(edit))
            } else {
                otherRunEditCount += 1
            }
        }
        return replay(context: context, journal: journal, otherRunEditCount: otherRunEditCount)
    }

    /// The fingerprint an edit with this action carries, computed on `self`. Journal-derived state only (never
    /// recognition), so a suggestion appearing or disappearing never makes an edit stale:
    ///
    /// | Action | Fingerprint |
    /// |---|---|
    /// | `rename(s, _)` | `fp1:rename:speaker=` S(s, `name=`O(explicit name)) |
    /// | `linkProfile(s, p)` | `fp1:linkProfile:profile=`L(p)`;speaker=` S(s, `link=`O(linked profile)`;rejected=<1 if p is rejected, else 0>`) |
    /// | `rejectProfile(s, p)` | `fp1:rejectProfile:` and the rest as `linkProfile` |
    /// | `reassignTurns(ids, to)` | `fp1:reassignTurns:to=<none for unknown, else S(to)>;turns=` N(T(id) for each id) |
    /// | `merge(from, into)` | `fp1:merge:from=` S(from, M) `;into=` S(into, M), where M = `name=`O(explicit name)`;link=`O(linked profile)`;rejected=`N(L(p) per rejection, in order)`;clusters=`N(L(c) per cluster, in order)`;turns=`N(sorted `L(turn ID):words=W;excluded=<0/1>` of its turns) |
    /// | `splitTurn(t, _)` | `fp1:splitTurn:turn=` T(t) |
    /// | `newSpeaker(s, _, ids)` | `fp1:newSpeaker:speaker=` S(s) `;turns=` N(T(id) for each id) |
    /// | `excludeFromEnrollment(ids)` | `fp1:excludeFromEnrollment:turns=` N(T(id)`;excluded=<0/1>` for each id) |
    /// | `revert(editID)` | `nil` (revert staleness is decided when reverts are collected) |
    ///
    /// - L(x) = `<Unicode scalar count of x>:<x>`; every string (names and IDs) is written this way.
    /// - O(x) = `none` when x is nil, else L(x).
    /// - N(items) = `<count>[<items joined by ,>]`.
    /// - S(id, fields) = L(id)`=absent`, or L(id)`=present;ordinal=<n>` then `;fields` when there are any. The
    ///   ordinal tells a speaker from one created later with the same ID after a merge removed the first.
    /// - T(id) = L(id)`=absent`, or L(id)`=present;speaker=`O(speaker, none = unknown)`;words=`W.
    /// - W = N(L(segment ID)`@<first>..<end>` per span, `end` exclusive).
    ///
    /// Every piece is self-delimiting, so each action's encoding is injective over the state it covers, and every
    /// referenced speaker or turn records whether it exists: deleting a speaker never looks like an unnamed one.
    /// Each fingerprint covers all state its action overwrites or discards: a merge deletes `from` (name, link,
    /// rejections, clusters) and moves its turns, so both speakers are described in full. A fingerprint longer than
    /// 256 Unicode scalars is replaced by `fp1:sha256:<64 hex digits of the SHA-256 of its UTF-8 bytes>`, which
    /// never equals a raw fingerprint (no action is named `sha256`).
    ///
    /// `reassignTurns` includes each turn's words (the §4.9 table lists only the speaker), so a reassign made on a
    /// view that has not seen another window split one of its turns is refused rather than moving only the part
    /// that kept the turn's ID.
    public func fingerprint(for action: SpeakerEditAction) -> String? {
        state.fingerprint(for: action)
    }

    /// `self` with one more applied edit, for editor batches and optimistic UI updates. The edit carries
    /// `fingerprint(for: action)` as its expected value and no batchID, so the result equals `make` over the
    /// journal with that line appended. An action that is not valid on `self` (a missing speaker or turn, …) is
    /// recorded in `staleEdits` and changes nothing.
    public func applying(_ action: SpeakerEditAction, editID: String) -> SpeakerProjection {
        let entry = JournalEntry(id: editID, action: action, expected: fingerprint(for: action), batchID: nil)
        // A revert changes which earlier lines apply, and a repeated edit ID may already be reverted: replay those.
        var needsReplay = journal.contains { $0.id == editID }
        if case .revert = action { needsReplay = true }
        if needsReplay {
            return Self.replay(context: context, journal: journal + [entry], otherRunEditCount: otherRunEditCount)
        }
        var next = state
        let outcome = next.process(entry, transcript: context.transcript)
        return SpeakerProjection(context: context, journal: journal + [entry], outcomes: outcomes + [outcome],
                                 state: next, otherRunEditCount: otherRunEditCount)
    }

    /// Applied edits that `SpeakerCarryOver` cannot carry: turn-level edits (reassign, split, new speaker, exclude)
    /// and merges. A merge changes which turns a speaker owns, and the new run's speakers need not line up with the
    /// merged clusters, so it is counted rather than silently lost.
    var appliedTurnEditCount: Int {
        zip(journal, outcomes).filter { entry, outcome in
            guard outcome == .applied else { return false }
            switch entry.action {
            case .reassignTurns, .splitTurn, .newSpeaker, .excludeFromEnrollment, .merge: return true
            case .rename, .linkProfile, .rejectProfile, .revert: return false
            }
        }.count
    }

    private init(context: Context, journal: [JournalEntry], outcomes: [Outcome], state: State, otherRunEditCount: Int) {
        self.context = context
        self.journal = journal
        self.outcomes = outcomes
        self.state = state
        runID = context.run.id
        transcriptID = context.run.transcriptID
        self.otherRunEditCount = otherRunEditCount
        editCount = journal.count

        var applied: [String] = []
        var reverted: [String] = []
        var stale: [StaleEdit] = []
        var lastBatch: String?
        for (entry, outcome) in zip(journal, outcomes) {
            switch outcome {
            case .applied:
                applied.append(entry.id)
                lastBatch = entry.batchID ?? entry.id
            case .reverted:
                reverted.append(entry.id)
            case .revert:
                break
            case .stale(let reason):
                stale.append(StaleEdit(editID: entry.id, reason: reason))
            }
        }
        appliedEditIDs = applied
        revertedEditIDs = reverted
        staleEdits = stale
        lastUndoableBatchID = lastBatch

        let projected = state.project(context: context)
        speakers = projected.speakers
        turns = projected.turns
        mergeSuggestions = projected.mergeSuggestions
    }

    /// Steps 3 and 4 of `make` over this run's journal.
    static func replay(context: Context, journal: [JournalEntry], otherRunEditCount: Int) -> SpeakerProjection {
        // Step 3: decide every revert before anything is applied. A revert may only undo an earlier line.
        var revertOutcomes: [Int: Outcome] = [:]
        var positions: [String: Int] = [:]
        var reverted = Set<String>()
        for (index, entry) in journal.enumerated() {
            if case .revert(let target) = entry.action {
                if let position = positions[target] {
                    if case .revert = journal[position].action {
                        revertOutcomes[index] = .stale(StaleReason.revertOfRevert)
                    } else if reverted.contains(target) {
                        revertOutcomes[index] = .stale(StaleReason.alreadyReverted)
                    } else {
                        reverted.insert(target)
                        revertOutcomes[index] = .revert
                    }
                } else {
                    revertOutcomes[index] = .stale(StaleReason.editNotFound)
                }
            }
            if positions[entry.id] == nil { positions[entry.id] = index }
        }

        // Step 4: every other line in file order.
        var state = State(run: context.run)
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(journal.count)
        for (index, entry) in journal.enumerated() {
            if let outcome = revertOutcomes[index] {
                outcomes.append(outcome)
            } else if reverted.contains(entry.id) {
                outcomes.append(.reverted)
            } else {
                outcomes.append(state.process(entry, transcript: context.transcript))
            }
        }
        return SpeakerProjection(context: context, journal: journal, outcomes: outcomes, state: state,
                                 otherRunEditCount: otherRunEditCount)
    }

    /// Trimmed; nil when nil, empty, or only whitespace.
    static func cleanName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Starts every fingerprint, raw or hashed.
    static let fingerprintVersion = "fp1:"

    /// `raw`, or `fp1:sha256:<64 hex digits of its SHA-256>` (of the UTF-8 bytes) when it is longer than 256
    /// Unicode scalars. Scalars rather than characters, because grapheme breaking can change between Unicode versions
    /// and fingerprints persist. Raw fingerprints start with `fp1:<action name>:`, and no action is named `sha256`,
    /// so a hashed value never equals a raw one.
    static func compactFingerprint(_ raw: String) -> String {
        guard raw.unicodeScalars.count > 256 else { return raw }
        return fingerprintVersion + "sha256:" + FingerprintSHA256.hexDigest(Array(raw.utf8))
    }
}

// MARK: - Printing

/// The projection keeps the whole transcript for `applying`. Printing, `dump`, and test-failure output show only the
/// public fields (IDs, times, names), never transcript text (docs/meeting-design.md §1.5, §1.9).
extension SpeakerProjection: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SpeakerProjection(runID: \(runID), transcriptID: \(transcriptID), speakers: \(speakers.count), "
            + "turns: \(turns.count), applied: \(appliedEditIDs.count), reverted: \(revertedEditIDs.count), "
            + "stale: \(staleEdits.count), otherRun: \(otherRunEditCount))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "runID": runID,
            "transcriptID": transcriptID,
            "speakers": speakers,
            "turns": turns,
            "appliedEditIDs": appliedEditIDs,
            "revertedEditIDs": revertedEditIDs,
            "staleEdits": staleEdits,
            "otherRunEditCount": otherRunEditCount,
            "editCount": editCount,
            "lastUndoableBatchID": lastUndoableBatchID as Any,
            "mergeSuggestions": mergeSuggestions,
        ], displayStyle: .struct)
    }
}

// MARK: - Stale reasons

enum StaleReason {
    static let changed = "changed since the edit was made"
    static let speakerNotFound = "speaker not found"
    static let turnNotFound = "turn not found"
    static let revertOfRevert = "cannot revert an undo"
    static let alreadyReverted = "already reverted"
    static let editNotFound = "edit not found"
    static let mergeIntoItself = "cannot merge a speaker into itself"
    static let wordNotInTurn = "word not in turn"
    static let splitAtFirstWord = "cannot split at the first word of a turn"
    static let wordsNotInTranscript = "turn words not in the transcript"
    static let turnExists = "turn already exists"
    static let speakerExists = "speaker already exists"
    static let notUserSpeaker = "new speaker IDs start with user:"
}

// MARK: - Internal state

extension SpeakerProjection {
    /// What the projection was built from, after the recognition and profile-name filters of step 2.
    struct Context: Sendable, Equatable {
        let run: DiarizationRun
        let transcript: Transcript
        /// Profile ID → current name, for names that are not blank.
        let profileNames: [String: String]
        /// Matches of known profiles by machine speaker, in file order, with current profile names. Empty when the
        /// recognition belongs to another run.
        let matches: [String: [SpeakerMatch]]
        /// Recognition's merge suggestions for known profiles.
        let mergeSuggestions: [MergeSuggestion]

        init(run: DiarizationRun, transcript: Transcript, recognition: RecognitionResult?,
             profileNames: [String: String]) {
            self.run = run
            self.transcript = transcript
            let known = profileNames.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            self.profileNames = known
            var matches: [String: [SpeakerMatch]] = [:]
            var suggestions: [MergeSuggestion] = []
            if let recognition, recognition.runID == run.id {
                for match in recognition.matches {
                    guard let name = known[match.profileID] else { continue }
                    var current = match
                    current.profileName = name
                    matches[match.speakerID, default: []].append(current)
                }
                suggestions = recognition.mergeSuggestions.filter { known[$0.profileID] != nil }
            }
            self.matches = matches
            self.mergeSuggestions = suggestions
        }
    }

    /// One journal line of this run, without the fields the projection does not use (`at`, `source`).
    struct JournalEntry: Sendable, Equatable {
        let id: String
        let action: SpeakerEditAction
        let expected: String?
        let batchID: String?

        init(id: String, action: SpeakerEditAction, expected: String?, batchID: String?) {
            self.id = id; self.action = action; self.expected = expected; self.batchID = batchID
        }

        init(_ edit: SpeakerEdit) {
            self.init(id: edit.id, action: edit.action, expected: edit.expected, batchID: edit.batchID)
        }
    }

    enum Outcome: Sendable, Equatable {
        /// In effect.
        case applied
        /// Undone by a later revert.
        case reverted
        /// An effective revert.
        case revert
        case stale(String)
    }

    struct SpeakerState: Sendable, Equatable {
        let id: String
        let ordinal: Int
        var clusterIDs: [String]
        /// The run marks it `.channelAssumption`.
        let isChannel: Bool
        /// The run's display name of a channel speaker ("Me").
        let channelName: String?
        /// Created by `newSpeaker`; listed even without turns.
        let isUserCreated: Bool
        var explicitName: String?
        var profileID: String?
        var rejectedProfileIDs: [String]
    }

    struct TurnState: Sendable, Equatable {
        var id: String
        let track: String
        var start: Double
        var end: Double
        var speakerID: String?
        /// The run's speaker for the words (for a split part, its parent's).
        let machineSpeakerID: String?
        let clusterID: String?
        var spans: [WordSpan]
        let overlap: Bool
        let otherClusters: [String]
        let assignmentScore: Double
        var timing: WordTimingQuality
        var modified: Bool
        var excluded: Bool
    }

    /// Speakers and turns with the journal applied so far; names are derived only by `project`.
    struct State: Sendable, Equatable {
        var speakers: [String: SpeakerState]
        /// Run order; split parts are appended.
        var turns: [TurnState]
        /// Turn ID → index in `turns` (the first turn with that ID).
        var turnIndex: [String: Int]
        /// The largest ordinal any speaker has had, so a new speaker never reuses a merged speaker's number.
        var maxOrdinal: Int

        init(run: DiarizationRun) {
            var speakers: [String: SpeakerState] = [:]
            var maxOrdinal = 0
            for speaker in run.speakers where speakers[speaker.id] == nil {
                let isChannel = speaker.provenance == .channelAssumption
                speakers[speaker.id] = SpeakerState(
                    id: speaker.id, ordinal: speaker.ordinal, clusterIDs: speaker.clusterIDs, isChannel: isChannel,
                    channelName: isChannel ? SpeakerProjection.cleanName(speaker.displayName) : nil,
                    isUserCreated: false, explicitName: nil, profileID: nil, rejectedProfileIDs: [])
                maxOrdinal = max(maxOrdinal, speaker.ordinal)
            }
            var turns: [TurnState] = []
            turns.reserveCapacity(run.turns.count)
            var turnIndex: [String: Int] = [:]
            // A run whose turns name a speaker it does not list (never built by SpeakerRunBuilder): the speaker is
            // added as a diarizer speaker with the next ordinal and its turns' clusters, so every turn stays visible.
            var unlisted = Set<String>()
            for turn in run.turns {
                if let speakerID = turn.speakerID {
                    if speakers[speakerID] == nil {
                        maxOrdinal = Self.ordinal(after: maxOrdinal)
                        unlisted.insert(speakerID)
                        speakers[speakerID] = SpeakerState(
                            id: speakerID, ordinal: maxOrdinal, clusterIDs: [], isChannel: false, channelName: nil,
                            isUserCreated: false, explicitName: nil, profileID: nil, rejectedProfileIDs: [])
                    }
                    if unlisted.contains(speakerID), let clusterID = turn.clusterID,
                       speakers[speakerID]?.clusterIDs.contains(clusterID) == false {
                        speakers[speakerID]?.clusterIDs.append(clusterID)
                    }
                }
                if turnIndex[turn.id] == nil { turnIndex[turn.id] = turns.count }
                turns.append(TurnState(
                    id: turn.id, track: turn.track, start: turn.start, end: turn.end, speakerID: turn.speakerID,
                    machineSpeakerID: turn.speakerID, clusterID: turn.clusterID, spans: turn.spans,
                    overlap: turn.overlap, otherClusters: turn.otherClusters, assignmentScore: turn.assignmentScore,
                    timing: turn.timing, modified: false, excluded: false))
            }
            self.speakers = speakers
            self.turns = turns
            self.turnIndex = turnIndex
            self.maxOrdinal = maxOrdinal
        }

        // MARK: Applying one line

        /// Step 4 for one non-revert line: existence, then fingerprint, then the action's own rules.
        mutating func process(_ entry: JournalEntry, transcript: Transcript) -> Outcome {
            // Reverts are decided in step 3 and never reach here; refuse one defensively rather than apply it.
            if case .revert = entry.action { return .stale(StaleReason.editNotFound) }
            if let reason = missingTarget(of: entry.action) { return .stale(reason) }
            if let expected = entry.expected, expected != fingerprint(for: entry.action) {
                return .stale(StaleReason.changed)
            }
            if let reason = apply(entry.action, editID: entry.id, transcript: transcript) { return .stale(reason) }
            return .applied
        }

        func missingTarget(of action: SpeakerEditAction) -> String? {
            switch action {
            case .rename(let speakerID, _), .linkProfile(let speakerID, _), .rejectProfile(let speakerID, _):
                return speakers[speakerID] == nil ? StaleReason.speakerNotFound : nil
            case .merge(let from, let into):
                return speakers[from] == nil || speakers[into] == nil ? StaleReason.speakerNotFound : nil
            case .reassignTurns(let turnIDs, let to):
                if let to, speakers[to] == nil { return StaleReason.speakerNotFound }
                return turnIDs.allSatisfy { turnIndex[$0] != nil } ? nil : StaleReason.turnNotFound
            case .splitTurn(let turnID, _):
                return turnIndex[turnID] == nil ? StaleReason.turnNotFound : nil
            case .newSpeaker(_, _, let turnIDs), .excludeFromEnrollment(let turnIDs):
                return turnIDs.allSatisfy { turnIndex[$0] != nil } ? nil : StaleReason.turnNotFound
            case .revert:
                return nil
            }
        }

        /// Applies a valid action; returns a stale reason instead, changing nothing, when its own rules refuse it.
        mutating func apply(_ action: SpeakerEditAction, editID: String, transcript: Transcript) -> String? {
            switch action {
            case .rename(let speakerID, let name):
                speakers[speakerID]?.explicitName = SpeakerProjection.cleanName(name)
            case .linkProfile(let speakerID, let profileID):
                speakers[speakerID]?.profileID = profileID
                speakers[speakerID]?.rejectedProfileIDs.removeAll { $0 == profileID }
            case .rejectProfile(let speakerID, let profileID):
                guard var speaker = speakers[speakerID] else { return StaleReason.speakerNotFound }
                if !speaker.rejectedProfileIDs.contains(profileID) { speaker.rejectedProfileIDs.append(profileID) }
                if speaker.profileID == profileID { speaker.profileID = nil }
                speakers[speakerID] = speaker
            case .merge(let from, let into):
                guard from != into else { return StaleReason.mergeIntoItself }
                guard let source = speakers[from], var target = speakers[into] else {
                    return StaleReason.speakerNotFound
                }
                for index in turns.indices where turns[index].speakerID == from {
                    turns[index].speakerID = into
                }
                for clusterID in source.clusterIDs where !target.clusterIDs.contains(clusterID) {
                    target.clusterIDs.append(clusterID)
                }
                speakers[into] = target
                speakers[from] = nil
            case .reassignTurns(let turnIDs, let to):
                for turnID in turnIDs {
                    if let index = turnIndex[turnID] { turns[index].speakerID = to }
                }
            case .splitTurn(let turnID, let word):
                return split(turnID, at: word, editID: editID, transcript: transcript)
            case .newSpeaker(let speakerID, let name, let turnIDs):
                guard speakerID.hasPrefix(Self.userSpeakerPrefix),
                      speakerID.utf8.count > Self.userSpeakerPrefix.utf8.count else {
                    return StaleReason.notUserSpeaker
                }
                guard speakers[speakerID] == nil else { return StaleReason.speakerExists }
                maxOrdinal = Self.ordinal(after: maxOrdinal)
                speakers[speakerID] = SpeakerState(
                    id: speakerID, ordinal: maxOrdinal, clusterIDs: [], isChannel: false, channelName: nil,
                    isUserCreated: true, explicitName: SpeakerProjection.cleanName(name), profileID: nil,
                    rejectedProfileIDs: [])
                for turnID in turnIDs {
                    if let index = turnIndex[turnID] { turns[index].speakerID = speakerID }
                }
            case .excludeFromEnrollment(let turnIDs):
                for turnID in turnIDs {
                    if let index = turnIndex[turnID] { turns[index].excluded = true }
                }
            case .revert:
                break
            }
            return nil
        }

        static let userSpeakerPrefix = "user:"

        /// `ordinal + 1`, or `Int.max` when a corrupt run already uses it: loading never traps on run data (§2.4).
        /// Speakers that share an ordinal still list in a stable order (by ID).
        static func ordinal(after ordinal: Int) -> Int {
            ordinal < Int.max ? ordinal + 1 : Int.max
        }

        /// `[first, at)` keeps the turn's ID, `[at, end)` becomes "<turnID>/<editID>" with the same speaker; both
        /// are `modified` and take start, end, and timing from their words. The new part keeps the exclusion flag.
        mutating func split(_ turnID: String, at word: WordRef, editID: String, transcript: Transcript) -> String? {
            guard let index = turnIndex[turnID] else { return StaleReason.turnNotFound }
            let turn = turns[index]
            guard let spanIndex = turn.spans.firstIndex(where: {
                $0.segmentID == word.segmentID && $0.first <= word.word && word.word < $0.end
            }) else { return StaleReason.wordNotInTurn }
            let span = turn.spans[spanIndex]
            guard spanIndex > 0 || word.word > span.first else { return StaleReason.splitAtFirstWord }
            let partID = "\(turnID)/\(editID)"
            guard turnIndex[partID] == nil else { return StaleReason.turnExists }

            var head = Array(turn.spans[..<spanIndex])
            if word.word > span.first {
                head.append(WordSpan(segmentID: span.segmentID, first: span.first, end: word.word))
            }
            let tail = [WordSpan(segmentID: span.segmentID, first: word.word, end: span.end)]
                + turn.spans[(spanIndex + 1)...]
            guard let headWords = SpanWords(head, in: transcript), let tailWords = SpanWords(tail, in: transcript) else {
                return StaleReason.wordsNotInTranscript
            }

            turns[index].spans = head
            turns[index].start = headWords.start
            turns[index].end = headWords.end
            turns[index].timing = headWords.timing
            turns[index].modified = true
            var part = turn
            part.id = partID
            part.spans = tail
            part.start = tailWords.start
            part.end = tailWords.end
            part.timing = tailWords.timing
            part.modified = true
            turnIndex[partID] = turns.count
            turns.append(part)
            return nil
        }

        // MARK: Fingerprints

        /// See `SpeakerProjection.fingerprint(for:)` for the grammar. Every piece is self-delimiting (a
        /// length-prefixed string, `none`, a counted list, an integer followed by a fixed separator, or one of two
        /// tags), so the encoding of one action is injective over the state it covers.
        func fingerprint(for action: SpeakerEditAction) -> String? {
            let raw: String
            switch action {
            case .rename(let speakerID, _):
                raw = "rename:speaker=" + speakerRecord(speakerID) { "name=\(Self.optionalText($0.explicitName))" }
            case .linkProfile(let speakerID, let profileID):
                raw = "linkProfile:" + profileRecord(speakerID, profileID)
            case .rejectProfile(let speakerID, let profileID):
                raw = "rejectProfile:" + profileRecord(speakerID, profileID)
            case .reassignTurns(let turnIDs, let to):
                let target = to.map { speakerRecord($0) } ?? "none"
                raw = "reassignTurns:to=\(target);turns=" + Self.list(turnIDs.map { turnRecord($0, exclusion: false) })
            case .merge(let from, let into):
                raw = "merge:from=\(speakerRecord(from, mergeFields));into=\(speakerRecord(into, mergeFields))"
            case .splitTurn(let turnID, _):
                raw = "splitTurn:turn=" + turnRecord(turnID, exclusion: false)
            case .newSpeaker(let speakerID, _, let turnIDs):
                raw = "newSpeaker:speaker=\(speakerRecord(speakerID));turns="
                    + Self.list(turnIDs.map { turnRecord($0, exclusion: false) })
            case .excludeFromEnrollment(let turnIDs):
                raw = "excludeFromEnrollment:turns=" + Self.list(turnIDs.map { turnRecord($0, exclusion: true) })
            case .revert:
                return nil
            }
            return SpeakerProjection.compactFingerprint(SpeakerProjection.fingerprintVersion + raw)
        }

        /// `<L(id)>=absent`, or `<L(id)>=present;ordinal=<n>` followed by `;<fields>` when `fields` gives any.
        /// The ordinal tells a speaker apart from a later one created with the same ID after a merge removed it.
        private func speakerRecord(_ speakerID: String, _ fields: (SpeakerState) -> String = { _ in "" }) -> String {
            guard let speaker = speakers[speakerID] else { return "\(Self.text(speakerID))=absent" }
            let extra = fields(speaker)
            return "\(Self.text(speakerID))=present;ordinal=\(speaker.ordinal)" + (extra.isEmpty ? "" : ";\(extra)")
        }

        /// Linking drops the profile from the rejections and rejecting unlinks it: both carry the link and whether
        /// the profile is already rejected.
        private func profileRecord(_ speakerID: String, _ profileID: String) -> String {
            "profile=\(Self.text(profileID));speaker=" + speakerRecord(speakerID) { speaker in
                let rejected = speaker.rejectedProfileIDs.contains(profileID)
                return "link=\(Self.optionalText(speaker.profileID));rejected=\(rejected ? 1 : 0)"
            }
        }

        /// Everything a merge deletes (`from`) or keeps as the merged speaker (`into`).
        private func mergeFields(_ speaker: SpeakerState) -> String {
            let owned = turns.filter { $0.speakerID == speaker.id }
                .map { "\(Self.text($0.id)):words=\(Self.words(of: $0));excluded=\($0.excluded ? 1 : 0)" }
                .sorted()
            return "name=\(Self.optionalText(speaker.explicitName));link=\(Self.optionalText(speaker.profileID))"
                + ";rejected=\(Self.list(speaker.rejectedProfileIDs.map(Self.text)))"
                + ";clusters=\(Self.list(speaker.clusterIDs.map(Self.text)));turns=\(Self.list(owned))"
        }

        /// `<L(id)>=absent`, or `<L(id)>=present;speaker=<O(speaker)>;words=<W>` plus `;excluded=<0/1>`.
        private func turnRecord(_ turnID: String, exclusion: Bool) -> String {
            guard let index = turnIndex[turnID] else { return "\(Self.text(turnID))=absent" }
            let turn = turns[index]
            let record = "\(Self.text(turnID))=present;speaker=\(Self.optionalText(turn.speakerID))"
                + ";words=\(Self.words(of: turn))"
            return exclusion ? "\(record);excluded=\(turn.excluded ? 1 : 0)" : record
        }

        /// W: `<L(segment ID)>@<first>..<end>` per span (`end` exclusive), as a counted list.
        private static func words(of turn: TurnState) -> String {
            list(turn.spans.map { "\(text($0.segmentID))@\($0.first)..<\($0.end)" })
        }

        /// L: `<Unicode scalar count>:<value>`, so free text never runs into the field after it.
        private static func text(_ value: String) -> String { "\(value.unicodeScalars.count):\(value)" }

        /// O: `none`, or L(value). `none` cannot start a length prefix.
        private static func optionalText(_ value: String?) -> String { value.map(text) ?? "none" }

        /// N: `<count>[<item>,<item>,…]`.
        private static func list(_ items: [String]) -> String { "\(items.count)[\(items.joined(separator: ","))]" }

        // MARK: Step 5 and output

        func project(context: Context) -> (speakers: [ProjectedSpeaker], turns: [ProjectedTurn],
                                           mergeSuggestions: [MergeSuggestion]) {
            var turnCounts: [String: Int] = [:]
            var talk: [String: Double] = [:]
            var projectedTurns: [ProjectedTurn] = []
            projectedTurns.reserveCapacity(turns.count)
            for index in turns.indices.sorted(by: turnPrecedes) {
                let turn = turns[index]
                if let speakerID = turn.speakerID {
                    turnCounts[speakerID, default: 0] += 1
                    talk[speakerID, default: 0] += max(0, turn.end - turn.start)
                }
                let reassigned: Bool
                if turn.speakerID == turn.machineSpeakerID {
                    reassigned = false
                } else if let clusterID = turn.clusterID, let speakerID = turn.speakerID,
                          speakers[speakerID]?.clusterIDs.contains(clusterID) == true {
                    reassigned = false
                } else {
                    reassigned = true
                }
                projectedTurns.append(ProjectedTurn(
                    id: turn.id, track: turn.track, start: turn.start, end: turn.end, speakerID: turn.speakerID,
                    clusterID: turn.clusterID, spans: turn.spans, overlap: turn.overlap,
                    otherClusters: turn.otherClusters, assignmentScore: turn.assignmentScore, timing: turn.timing,
                    reassigned: reassigned, modified: turn.modified, excludedFromEnrollment: turn.excluded,
                    uncertain: turn.assignmentScore < 0.6 || turn.overlap || turn.speakerID == nil))
            }

            let listed = speakers.values
                .filter { turnCounts[$0.id] != nil || $0.isUserCreated }
                .sorted { ($0.ordinal, $0.id) < ($1.ordinal, $1.id) }
            var projectedSpeakers: [ProjectedSpeaker] = []
            projectedSpeakers.reserveCapacity(listed.count)
            var effectiveProfiles: [String: String] = [:]
            for speaker in listed {
                let usable = (context.matches[speaker.id] ?? []).filter {
                    !speaker.rejectedProfileIDs.contains($0.profileID)
                }
                // A name or link is the user's decision: no automatic name and no suggestion on top of it.
                let confirmed = speaker.explicitName != nil || speaker.profileID != nil
                let automatic = confirmed ? nil : usable.first { $0.tier == .likely }
                let suggestion = confirmed || automatic != nil ? nil : usable.first { $0.tier == .possible }

                let name: String
                let provenance: LabelProvenance
                if let explicitName = speaker.explicitName {
                    name = explicitName
                    provenance = .userRenamed
                } else if let profileID = speaker.profileID {
                    name = context.profileNames[profileID] ?? Self.fallbackName(speaker)
                    provenance = .userConfirmed
                } else if let automatic {
                    name = automatic.profileName
                    provenance = .recognized(distance: automatic.distance, tier: .likely)
                } else {
                    name = Self.fallbackName(speaker)
                    provenance = speaker.isChannel ? .channelAssumption : .diarizer
                }
                if let profileID = speaker.profileID ?? automatic?.profileID {
                    effectiveProfiles[speaker.id] = profileID
                }
                projectedSpeakers.append(ProjectedSpeaker(
                    id: speaker.id, ordinal: speaker.ordinal, name: name,
                    label: automatic == nil ? name : "\(name) (auto)", explicitName: speaker.explicitName,
                    profileID: speaker.profileID, provenance: provenance, isAutomatic: automatic != nil,
                    suggestion: suggestion, rejectedProfileIDs: speaker.rejectedProfileIDs,
                    clusterIDs: speaker.clusterIDs, talkSeconds: talk[speaker.id] ?? 0,
                    turnCount: turnCounts[speaker.id] ?? 0))
            }
            let merges = mergeSuggestions(listed: projectedSpeakers, effectiveProfiles: effectiveProfiles,
                                          context: context)
            return (projectedSpeakers, projectedTurns, merges)
        }

        /// "Me" (or the run's name) for the channel speaker, else "Speaker N".
        private static func fallbackName(_ speaker: SpeakerState) -> String {
            speaker.isChannel ? speaker.channelName ?? "Me" : "Speaker \(speaker.ordinal)"
        }

        /// (start, track, id) order; IDs compare numerically ("T9" before "T10"), then by position for duplicates.
        private func turnPrecedes(_ left: Int, _ right: Int) -> Bool {
            let a = turns[left]
            let b = turns[right]
            if let order = TurnOrder.precedes(a.start, a.track, b.start, b.track) { return order }
            if a.id != b.id {
                switch a.id.compare(b.id, options: [.numeric]) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.id < b.id
                }
            }
            return left < right
        }

        /// Linked (or automatic) speakers grouped by profile, plus recognition's suggestions for listed speakers that
        /// did not reject the profile and are not linked to another one; groups of two or more.
        private func mergeSuggestions(listed: [ProjectedSpeaker], effectiveProfiles: [String: String],
                                      context: Context) -> [MergeSuggestion] {
            var position: [String: Int] = [:]
            for (index, speaker) in listed.enumerated() { position[speaker.id] = index }
            var members: [String: [String]] = [:]
            func add(_ speakerID: String, _ profileID: String) {
                if members[profileID]?.contains(speakerID) != true { members[profileID, default: []].append(speakerID) }
            }
            for speaker in listed {
                if let profileID = effectiveProfiles[speaker.id] { add(speaker.id, profileID) }
            }
            for suggestion in context.mergeSuggestions {
                for speakerID in suggestion.speakerIDs {
                    guard let index = position[speakerID],
                          !listed[index].rejectedProfileIDs.contains(suggestion.profileID) else { continue }
                    let effective = effectiveProfiles[speakerID]
                    if effective == nil || effective == suggestion.profileID { add(speakerID, suggestion.profileID) }
                }
            }
            return members
                .filter { $0.value.count >= 2 }
                .map { profileID, speakerIDs in
                    MergeSuggestion(speakerIDs: speakerIDs.sorted { position[$0, default: .max] < position[$1, default: .max] },
                                    profileID: profileID)
                }
                .sorted { lhs, rhs in
                    let left = position[lhs.speakerIDs[0], default: .max]
                    let right = position[rhs.speakerIDs[0], default: .max]
                    return (left, lhs.profileID) < (right, rhs.profileID)
                }
        }
    }

    /// Start, end, and timing quality of the effective words of some spans; nil when a span is not in the
    /// transcript (missing segment, indices out of range) or a word has no finite time.
    struct SpanWords {
        let start: Double
        let end: Double
        let timing: WordTimingQuality

        init?(_ spans: [WordSpan], in transcript: Transcript) {
            var start = Double.infinity
            var end = -Double.infinity
            var count = 0
            var estimated = 0
            for span in spans {
                guard span.first >= 0, span.first < span.end,
                      let segment = transcript.segments.first(where: { $0.id == span.segmentID }) else { return nil }
                let words = WordTiming.effectiveWords(of: segment)
                guard span.end <= words.count else { return nil }
                for word in words[span.first..<span.end] {
                    guard word.start.isFinite, word.end.isFinite else { return nil }
                    start = min(start, word.start)
                    end = max(end, max(word.start, word.end))
                    count += 1
                    if word.estimated { estimated += 1 }
                }
            }
            guard count > 0 else { return nil }
            self.start = start
            self.end = end
            timing = WordTimingQuality(estimated: estimated, of: count)
        }
    }
}

// MARK: - SHA-256

/// SHA-256 (FIPS 180-4) for long fingerprints. HolosSpeakers imports only Foundation and HolosCore
/// (docs/meeting-design.md §5.3), so it cannot use CryptoKit.
enum FingerprintSHA256 {
    static func hexDigest(_ message: [UInt8]) -> String {
        let hexDigits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(64)
        for byte in digest(message) {
            text.append(hexDigits[Int(byte >> 4)])
            text.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var schedule = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: bytes.count, by: 64) {
            for index in 0..<16 {
                let offset = block + index * 4
                schedule[index] = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            }
            for index in 16..<64 {
                let w15 = schedule[index - 15]
                let w2 = schedule[index - 2]
                let s0 = rotateRight(w15, 7) ^ rotateRight(w15, 18) ^ (w15 >> 3)
                let s1 = rotateRight(w2, 17) ^ rotateRight(w2, 19) ^ (w2 >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ sum1 &+ choice &+ roundConstants[index] &+ schedule[index]
                let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a; hash[1] = hash[1] &+ b; hash[2] = hash[2] &+ c; hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e; hash[5] = hash[5] &+ f; hash[6] = hash[6] &+ g; hash[7] = hash[7] &+ h
        }
        var result: [UInt8] = []
        result.reserveCapacity(32)
        for word in hash {
            result.append(UInt8(truncatingIfNeeded: word >> 24))
            result.append(UInt8(truncatingIfNeeded: word >> 16))
            result.append(UInt8(truncatingIfNeeded: word >> 8))
            result.append(UInt8(truncatingIfNeeded: word))
        }
        return result
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}
