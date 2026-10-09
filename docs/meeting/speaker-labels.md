# Speaker labels

The edit journal, the projection and carry-over (§4.9). §5.3 (the speaker algorithms) and §5.5 (labels after a
recording) come from the build plan and name the PRs that built them; the code cites them for behaviour.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.9 Edit journal, projection, carry-over

The run is immutable; edits are an append-only journal; the projection is a pure
function (PR5b, `Sources/HolosSpeakers/SpeakerProjection.swift`) that everyone uses:
exports (PR7b), CLI (PR8), review window (PR9), enrollment (PR10).

```swift
public struct ProjectedSpeaker: Sendable, Equatable, Identifiable {
    public let id: String
    public let ordinal: Int
    /// Plain name: explicit name, else linked profile name, else automatic (likely) profile name,
    /// else "Me" for the channel speaker, else "Speaker N".
    public let name: String
    /// What the UI and every export show: `name`, plus " (auto)" when `isAutomatic` ("Jim (auto)").
    public let label: String
    public let explicitName: String?
    /// Linked by an edit (a confirmed label).
    public let profileID: String?
    public let provenance: LabelProvenance
    /// A `likely` match applied automatically and not confirmed.
    public let isAutomatic: Bool
    /// A `possible` match, not applied; the UI shows "Maybe Maria — Confirm". Never exported.
    public let suggestion: SpeakerMatch?
    public let rejectedProfileIDs: [String]
    public let clusterIDs: [String]
    public let talkSeconds: Double
    public let turnCount: Int
    /// The stored speakers shown as this one: its own ID first, then same-named speakers joined
    /// into it ("Speakers with the same name", below).
    public let memberIDs: [String]
}

public struct ProjectedTurn: Sendable, Equatable, Identifiable {
    public let id: String
    public let track: String
    public let start: Double
    public let end: Double
    public let speakerID: String?          // nil = unknown speaker
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
}

public struct StaleEdit: Sendable, Equatable {
    public let editID: String
    public let reason: String
}

public struct SpeakerProjection: Sendable, Equatable {
    public let runID: String
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
    /// batchID of the newest applied batch that is not an undo, for undo.
    public let lastUndoableBatchID: String?
    public let mergeSuggestions: [MergeSuggestion]

    /// `recognition` matches whose profileID is not in `profileNames` (forgotten people) are ignored.
    public static func make(run: DiarizationRun, transcript: Transcript, edits: [SpeakerEdit],
                            recognition: RecognitionResult?, profileNames: [String: String]) -> SpeakerProjection
    /// The fingerprint an edit with this action carries, computed on `self`. Journal-derived state only.
    public func fingerprint(for action: SpeakerEditAction) -> String?
    /// `self` with one more applied edit, for editor batches and optimistic UI updates.
    public func applying(_ action: SpeakerEditAction, editID: String) -> SpeakerProjection
}
```

Application order in `make`:

1. Start from `run.speakers` and `run.turns`.
2. Apply `recognition` only if `recognition.runID == run.id`, ignoring matches for
   profiles not in `profileNames`: `likely` matches become an automatic profile link
   (name from `profileNames[profileID]`); `possible` matches become `suggestion`.
