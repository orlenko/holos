# People and voices

People, voice data and recognition (§4.10). §5.9 comes from the build plan and names the PR that built it; the
code cites it for behaviour.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.10 People, voice data, recognition (PR10)

Names are not biometric; voiceprints are. The design keeps them apart.

`Sources/HolosCore/VoiceProfiles.swift` (PR10, new):

```swift
public enum RecordingCondition: String, Codable, Sendable { case room, call }

public struct VoiceprintSample: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionID: String
    public var sessionName: String
    /// Speakers in that session the sample was built from (after merges).
    public var speakerIDs: [String]
    public var speechSeconds: Double
    public var embedding: FloatVector            // L2-normalized
    public var condition: RecordingCondition
    /// speechSeconds < thresholds.minSampleSeconds; cannot produce `likely`.
    public var weak: Bool
    /// Turns dropped by the outlier pass.
    public var droppedOutlierTurns: Int
    public var addedAt: Date
}

public struct SpeakerProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var createdAt: Date
    /// Updated when the person is linked in a meeting; orders the name list.
    public var lastUsedAt: Date
    /// The user ("This is me").
    public var isSelf: Bool
    /// Set with the first sample; samples from another model are refused.
    public var embeddingModel: EmbeddingModelID?
    public var recognitionEnabled: Bool
    public var samples: [VoiceprintSample]       // at most one per sessionID; may be empty
}

public struct SpeakerProfileDatabase: Codable, Sendable, Equatable {
    public var schemaVersion: Int                // 1
    /// On in a new store; an existing store keeps its value. Governs voice samples, per-session voice data, and
    /// recognition. Never names.
    public var rememberVoices: Bool
    /// Set by `holos people calibrate --apply`; `likely` exists only when this is set, and only for runs of
    /// `calibratedModel`.
    public var calibratedThresholds: RecognitionThresholds?
    /// The embedding model the thresholds were measured on; set with them.
    public var calibratedModel: EmbeddingModelID?
    public var profiles: [SpeakerProfile]
    /// When a change to the samples last cleared the calibration; nil after `calibrate --apply`.
    public var calibrationResetAt: Date?
}
```