3. Collect reverts: an edit is reverted if a later `revert(editID:)` for it exists and
   that revert is not itself stale. Reverting a revert is stale ("cannot revert an
   undo"); there is no redo in v1.
4. For each remaining edit in file order with `baseRunID == run.id`: compute
   `fingerprint(for:)` on the current state. If `expected != nil` and differs → stale
   ("changed since the edit was made"). If a referenced speaker or turn does not exist →
   stale ("speaker not found" / "turn not found"). Otherwise apply.
5. Derive names and provenance at the end: explicit name → `userRenamed`; linked profile
   → `userConfirmed`; automatic likely match not rejected → `recognized`; channel →
   `channelAssumption`; else `diarizer`. Then list same-named speakers as one ("Speakers
   with the same name", below).
6. With a call's acoustic echo mask, hide the words and clusters it flags (§5.11). A turn
   with no words at all (every one deleted in Review with its segment, §5.10 "Editing
   words") is not shown either, mask or not; edits still name it.
7. Decide the short interjections of the unknown speaker on the turns of step 6
   (`interjections`, `shownTurns`, §5.10 "Short interjections"). Presentation only: `turns`
   and `speakers` stay as steps 1–6 left them; the Review list and the exports read
   `shownTurns`.

Fingerprints use only state derived from the run and the journal (never recognition).
This is the format implemented in PR5b (`SpeakerProjection.State.fingerprint(for:)`). The
raw encoding is injective per action and self-describing, so an unhashed stale fingerprint
never compares equal to the current state; hashed fingerprints (below) are
collision-resistant rather than injective:

| Action | Fingerprint |
|---|---|
| `rename(s, _)` | `fp1:rename:speaker=` S(s, `name=`O(explicit name)) |
| `linkProfile(s, p)` | `fp1:linkProfile:profile=`L(p)`;speaker=` S(s, `link=`O(linked profile)`;rejected=<1 if p is rejected, else 0>`) |
| `rejectProfile(s, p)` | `fp1:rejectProfile:` and the rest as `linkProfile` |
| `reassignTurns(ids, to)` | `fp1:reassignTurns:to=<none for unknown, else S(to)>;turns=` N(T(id) for each id) |
| `merge(from, into)` | `fp1:merge:from=` S(from, M) `;into=` S(into, M), where M = `name=`O(explicit name)`;link=`O(linked profile)`;rejected=`N(L(p) per rejection, in order)`;clusters=`N(L(c) per cluster, in order)`;turns=`N(sorted `L(turn ID):words=W;excluded=<0/1>` of its turns) |
| `splitTurn(t, _)` | `fp1:splitTurn:turn=` T(t) |
| `newSpeaker(s, _, ids)` | `fp1:newSpeaker:speaker=` S(s) `;turns=` N(T(id) for each id) |
| `excludeFromEnrollment(ids)` | `fp1:excludeFromEnrollment:turns=` N(T(id)`;excluded=<0/1>` for each id) |
| `revert(editID)` | `nil` (revert staleness is decided in step 3) |

- L(x) = `<Unicode scalar count of x>:<x>`; every string (names and IDs) is written this way.
- O(x) = `none` when x is nil, else L(x).
- N(items) = `<count>[<items joined by ,>]`.
- S(id, fields) = L(id)`=absent`, or L(id)`=present;ordinal=<n>` then `;fields` when there
  are any. The ordinal separates a speaker from a later one re-created with the same
  `user:` ID after a merge removed the first.
- T(id) = L(id)`=absent`, or L(id)`=present;speaker=`O(speaker, none = unknown)`;words=`W.
- W = N(L(segment ID)`@<first>..<end>` per span, `end` exclusive). Word ranges are included
  so a reassignment or merge made before another window split a turn is refused.
- A fingerprint longer than 256 Unicode scalars is replaced by
  `fp1:sha256:<64 hex digits of the SHA-256 of its UTF-8 bytes>`, which can never equal an
  unhashed fingerprint. Two different long states could in principle hash alike; with
  SHA-256 that is negligible, so hashed fingerprints are collision-resistant, not injective.
  The property test samples states and does not prove global injectivity.

Every action that changes speaker assignment, turn boundaries, names, links, rejections,
or enrollment therefore carries all the state it reads or discards. Tests (PR5b):
`staleExcludeAfterSplitIsRefused`, `staleMergeAfterReassignIsRefused`,
`staleMergeAfterChangeToEitherSpeakerIsRefused`, `staleRejectAfterRelinkIsRefused`,
`staleLinkAfterRejectionIsRefused`, `staleReassignAfterSplitIsRefused`,
`deletedSpeakerFingerprintDiffersFromAnUnnamedOne`, `hashedFingerprintNeverEqualsARawOne`,
and the property test `fingerprintsAreInjectiveOverTheStateEachActionReads`.

Action semantics:

- `rename(s, name)`: trims; empty or nil clears the explicit name.
- `linkProfile(s, p)`: links, removes `p` from `s`'s rejections. Two speakers linked to
  one profile is allowed (it yields a merge suggestion); given one name, they are one
  speaker ("Speakers with the same name", below).
- `rejectProfile(s, p)`: adds `p` to rejections; unlinks if linked; suppresses an
  automatic match or suggestion of `p`.
- `merge(from, into)`: all turns of `from` go to `into`; `into.clusterIDs +=
  from.clusterIDs`; `from` is removed, so later edits naming it become stale. `into`
  keeps its name.
- `reassignTurns(ids, to)`: `to` must exist (or be nil).
- `splitTurn(t, at)`: `at` must be a word of `t` other than its first; `[first, at)`
  keeps `t`, `[at, end)` becomes `<t>/<editID>` with the same speaker. Both parts are
  `modified`.
- `newSpeaker(sid, name, ids)`: `sid` must start with `user:` and not exist; ordinal =
  max + 1.
- `excludeFromEnrollment(ids)`: flags turns.
- Split parts get start/end from their words (`WordTiming.effectiveWords`).

Speakers listed: every speaker with at least one turn, plus user-created speakers.
Talk time = sum of turn durations.

**Speakers with the same name.** Within a meeting, the same name is the same person, and
is shown as one speaker (`SameNameSpeakers`, HolosSpeakers). Names compare by
`SameNameSpeakers.key`: runs of whitespace and control characters become one space, the
ends are trimmed, and case, diacritics and character width are ignored ("Zoë  Smith" =
"zoe smith"). Only names join: the name the user gave (`rename`, `newSpeaker`), or the
channel speaker's own ("Me"), read from the journal's state alone. Links never join anyone
(two speakers linked to one person under different names stay two, and a merge is
suggested as before). One exception, also read from the journal alone: speakers of one
name linked to two or more different people (two remembered people called Alex, each
linked in the meeting) are those people, and are shown apart, each with its own link; an
edit of one never reaches the other. A group with one link, or none (an unlinked Alex and
an Alex linked to a person), is joined. "Not <person>" keeps that person's suggestions away
and nothing else. A "Speaker N" fallback names nobody, and an
automatic match ("Jim (auto)") or a suggestion is a guess nobody confirmed: neither joins
anyone. Nothing here reads the people store, recognition, the echo mask or talk time, so
every projection of a meeting (Review, the exports, the CLI, summaries,
`SpeakerAnalysis.headState`) shows the same speakers as one.

It is display only: nothing is ever merged automatically. The journal keeps every stored
speaker, with its own link and its own voice.

- *Showing (every meeting, nothing written).* After step 5, the projection lists each
  group as one: `speakers` has one entry, `ProjectedSpeaker.memberIDs` lists the stored IDs
  it shows (its own first), and `turns` (so `shownTurns`, the exports, Review, the CLI and
  summaries) gives the others' turns to it. The groups (`SameNameSpeakers.joins`) are the
  stored speakers of one name that hold a turn with words or were made by `newSpeaker`. The
  one shown is the lowest (ordinal, ID), fixed by the journal. It keeps its ID, ordinal,
  name and rejections, shows the group's person (its own link, else the link of the lowest
  (ordinal, ID) other one that has one), and adds the others' clusters, talk time and turn
  counts. `mergeSuggestions` are worked out on the joined list. Edits and fingerprints see
  every stored speaker, so journals written before the rule replay exactly as before; only
  their display changes. This is what shows a journal like "a new speaker named Alice for
  one unknown turn, then the cluster renamed Alice" as one Alice in the exports'
  Participants (talk time summed), in Review's sidebar and in every count, and what keeps
  names carried over by Label Again (`SpeakerCarryOver` maps the joined speaker) from
  listing a person twice.
- *Voice.* `SpeakerProjection.unjoined` lists every stored speaker as itself (every one that
  holds words or was made by `newSpeaker`, also one whose words the echo mask all hides),
  and voice data reads it: samples are learned per stored speaker for the person it is
  linked to, and forgetting a person removes exactly the clusters and turns of the stored
  speakers linked to them, never those of a same-named speaker shown with them but linked
  to nobody (`VoiceProfileService`: `syncSamples`, `samplesAffected`, earlier-run views,
  `removeVoiceEntries`).
- *Editing (`SpeakerEditor`, Review, the CLI).* Giving a speaker a name another speaker has
  only renames it; the display joins them. An edit of any stored speaker of a same-name
  group reaches every other one of the group, in the same batch
  (`SpeakerProjection.fanningOut`, worked out by the editor under the speaker lock on the
  current labels, and by Review on the labels shown for its preview). The group is the
  journal's (`SameNameSpeakers.joins`). An edit must reach the stored speakers the
  caller's view showed in its group: when the group changed since (another window named a
  speaker into or out of it), the editor refuses the batch as made on outdated labels
  (`SpeakerEditor.changedMessage`), and the caller rereads and asks again (Review reloads;
  the live speaker-name pass plans again with its protection worked out afresh). A rename or clearing the name, a link, a rejection ("Not Jim"), "This
  is me", a confirmed suggestion and Confirm All are made to each of them, one stored
  speaker after another; a merge of one into another speaker ("Merge into…") moves each
  of them into that speaker. Turns given to the speaker shown go to it. Review's name
  field, clearing a name, also unlinks each stored speaker from its own person when that
  differs from the person shown, so no link names it again. The lines added follow the
  asked ones, carry the current fingerprints, and share the batch's ID: one undo takes all
  of them back. Whether a change changes anything (`SpeakerEditor.changesNothing`,
  `applyUnlessUnchanged`, a link of a person already shown) is decided with these lines
  added, on every stored speaker (`unjoined`), not on the speaker shown: linking the shown
  Alex to the person it already shows still links a stored Alex that is not.
  `SpeakerEditor.saved(_:asAsked:)` lets a caller (Review) recognize its batch among the
  lines read back. A `newSpeaker` named as nobody in the caller's view is, but as somebody
  in the labels under the lock (another window named a speaker so meanwhile), is refused as
  made on outdated labels: on the labels as they are, the caller gives the turns to that
  speaker instead.
- *Who reads which.* The joined list is for showing: the exports, Review's rows and
  sidebar, the CLI's listing and selectors (whose edits fan out), summaries, participant
  lists and Review's voice suggestions. Whatever maps identities, links or voice reads
  the stored speakers (`unjoined`): voice learning and forgetting, Label Again
  (`SpeakerCarryOver` matches each stored speaker to the new speaker its own speech lands
  in, and gives it the identity of the group it is shown as: the group's name, its one
  link and its rejections, so whichever of them a new speaker's speech comes from gets
  the whole identity, two new speakers both get it, and a member whose group-mate carried
  it is not reported unmatched; two Alexes linked to two people, shown apart, each keep
  their own link on their own speech), the editor's refusal messages, and the CLI's link report. Live speaker names
  (`LiveHintStage`) treat a same-name group as named by hand when any of its stored
  speakers is, since a name given to the one shown would reach them all.
- *Choosing a name that exists.* Review's "New Speaker…" (and `voiceislocal speakers assign
  --to new:NAME`) with a name a speaker is shown under gives the turns to the one shown
  (`SpeakerProjection.speaker(named:)`: matched on the name each stored speaker joins by in
  the journal, the given name or the channel speaker's own "Me" whether or not it is
  linked, never on a name shown only through a link, and never picked among several).
  Every name typed to choose a speaker or a person (the CLI's selectors, Review's name
  field) compares as `SameNameSpeakers.key` does.
  "Assign to <person>" gives the turns to the
  stored speaker linked to that person, else to the speaker called their name when it is
  linked to nobody (linked to them in the same batch unless it said "Not <person>"), else
  to a new speaker called their name and linked to them (one called their name but linked
  to somebody else is that other person, and the new speaker is shown apart from it): the move (or the new speaker) and the link
  are one batch (`VoiceProfileService.link(preceding:)`), shown and saved alike. Review's
  name field links the known person whose name matches by `key` (accents and spaces too,
  not only case) rather than creating a second person of that name.

Why display only, rather than merging same-named speakers (when a name is given, or when
Review opens a meeting with duplicates): a merge deletes a stored speaker, and with it the
link that says whose voice its turns are, so forgetting that person later finds nothing to
remove, a merge into another speaker loses which turns were somebody else's, and clearing a
name or relinking reaches only the speaker that survived. Showing them as one needs no
write (exports, the CLI and summaries of meetings nobody reopens are right too), cannot be
undone into a loop of re-merges, covers names Label Again carries onto two new speakers,
and keeps each person's voice data theirs. Fanning edits out keeps the stored speakers
alike, so they keep showing as one. An older Voice is Local shows them as separate
speakers.

**`SpeakerEditor` (PR8)** is the only writer of the journal. A caller passes the
projection it showed the user (`view`). Under `SessionArchive.withSpeakerLock` the
editor loads the current snapshot and refuses the whole batch, writing nothing, with
`HolosError.unavailable("Speaker labels changed since this view was loaded; reload.")`
when the head run is not `view.runID`, or when any action's fingerprint computed on the
caller's view (sequentially, with `applying` for earlier actions of the batch) differs
from the same fingerprint on the current state. Otherwise it appends every line with one
`batchID` in one write, **releases the lock**, and then regenerates exports (unless told
not to) and, from PR10, refreshes voice samples. This is a real compare-and-append: a
window opened before a `session diarize --force`, or a CLI command typed from an older
`speakers list`, cannot edit a different turn in the new run, and a stale rename cannot
silently overwrite a newer one.

**Carry-over (PR5b, `SpeakerCarryOver`).** `docs/contracts.md` requires human edits to
survive reprocessing, with conflicts reported. When a new run replaces a head (relabel
with `--force`, a changed transcript, Find More Speakers), the post-processor carries
speaker-level labels:

```swift
public enum SpeakerCarryOver {
    public struct Result: Sendable, Equatable {
        /// rename / linkProfile / rejectProfile actions on the new run's speakers, then at most one
        /// excludeFromEnrollment of the new run's turns.
        public var actions: [SpeakerEditAction]
        /// Old speakers with a name, link, or rejection that matched nothing (IDs only).
        public var unmatchedSpeakers: [String]
        /// Turn-level edits (reassign, split, new speaker) and merges that are not carried.
        public var droppedTurnEdits: Int
    }
    /// Maps each old projected speaker with an explicit name, link, or rejection to the new run's speaker with
    /// the most shared speech time on the same track (one-to-one, greedy by shared seconds, ties by ID),
    /// accepted only when the shared time is at least 50% of the smaller of the two talk times.
    public static func carry(from old: SpeakerProjection, to new: DiarizationRun) -> Result
}
```

The actions are appended with `source: "carry"`, the new run as `baseRunID`, and one
batch ID. The command reports "Kept 8 names; 1 name could not be matched and 12
turn-level changes were not carried." Old edits stay in the journal under the old run
ID. User-created speakers carry by time like any other. Speech kept out of voice learning
(`excludeFromEnrollment`, by the user or by an automatic merge nobody confirmed, §4.10)
stays out: every new turn that shares any time with an excluded old turn on the same track
is excluded in the carry batch (`SpeakerCarryOver.excludedTurnIDs`), whichever speaker it
lands in, so a relabel never lets that speech reach a voice sample. Exclusions are therefore
not counted as dropped. Test: `carryKeepsTimeOutOfVoiceLearning` (HolosSpeakers),
`relabellingKeepsTurnsOutOfVoiceLearning` (HolosMeeting).

### 5.3 PR5a, PR5b, PR5c: HolosSpeakers (wave 1, stacked)

**Goal.** Every speaker algorithm as pure, tested code, delivered in three stacked PRs
(each branches from the previous one; same wave): PR5a alignment and run building,
PR5b the edit projection and carry-over, PR5c exporters, the Otter parser, and scoring.
`swift build --target HolosSpeakers` imports nothing beyond Foundation and HolosCore;
`rg "FileManager|Data\(contentsOf" Sources/HolosSpeakers` is empty.

**Files.**

- PR5a: add `Sources/HolosSpeakers/{WordTiming, DiarizationNormalizer, SpeakerAlignment, TurnEmbeddings, SpeakerRunBuilder, VectorMath, FakeDiarizer}.swift`;
  change `Package.swift` (§1.2 wave 1: the HolosSpeakers target and test target);
  tests `Tests/HolosSpeakersTests/{WordTimingTests, NormalizerTests, AlignmentTests, TurnEmbeddingTests, RunBuilderTests, VectorMathTests, FakeDiarizerTests}.swift`.
- PR5b: add `Sources/HolosSpeakers/{SpeakerProjection, SpeakerCarryOver}.swift` (§4.9);
  tests `{ProjectionTests, CarryOverTests}.swift`.
- PR5c: add `Sources/HolosSpeakers/Export/{ExportDocument, MarkdownExport, JSONExport, TextExport, TimeFormat}.swift` (§4.11),
  `OtterTranscriptParser.swift`, `DiarizationScoring.swift`;
  tests `{ExportTests, OtterParserTests, ScoringTests}.swift`.

**API (PR5a).**

```swift
public struct EffectiveWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public let utf16Offset: Int
    public let utf16Length: Int
    public let estimated: Bool
}
public enum WordTiming {
    /// `segment.words` in order when non-empty (measured). Otherwise the text split at whitespace into
    /// tokens with equal durations over [start, start + max(end − start, 0.01 × count)) (estimated).
    /// WordRef and WordSpan indices refer to this array.
    public static func effectiveWords(of segment: TranscriptSegment) -> [EffectiveWord]
}

public enum DiarizationNormalizer {
    /// Prefixes engine labels with the track ("system:S1"), drops segments shorter than 0.05 s, sorts by
    /// (start, clusterID), sets overlapCount, and builds ClusterSummary (speechSeconds = union length per cluster).
    public static func normalize(_ output: DiarizerOutput, track: String) -> TrackDiarization
}

public struct AlignedWord: Sendable, Equatable {
    public let ref: WordRef
    public let track: String
    public let start: Double
    public let end: Double
    public let estimated: Bool
    public var label: String?            // cluster or channel speaker; nil = unknown
    public var coveredSeconds: Double    // overlap with `label`'s segments
    public var overlapClusters: [String]
}

public enum SpeakerAlignment {
    /// Offset in [−search, +search] (step `offsetStepSeconds`) to add to diarization times that maximizes the
    /// measured-word time covered by any segment; 0 with fewer than 50 measured words, or when the best
    /// offset covers less than 1% more word time than 0. Ties: smallest |offset|.
    public static func estimateOffset(segments: [TranscriptSegment], track: String, diarization: TrackDiarization,
                                      parameters: AlignmentParameters) -> Double
    /// Steps 1–4 below, for the transcript segments of `track` (diarization already shifted by the offset).
    public static func assignWords(segments: [TranscriptSegment], track: String, diarization: TrackDiarization,
                                   parameters: AlignmentParameters) -> [AlignedWord]
    /// Step 5. Turns get placeholder IDs; the run builder renumbers them.
    public static func buildTurns(_ words: [AlignedWord], parameters: AlignmentParameters) -> [SpeakerTurn]
}