- **Store.** `SpeakerProfileStore` (HolosStorage) at `HolosPaths.speakerProfiles`
  (`<support>/Speakers/`, 0700, excluded from Time Machine with
  `URLResourceValues.isExcludedFromBackup`; `profiles.json` 0600). `load()` returns an
  empty database (`rememberVoices: true`, the default for new installs since
  2026-10-06) when the file is missing; an existing `profiles.json` keeps the value it
  has, so a store saved off, by the user or under the earlier off default, stays off.
  `update(_ body: (inout SpeakerProfileDatabase) throws -> T)` takes `profiles.lock`
  (2 s), reads, mutates, validates (unique IDs, one sample per session per profile,
  one `isSelf`, finite sample values, and calibrated thresholds that are finite, in
  range, `likely ≤ possible`, with a margin of 0 … 2, a non-negative minimum length,
  and a calibrated model only with thresholds), and writes atomically; `load()` applies
  the same validation and refuses a damaged store. Centroids are computed, never stored.
  When the write changes the sample population (a sample learned, refreshed into another
  vector, moved by a merge, or forgotten in any scope, or a person's embedding model), the
  same write clears `calibratedThresholds` and `calibratedModel` and sets
  `calibrationResetAt` (`SpeakerProfileDatabase.resetCalibrationIfSamplesChanged`), unless
  the write saved new thresholds itself; `holos people list`, the People window, and the
  CLI commands that changed samples say the calibration was reset.
  `withLockedDatabase(_:)` takes `profiles.lock`, reads, and runs its body with the lock
  held, writing nothing to the store: for a write elsewhere made from the people.
- **Snapshot, then write.** Every operation that computes from an unlocked read and then
  writes either computes inside the locked update (merge, rename, suggestions, `calibrate
  --apply`, the store step of every forget) or checks under the lock that its inputs are
  unchanged and otherwise starts again: enrollment and refresh publish only when the
  speaker generation is unchanged and the store still gives the same sample plan;
  recognition compares again and writes its result while holding the speaker lock and then
  `profiles.lock` (`withLockedDatabase`, the ../conventions.md §1.7 order), so every store change (a
  suggestion or Remember voices setting, a merge, a forget, a sample, a calibration) is
  either reflected in the result or made after it is written; a forget's per-meeting
  clean-up reads the people the same way. Nothing takes a speaker lock while holding
  `profiles.lock` (a forget releases it before cleaning meetings). The first
  run of a forget removes every sample matching its scope at its store write (`.all`:
  every sample; `.session`: every sample of the meeting; `.profile`: the person;
  `.sample`: the sample).
- **Incomplete edit journals.** When `edits.jsonl` has a torn or unreadable line, a
  meeting's labels may miss a link, a rejection, or a reassignment: no voice sample is
  learned, recomputed, or removed from them (`unavailable`, said once there is
  something to do), recognition results are not applied to the projection (no
  suggestion, no automatic name), and "Confirm all" is refused.
- **People without voiceprints.** Linking a speaker to a person always creates or links
  the profile, whatever the setting, so names carry across meetings: the review
  window's name field is a combo box of known people (most recently used first) and the
  turn pop-up lists them. "This is me" links a speaker to the `isSelf` profile (created
  on first use with `NSFullUserName()`, editable). The People window lists people even
  when "Remember voices" is off.
- **No stored voice data for unconfirmed people (Codex review of PR #4).** Post-processing
  never persists embeddings, whatever the setting: centroids and turn embeddings exist
  only in memory during stages 6–7, and recognition (stage 7) uses them there and stores
  distances only. `speakers/voice/<runID>.json` is written only with the hidden
  `forceVoiceData` (evaluation sessions). A voiceprint reaches disk only as a profile
  sample, and only for a speaker the user confirmed as a person with voice learning on.
  The review window's voice pass ("Voices within one meeting" below) keeps every turn's
  embedding in memory while the window is open and writes none.
- **Voice sample extraction on demand.** `VoiceSampleExtractor` (protocol in HolosMeeting,
  PR10) returns turn embeddings for exactly the turns it is asked about:

  ```swift
  public protocol VoiceSampleExtractor: Sendable {
      /// Renders the track, extracts embedding windows, and returns one embedding per
      /// requested turn that has enough clean speech. Every other window is discarded in memory.
      func turnEmbeddings(session: URL, track: String, turns: [TurnRef]) async throws -> [TurnEmbedding]
  }
  ```

  `FluidVoiceSampleExtractor` (HolosDiarization, PR10) renders the track with
  `TrackRenderer`, runs a fresh FluidAudio pass with `exposeChunkEmbeddings` (same model
  and configuration as the run), and selects vectors **by speaker slot first, then by
  time**. FluidAudio emits one `ChunkEmbedding` per (10 s window, local speaker slot), and
  two people in one window share the same window bounds, so time alone cannot separate
  them. For each requested turn:
  1. Map the turn to the fresh pass's speaker: the `speakerId` whose fresh segments
     overlap the turn's time the most. If that overlap is under 60 % of the turn's
     duration, or a second fresh speaker overlaps the turn by more than 25 %, the turn gets
     no embedding (it is not clean single-speaker speech).
  2. Take only `ChunkEmbedding`s with that `speakerId` whose window overlaps the turn,
     weighted by overlap seconds, as `TurnEmbeddings.compute` does (windows are about
     10 s, longer than most 2–9 s turns, so containment would leave ordinary turns
     without an embedding). L2-normalize.
  3. All other vectors, including every other speaker slot in the same windows, are
     discarded in memory; the render is deleted.

  Tests (PR10): `extractorUsesOverlappingWindowsForShortTurns` (a 3 s turn inside a 10 s
  window gets an embedding), `extractorIgnoresOtherSpeakerSlotInSharedWindow` (two slots in
  one window with orthogonal vectors; the turn's embedding equals its own slot's vector),
  `extractorSkipsTurnsWithoutADominantSpeaker`. The app never links FluidAudio: its
  extractor, `SubprocessVoiceSampleExtractor` (HolosMeeting), runs the bundled hidden
  `holos speakers embed <session> --track <t> --turns <id,id,… | -> --json`, which prints the
  turn embeddings as JSON on stdout (a pipe, never a file) and writes nothing. The app
  passes each turn as `ID@start-end`, its exact span, one per line on stdin (`--turns -`); a bare ID is resolved against the
  current labels.
  `VoiceProfileService` is the only code that turns embeddings into a stored sample. The
  CLI's own `link`/`me` commands inject `FluidVoiceSampleExtractor` directly. Extraction needs the
  session's audio: after Delete Audio, linking keeps the name and says "The recording's
  audio was deleted, so this voice can't be learned." `refreshSamples` re-extracts the
  affected `(profile, session)` samples the same way. Meetings processed while Remember
  voices was off need nothing special: confirming a person later extracts on demand.
- **Forgetting is resumable.** What a forget lists and the tombstone that records it are
  one locked step (`SpeakerProfileStore.appendForgetRecord(listing:)`), so no merge can
  move a sample out from between them, and a merge that starts afterwards is refused while
  the forget is unfinished. Every forget operation first appends a tombstone to
  `Support/Speakers/forget-journal.jsonl` (0600, fsync; `{id, kind, profileID?, sampleIDs,
  sessionIDs, turnRememberOff?, state: "pending"}`), then updates the profile store, then
  appends `{id, profileID?, state: "stored"}`, then cleans each affected session under its
  speaker lock (drops every reference to the profile from each recognition result, that is
  its matches, merge suggestions, and `skippedProfiles` entries, through the one helper
  `RecognitionResult.removeProfiles`; removes any evaluation voice file entries;
  regenerates exports), then appends `{id, state: "done"}`.
  `VoiceProfileService.resumePendingForgets(store:sessionsRoot:)` runs at app launch and
  at the start of every `holos people`, `speakers`, and `session` command (except the
  read-only `session echo-label-stats`, `ForgetResumeScope`) and finishes any
  pending tombstone; each step is idempotent, so a crash at any point leaves nothing
  behind once the next run completes.
  - The `stored` line is what tells a resumed forget which phase it is in, rather than the
    caller. While it is missing, the store write is still owed in full: it turns "Remember
    voices" off when the tombstone asked for that, and it removes every sample the scope
    covers in the store at that write, not only the IDs the tombstone listed. Once it is
    there, a later run removes only the listed samples and never touches the setting
    again, so a forget that keeps failing on one meeting cannot undo the user turning
    remembering back on or take a sample learned since. A crash between the store write
    and its `stored` line makes the next run sweep once more, which forgets slightly more
    than it had to, never less.
  - A `cleaned` line follows, once every meeting's voice data and recognition results are
    done, and before any exported transcript is rewritten. The forget visits the meetings
    twice for that reason: scrubbing them all, then rewriting the exports of those that
    owe one. A rewrite that ran while the forget still held recognition back would have
    dropped every other person's automatic name from that meeting for good. Nothing Holos reads
    names the forgotten person from then on, so `recognitionAllowed` stops waiting on that
    tombstone: a meeting whose manifest cannot be read keeps its forget pending for a
    readable one without suppressing voice suggestions everywhere in the meantime.
  - Every forget's store write bumps `SpeakerProfileDatabase.forgetEpoch`, whatever it had
    left to remove, and `syncSamples` publishes a voice sample only while that counter is
    the one its plan was made on; the hidden `--voice-data` evaluation pass checks it too,
    under the speaker lock, before writing a voice file. Comparing the samples cannot see a
    forget when the person had none from this meeting either way, which is exactly a first
    enrollment. A refresh that loses the race says nothing; a voice the user asked to learn
    is reported as not saved and is not tried again, since a retry would put back what they
    have just forgotten. `perform` acts only on a tombstone the journal still holds as
    unfinished, so replaying a finished one changes nothing at all.
  - A link naming somebody the store no longer holds counts as the forgotten person's,
    because a merge moves the samples and leaves the meeting's link as it was — unless
    `mergedInto` says where that person went and they are still there, which means a merge
    is retargeting its meetings and those links are somebody else's.
  - Whose a speaker is, for the voice data, is `ProjectedSpeaker.effectiveProfileID`: the
    linked person, else the one a `likely` match named automatically. So a meeting that
    names somebody through a match alone still gives up their voiceprints, and a "Not Jim",
    a link to somebody else or an explicit name takes that back, without the forget
    repeating any of those rules. The voice data is therefore cleaned before the matches
    are scrubbed, and each run is read with its own result, since a speaker ID means
    something only inside its run. A result that cannot be read leaves the question
    undecidable, so that meeting's voice data goes; so do labels written by a newer Holos,
    which is the one place `unavailable` is not a reason to keep a file.
  - The `stored` line also records the person the meetings are cleaned of: for a `.sample`
    or `.profile` forget, the person the store write found the listed samples under, which
    a merge may have changed since the tombstone was written. Cleaning with the tombstone's
    own ID would then miss the person the samples moved to, whose matches a merge has
    already retargeted.
  - Compaction keeps a `stored` line while its tombstone is kept, and, like an unmatched
    `done` line, whenever some line cannot be read here: that tombstone may be one of them
    (a newer Holos's forget kind), and dropping its marker would have that Holos run its
    store write a second time.
  - The exports of a cleaned meeting are rewritten because they show the names recognition
    gave, and a failure there keeps the tombstone pending. Whether the rewrite is owed
    cannot be read back from the recognition file the run has already scrubbed, so
    `.profile` rewrites every meeting that has recognition results and `.all` every
    meeting whose exports Holos generated; the rewrite itself only writes files that
    differ.
  - A forget also removes atomic-write leftovers (`.<token>.tmp`) from the Speakers
    folder: one holds a whole copy of the database, voiceprints and all, that a kill
    between an fsync and a rename left behind.
  - When a forgotten person's turn was won by a cluster that is not one of their speaker's
    (the user reassigned it, or moved it to a speaker they made), that cluster's centroid
    holds their voice and cannot be told apart from the rest of the cluster's, so the
    meeting's evaluation voice data is deleted instead of filtered.
  A `.profile` forget owes its meetings' exported transcripts on every run, not only when
  it found recognition results: an earlier attempt may have scrubbed or deleted the files
  that would say a rewrite is still due.
  Tests (PR10): `forgetResumesAfterCrashBetweenStoreAndSessions` (failure injected after
  the store update; resume removes every reference), `forgetJournalReplayIsIdempotent`,
  `aForgetThatCrashedBeforeItsStoreWriteStillTurnsRememberingOff`,
  `aResumedForgetLeavesRememberingAndNewerSamplesAlone`,
  `forgettingASampleFollowsItToThePersonItWasMergedInto`,
  `forgetStaysPendingUntilTheExportsAreRewritten`,
  `forgetDeletesVoiceDataWhoseCentroidStillHoldsAReassignedTurn`,
  `leftoverTemporaryFilesArePurgedFromTheStore`,
  `compactionKeepsAStoredLineWhoseTombstoneThisBuildCannotRead`,
  `aVoiceForgottenWhileItWasLearnedIsNotPutBack`, `forgetJournalReplayIsIdempotent`,
  `forgetCleansMeetingsWhoseManifestCannotBeRead`.
- **A merge takes the meetings with it.** Merging person A into B removes A from the
  store, and a projection drops a recognition match whose person is not in the store, so
  the meetings A's voice was recognised in would lose their automatic name (or
  suggestion) rather than showing B. `VoiceProfileService.merge` therefore journals a
  `.merge` record (`{id, kind: "merge", profileID, targetProfileID, state: "pending"}`) in
  the forget journal before its store write, then points every meeting's recognition
  results at B under that meeting's speaker lock (`RecognitionResult.retargetProfiles`:
  matches, merge suggestions and `skippedProfiles`, joining what the merge made one
  person; the nearer match wins where a speaker then names B twice) and rewrites the
  generated exports of the meetings that changed. A meeting that cannot be written now
  leaves the record pending and `merge` throws `incomplete`; `resumePendingForgets`
  finishes it, which is why the record carries the two IDs the store no longer holds
  together. A `stored` line is appended only once the store write has committed, and
  nothing is retargeted without it: the record is written before that write, so a merge
  refused there (samples of different speaker models) or lost to a crash leaves a record
  that a resume drops rather than acts on. Which of the two it was comes from the store,
  not from the missing marker, and not from the person's absence either: a merge records
  what it did in the same write that removes the person
  (`SpeakerProfileDatabase.mergedInto`, source ID -> target ID), because a forget or
  another merge leaves the same shape behind. A resume that finds its own entry there
  writes the marker the crash cost it and finishes the meetings. That map is also how the
  destination is followed onwards (`A -> B` then `B -> C` retargets `A` to `C`, at most
  `mergeChainLimit` steps and never around a cycle), so only merges that committed are
  followed; a destination no longer in the store drops the record. The map is kept rather
  than cleared: clearing it raced with the next merge's own commit, and it is resolved
  again for each meeting, because another window can merge the destination onwards while a
  pass is running. A merge is also refused while a `.profile` forget of either person is
  unfinished (checked in the merge's own locked write): that forget removes the samples it
  listed, and one learned since and moved by the merge would survive on the other person. Unlike a forget, this never deletes what it cannot
  read: a meeting is skipped only when its manifest is absent (ENOENT or ENOTDIR; any other
  inspection failure keeps the record pending), a recognition folder holding an entry this
  build does not know keeps it pending too, and a recognition result that cannot be read
  keeps the record pending for a Holos that can read it. The exports
  of every meeting that has recognition results and generated exports are rewritten, not
  only of those a run changed, since a retry finds them already retargeted. Tests (PR10):
  `mergePointsMeetingsAtThePersonTheyWereMergedInto`,
  `aMergeThatCouldNotReachAMeetingIsFinishedLater`,
  `retargetingProfilesJoinsWhatTheMergeMadeTheSamePerson`,
  `aMergeWhoseStoreWriteNeverHappenedIsDroppedNotReplayed`,
  `aMergeStaysPendingWhenAMeetingsRecognitionCannotBeRead`,
  `aMergeStaysPendingUntilTheExportsAreRewritten`,
  `aMergeThatCommittedBeforeItsMarkerIsStillFinished`, `aPersonAMergeAdoptedIsNotRolledBack`,
  `forgettingAPersonFollowsTheirSamplesThroughAMerge`,
  `aMergeIsNotRecoveredWhenSomethingElseRemovedItsSource`,
  `aMergeChainFollowsOnlyCommittedMerges`,
  `aMergeStaysPendingWhenAMeetingHoldsUnknownRecognitionFiles`,
  `aMergeStaysPendingWhenAMeetingFolderCannotBeInspected`,
  `aMergeWaitsWhileOneOfItsPeopleIsBeingForgotten`, `whatAMergeRemovedIsKeptForLaterChains`.
- **A no-op is decided on the current labels, and still finishes what an earlier run
  left.** `SpeakerEditor.applyUnlessUnchanged` makes that decision under the speaker lock,
  and linking, `speakers reject` (`VoiceProfileService.reject`, which returns nil for it)
  and the other `holos speakers` commands all go through it rather than testing the
  caller's view. A confirmed no-op then still runs the sample refresh, because the run
  before it may have saved its edit and failed to bring the samples in step, which would
  leave a voiceprint holding speech the edit moved to someone else; the refresh is decided
  by input digests, so it costs nothing when they are already in step. Tests (PR10):
  `aRejectionThatChangesNothingIsDecidedOnTheCurrentLabels`; the CLI half has no test
  target (`HolosCLI`).
- **A link is saved against the people and the labels as they are at the write.** The
  batch's people are checked and marked used under `profiles.lock`, inside the meeting's
  speaker lock, immediately before the lines are appended
  (`SpeakerEditor.apply(requirePeople:)`), so a person another window forgot or merged
  away is refused instead of being linked to by a meeting, and so is one another window
  renamed: the batch's lines and the caller's view were both made from the name the user
  saw, so saving a different one would give the meeting a name they never chose. A batch the caller's view says
  changes nothing appends no line, so it is checked against the meeting's current labels
  under the speaker lock instead of being reported as success. A person created for a link
  that is then refused is taken back only while nobody has taken them up: no samples, and
  still `provisional`, the state such a person is created with. It is cleared by any store
  write that changes them, and by the operations that take a person up without necessarily
  changing anything about them: a merge into them (the target of a merge from a person
  with no samples can come out byte for byte the same), a rename, a suggestions setting,
  and the locked claim of a saved link. The state is explicit because `HolosJSON` stores dates to the
  second, so `createdAt` and `lastUsedAt` cannot tell a person another window linked
  inside that second from one nobody has touched. Tests (PR10): `anEditIsRefusedWhenThePersonItLinksIsGone`,
  `aLinkThatChangesNothingIsRefusedWhenAnotherWindowChangedIt`,
  `aPersonAnotherLinkHasTakenUpIsNotRolledBack`, `aRefusedNewPersonIsStillRemoved`,
  `aLinkIsRefusedWhenThePersonWasRenamedMeanwhile`, `anEditThatNeedsWholeLabelsIsRefusedUnderTheLock`.
  `confirmAll` also asks the editor to refuse under the lock when the meeting's edit journal
  has a line this build cannot read (`requireCompleteJournal`): its suggestions were read
  from labels such a line may contradict, and another Holos can append one between the
  caller's own check and the lock.
- **"Remember voices" governs recognition, not only new voice data.** Turning it off
  without forgetting the samples keeps them, and the People window promises that "Kept
  samples are not used while Remember voices is off." `SpeakerSessionSnapshot.load`
  therefore takes `applyRecognition`, and with it false neither reads nor applies the
  meeting's stored recognition result, exactly as it does for an incomplete edit journal:
  no suggestion and no automatic name, in the review window, the CLI, or the exports. The
  callers that read the people store pass `VoiceProfileService.recognitionAllowed` (the
  editor's reload and export rewrite, the forget and merge export rewrites,
  post-processing's export write, `holos speakers`, `holos session export`, the Meetings
  window's Save As, and `VoiceProfileService.reject`, which takes the store for it). Nothing is
  deleted, so turning the setting back on brings the suggestions back. Names are not
  governed by the setting, as they never were. `recognitionAllowed` is also false while
  any forget other than a merge has not reached its `cleaned` line, and while the journal
  holds a line this build cannot read (a newer Holos's forget, which cannot be resumed or
  accounted for here): a crash between a forget's store write and
  its meetings leaves results naming people it was meant to remove, and
  `resumePendingForgets` clears them in the background, so until it has, those results are
  not shown or exported. Tests (PR10): `keptSamplesAreNotUsedWhileRememberVoicesIsOff`,
  `recognitionIsNotUsedWhileAForgetIsUnfinished`,
  `recognitionIsNotUsedWhileAForgetLineCannotBeRead`.
- **A person created for a link is taken back only by the call that created them.** They
  are created `provisional`; `claimPeople` leaves a call's own creations alone until its
  lines are appended, and the call takes them up afterwards, so a link refused in that run
  removes them (`rollBack`) and one that is saved keeps them. Nothing removes a person on
  the strength of the flag alone. A launch sweep used to, and it was the wrong trade: a
  crash between saving a link and clearing the flag would have cost that meeting its
  person, which is worse than the leftover it cleaned. So a crash between creating the
  person and saving the link leaves a person in People with no meetings, which the user can
  remove and which nothing else acts on. Tests (PR10):
  `aPersonStaysUnfinishedUntilTheirLinkIsSaved`, `aPersonIsTakenUpEvenWhenTheLinkReportsAFailure`.
- **A name a meeting was already given keeps it.** Calibration governs the decisions
  recognition makes, not the ones it has made: resetting it (a sample changed) stops new
  meetings being named automatically, and a meeting whose stored result already names
  somebody `likely` keeps showing and exporting that name. `holos people list` says so in
  those words, since "automatic names: off" on its own would claim more than Holos does.
  Demoting stored decisions would mean rewriting every meeting's recognition result on
  every sample change, and would take back a name the user has already seen and kept.
- **Accepted races.** Two user-initiated Holos operations on the same data, started in
  different windows inside the same lock-free window, can interleave in ways Holos does not
  coordinate. ../conventions.md §1.7 is not the reason: it excludes a hostile process running as the user,
  and Holos does defend against its own concurrent processes elsewhere. These are listed
  once, deliberately, rather than answered with more coordination:
  - `holos session export --all` reads "Remember voices" before it takes the meeting's
    speaker lock, so an export that began just before `holos people remember off` (without
    forgetting the samples) can write automatic names after the setting changed. Turning
    the setting off schedules no rewrite, so those names stay in that meeting's exported
    files until it is exported again. The samples themselves are untouched, and any later
    export writes them without names. Stage 8 of automatic post-processing reads it the
    same way and has the same window; the recording that runs it is the user's too.
  - Merging a person visits the meetings under the meetings root. A `.holos` folder kept
    elsewhere and worked on by path is not one Holos can enumerate, so its recognition
    results keep naming the person merged away and lose that automatic name, as they did
    before merges retargeted anything. `mergedInto` records where that person went, so
    such a meeting can be repaired later without guessing; nothing reads it for that yet.
- **Enrollment renders are swept.** `DiarizerVoiceSampleExtractor` renders a track to
  `holos-voice-<UUID>` in the temporary directory and deletes it in a `defer`, which a kill
  or a power loss skips; the render is a decoded copy of the meeting's audio, so
  `removeStaleRenders` removes such folders older than six hours (at most 64 per run) at
  app launch and at the start of every `holos people`, `speakers`, and `session` command.
  Test (PR10): `leftoverVoiceRendersAreSweptOnceTheyAreOldEnough`.
- **Recognition** (`SpeakerRecognizer.recognize`, HolosSpeakers, pure; stage 7, only
  with "Remember voices" on):
  1. Candidates: machine speakers of diarized tracks with a centroid. Condition: `system`
     track → `call`; `mic` track → `room`.
  2. Profiles: `recognitionEnabled`, with samples, same `embeddingModel` as the run;
     others go to `skippedProfiles`.
  3. Distance(speaker, profile) = minimum cosine distance (1 − cosine similarity) to the
     profile's non-weak samples of the same condition. If there are none, use its other
     samples and cap the tier at `possible`.
  4. Thresholds: `database.calibratedThresholds(for: run's embedding model) ??
     SpeakerRecognizer.defaultThresholds` (calibrated thresholds apply only to runs of the
     model they were measured on, `calibratedModel`).
     **`likely` is possible only with calibrated thresholds for the run's model.** With the
     default thresholds the recognizer never produces `likely`, whatever the distance
     (an identical vector has distance 0, so a zero threshold alone would not prevent it).
     So **v1 only suggests** (`possible`, shown as "Maybe Jim — Confirm"); nothing is
     applied automatically until calibrated. `defaultThresholds.likelyMaxDistance` stays 0
     only as a stored value.
     `possibleMaxDistance` comes from PR7c's cross-recording measurement (below); until
     PR10 sets it from those numbers, use 0.40. `likelyMinMargin` 0.10,
     `minSampleSeconds` 20. FluidAudio's 0.65 (`SpeakerManager.speakerThreshold`) does
     not apply: it belongs to the streaming pipeline and an older embedding model, and
     the offline clustering threshold of 0.6 Euclidean on unit vectors is about 0.18
     cosine distance.
  5. `likely` requires calibrated thresholds, distance ≤ `likelyMaxDistance`, the next-best profile at least
     `likelyMinMargin` farther, and an uncapped tier.
  6. One-to-one greedy assignment in ascending distance (ties by speakerID, profileID).
     Another speaker within `possibleMaxDistance` of an assigned profile →
     `MergeSuggestion`. Zero-norm vectors have distance 2 and never match.
- **Calibration.** PR7c measures, on the Otter recordings 001 and 003 (six shared
  participants), cosine distances between centroids of clusters mapped to the same
  named Otter label across the two files and to different labels, and records
  percentiles and counts only in `speaker-evaluation.md`. PR10 sets
  `defaultThresholds.possibleMaxDistance` to the distance with at most 5 %
  different-person pairs below it. Hidden `holos people calibrate [--apply]` computes the
  same from the user's confirmed meetings (samples of one profile across sessions vs.
  samples of different profiles), prints percentiles and counts, and with `--apply`
  stores `calibratedThresholds` (`likelyMaxDistance` at ≤ 1 % false accepts,
  `possibleMaxDistance` at ≤ 5 %) with `calibratedModel`. `--apply` requires at least 3
  meetings with confirmed links and at least 2 people with samples from 2 or more
  meetings, all samples of one embedding model (distances of different models are not
  comparable; each model is reported separately), and computes the thresholds inside the
  store's locked update. The thresholds hold only for the population they were measured
  on: any later change to the samples resets them in that change's store write (see
  **Store**), and automatic names stay off until `--apply` is run again.
- **Enrollment** (`VoiceEnrollment.sample`, HolosSpeakers, pure): qualifying turns are
  the linked speakers' projected turns that are not reassigned, not `modified`, not
  overlapped, at least 2 s long, not excluded, and get a turn embedding from
  `VoiceSampleExtractor`. Vector = speech-weighted mean, L2-normalized; then one outlier pass drops turns
  more than 0.5 cosine distance from that mean and recomputes (count reported in
  `droppedOutlierTurns`). `weak` if total speech < 20 s. No audio or no qualifying
  turns → no sample. Only the confirmed speaker's turns are ever sent to the extractor,
  except by the review window's voice pass below, whose vectors never leave its memory.
- **Voices within one meeting (review window).** Naming one "Speaker N" shows which
  other speakers and turns of the same meeting have that voice, because the diarizer
  often splits one person into two or three speakers.
  - *Voice pass.* When Review opens (`ReviewSession(analyseVoices: true)`), the window runs
    the voice sample extractor once per diarized track in the background, asking about
    every turn of 2 s or more that no split has cut (`ReviewSession.analysable`), and
    keeps the turn embeddings in a `MeetingVoiceCache` (HolosMeeting). The footer says
    "Comparing voices (1 of 2)…" meanwhile; a pass that fails on any track says why under
    the footer and nothing is suggested or merged on any track (matching half the meeting
    would leave out the failed track's matches unsaid; what the other passes stored still
    serves voice learning). On the user's 53-minute meeting a pass took about 30 s per
    track (debug build). The extractor is asked about each turn with its exact span
    (`T12@723.5-731.25`), so a vector is always of the times the cache keeps it against,
    even when a split changes the turn while the pass runs. A word edit keeps the turns (its
    run is retargeted): what the cache holds for turns at the same times stays; when it moved
    a turn worth a voice (an untimed segment spreads its words again), the voices are worked
    out again on the new run, a pass running replaced (what it would store is at the old
    times, never served). Whenever the labels shown change once a pass has ended (an undo puts
    back a turn a split cut while the pass ran), the voices are those the cache holds for the
    turns at their times now; a saved turn worth a voice that no pass covered at its times
    sends a new pass. The app passes the spans on the
    child's stdin, one per line (`speakers embed --turns - …`), from a 0600 temporary file it
    unlinks before the child starts: a 3-hour meeting has thousands of turns, and one argv
    entry holding them all could pass `ARG_MAX`. The other helper commands the app runs take
    a fixed handful of arguments (a word list goes by file, `--vocabulary-file`). The
    child the app stops (a review closed, a newer change) deletes its render, a decoded
    copy of the audio, on SIGTERM before it exits, instead of leaving it for the six-hour
    stale-render sweep.
  - *Privacy decision.* The cache is memory only and is never written, whatever Remember
    voices says: the design keeps unconfirmed speakers' embeddings off disk ("No stored
    voice data for unconfirmed people" above), and a per-meeting file would have joined
    the forget machinery (tombstones, resumable scrubs) for no gain a 30-second pass
    cannot give back. It lives while the window is open for that meeting's head run, and
    is dropped when the window closes, the meeting is labelled again (another run's
    turns), its audio is deleted, or a maintenance command pauses the review while the
    pass is running. The vectors travel only through the extractor's stdout pipe, as
    before. Matching inside one meeting compares a meeting's voices with each other, which
    is what diarizing it already did; it stores nothing and compares with no other meeting
    or person, so it is not gated on Remember voices. Only learning a voice (a profile
    sample) still is.
  - *Matching* (`MeetingVoiceMatcher`, HolosSpeakers, pure): a voice is the speech-weighted
    mean of a group's usable turns on one track (not overlapped, not split, not excluded
    from voice learning, 2 s or more), after enrollment's outlier pass (0.5). Anchors are
    the people speakers are linked to (a typed name links a person; "This is me" links
    you) who are still in People; automatic names, names without a person, and a person
    forgotten since (the meeting keeps the link and the name) are not anchors. Nothing is
    matched while the edit journal has a line this build cannot read, as recognition's
    suggestions are not used then: the line may be a rejection or a reassignment the
    matches would contradict. Candidates are
    speakers with no name, link or automatic name, never a channel speaker. Voices are
    compared on the same track only (room and call audio sound different). A candidate
    gets "Maybe Jim" when Jim's voice is the nearest within `suggestMaxDistance` and no
    other named person is within `ambiguityMargin` (0.05) of it, unless it rejected Jim.
    A turn gets "Jim (suggested)" when it is within `turnHintMaxDistance` of Jim and at
    least `turnHintMinMargin` (0.15) closer to Jim than to the rest of its own speaker (its
    speaker's voice without it), its speaker is not Jim's, has not rejected Jim, and is not
    already suggested as Jim.
  - *Thresholds* (`MeetingVoiceThresholds.derived`): `suggestMaxDistance` is recognition's
    `possibleMaxDistance` (calibrated when `calibratedModel` is the run's model, else
    0.43) capped at 0.35; `mergeMaxDistance` 0.15, or the calibrated `likelyMaxDistance`
    when lower (the diarizer's own clustering threshold is about 0.18 cosine, so it only
    joins what the diarizer should have joined); `turnHintMaxDistance` 0.30, never above
    the suggestion threshold. Measured on the user's meeting (53 min, mic and system
    tracks diarized, 241 turns of 2 s or more, 189 with an embedding; aggregate numbers
    only): the 7 system-track clusters are 0.413 apart at the closest, then 0.618 and
    up; a turn lies within 0.055 / 0.136 / 0.330 (p10 / p50 / p90) of its own cluster and
    0.425 / 0.545 / 0.820 of the nearest other; no machine-cluster pair is under 0.35 and
    no turn would be flagged at 0.30 / 0.15. Among the 11 speakers after the user's edits,
    three pairs are under 0.35 (0.054, 0.057, 0.177), each a speaker the user made by hand
    next to the one its turns came from. The cross-recording measurement put every
    same-person pair at 0.244 or less.
  - *Suggestions in the window.* A voice suggestion shows exactly like recognition's
    ("Maybe Jim" with Confirm / Not Jim, counted in Confirm All (n)) and takes precedence
    over a recognition suggestion for the same speaker, since it compares the same
    recording. Confirm links the person (learning the voice when the footer box is on);
    Not Jim saves `rejectProfile`, so Jim is not suggested again, even after reopening;
    Confirm All links every shown suggestion in one batch
    (`VoiceProfileService.confirmAll(suggestions:)`). "Jim (suggested)", first in a turn
    row's speaker pop-up, gives that turn to Jim's speaker in one choice
    (`acceptTurnHint`). Suggestions are worked out again on every change of the shown labels, so they appear as soon as the name is saved.
  - *Automatic merge* ("Merge Matching Voices Automatically" in the Speakers menu, a
    UserDefaults setting, off by default): after a name is given and the queue is idle,
    every suggestion within `mergeMaxDistance` with at least 10 s of speech on both sides
    is merged into the named speaker it matched, as one change that one undo reverts. The
    merges are worked out again as they are queued (a speaker named or rejected meanwhile
    is left alone) and refused under the speaker lock when the journal has an unreadable
    line. The merged speaker's turns are first marked `excludeFromEnrollment` in the same
    batch: nobody confirmed them, and a voice sample never comes from an automatic match.
    Labelling the meeting again keeps that speech excluded (carry-over, speaker-labels.md §4.9).
    A speaker whose name field has the keyboard (`speakerBeingNamed`, asked when the merges
    are worked out) is never merged, so the name being typed still has its speaker at
    Return.
  - *Voice learning off the edit queue.* The window's links, "This is me", Confirm All,
    and Assign to a person save with `deferSamples: true`: the name is saved and shown at
    once, and `VoiceProfileService.syncSamples` runs afterwards in the background
    (`ReviewSession.sampleDelay`, 1.5 s after the queue is idle), enrolling the people
    linked with the footer box on. So do edits that affect a sample from this meeting.
    A newer change cancels a sync that is waiting or running (the extractor's child is
    stopped); it runs again once the change is saved. `pause` stops and waits for it
    before a maintenance command starts; `close` runs one still owed and waits for it. Its
    extractor is `CachedVoiceSampleExtractor`: the requested turns come from the voice
    pass (waiting for a pass that is running), and a turn the pass did not cover (another
    run, other times, another track) sends the whole request to the bundled extractor as
    before. A sync that fails says so under the footer ("The name was saved, but the
    voice could not be learned: …"); the name stays. The generation and forget checks of
    `syncSamples` are unchanged, so a sample computed while the labels changed is not
    saved. Because the voice is now learned a while after it was asked for, the window
    records the store's `forgetEpoch` when the link is made and passes it
    (`syncSamples(enrollEpochs:)`): a person whose voice was asked for before a forget
    that has landed since is not enrolled ("Voices were forgotten while this one was being
    learned…"), since the forget is the later request; the epoch read at the start of the
    sync is also held across its attempts. The people enrolled are the ones the change
    itself linked (`deferSamples: DeferredSamples`, filled once its lines are saved), not
    whoever the labels name when the window rereads them. A request not run yet is kept
    with the batch of the link that made it: undoing that link withdraws its request only
    (another link's request for the same person stays), and linking the same person again
    with the footer box off withdraws them all (the newest link of a person decides).
    `pause`, `close` and a relabel from the window stop a running voice pass and wait for
    its child to exit, so no command or second diarization runs while it still reads the
    audio (a new pass follows a relabel); while closing, the cache is kept until the last
    sync has used it. When quitting gives up waiting for a review (10 s), its voice work is
    stopped (`stopBackgroundWork`) so no child outlives the app; the name stays saved.
    A sync that fails while the window closes (nobody sees its footer), or one still owed
    when quitting stops it, is recorded in `PendingVoiceSamples` (UserDefaults, like
    `PendingExports`: the session ID, the people asked for with the forget epoch of their
    request, and why it failed; no voice data). The meeting's next review runs it again and
    says so under the footer ("When this meeting's review last closed, a voice could not be
    learned; trying again. …") until it ends; the record is cleared once a sync ends with
    the window open (a failure then shows in the footer) or the meeting or its audio is
    deleted. The epochs still apply, so a forget made meanwhile wins, and a failure that is
    a forget winning is not recorded.
    A request made after a forget replaces the person's earlier requests rather than
    joining them, so undoing it cannot leave a pre-forget request standing. "Not Jim" saves
    the person the row showed, even when a voice match has replaced the suggestion since.
  Tests: `meetingThresholdsAreCappedBelowRecognitions`,
  `meetingThresholdsFollowTheStoreOnlyForItsModel`, `aSpeakerSplitFromANamedOneIsSuggested`,
  `onlyVoicesWithinTheThresholdAreSuggested`, `nothingIsSuggestedBeforeAnybodyIsNamed`,
  `notJimStopsJimBeingSuggestedAgain`, `aSpeakerBetweenTwoNamedPeopleIsLeftAlone`,
  `namedAndOtherTrackSpeakersAreNotSuggested`, `onlyCloseVoicesOnEnoughSpeechAreMergeable`,
  `aTurnInsideAMixedSpeakerIsHinted`, `turnsTooShortOverlappedOrOnTheirOwnAreNotHinted`,
  `aForgottenPersonIsNoAnchor` (HolosSpeakers);
  `theCacheServesCoveredTurnsOfTheHeadRunAndFallsBackOtherwise`, `turnSpansRoundTrip`,
  `nothingIsSuggestedWhileTheJournalHasAnUnreadableLine`,
  `aVoiceAskedForBeforeAForgetIsNotLearned`, `anUndoneOrNewerLinkTakesBackAVoiceNotLearnedYet`,
  `undoingOneLinkKeepsAnotherLinksRequestToLearnTheVoice`,
  `aDeferredLinkRecordsWhoItLinkedAndLearnsNothing`,
  `aLateStoreOfAnEarlierPassIsIgnored`, `aLearnerWaitsForThePassOrStopsWhenCancelled`,
  `namingASpeakerSuggestsTheSpeakersWithItsVoice`,
  `notJimOnAVoiceSuggestionIsSavedAndConfirmAllTakesTheRest`,
  `aTurnHintGivesTheTurnToTheNamedSpeaker`, `matchingVoicesAreMergedOnlyWhenAsked`,
  `noVoicesAreWorkedOutUnlessAsked`, `aNameIsSavedWhileItsVoiceIsStillBeingLearned`,
  `aNewerChangeStopsAVoiceBeingLearnedAndItIsLearnedAfter`,
  `closingLearnsAVoiceStillWaitingForItsDelay`, `aSampleSyncThatFailsSaysSoAndKeepsTheName`,
  `aVoiceThatFailsWhileTheReviewClosesIsLearnedWhenItOpensAgain`,
  `aVoiceStoppedByQuittingIsTriedAgainAndAFailureThenShows`, `aPassThatFailsOnOneTrackMatchesNothing`,
  `subprocessExtractorReadsEmbeddingsFromAPipe` (spans on stdin, 20 000 turns)
  (HolosMeeting).
- **`VoiceProfileService`** (HolosMeeting, PR10) is the only code that writes profiles
  and samples:
  - `link(session:speakerID:to:view:learnVoice:extractor:store:)` (async) where `to` is an existing
    profile or a new name: creates or links the profile, appends `linkProfile` and
    `rename(name: profile.displayName)` in one batch (so the session keeps the name if
    the profile is later forgotten), and, if `learnVoice` and "Remember voices" is on
    and the session's audio exists, extracts and upserts the sample for
    `(profile, session)` through `VoiceSampleExtractor`. Samples come only
    from this call, never from automatic matches (decision 2). With `deferSamples`
    (the review window) only the link is saved, and the caller runs `syncSamples`
    afterwards, enrolling the person; `markSelf` and `confirmAll` take it too.
  - `confirmAll(session:view:learnVoices:store:)`: links every current suggestion in one
    batch, so one undo reverts it.
  - `markSelf(session:speakerID:view:learnVoice:extractor:store:)` (async): "This is me". Like `link`, it
    enrolls a voice sample only when `learnVoice` is true (the Review footer's
    `ReviewSession.learnVoices`, and Remember voices on); otherwise it only records the
    `isSelf` link. Test `markSelfHonoursLearnVoice` (PR10).
  - `reject(session:speakerID:profileID:view:)`.
  - `refreshSamples(session:extractor:store:)` (async): after any edit in a session that
    contributed samples, re-extract and recompute them; remove a sample when no qualifying
    turns remain. `SpeakerEditor.apply` stays synchronous and returns
    `SpeakerEditResult` (`snapshot`, `needsSampleRefresh`); its callers (the CLI speaker
    commands and `ReviewSession`) then `await refreshSamples`.
  - **Refreshes cannot overwrite newer state.** Before extracting, `refreshSamples` (and
    `link`/`markSelf` when they enroll) reads the session's speaker generation under the
    speaker lock: `SessionSpeakerStore.generation(session:)` = head run ID plus the edit
    journal's byte length (PR10 adds this additive helper). It computes the sample outside
    the lock, then takes the speaker lock, then `profiles.lock` (the ../conventions.md §1.7 order), re-reads
    the generation, and upserts only if it is unchanged. Otherwise it releases both,
    rebuilds the projection, and retries (at most 3 times, then leaves the existing sample
    and logs). Samples are also stamped with the generation they were built from, so an
    older result can never replace a newer one. Tests (PR10):
    `staleRefreshDoesNotOverwriteNewerSample` (extraction A starts; an edit reassigns a
    turn; extraction B finishes first; A finishes last and is discarded and retried),
    `refreshGivesUpAfterThreeChanges`.
  - `forget(sampleID:)`, `forget(profileID:)`, `forget(sessionID:)` (samples learned
    from that meeting), `forgetAll()` (every sample and every voice file; names stay),
    `rename(profileID:to:)`, `merge(profileID:into:)` (refused across embedding models),
    `setRemember(_:forgetExisting:)`, `profileNames()`, `knownPeople()`. Forgetting a
    person also regenerates the exports of sessions whose recognition file names them.
    Forget operations update the profile store first, release `profiles.lock`, then
    rewrite each affected voice file under that session's speaker lock (../conventions.md §1.7 rule 2).
- **Export.** `holos people export` writes names and sample metadata; embeddings only
  with `--include-voiceprints`, which prints a warning to stderr (decision 2 includes
  export). Session exports never contain vectors (exports.md §4.11).

### 5.9 PR10: People and voice profiles (wave 4)

**Goal.** Names that carry across meetings, opt-in voiceprints from confirmed labels
only, recognition as suggestions until calibrated, a People window, and `holos people`.
Update `docs/design.md` and `docs/implementation.md` (decision 2 reverses "No inferred
cross-meeting voiceprint database" and T11's "No cross-session identity claim").

**Files.**

- Add `Sources/HolosCore/VoiceProfiles.swift` (§4.10 types, with public inits).
- Add `Sources/HolosStorage/SpeakerProfileStore.swift` (+ `extension HolosPaths { static var speakerProfiles: URL }`
  = `supportRoot/Speakers`).
- Add `Sources/HolosSpeakers/{SpeakerRecognizer, VoiceEnrollment, RecognitionCalibration}.swift`.
- Add `Sources/HolosMeeting/VoiceProfileService.swift`,
  `Sources/HolosMeeting/PostProcessing/RecognizeStage.swift`.
- Change `Sources/HolosMeeting/MeetingPostProcessor.swift` (`profiles:` parameter; the
  stage-6 voice-data gate; stage 7), `Sources/HolosMeeting/SpeakerEditor.swift`
  (`profiles: SpeakerProfileStore? = nil` parameter on `apply`/`undoLast`; when set, the
  result's `needsSampleRefresh` tells the caller to `await
  VoiceProfileService.refreshSamples(session:extractor:store:)` after the lock is released),
  `Sources/HolosCLI/PostProcessing.swift` (pass `SpeakerProfileStore()`),
  `Sources/HolosCLI/Speakers.swift` (`link`, `me`, `reject`; pass the store),
  `Sources/HolosCLI/Holos.swift` (add `People.self`), `Package.swift` (identical wave-4
  edit).
- Add `Sources/HolosCLI/People.swift`, `Sources/HolosApp/PeopleWindow.swift`,
  `Sources/HolosApp/HolosApp+People.swift` (`@objc func showPeople()` using
  `PeopleWindowController.shared`). Change `Sources/HolosApp/HolosApp.swift` by exactly
  one line in `rebuildMenu()`: `menu.addItem(item("People…", #selector(showPeople)))`
  after `Meetings…`, and `Sources/HolosApp/HolosApp+Meeting.swift` by one expression:
  the vocabulary closure adds `VoiceProfileService.profileNames().values`.
- Add `docs/voice-profile-validation.md` (manual check H15). Change `docs/design.md`,
  `docs/implementation.md`. PR10 merges last in wave 4 and writes the wave-4
  `README.md` and `docs/status.md` notes for PR4 and PR10.
- Tests: `Tests/HolosSpeakersTests/{RecognizerTests, EnrollmentTests, CalibrationTests}.swift`,
  `Tests/HolosStorageTests/ProfileStoreTests.swift`,
  `Tests/HolosMeetingTests/VoiceProfileServiceTests.swift` (helpers prefixed `profile…`).

**API.**

```swift
public struct SpeakerProfileStore: Sendable {
    public init(directory: URL = HolosPaths.speakerProfiles)
    public func load() throws -> SpeakerProfileDatabase           // missing file → empty, rememberVoices false
    public func update<T>(_ body: (inout SpeakerProfileDatabase) throws -> T) throws -> T
}

public enum SpeakerRecognizer {
    /// likelyMaxDistance 0 (suggestions only), likelyMinMargin 0.10, possibleMaxDistance from PR7c's
    /// calibration (0.40 until set), minSampleSeconds 20.
    public static let defaultThresholds: RecognitionThresholds
    /// §4.10 steps 1–6. `condition(track)`: system → call, mic → room. nil when the run has no engine or
    /// `voiceData` is nil.
    public static func recognize(run: DiarizationRun, voiceData: SessionVoiceData?, database: SpeakerProfileDatabase,
                                 now: Date = Date()) -> RecognitionResult?
}

public enum VoiceEnrollment {
    /// §4.10 enrollment rules. `speakerIDs` are the session's speakers linked to one profile.
    public static func sample(for speakerIDs: [String], projection: SpeakerProjection, run: DiarizationRun,
                              turnEmbeddings: [TurnEmbedding], minSampleSeconds: Double = 20)
        -> (vector: FloatVector, speechSeconds: Double, condition: RecordingCondition, weak: Bool, droppedOutlierTurns: Int)?
}

public enum RecognitionCalibration {
    /// Percentiles of same-person and different-person sample distances; nil below the §4.10 minimums.
    public static func thresholds(database: SpeakerProfileDatabase) -> (thresholds: RecognitionThresholds,
        samePerson: [Double], differentPerson: [Double])?
}

public enum ProfileTarget: Sendable, Equatable { case existing(profileID: String), new(name: String) }

/// Enrollment is asynchronous and the extractor is injected: its real implementations live in
/// HolosDiarization (CLI) or spawn the bundled `holos` (app), and HolosMeeting cannot import FluidAudio.
/// `extractor == nil`, `learnVoice == false`, Remember voices off, or deleted audio → the name/link is
/// recorded and no sample is taken. Journal edits are appended under the speaker lock first; extraction
/// runs after the lock is released; the sample is upserted under `profiles.lock` last.
public enum VoiceProfileService {
    public static func link(session: URL, speakerID: String, to target: ProfileTarget, view: SpeakerProjection,
                            learnVoice: Bool, extractor: (any VoiceSampleExtractor)?,
                            store: SpeakerProfileStore) async throws -> SpeakerSessionSnapshot
    public static func confirmAll(session: URL, view: SpeakerProjection, learnVoices: Bool,
                                  extractor: (any VoiceSampleExtractor)?,
                                  store: SpeakerProfileStore) async throws -> SpeakerSessionSnapshot
    public static func markSelf(session: URL, speakerID: String, view: SpeakerProjection,
                                learnVoice: Bool, extractor: (any VoiceSampleExtractor)?,
                                store: SpeakerProfileStore) async throws -> SpeakerSessionSnapshot
    public static func reject(session: URL, speakerID: String, profileID: String,
                              view: SpeakerProjection) throws -> SpeakerSessionSnapshot
    public static func refreshSamples(session: URL, extractor: (any VoiceSampleExtractor)?,
                                      store: SpeakerProfileStore) async throws
    public static func setRemember(_ on: Bool, forgetExisting: Bool, store: SpeakerProfileStore,
                                   sessionsRoot: URL = HolosPaths.sessions) throws
    public static func rename(profileID: String, to name: String, store: SpeakerProfileStore) throws
    public static func merge(profileID: String, into target: String, store: SpeakerProfileStore) throws
    public static func forget(sampleID: String, store: SpeakerProfileStore, sessionsRoot: URL = HolosPaths.sessions) throws
    public static func forget(profileID: String, store: SpeakerProfileStore, sessionsRoot: URL = HolosPaths.sessions) throws
    public static func forget(sessionID: String, store: SpeakerProfileStore) throws
    public static func forgetAll(store: SpeakerProfileStore, sessionsRoot: URL = HolosPaths.sessions) throws
    /// Current names, for SpeakerProjection.make(profileNames:).
    public static func profileNames(store: SpeakerProfileStore = SpeakerProfileStore()) -> [String: String]
    /// Most recently used first; for the review window's name combo box.
    public static func knownPeople(store: SpeakerProfileStore = SpeakerProfileStore()) -> [SpeakerProfile]
}
```

**CLI.**

```
holos people list [--json]                 # "Remember voices: on" header, then one line per person
holos people remember on|off|status [--forget]
holos people rename <person> <name>
holos people merge <person> <into-person>
holos people forget <person> [--sample SAMPLE-ID] --yes
holos people forget --session <session> --yes
holos people forget --all --yes
holos people export [--output FILE] [--include-voiceprints]
holos people calibrate [--apply]           # hidden; prints counts and percentiles only
holos speakers link <session> <speaker> <person|new:NAME> [--learn-voice]
holos speakers me <session> <speaker>
holos speakers reject <session> <speaker> <person>
```

`people list` line: `Jim   3 samples (2:41 of speech; room 2, call 1)   suggestions on`,
or `Sam   no voice samples`. `<person>` is a profile ID or a unique name.
`people remember off --forget` also deletes every sample and voice file.
`people export --include-voiceprints` prints "This file contains voiceprints, which are
biometric data about the people in it." to stderr.

**People window** (`NSWindow` 680 × 480):

```
[x] Remember voices of people I name
    Only remember people who agreed to it. Voiceprints are biometric data; they stay on
    this Mac and are not included in Time Machine backups.
┌ People ─────────────────┬ Jim ───────────────────────────────────────────── [Rename…] ┐
│ Me          no samples  │ [x] Suggest Jim in new meetings                               │
│ Jim         3 · 2:41    │ Samples                                                        │
│ Maria       1 · weak    │  Council meeting   2026-09-20   room   1:12   [Forget]          │
│ Sam         no samples  │  Budget call       2026-09-22   call   0:48   [Forget]          │
│                         │ [Merge Into… ▾]                     [Forget Jim…]              │
└─────────────────────────┴───────────────────────────────────────────────────────────────┘
Deleting a meeting keeps its voice samples unless you choose to forget them.  [Forget All Voices…]
```

Unchecking "Remember voices" asks "Also forget the 12 saved voice samples and the voice
data of 5 meetings?" `[Forget]` `[Keep]`. People without samples are listed whatever the
setting.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `likelyIsOffByDefault` | default thresholds; Jim at 0.10 | possible, not likely |
| `likelyNeedsCalibrationDistanceAndMargin` | calibrated (likely 0.25); Jim 0.20, Maria 0.28 | Jim possible (margin 0.08 < 0.10) |
| `likelyWhenCalibratedAndClear` | calibrated; Jim 0.20, Maria 0.60 | Jim likely |
| `possibleBelowThreshold` | default (0.40); Jim 0.35 | possible |
| `noMatchAboveThreshold` | Jim 0.45 | no match |
| `assignmentIsOneToOne` | S1 and S2 both nearest Jim (0.2, 0.3) | S1 ↔ Jim; S2 gets its next profile or none |
| `twoSpeakersOneProfileSuggestMerge` | S1 0.2, S2 0.3 to Jim | merge suggestion [S1, S2] |
| `crossModelProfilesSkipped` | profile with another embedding model | in `skippedProfiles` |
| `profilesWithoutSamplesAreNotCandidates` | Sam with no samples | never matched; not in `skippedProfiles` |
| `identicalVectorIsOnlyPossibleUntilCalibrated` | uncalibrated; cluster centroid identical to a sample (distance 0) | `possible`, never `likely` |
| `weakOrOtherConditionCapsAtPossible` | calibrated; only weak samples at 0.2; only call samples for a room speaker | possible |
| `rememberOffMeansNoVoiceDataAndNoRecognition` | Remember off; post-process | no `speakers/voice/`, no recognition file |
| `enrollExtractsOnlyTheConfirmedSpeaker` | `FakeVoiceSampleExtractor`; link S2 to Jim with learnVoice | extractor asked only for S2's qualifying turns; one sample for (Jim, session); no other embeddings written |
| `enrollWithoutAudioKeepsNameOnly` | session after Delete Audio; link with learnVoice | profile linked, no sample, message "…audio was deleted…" |
| `rememberOnWritesRecognitionOnly` | Remember on; a profile with samples | recognition file (distances only, no vectors); **no** `speakers/voice/` file |
| `sampleUsesOnlyQualifyingTurns` | 8 turns: reassigned, modified, overlapped, 1.5 s, excluded, no embedding, + 2 qualifying | vector from the 2 qualifying turns |
| `splitThenReassignKeepsOtherVoiceOut` | split T5, reassign the tail to Maria, link T5's speaker to Jim | Jim's sample uses no window from T5 |
| `mergeKeepsTurnsInSample` | merge S3 into S1, link S1 to Jim | S3's turns count |
| `mergedClusterSampleDropsOutlierTurns` | 6 turns near [1,0], 2 near [0,1] | the 2 dropped; `droppedOutlierTurns == 2` |
| `underTwentySecondsIsWeak` | 12 s qualifying | weak |
| `linkWithoutRememberKeepsTheName` | Remember off; link new "Jim" | profile Jim with 0 samples; linkProfile + rename in one batch; Jim in `knownPeople` |
| `linkWithLearnVoiceCreatesSample` | Remember on; `learnVoice` true; voice data present | one sample |
| `footerToggleControlsSampleWrites` | Remember on; `learnVoice` false | profile linked; no sample |
| `confirmAllIsOneEdit` | 3 suggestions | one batch of 6 lines; one undo reverts all |
| `markSelfCreatesOneSelfProfile` | markSelf in two sessions | one `isSelf` profile, linked in both |
| `enrollmentNeverFromAutomaticMatch` | likely match, no link | no sample written |
| `reassignAfterEnrollmentRecomputesSample` | link, then reassign a qualifying turn away | same sample ID, new vector and seconds |
| `forgetPersonRemovesSamplesAndVoiceEntries` | forget Jim | samples gone; Jim's entries removed from contributing voice files; sessions keep the name; exports regenerated |
| `forgetAllRemovesVoiceFilesKeepsNames` | forgetAll | every `speakers/voice/` gone; profiles remain with 0 samples |
| `forgetSessionRemovesItsSamples` | forget(sessionID:) | only that meeting's samples gone |
| `rememberOffWithForget` | `setRemember(false, forgetExisting: true)` | samples and voice files gone; names remain |
| `missingStoreLoadsEmptyWithRememberOn` | no `profiles.json` | on; the first write saves `rememberVoices: true` |
| `existingStoreKeepsItsRememberSetting` | a store saved off, and one saved on | each keeps its value through reads and writes |
| `learnVoicesFollowsTheRememberSetting` | review window on a fresh store, then on a store saved off | footer box starts on, then off |
| `profileStoreIsPrivateLockedAndNotBackedUp` | two concurrent updates | both applied; 0600 / 0700; `isExcludedFromBackup` |
| `peopleExportOmitsEmbeddingsByDefault` | export | no `embedding` keys |
| `calibrationNeedsThreeMeetings` | 2 meetings with links | `--apply` refused |
| `calibrationPercentiles` | synthetic same/different distances | likely at the 1st and possible at the 5th percentile of different-person distances |

**Does not touch.** `MeetingController`, `MeetingStartPanel.swift`, `MeetingsWindow.swift`,
`build-app.sh`, `RecordingWorkflow.swift`, `Record.swift`, `Fakes.swift`.