public enum TurnEmbeddings {
    /// For each turn with a clusterID, not overlapped, at least 2 s long: the mean of that cluster's windows
    /// overlapping the turn, weighted by overlap seconds, L2-normalized. Other turns get none.
    public static func compute(turns: [SpeakerTurn], windowsByCluster: [String: [EmbeddingWindow]]) -> [TurnEmbedding]
}

public enum SpeakerRunBuilder {
    public static let alignmentVersion = 1
    public struct TrackInput: Sendable, Equatable {
        public var track: String
        public var policy: TrackPolicy
        public var output: DiarizerOutput?      // required for .diarized; times already on the session timeline
        public init(track: String, policy: TrackPolicy, output: DiarizerOutput? = nil)
    }
    public struct Result: Sendable, Equatable {
        public var run: DiarizationRun
        /// Centroids and turn embeddings; nil without an engine. The caller decides whether to persist it.
        public var voiceData: SessionVoiceData?
    }
    /// Estimates and applies the per-track offset, normalizes, aligns, numbers turns T1… in (start, track)
    /// order, creates speakers (one per cluster with at least one turn, id = clusterID, provenance .diarizer;
    /// one per channel policy, provenance .channelAssumption, displayName from the policy), assigns ordinals by
    /// first turn start, and computes turn embeddings into `voiceData`.
    public static func build(sessionID: String, transcript: Transcript, tracks: [TrackInput],
                             engine: DiarizationEngineInfo?, parameters: AlignmentParameters = .v1,
                             id: String = UUID().uuidString, createdAt: Date = Date()) -> Result
}

public enum VectorMath {
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double   // 1 − cos; 2 if either norm is 0 or sizes differ
    public static func normalized(_ v: [Float]) -> [Float]
    public static func weightedMean(_ vectors: [([Float], Double)]) -> [Float]?
}
```

**Alignment algorithm** (per track; parameters from `AlignmentParameters.v1`):

0. Offset: `estimateOffset`; shift the track's segments and windows by it; record it in
   `AlignmentInfo.trackOffsets`. PR7c reports the measured offsets on the Otter files.
1. Words: segments whose `track` equals the track (a `nil` track counts when the
   transcript has one track), in start order, expanded with `WordTiming.effectiveWords`.
2. Main cluster of word `[s, e)`: the cluster with the largest overlap with the union of
   its segments. Ties: the cluster whose overlapping segment starts first, then the
   smaller cluster ID. No overlap: the nearest segment by edge distance if that
   distance ≤ `gapSnapSeconds` (same tie rule), else unknown (`nil`).
3. Overlap: other clusters overlapping the word by at least
   `min(overlapMinSeconds, overlapMinFraction × (e − s))`.
4. Flicker smoothing (one left-to-right pass over labels, `nil` included). A maximal run
   R of words labelled B, with label A ≠ B on both sides, takes label A only when all of
   these hold: at most `flickerMaxWords` words; R spans at most `flickerMaxSeconds`; the
   pause from the last A word before R to R's first word, and from R's last word to the
   next A word, are each at most `flickerMaxGapSeconds`; and, when B is a cluster, R
   starts or ends within `flickerBoundarySeconds` of a point where an A segment meets a
   B segment, and no single B segment at least `flickerMinOwnSegmentSeconds` long covers
   R. Runs touching either end of the track are kept. So boundary jitter inside
   continuous speech is smoothed, while a short "Yes" between pauses stays with the
   person who said it.
5. Turns: a new turn starts when the label changes or when `word.start − previous.end >
   turnPauseSeconds`. Consecutive words of one segment form one `WordSpan`. `start`/`end`
   from the words; `overlap` if any word has overlap clusters; `otherClusters` = sorted
   union; `assignmentScore = Σ coveredSeconds / Σ (end − start)` (0 for unknown);
   `timing` from the words' `estimated` flags.
6. `channel` policy: every word gets the channel speaker, no overlap, score 1. `skipped`:
   no turns.

**API (PR5b):** §4.9 (`ProjectedSpeaker`, `ProjectedTurn`, `StaleEdit`,
`SpeakerProjection` with `make`, `fingerprint`, `applying`; `SpeakerCarryOver`).

**API (PR5c):** §4.11 (`ExportMetadata`, `ExportDocument`, `ExportFormat`, `ExportBlock`,
`TranscriptExporter`), plus:

```swift
public struct ReferenceTurn: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double?       // next turn's start; nil for the last turn
    public var wordCount: Int     // text is counted, never kept
}
public enum OtterTranscriptParser {
    /// Header lines "Name  mm:ss" or "Name  h:mm:ss" start turns; the footer "Transcribed by https://otter.ai" is ignored.
    public static func parse(_ text: String) -> [ReferenceTurn]
}

public struct LabelledInterval: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
}
public struct DiarizationScore: Sendable, Equatable {
    public var referenceSeconds: Double
    public var missSeconds: Double
    public var falseAlarmSeconds: Double
    public var confusionSeconds: Double
    public var der: Double
    public var mapping: [String: String]      // reference → hypothesis
    public var referenceSpeakers: Int
    public var hypothesisSpeakers: Int
}
public enum DiarizationScoring {
    /// Frame-based (10 ms) DER with a no-score collar around reference boundaries; optimal one-to-one mapping
    /// (Hungarian up to 20 × 20, greedy by overlap above that).
    public static func der(reference: [LabelledInterval], hypothesis: [LabelledInterval], collar: Double = 0.25) -> DiarizationScore
    /// For Otter references (turns cover silence): over frames where both sides have a speaker, the share whose
    /// mapped speaker differs. Reported as "agreement with Otter", not DER. `confusion` is nil (not comparable) when
    /// no scored frame has both; `referenceSeconds` and `hypothesisSeconds` (scored time per side) say why.
    public static func agreement(reference: [LabelledInterval], hypothesis: [LabelledInterval],
                                 collar: Double = 0.25) -> DiarizationAgreement
    // DiarizationAgreement { confusion: Double?, comparedSeconds, referenceSeconds, hypothesisSeconds: Double,
    //                        mapping: [String: String] }; prints no labels.
}
```

**Tests** (inputs are synthetic; `seg(start, end, words…)` builds a segment with measured
words):

| PR | Test | Input | Expected |
|---|---|---|---|
| 5a | `untimedSegmentSpreadsWordsEvenly` | segment 10–14 "one two three four", no words | words at 10–11, 11–12, 12–13, 13–14, estimated |
| 5a | `measuredWordsKeepOffsets` | segment with 3 TimedWords | same times and UTF-16 offsets |
| 5a | `normalizerPrefixesSortsAndCountsOverlap` | raw S2 5–9, S1 0–6 | `system:S1` 0–6 (overlap 1), `system:S2` 5–9 (overlap 1) |
| 5a | `normalizerDropsTinySegments` | 0–0.03 | dropped |
| 5a | `wordInsideSegment` | A 0–5, B 5–10; word 1.0–1.4 | A |
| 5a | `boundaryWordTakesLargerOverlap` | word 4.8–5.3 | B (0.3 vs 0.2) |
| 5a | `equalOverlapTakesEarlierSegment` | word 4.8–5.2 | A |
| 5a | `gapWordSnapsWithinHalfSecond` | A 0–5, B 7–10; words 5.3–5.6 and 6.0–6.4 | A; unknown |
| 5a | `boundaryFlickerIsSmoothed` | A 0–5.1, B 5.1–10 and A 10–20 (continuous speech); words A A B B A A with the B pair 4.9–5.2, gaps 0.1 s | all A |
| 5a | `isolatedShortReplyIsKept` | A 0–10, B 11.5–11.8, A 13.3–20; "Yes" 11.5–11.8 with 1.5 s pauses | the word stays B |
| 5a | `flickerCoveredByOwnSegmentIsKept` | B segment 5.0–5.5 covers a 2-word run with 0.1 s gaps | B kept |
| 5a | `flickerOverLimitIsKept` | B-run of 3 words, or spanning 0.5 s | B kept |
| 5a | `longPauseSplitsSameSpeaker` | A words with a 2.0 s gap | two turns |
| 5a | `segmentSplitsAtSpeakerChange` | one segment, words 0–2 in A, 3–5 in B | two turns; spans [0,3) and [3,6) of that segment |
| 5a | `turnSpansTwoSegments` | same speaker, 0.5 s between segments | one turn, two spans |
| 5a | `overlapMarkedWithoutDuplicatingWords` | A 0–10, B 4–6; words throughout | the words in 4–6 stay in A's turn, `overlap`, `otherClusters == [B]`; total words in turns = input words |
| 5a | `assignmentScoreIsCoveredShare` | turn words 2.0 s, 1.5 s covered | 0.75 |
| 5a | `channelTrackIsOneSpeaker` | policy channel mic:me | all turns `mic:me`, score 1 |
| 5a | `offsetEstimateRecoversShift` | 200 measured words; segments equal to the speech intervals shifted +0.2 s | offset −0.20 ± 0.02; recorded in `trackOffsets` |
| 5a | `offsetIsZeroWithFewWords` | 30 measured words | 0 |
| 5a | `turnEmbeddingWeightsWindows` | turn 10–14 of S1; windows S1 9–12 [1,0], 12–20 [0,1] | normalized [0.707, 0.707] (2 s each) |
| 5a | `shortOrOverlappedTurnsGetNoEmbedding` | 1.5 s turn; overlapped turn | none |
| 5a | `runBuilderNumbersTurnsAndOrdinals` | mic channel turn at 3.0; system S2 at 1.0, S1 at 5.0 | T1 system:S2, T2 mic:me, T3 system:S1; ordinals S2 1, me 2, S1 3 |
| 5a | `runHoldsNoVectors` | build with FakeDiarizer output | the encoded run has no key named `centroid`, `centroids`, `vector`, or `turnEmbeddings`; `voiceData` has one centroid per cluster |
| 5a | `fakeAlternatingOutput` | speakers [S1,S2], 5 s, 20 s | 4 segments alternating; 2 orthogonal centroids |
| 5b | `renameApplies` | rename system:S2 "Maria", expected "" | name Maria, provenance userRenamed, edit applied |
| 5b | `staleRenameIsSkipped` | expected "Jim", current "" | stale "changed since…" |
| 5b | `otherRunEditsCounted` | edit with another baseRunID | `otherRunEditCount == 1`, not applied |
| 5b | `mergeMovesTurnsAndRemovesSpeaker` | merge S3 into S1; later rename S3 | S3 gone; its turns S1; later rename stale |
| 5b | `mergedTurnsAreNotReassigned` | merge S3 into S1 | S3's former turns `reassigned == false` |
| 5b | `reassignTurnsToUnknown` | reassignTurns [T4] to nil | T4 speaker nil, uncertain, reassigned |
| 5b | `splitTurnCreatesSuffixTurn` | split T5 at word 3 | T5 words [0,3); T5/<e> words [3,…); both `modified` |
| 5b | `newSpeakerGetsNextOrdinal` | newSpeaker user:X "Guest" [T7] | ordinal max + 1; T7 → user:X |
| 5b | `revertSkipsEdit` | rename then revert | name cleared; edit in revertedEditIDs |
| 5b | `revertOfRevertIsStale` | revert(revertEditID) | stale |
| 5b | `lastUndoableBatchIsNewestBatch` | batch B1 (2 edits), then B2 (1 edit) | `lastUndoableBatchID == B2`; after reverting B2, B1 |
| 5b | `applyingMatchesMake` | 10 random actions | `applying` chain equals `make` over the same journal |
| 5b | `likelyMatchIsAutomatic` | recognition likely Jim for S1 | name Jim, label "Jim (auto)", isAutomatic |
| 5b | `forgottenProfileMatchIsIgnored` | likely Jim, `profileNames` without Jim | label "Speaker N"; no suggestion |
| 5b | `fingerprintIgnoresRecognition` | likely Jim for S1, no edits | `fingerprint(linkProfile(S1, …)) == ""` |
| 5b | `rejectProfileSuppressesMatch` | rejectProfile S1 Jim | label back to "Speaker N" |
| 5b | `possibleMatchIsSuggestionOnly` | possible Maria for S2 | suggestion set; label "Speaker 2" |
| 5b | `userRenameBeatsRecognition` | likely Jim + rename "James" | James, userRenamed, not automatic |
| 5b | `carryNamesByOverlap` | old run: S1 "Jim" 0–60 s, S2 "Maria" 60–120 s; new run: X 0–58, Y 58–120 | rename+link actions for X "Jim", Y "Maria"; nothing unmatched |
| 5b | `carryNeedsHalfTheTalkTime` | old "Jim" overlaps new X for 30 % of the smaller talk time | Jim unmatched |
| 5b | `carryIsOneToOne` | two old named speakers both overlap X most | X gets the larger overlap; the other maps to its next choice or is unmatched |
| 5b | `carryCountsDroppedTurnEdits` | journal with 2 reassigns, 1 split | `droppedTurnEdits == 3` |
| 5c | `markdownShowsHeaderGapsAndMarkers` | 1 pause gap, 1 marker | header lines; `_[Recording paused …]_`; `_[Marker …: Vote]_` in time order |
| 5c | `consecutiveSameSpeakerTurnsExportAsOneBlock` | Jim turns at 10, 14, 19 s (pauses 2 s) | one Markdown block and one text header for Jim |
| 5c | `blocksBreakAtGapMarkerAndLongSilence` | same speaker around a marker; around a 40 s silence | separate blocks |
| 5c | `textMatchesEvaluatorAndRoundTrips` | 2 blocks at 65 s and 3725 s | headers `Jim  01:05` and `Speaker 2  1:02:05`; each matches the evaluator's header regex; `OtterTranscriptParser` returns the same names and starts |
| 5c | `jsonExportIsDeterministicAndHasNoVectors` | render twice | identical bytes; no key named `centroid`, `centroids`, `vector`, `embedding`, or `turnEmbeddings` at any depth |
| 5c | `autoLabelAndNoSuggestionsInExports` | automatic Jim; possible Maria for S2 | "Jim (auto)" in md/txt/json; "Maria" absent |
| 5c | `speakerlessExportUsesTrackNames` | no projection | names "Microphone" / "System audio" |
| 5c | `otterParserIgnoresFooterAndCountsWords` | sample with footer | 2 turns; counts only |
| 5c | `derZeroForIdentical` | same intervals | 0 |
| 5c | `derCountsConfusionAfterMapping` | ref A 0–10, B 10–20; hyp X 0–12, Y 12–20 | mapping A→X, B→Y; confusion 1.75 s (10.25–12 s; 9.75–10.25 s is inside the collar) |
| 5c | `collarExcludesBoundary` | boundary error of 0.2 s | 0 with collar 0.25 |

**Acceptance.** All tests pass after each of the three PRs; the target stays pure (above).

**Does not touch.** HolosStorage, HolosMeeting, HolosCLI, HolosApp, contract files,
`Models.swift`, README and `docs/status.md` (PR1 writes the wave-1 docs).

### 5.5 PR7a, PR7b, PR7c: Speaker labels after a recording (wave 2)

**Goal.** After a recording stops, produce a labelled transcript. PR7a: the FluidAudio
adapter, model install and verification, doctor/setup, notices. PR7b (parallel with
PR7a): rendering, the post-processor stages, exports, the snapshot, the timeline
reader, and `holos session diarize`, all tested with `FakeDiarizer`. PR7c (after both):
`session import`, `session score`, and the Otter speaker evaluation.

#### PR7a

**Files.**

- Add `Sources/HolosDiarization/`: `FluidDiarizer.swift`, `FluidModels.swift` (install,
  status, `ModelTreeDigest`), `PinnedModels.swift`, `Int16CAFSampleSource.swift`,
  `ModelPaths.swift` (`extension HolosPaths { static var models: URL }` =
  `supportRoot/Models`).
- Change `Sources/HolosCLI/PostProcessing.swift` (`makeMeetingPostProcessor` builds
  `FluidDiarizer` with `FluidDiarizerConfiguration.default.overridden(by:
  options.engineOverrides)` when `FluidModels.status() == .verified`, else `nil`),
  `Sources/HolosCLI/Doctor.swift` (model status line; `"speakerModels": "verified" |
  "notInstalled" | "damaged"` in `--json`; `setup --speakers`), `Package.swift` (§1.2
  wave 2).
- Add `THIRD_PARTY_NOTICES.md` (docs/meeting/post-processing.md §4.8).
- Tests: `Tests/HolosDiarizationTests/{ModelVerificationTests, SampleSourceTests, FluidDiarizerFixtureTests}.swift`.

**API:** §4.8.

**CLI.**

```
holos setup --speakers        # network; downloads, verifies, prints the credits line
holos doctor [--json]         # adds "Speaker models: verified | not installed | damaged (N files)"
```

`setup --speakers` prints progress to stderr and `Ready: speaker models (FluidAudio
0.17.1, speaker-diarization-coreml@df2625ac79a7).` plus the credits line.
`HOLOS_RECORD_MODEL_MANIFEST=1` prints the file manifest instead of verifying (the
one-time pinning step, §4.8).

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `modelStatusDetectsMissingCorruptAndWrongRevision` | temp folder, fake pinned list | `notInstalled`; `verified`; `corrupt([file])` after changing one byte; `corrupt([".fluidaudio-revision"])` with another marker |
| `treeDigestIsOrderIndependent` | same files created in different order | same digest |
| `installNeverLeavesPartialFolder` | install with an internal downloader seam that fails midway | nothing at the target; the partial folder removed |
| `sampleSourceReadsInt16CAF` | generated 16 kHz mono Int16 CAF with a ramp | `copySamples` returns the ramp ÷ 32768 at offsets 0, 1,000, and the last sample |
| `sampleSourceRejectsOtherFormats` | 48 kHz mono; 16 kHz stereo | throws |
| `configurationOverridesParse` | `["exclusiveSegments": "true", "clusteringThreshold": "0.7"]`; `["x": "1"]` | applied; the unknown key throws |
| `doctorJSONReportsSpeakerModels` | no models in `HOLOS_SUPPORT_DIR` | `"speakerModels": "notInstalled"` |
| `threeVoiceFixtureMeetsDER` (opt-in `HOLOS_DIARIZATION_FIXTURE=1`) | 3 system voices via `NativeSpeechRenderer`, 12 alternating 5–8 s turns, rendered to a 16 kHz Int16 CAF | 3 clusters; DER < 10 % (collar 0.25); prints runtime |

**Acceptance.** Tests pass; `holos doctor` runs without network; with models installed
the implementer runs the fixture and reports its numbers.

**Does not touch.** HolosMeeting, `Session.swift`, `MeetingPostProcessor.swift`,
`RecordingWorkflow.swift`, `Record.swift`, HolosAudio, contract files, HolosApp.

#### PR7b

**Files.**

- Add `Sources/HolosAudio/TrackRenderer.swift` (with `RenderTimeMap`).
- Add `Sources/HolosMeeting/PostProcessing/`: `SpeakerAnalysis.swift` (stages 2–6),
  `SessionExports.swift` (§4.11), `SpeakerSessionSnapshot.swift`,
  `SessionTimelineReader.swift`.
- Change `Sources/HolosMeeting/MeetingPostProcessor.swift` (§4.7 stages).
- Add `Sources/HolosCLI/SessionDiarize.swift`; change `Sources/HolosCLI/Session.swift`
  (add `Diarize.self`).
- Tests: `Tests/HolosAudioTests/TrackRendererTests.swift`;
  `Tests/HolosMeetingTests/{PostProcessorTests, SessionExportsTests, TimelineReaderTests, SnapshotTests}.swift`;
  `Tests/HolosMeetingTests/SessionFixtures.swift` (PR7b owns it in wave 2: a temporary
  finished session with generated chunks, a transcript with TimedWords, and a head-run
  builder that later waves reuse); PR7b also owns `Fakes.swift` edits in wave 2.

**API.**

```swift
// HolosAudio
public struct RenderSpan: Sendable, Equatable {
    public var renderStart: Double
    public var sessionStart: Double
    public var duration: Double
}
public struct RenderedTrack: Sendable, Equatable {
    public var url: URL
    public var track: String
    public var sampleRate: Double      // 16,000
    public var frameCount: Int
    public var timeMap: [RenderSpan]
}
public enum RenderTimeMap {
    public static func sessionTime(_ renderTime: Double, map: [RenderSpan]) -> Double
    /// Maps segments and windows to session time; splits anything crossing inserted silence (§4.7).
    public static func map(_ output: DiarizerOutput, map: [RenderSpan]) -> DiarizerOutput
}
public enum TrackRenderer {
    /// Joins a track's finalized chunks into one mono 16 kHz Int16 CAF. Channels are averaged; gaps up to
    /// `compressGapsLongerThan` are silence, longer gaps (and a long lead-in) become `keptSilence` seconds;
    /// one AVAudioConverter per contiguous run of chunks (reset at gaps). Checks cancellation per chunk.
    public static func render(session: URL, manifest: SessionManifest, track: String, to output: URL,
                              compressGapsLongerThan: Double = 60, keptSilence: Double = 5,
                              progress: (@Sendable (Double) -> Void)? = nil) throws -> RenderedTrack
}

// HolosMeeting
public struct SpeakerSessionSnapshot: Sendable {
    public let session: URL
    public let manifest: SessionManifest
    public let meeting: MeetingInfo            // meeting.json or MeetingInfo.inferred
    /// The head run's transcript when a run exists (§2.4); otherwise the current transcript.
    public let transcript: Transcript
    public let run: DiarizationRun?            // head run, nil when unusable
    public let journal: EditJournal
    public let recognition: RecognitionResult?
    public let projection: SpeakerProjection?
    public let gaps: [TimelineGap]
    public let markers: [TimelineMarker]
    /// A newer transcript exists than the one the run was built from.
    public let transcriptChanged: Bool
    /// Why the head run could not be used (missing transcript, invalid span), if so.
    public let runProblem: String?
    public let audioDeleted: Bool
    public let meetingInfoDamaged: Bool        // meeting.json damaged or of another session; inferred used
    public let recognitionUnreadable: Bool     // recognition result left out
    public let skippedEvents: Int              // event log lines/events the gaps and markers skipped
    /// Throws unavailable when the session has no transcript.
    public static func load(session: URL, profileNames: [String: String] = [:]) throws -> SpeakerSessionSnapshot
    public func exportDocument(timeZone: TimeZone = .current) -> ExportDocument
}
public enum SessionTimelineReader {
    /// Gaps from audioDiscontinuity events longer than 0.05 s. Reasons that are GapReason raw values map 1:1;
    /// timestampGap longer than 1 s → audioGap; formatChanged and shorter timestampGaps are ignored; any other
    /// reason longer than 1 s → audioGap. Within a gap, the stretch between `paused` and `resumed` events is
    /// `paused`, and between `systemWillSleep` and `didWake` is `sleep`. The same gap on both tracks merges into
    /// one with track nil. Markers from marker events. Tolerates torn and corrupt lines.
    public static func read(session: URL) throws -> (gaps: [TimelineGap], markers: [TimelineMarker])
}
```

**CLI.**

```
holos session diarize <path> [--force] [--speakers N | --min-speakers N --max-speakers N]
                             [--others-in-room | --no-others-in-room] [--keep-derived]
                             [--after-recording] [--keep-transcript] [--json]
                             # --keep-transcript: no language detection (§4.14), the review window's relabels
                             # hidden: [--exclusive-segments true|false] [--voice-data]
                             #         [--lease-fd N]
```

- Runs `MeetingPostProcessor` and prints `Labelled 11 speakers in 343 turns (run 5C1D…).
  Kept 8 names. Exports: <path>/exports`, or the `PostProcessingRecord` with `--json`.
  Refuses to replace an edited head without `--force`. Exit 0, 3 (partial), or 1.
- `--after-recording`: waits up to 30 s for the writer lock to be released, then takes
  the lease, unless `--lease-fd` is given.
- `--lease-fd N` (hidden; in-process hand-off, §4.1): adopts the inherited descriptor as
  the `ProcessingLease` instead of acquiring one. It validates that `fstat(N)` has the same
  device and inode as this session's lease file and that `flock(N, LOCK_EX | LOCK_NB)`
  succeeds (it does, idempotently, because the parent's lock belongs to the same open file
  description); otherwise exit 1 "The inherited lock is not this session's processing
  lease." It never re-acquires the non-reentrant lease, and it releases the lock by
  closing N when it exits. Tests (PR7b): `diarizeAdoptsInheritedLease` (a test process
  holds the lease, spawns the command with the descriptor at fd 3, closes its copy;
  post-processing runs and `isProcessing` stays true until exit),
  `diarizeRefusesForeignLeaseFd` (fd 3 is another session's lease → exit 1, nothing
  changes).
- `--voice-data` sets `forceVoiceData` (evaluation sessions only). `--exclusive-segments`
  sets `engineOverrides`.
- Without verified models: exit 1 with the setup hint; nothing changes.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `rendererFillsShortGapsWithSilence` | mic chunks: 1 kHz tone 0–1 s and 3.5–4.5 s at 48 kHz | 72,000 frames; RMS ≈ 0 in 1.05–3.45 s; tone present in both chunks |
| `rendererCompressesLongGaps` | chunks 0–10 s and 200–210 s | 25 s render (10 + 5 + 10); two spans; render 16.0 s ↔ session 201.0 s |
| `timeMapSplitsSegmentsAcrossCompressedGap` | render segment 8–17 s | session segments 8–10 s and 200–202 s |
| `rendererKeepsSessionTiming` | a click at 2.0 s inside the second chunk | output peak at frame 32,000 ± 32 (±2 ms) |
| `rendererDownmixesStereo` | L = R = 0.5 constant | output ≈ 0.5 (Int16 step tolerance) |
| `rendererRejectsMissingChunk` | manifest entry without file | throws |
| `rendererTrimsOverlappingChunks` | legacy manifest with chunk 2 starting 0.2 s before chunk 1 ends | chunk 2's first 0.2 s skipped; output length equals the timeline span; no sample written twice |
| `postProcessorWritesRunHeadAndExports` | fixture (manifest, 20 s audio, transcript with 2 speakers' words) + `FakeDiarizer.alternating` | run, `head.json`, `transcript.{md,json,txt}` (0400), `.generated.json`, `postprocess.json` succeeded, `derived/` empty, **no** `speakers/voice/` |
| `voiceDataOnlyWhenForced` | `forceVoiceData: true` | `speakers/voice/<run>.json` exists, 0600, excluded from backup |
| `rememberOnStoresNoVoiceData` | "Remember voices" on (PR10 store), no `forceVoiceData` | no `speakers/voice/`; `recognition.json` has distances only |
| `missingDiarizerSkipsSpeakersButExports` | `diarizer: nil` | state succeeded; diarize stage skipped with the setup hint; exports use track names; no run |
| `diarizerFailureIsRecorded` | FakeDiarizer with error | diarize stage failed; exports written; state partial |
| `diskLowStopSkipsRender` | `stopReason: .diskLow` | render skipped with the disk message; exports written; state partial |
| `lowFreeSpaceSkipsRender` | `FixedFreeSpace(500 MB)` | same |
| `callWithoutOthersInRoomMakesMicMe` | meeting.json call, othersInRoom false; mic+system transcript | mic policy channel mic:me; system diarized |
| `othersInRoomOverride` | meeting.json false; option true | mic diarized; `postprocess.json` `othersInRoom: true` |
| `editedHeadNeedsForce` | run with a rename; rerun without and with `force` | first: speaker stages skipped with the message; second: new run, head moved, the name carried (a `carry` line), old edits counted as other-run |
| `changedTranscriptRelabels` | head built from transcript A; pointer now B | new run from B; names carried |
| `snapshotLoadsRunTranscriptAndFlagsChange` | head from A, current B, no relabel yet | `snapshot.transcript.id == A`; `transcriptChanged` |
| `invalidSpanMakesRunUnusable` | run with a span past the word count | `runProblem` set; exports speaker-less; no trap |
| `derivedClearedAtStartAndEnd` | leftover `derived/x.caf`; failing diarizer | `derived/` empty afterwards |
| `secondProcessorRefusedWhileLeaseHeld` | lease held by the test; `run(lease: nil)` | throws `unavailable` |
| `usesGivenLease` | `run(lease: L)` | does not acquire another; `L` still held afterwards |
| `refusesActiveRecording` | writer lock held | throws "still recording" |
| `regenerateMovesHandEditedExportAside` | make `transcript.md` writable and append a line; regenerate | `edited-<timestamp>.md` holds the edit; new `transcript.md` is 0400; `movedAside` has 1 URL |
| `regenerateLockedRunsInsideTheLock` | inside `withSpeakerLock`, call `regenerateLocked` | succeeds (plain `regenerate` there would time out) |
| `timelineReaderMapsEveryReason` | discontinuities `paused` (both tracks), `sleep`, `deviceChanged`, `captureRestarted`, `audioUnavailable`, `overflow`, `timestampGap` 0.4 s and 2 s, `somethingNew` 3 s; 2 markers | gaps with those reasons; 0.4 s ignored; 2 s and `somethingNew` → `audioGap`; paused merged with track nil; 2 markers |
| `timelineReaderSplitsGapAtPauseEvents` | `audioUnavailable` gap 100–200 s with `paused` at 120 and `resumed` at 180 | gaps 100–120 `audioUnavailable`, 120–180 `paused`, 180–200 `audioUnavailable` |
| `diarizeWithoutModelsChangesNothing` | CLI builder returns nil diarizer | exit 1 with the hint; no files changed |

**Does not touch.** HolosDiarization, `PostProcessing.swift`, `Doctor.swift`,
`Package.swift`, `RecordingWorkflow.swift`, `LiveTrack.swift`, `TrackReplayer.swift`,
`Record.swift`, `ChunkWriter.swift`, `AudioCapture.swift`, contract files, HolosApp.

#### PR7c (after PR7a and PR7b merge)

**Files.**

- Add `Sources/HolosMeeting/SessionImporter.swift`,
  `Sources/HolosCLI/{SessionImport, SessionScore}.swift`; change
  `Sources/HolosCLI/Session.swift` (add `Import.self`, `Score.self`),
  `scripts/evaluate-references.swift` (`--speakers`, `--calibrate`).
- Append "PR7c results" to `docs/speaker-evaluation.md` (numbers only).
- Tests: `Tests/HolosMeetingTests/SessionImporterTests.swift`.
- Docs: PR7c merges last in wave 2 and writes the wave-2 `README.md` and
  `docs/status.md` notes for PR7a–c and PR2a–b.

**API.**

```swift
public enum SessionImporter {
    /// Creates a session from an audio file: track "mic", channels averaged to mono, source sample rate,
    /// Int16 chunks through AudioChunkWriter, meeting.json {mode: inPerson, origin: imported}, vocabulary.json;
    /// transcribes with TrackReplayer unless `transcribe == false`; finishes as complete or audioOnly.
    public static func importAudio(from file: URL, name: String, root: URL, locale: String, backend: SpeechBackend,
                                   vocabulary: [String] = [], transcribe: Bool = true,
                                   makeSpeech: LiveSpeechFactory? = nil,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL
}
```

**CLI.**

```
holos session import <audio-file> [--name NAME] [--directory D] [--locale L] [--backend B]
                                  [--vocabulary-file FILE] [--no-transcribe] [--no-postprocess]
holos session score <path> --otter <transcript.txt> [--collar 0.25] [--json]     # hidden
```

- `session import` prints the new session path on stdout.
- `session score` prints only numbers: reference speakers, Holos speakers, agreement
  confusion, compared seconds, mapping size. With `--json`, the mapping is keyed by
  the first 12 hex characters of the SHA-256 of each Otter label, so scripts can match
  people across files without printing names. It never prints text. It fails rather
  than print zeros when nothing can be compared: no audio, no speaker segments, Otter
  times that go backwards or start after the audio ends (another recording), no Otter
  turn inside the audio, every turn inside the collar, or no overlap. A run without
  labelled turns reports the turn score as not comparable.
- `scripts/evaluate-references.swift --speakers` (with `--reference-format otter`): for
  each pair, `holos session import` (transcribed once) into
  `.local/evaluation/<run>/sessions`, then for each configuration `holos session diarize
  --force` and `holos session score --json`: default (`exclusiveSegments` false);
  `--exclusive-segments true`; and `--min-speakers n−1 --max-speakers n+1` where n is the
  number of Otter labels with at least 30 s. Report per pair and configuration
  `referenceSpeakers`, `holosSpeakers`, `agreementConfusion`, `comparedSeconds`,
  `diarizationSeconds`, peak RSS, and the track offset from `AlignmentInfo`, labelled
  "agreement with Otter". `--calibrate` diarizes 001 and 003 with `--voice-data`, maps
  clusters to hashed labels, and reports same-person and different-person centroid
  cosine distances (count, 5th, 50th, 95th percentile). Sessions are deleted unless
  `--keep-sessions`.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `importCreatesCompleteSession` | 10 s stereo 44.1 kHz WAV generated in the test; FakeSpeech | mono mic chunks at 44.1 kHz; `meeting.json` imported; status complete; pointer set |
| `importPassesVocabulary` | `vocabulary: ["Maria Chen"]` | FakeSpeech saw it; `vocabulary.json` written |
| `scoreJSONHasNoNames` | fixture session + Otter-format text with names | output contains numbers and hashed keys only; no label text |

**Acceptance (run by the implementer with models installed).** The Otter evaluation
above and the calibration run; numbers recorded in `speaker-evaluation.md` and the PR
description (counts and metrics only): runtime, peak RSS (`/usr/bin/time -l`),
agreement confusion per configuration, speaker counts, track offsets, and calibration
percentiles. The `exclusiveSegments` default follows docs/meeting/post-processing.md §4.8. Temporary sessions and audio
are deleted.

**Does not touch.** HolosDiarization, `MeetingPostProcessor.swift`, HolosAudio,
`RecordingWorkflow.swift`, contract files, HolosApp.
