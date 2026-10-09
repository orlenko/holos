# Architecture audit and roadmap

**This is a snapshot of an architecture audit of `main` at commit `fa4bfa8`.** Every line number, line count and
finding count refers to that commit; the code has moved since, so treat them as pointers, not facts. Sections 0–5
and 7 are not kept up to date.

**The roadmap table in §6 is the living part.** Update its Status column in the PR that lands or starts a step, and
add a row when a step is split. The working rules that came out of this audit are in [AGENTS.md](../AGENTS.md).

**Tags:** [M] = measured with rg/fd/wc/git/gh. [J] = judged from reading the code.

**Citations:** a bare `§N` in this file is a section of this file. The table in §4.3 lists sections of
`docs/meeting-design.md`; other documents are always named.

---

## 0. Summary

1. **The target-level layering is mostly sound** [M]. There are no cycles. `HolosSpeakers` is pure (no file I/O, depends only on Core). FluidAudio and WhisperKit stay out of the app. `HolosStorage` owns the core session files through `SessionPaths`, `AtomicFile` and a documented lock order. The spaghetti risk is inside three targets that each mix several subsystems:
   - `HolosMeeting`: 40.7K lines in 110 files.
   - `HolosApp`: 21.9K lines.
   - `HolosCore`: about half domain model, half app helpers.
2. **Half the code is in large files** [M]. 52.6K of 105.5K Swift lines are in the 48 files over 600 lines; 9 files are over 1,500. The files with the most review findings are the ones with the most churn and the most mutable state:

   | File | Lines | Commits since 2026-09-15 | Codex findings |
   |---|---|---|---|
   | ReviewSession | 3,872 | 80 | 46 |
   | ReviewWindow | 2,369 | 79 | 31 |
   | TurnListView family | 1,847 | 77 | 28 |
   | MeetingScreenCapture | 737 | 17 | 22 |

3. **One bug class dominates review** [M]. 45 of 242 Codex findings were an async edit acting on a stale view.
   - Fixes keep adding one-off guards: `movesSeen`, `wordsEpoch`, `runID`, field epochs, `owedHead`, `superseded`, `overtaken`.
   - 61% of findings landed on lines written by an earlier review fix-up.
   - Findings per round never fall.
   - [J] There is no single edit/revision model, so each fix adds a state for the next round to probe. Splitting files will not fix this on its own; the shared primitives in §3 will.
4. **Four kinds of duplication cause bugs** [M]:
   - The transcript publish protocol (plan → stage → save → publishHead → repair) is copied into 6 stages. `LanguageStage.swift:728-746` and `DeepTranscriptionStage.swift:481-499` differ only in the event kind.
   - The app has 3 hand-copied background-job schedulers (about 1,300 untested lines), and `MeetingController` has a fourth.
   - About 8 places spawn `voiceislocal` and parse its output files by hand.
   - `<id>.holos` folder names are built in 7 places and parsed in 5, with different rules.
5. **Agents have little to orient by** [M].
   - There is no AGENTS.md or CLAUDE.md, and no module READMEs.
   - `meeting-design.md` is 9,317 lines: 35% is a PR plan (its section 5) and 18% is code copies (its sections 3.1–3.3). Those copies have drifted: the SHA-256 digests it lists for `MeetingModels.swift` and `SpeakerModels.swift` no longer match the code.
   - `docs/contracts.md` describes a `HolosCorrections` target and a SQLite store that don't exist.
   - 92 of 204 test files are not named after the source file they test.
6. **Roadmap (§6):** 14 steps at the time of the audit (step 15 was added later), about 24 PRs, each under 1,000 non-test lines, in parallel lanes; steps that change behaviour are marked.

**PR-size rule note** [J]. Moving N lines of code within or between files shows as about 2N changed lines; only whole-file `git mv` renames show as near zero. Count moved lines separately and verify them with `git diff --color-moved=dimmed-zebra --color-moved-ws=ignore-all-space`. Otherwise each file split has to be cut into pieces of about 450 lines.

---

## 1. Module map

### 1.1 Targets [M]

| Target | Lines / files | Depends on | Owns |
|---|---|---|---|
| HolosCore | 8,764 / 32 | (none) | Shared values (Models, MeetingModels, SpeakerModels, HolosJSON); text processing (TranscriptFixer 1,035, SpokenCode 925); also dictation helpers and app-only UI flows (L2) |
| HolosStorage | 5,655 / 16 | Core | SessionArchive (963), AtomicFile (882), locks, SessionPaths, speaker store, profile store, history, word list, screen context |
| HolosSpeech | 459 / 1 | Core | Apple SpeechTranscriber adapter |
| HolosSynthesis | 1,703 / 6 | Core | Native TTS, playback, audiobook writing |
| HolosContent | 7,416 / 11 | Core, Synthesis | Document loaders, web extraction (WebKit), reading pipeline, library |
| HolosAudio | 3,945 / 15 | Core, Storage | Capture, chunk writing, ScreenCaptureKit, power |
| HolosDesktop | 888 / 2 | Core | Hotkey, text insertion |
| HolosDictation | 637 / 3 | Core, Audio, Speech | Dictation controller, rerun |
| HolosSpeakers | 6,751 / 26 | Core | Pure speaker algorithms: projection, alignment, echo, exports |
| HolosMeeting | **40,727 / 110** | Core, Storage, Audio, Speech, Speakers | Recorder workflow and state machine, MeetingController, PostProcessing (25 files), Review (10), Summary (7), **Evaluation (14 files, 6,395 lines, includes an OpenAI URLSession client)**, voice profiles, import, catalog |
| HolosDiarization | 1,103 / 5 | Core, FluidAudio | Diarizer (CLI only) |
| HolosWhisper | 791 / 4 | Core, WhisperKit | Deep transcription (CLI only) |
| HolosApp (executable) | 21,915 / 44 | 10 targets | AppKit shell: `HolosAppDelegate` plus 11 extensions, MainWindow panes, Review window, Reading UI |
| HolosCLI (executable) | 4,748 / 28 | 11 targets + ArgumentParser | Mostly thin commands over HolosMeeting `*Command.run`; the workflow logic `Speakers.swift` and `Eval.swift` held moved to `SpeakerEditCommand` (step 15a, #136) and the HolosEvaluation `Eval*Command` types (step 15b, #137) |

**Processes** [M]:
- **Recorder child.** The app `posix_spawn`s `voiceislocal record start` as a detached child. It talks to it through:
  - `status.json`, rewritten every second
  - `control/<uuid>.json` requests, polled every 100 ms
  - SIGTERM
  - flock leases
- **Maintenance commands.** `MaintenanceLauncher` spawns `session deep-transcribe`, `summarize`, `echo-analyze`, `diarize`, `recover`, `delete` and `rename`, plus `doctor --json`.
- **One spawn helper.** All of these go through the single helper at `RecorderLauncher.swift:462+`.

**What is healthy** [M]:
- No dependency cycles.
- FluidAudio and WhisperKit are out of the app.
- HolosSpeakers does no file I/O.
- HolosMeeting has no AppKit, so `ReviewSession` and `MeetingController` are testable `@MainActor` classes.
- CLI commands are thin (step 15). `Speakers.swift` keeps parsing, selectors, `list`, the hidden `embed` (pipes, stdin and SIGTERM) and printing; `Eval.swift` keeps parsing, the consent prompt, `EvalInterrupt` (signals), `list` and printing.

### 1.2 Layering violations and unclear boundaries

| # | Finding | Evidence | Tag |
|---|---|---|---|
| L1 | Evaluation and cloud code sits in HolosMeeting, so it is in the app's link graph, but the app never references it | `HolosMeeting/Evaluation/` (6,395 lines). Only production coupling: `EchoAnalysisStage.swift:20,118` uses `EvalStore.audioFingerprint`. Only caller is the CLI's `Eval.swift` | M |
| L2 | HolosCore is half a junk drawer | 9 app-only files (PermissionButtons, SetupAssistantFlow, MainWindowLaunch, SettingsSearch, AppearanceChoice, LicenseNotice, ResultRetention, DeclinedCorrectionQueue, …). `Lexicon.swift:1` imports AppKit (NSSpellChecker). `Corrections.swift` does file I/O, runs a FolderWatcher and has its own flock | M |
| L3 | Two `DictationRerun.swift` files with different code | Core copy (615 lines, pure) and Dictation copy (208 lines, I/O and settings). No duplicate types, but the shared name hides the split | M |
| L4 | App knows storage internals | `ReviewWindow.recognizeNextScreenBatch` takes the processing lease itself. `MeetingsPane.swift:801,1008` builds export paths. `HolosApp+DeepTranscription.swift:597` reads the event journal. 13 app files import HolosStorage | M |
| L5 | Deletion bypasses `SessionPaths` | `SessionDeletion.swift:148-170` hard-codes `screen`, `eval/review`, `derived`. HolosStorage owns deletion and every path in a session, so the fix is to centralize these names in `SessionPaths`, not to move deletion | M |
| L6 | Session files have several owners | `meeting.json` has 3 writers, one an untyped `[String: Any]` rewrite (`SessionRenameCommand.swift:632-648`). `events.jsonl` has 2 parsers (`LiveTranscript.swift:323-365`). `.holos` names built in 7 places, parsed in 5 with different rules (`SessionDeletion.swift:281` requires a UUID; `FolderChain.swift:206` and `SessionCatalog.swift:393` require more than 6 characters; `VoiceProfileService.swift:1749` checks only the suffix). 3 lock-file implementations in one session folder | M |
| L7 | HolosContent imports AppKit, WebKit and PDFKit | `DocumentLoader`, `WebArticleExtractor`. Acceptable, but the target is not headless | M |
| L8 | Duplicated helpers | `InstallLock` (`WhisperModels.swift:255`, `FluidModels.swift:447`); `ProgressMeter` (Audio and Meeting); 3 one-shot gates (`OutcomeGate`, `RaceGate`, `OneShot`); flock hand-written in 11 files across 8 targets | M |
| L9 | Dependency cycle inside Meeting | VoiceProfileService calls SpeakerEditor and SessionExports, which call back into it | M |
| L10 | HolosAppTests depends on the executable target | 16 files `@testable import HolosApp`, so every focused test run builds the whole app | M |
| L11 | Ownership docs are stale | `contracts.md:21-42` lists HolosCorrections and SQLite. `docs/meeting-design.md §1.1` says "HolosApp keeps AppKit views only", but the app holds scheduler logic | M |

### 1.3 CLI and app duplication [M]

- **Two routes from start settings to `RecordingOptions`, and they already differ.**
  - Through argv: `RecorderLauncher.swift:59-78`, parsed in `Record.swift:94-111`.
  - Direct (in-process): `RecorderLauncher.swift:147-160`.
  - They resolve locale and the default microphone differently.
- **Vocabulary limits and filtering exist 3 times:** `RecordingWorkflow.swift:222,334`, `MeetingController.swift:32,650`, `SessionImporter.swift:311`.
- **The app re-declares CLI output types:**
  - `SummaryOutcome` (`HolosApp+MeetingSummary.swift:399`) duplicates `SessionSummarizeCommand.Outcome`.
  - `EchoOutcome` (`HolosApp+EchoCatchUp.swift:220`) duplicates the echo command's outcome.
  - Doctor output is parsed as `[String: Any]` (`HolosApp+Meeting.swift:1479`) instead of using `DoctorReport`.
- **The job lock is taken in different layers:** in the CLI for deep-transcribe and summarize, in the library for echo-analyze (`SessionEchoAnalyzeCommand.swift:73`).
- **A subprocess run only to read model status.** `doctor --json` is spawned just to learn model status, although `FluidModels.status` only hashes files.

---

## 2. Hotspots

### 2.1 Size × churn × findings

Churn is commits since 2026-09-15, which covers the whole history (896 commits). Findings are Codex inline comments on the last 30 merged PRs (#85–#118). All numbers [M].

| File | Lines | Churn | Findings | What it mixes |
|---|---|---|---|---|
| `HolosMeeting/Review/ReviewSession.swift` | 3,872 | 80 | 46 | 14 responsibility clusters (2.2) |
| `HolosApp/Review/ReviewWindow.swift` | 2,369 | 79 | 31 | Layout, refresh, split logic, word-edit save tracking, close flow, 12 helper types |
| `HolosApp.swift` + 11 `HolosApp+*` | about 5,700 | 97/79/20 | 5+ | God object: about 150 stored fields in 5 holders, about 280 functions, no test references `HolosAppDelegate` |
| `TurnListView` (+WordEditing, +Splitting) | 1,191+469+187 | 39+25+13 | 28 | 7 classes in one file, an edit-field state machine, about 30 callbacks |
| `HolosAudio/MeetingScreenCapture.swift` | 737 | 17 | 22 | Stream lifecycle plus display hot-plug |
| `RecordingWorkflow.swift` | 1,935 | 39 | (none) | `Recorder` class (31 vars): poll loop, capture, power, status, stop, exit |
| `VoiceProfileService.swift` | 1,817 | 44 | (none) | Static enum: link, people management, forget engine, sample sync, queries, its own folder enumeration |
| `MeetingsPane.swift` | 1,785 | 36 | (none) | Data loader inside a view controller, actions, rename, menus, row views |
| `DocumentLoader.swift` | 1,753 | 24 | (none) | 6 readers; HTMLReader alone is 1,185 lines |
| `ReadingPipeline.swift` | 1,726 | 30 | (none) | Pipeline plus reservation locks, path identity, temp files, cache, file I/O, chunker (27 types) |
| `TranscriptFixer.swift` | 1,035 | 45 | (none) | 18 types |
| `SpeakerProjection.swift` | 1,278 | 23 | 6 | Journal replay, presenter, fingerprints, hand-written SHA-256 |

### 2.2 ReviewSession

One `@MainActor final class` with 171 functions (53 public) and about 112 var/let [M].

Locations in this subsection name symbols as the code has them after the step 8 splits (in `ReviewSession.swift`
unless another file is named), not the audit's line numbers.

| Where | Cluster | Seam | Risk |
|---|---|---|---|
| `ReviewSessionTypes.swift`, `ReviewSession+Loading.swift` | Value types, loading | Moved out (step 8a) | Low (moves only) |
| `WordChecks` (`ReviewSessionTypes.swift`), `readWordChecks`, `wordEditRefusal`, `revertRefusal`, `checks`, `checked` | Word-edit dry-run checks; cache keyed by `\u{1f}`-joined strings | `ReviewWordEditChecks` | Medium: invalidation is implicit in `projection`'s `didSet` and in `adopt` |
| `Operation` (`ReviewSessionTypes.swift`); "Queue" section: `enqueue`, `queued`, `drain`, `run(_:)` | Queue and `Operation`: 6 booleans (`started`, `undone`, `superseded`, `overtaken`, `finished`, `savedUnreloaded`) and a 170-line `run(op)` switch | A lifecycle enum for the exclusive states plus separate flags for the ones that combine (step 11), done last | High |
| "Saving" section: `saveEdit`, `saveWordEdit`, `learnFromEdits`, `publishWordChange`, `repairOwedHead`, `handleFailure`, `holdUnreread`, `undoBatch` | Saving, learning, owed-head repair | Uses `TranscriptPublisher` (step 7) | Medium |
| "Voice samples (background)" section: `oweSamples` … `resumePendingSamples` | Voice-sample sync | `ReviewSampleSync` | Medium |
| "Voices within the meeting" section: `startVoiceAnalysis` … `autoMergeActions` | Voice analysis, auto-merge | `ReviewVoiceAnalysis` | Medium-high (coupled to `adopt`) |
| `adopt(_:op:matching:external:)` | Journal claim inside `adopt` | Pure `ReviewJournalClaim` (HolosSpeakers, step 9) | Low |
| "Exports" section: `changesSaved`, `regenerateExports` | Export scheduling | `ReviewExportScheduler` (step 9) | Low-medium |

**Implicit invariants** [M]:
- Every change to the queue must be followed by `recomputeProjection()`, `updateActivity()` and `notify()`. This is done by hand at each site: `queued`, `drain`, and the end of `adopt`.
- `queue.first.started` means "running now" (`adopt`, `holdUnreread`).
- `recordSplits(of:lines:)` assumes the saved lines match the optimistic actions in order.
- The UI passed `movesSeen` and `wordsEpoch` back as loose Ints: `TurnListView.onEditWords` took 5 positional arguments. Step 9 bundles them, with the labels run, into one `ReviewRevision` (`seen:`).

**Why stale views happen** [J]. The view pulls through closures that capture the live `review` (`text:`, `words:`, `resolve:`). Cells can therefore read newer state than the paragraphs they were built from, which is how stale views arise.

### 2.3 RecordingWorkflow [M]

**Seams:**
- Split the `Recorder` class into `+Capture` (846–1040), `+Power` (1041–1094), `+Status` (1095–1266) and `+Stop` (1270–1533).
- Move 1534–1768 into one exit owner, `RecorderExitSequence` (`RecorderExit` is HolosCore's exit record).

**Invariant:** `status.json` must say "exited" before the last lock is released (255–258, 1575). It is kept by hand across 9 `exitStatus` call sites and 46 cancellation checks.

**Main-thread I/O in in-process mode:** `inbox.poll()` (702), `fileExists(stop.request)` (742), `freeSpace` (767), `readManifest` (1293).

### 2.4 HolosAppDelegate [M]

**Where its state lives:**
- `HolosAppDelegate`: 71 fields.
- `MeetingAppState`: 38.
- `DeepTranscriptionAppState`: 17.
- `MeetingSummaryAppState`: 12.
- `EchoCatchUpAppState`: 14.

**Business logic in the app:**
- Dictation session: `HolosApp.swift:569-1100`.
- Schedulers: `+DeepTranscription:176-487`, `+MeetingSummary:146-372`, `+EchoCatchUp:63-287`.
- Meeting maintenance: `+Meeting:672-1437`.

**Main-thread I/O:**
- `MeetingController.swift:330-392` polls every 1 s while following a meeting (2–3 status reads, 2 flock probes) and every 3 s while idle (lists every session folder).
- `RecorderChannel.send` does an fsync'd create on main (`MeetingController.swift:569`).
- The schedulers read output files of up to 16 MiB on main: `+DeepTranscription:402-405`, `+Meeting:1416`, `+MeetingSummary:312`.

### 2.5 Other seams

All low risk and pure moves unless noted. Line ranges [M], risk [J].

- **DocumentLoader:**
  - `HTMLEncodingDetector` (318–647)
  - `HTMLPreparation` (648–880)
  - `HTMLWalker` (918–1156)
  - `HTMLInlineStyle` (1157–1462)
  - `PDFReader` (1470–1673)
  - Markdown, plain-text and DocumentText readers
- **ReadingPipeline:**
  - Manifest (7–151)
  - `ReadingOutputReservation` (834–1150)
  - Locks and path identity (741–807, 1162–1263)
  - Temporaries (1278–1423)
  - Cache (1429–1551)
  - File I/O (1553–1673)
  - `SemanticChunker` (1675–1726)
- **ReadingLibrary:**
  - Split into `extension ReadingLibrary` files: launch policy, ownership, file status, deletion (925–1242), sharing.
  - The UI formatters (1242–1257) belong in the app.
- **WebArticleExtractor:** about 470 lines of JavaScript in Swift strings (397–831). Move it to `Resources/*.js` with `embedInCode`, as `Readability.js` already is. Medium risk: the strings are concatenated at 787.
- **VoiceProfileService:**
  - `PeopleQueries` (592–708)
  - `VoiceForgetting` (510–590, 1355–1735)
  - `ProfileMerge` (271–410)
  - `VoiceSampleSync` (157–212, 861–1354), high risk
  - Replace its own folder scan (1736–1785) with a shared one.
- **SpeakerProjection:**
  - Separate the journal reducer from the presenter (910–1160).
  - Move the SHA-256 code (1196–1278) to Core.

---

## 3. Recurring bug classes and structural remedies

Source [M]: 242 Codex inline findings on PRs #85–#118, classified by hand, plus 24 commits labelled astra. PR #93 alone (11K lines, 56 commits, 42 rounds) has 99 findings.

| Class | n | Architectural cause [J] | Structural remedy |
|---|---|---|---|
| **Async edit vs stale view** | 45 (#93 19, #104 14) | No single "version the user acted on". Views capture rows and indices; the session keeps 3+ unrelated counters; cells read live state through closures | **Revision-stamped commands.** The view renders an immutable `ReviewSnapshot` value (transcript ID, head run, journal length, epoch, moves); cells get values, not closures. Every UI command carries `seen: ReviewRevision`. One entry point, `ReviewSession.submit(_:seen:) -> .applied / .rebased / .refused(reason)`, with a table-driven test. New edit kinds plug into it instead of adding counters |
| **Undo/revert/learning side effects** | 29 | Side effects run imperatively next to the edit, so undo has to know about each one | Edits are command values whose declared inverse includes their side effects. Learning entries carry the ID of the edit that caused them, so revert removes them by ID. Better: derive learning from the journal |
| **Damaged stored input, bounds** | 25 | Each reader validates on its own. Schema decode is written twice (`TranscriptPointer.swift:48-89`, `SpeakerSessionSnapshot.swift:239`), plus 10 hand-written version checks | `VersionedFile<T: ValidatedDecodable>` in Storage: decode, check the version, then `validate()` into a checked type (indices known to be in range). Add one corpus test feeding every decoder truncated or garbled files |
| **Pending work at close/quit, stream lifecycle** | 22 (#101 10) | Each component invents its own close gate (`ReviewCloseGate`, `UnsavedWordEdits`, `ClosingReview`, `QuitReadiness`). ScreenCaptureKit outputs are held weakly | A `Drainable` protocol (`pendingWork`, `drain()`), collected by window close and app quit. Scoped ownership for OS streams (`withStream {}` holds outputs strongly) |
| **UI focus/search/responder** | 18 | Edit-field state is spread across the view controller, table and extensions | `ReviewWordEditCoordinator` with an `EditFieldState` enum, tested without a window (step 10) |
| **Derived-data invalidation** | 15 (#86 11) | No dependency graph. `SessionExports.filesState` (377–407) ignores the speaker generation. The generation (`SessionSpeakerStore.swift:176-191`) leaves out the transcript pointer. Exports are rewritten by whichever of 9 callers remembers | A `SessionGeneration` stamp written into `.generated.json`, `summary.json` and caches. `isCurrent` compares stamps; `DerivedArtifacts.refresh(session:)` is the single rebuild path |
| **Durability, commit ordering** | 10 | Publish protocol copied 6×, each with its own repair path; 37 manual `releaseLock()` calls | `TranscriptPublisher.publish(transcript, event:, retarget:)` on top of `withMaintenanceArchive {}` (release in `defer`); one fault-injection test table |
| **Locks held by convention** | cross-cutting | "Caller holds the speaker lock" exists only in comments (`SessionSpeakerStore.swift:27`, `VoiceProfileService.swift:1620,1650`, `SessionExports.swift:73`). `.speakers.lock` guards 35 sites covering much more than speakers | A lock-token type: `withSessionLock { (tx: LockedSession) in tx.appendEdits(…) }`, with writers callable only on `tx`, keeping the `.speakers.lock` file name. Renaming the lock file is a separate compatibility change in its own PR (old recorder children must keep coordinating with new processes), never part of the token refactor |
| **Snapshot read before the lock, used after** | in code | `VoiceProfileService.swift:458-461,1603-1606`; `SpeakerEditor.swift:448-476` rewrites exports with names read earlier | Read the names under the same locks as the rewrite. Outside any lock, call `regenerate(session:people:)`, which takes the speaker and profile locks itself. Inside an edit that already holds the speaker lock, call a locked path (`regenerateLocked` with names read from `SpeakerProfileStore.withLockedDatabase` in that same lock): the locks are not re-entrant, so the plain `regenerate` must never run inside them |
| **Subprocess lifecycle, temp files** | few in review | 8+ hand-copied spawn/temp/decode/delete sites; an hourly sweep (`HolosApp+Meeting.swift:1702`); 41 `try?` on writes or removals | `CommandRunner` with shared Codable outcomes, plus `TemporaryArtifact`. A lint check bans new `try?` on removals outside it, starting from an allowlist of the existing sites, which shrinks as they are fixed |
| **Main-thread blocking** | 0 in review, but present (2.4) | `@MainActor` controllers call `AtomicFile` and `FileManager` directly in poll loops | Rule: `@MainActor` types do no file system work. Readers run off the main actor (an `async` function that leaves it, such as a `nonisolated async` reader or a detached task; a synchronous `nonisolated` call still runs on the caller's thread) and return snapshots with a token. Enforce with an rg check and an allowlist |
| Identity / same-name | 12 (#113) | Domain-specific | Write the PersonID vs display-name rules at type level |

**Why review rounds don't converge** [M]:
- 71 of 99 findings on #93, and 20 of 28 on #104, were on fix-up lines.
- #104 got 5 clean verdicts interleaved with 14 rounds that had findings.
- Design changed mid-review: #113 switched at commit 8 of 11; #101 dropped hot-plug after about 9 rounds.

**Process remedies** [J]:
- Settle the design before opening the PR.
- When two findings fall in the same class, fix the primitive instead of patching the site.
- Require two consecutive clean reviews; one clean sample is not enough.

---

## 4. Agent maintainability

The audit's findings here (files too large to read whole, invariants written as race stories, no orientation
docs, code citing the PR plan, false docs, test files hard to find) and its proposed rules became
[AGENTS.md](../AGENTS.md), the module READMEs and `scripts/check-size.sh` (step 1). The docs layout below is still
the plan for step 2.

### 4.3 Docs layout

Keep the `§N.M` numbers as headings so all 686 existing citations still resolve. Section sizes of `docs/meeting-design.md` [M]: section 3 = 1,640 lines, section 4 = 3,420, section 5 = 3,299.

| New file | Sections from `docs/meeting-design.md` |
|---|---|
| `docs/conventions.md` | §1 |
| `docs/meeting/session-format.md` | §2 and §3.4. Delete §3.1–3.3 (1,550 lines of stale code copies) |
| `docs/meeting/recorder.md` | §4.1–4.6, §4.12 (concurrent dictation, microphone selection, vocabulary), behaviour from §5.4 |
| `docs/meeting/retention-deletion.md` | §4.13 |
| `docs/meeting/post-processing.md` | §4.7–4.8 |
| `docs/meeting/speaker-labels.md` | §4.9, §5.3, §5.5 |
| `docs/meeting/people-voice.md` | §4.10, §5.9 |
| `docs/meeting/exports.md` | §4.11, §5.7 |
| `docs/meeting/languages.md` | §4.14 |
| `docs/meeting/screen-context.md` | §4.15 |
| `docs/meeting/deep-transcription.md` | §4.16 |
| `docs/meeting/titles-summaries.md` | §4.17 |
| `docs/meeting/review-window.md` | §5.10 (885 lines; rewrite as behaviour) |
| `docs/meeting/online-calls-echo.md` | §5.11 |
| `docs/archive/meeting-plan-2026-09.md` | §0.2–0.3, §5.1–5.2, §6, §8–§10 |

Also:
- Rewrite `docs/contracts.md` as the current ownership table.
- Split `design.md`'s tool sections into `docs/features/`.
- Reorganise `status.md` by feature instead of by wave.

---

## 5. Test suite

**Size** [M]:
- 208 files, 78.6K lines, 3,039 `@Test`, all Swift Testing.
- HolosMeetingTests is 42.8K lines in 82 files.
- Largest files: ReviewWordEditTests 3,564, VoiceProfileServiceTests 2,976, ReadingPipelineTests 2,179.

**Isolation** [M]:
- `scripts/test.sh` points `HOLOS_DATA_DIR` and `HOLOS_SUPPORT_DIR` at a temp folder and finds the TestingMacros plugin. A plain `swift test` does neither.
- Global state is mostly controlled: 15 UserDefaults suites, 103 `@TaskLocal` injections.
- Exception: `MainWindowNarrowTests:546-547` writes to `UserDefaults.standard`.

**Time** [M]:
- 99 `Task.sleep` calls, mostly 1–10 ms poll steps.
- 15 sleeps of 200–500 ms remain the main slow or flaky risk.
- 752 tests use `.timeLimit`.
- One elapsed-time assertion (`PollBudgetTests`, under 60 s).

**Processes and frameworks** [M]: these run without a gate:
- `posix_spawn` in `LeaseHandOffTests`.
- `/bin/chmod` in `ReadingPipelineTests`.
- Real `AVSpeechSynthesizer` rendering to a file.
- `WKWebView`, with no network.

Model tests are gated by environment variables.

**Duplication** [M]:
- 24 temp-directory helpers and 24 wait/poll helpers.
- `segment(` 11×, `turn(` 10×, `turnEmbeddings(` 10×.
- 4 test targets depend on HolosSynthesis just to make TTS fixtures.
- 57 meeting test files build session files on disk by hand.

**Focused runs.** `scripts/test.sh --filter X` works [M], but it still builds every target (`docs/toolchain.md:18`). [J] That includes WhisperKit, FluidAudio and the app executable, because HolosAppTests depends on the executable.

**Recommendations** [J]:
1. A `HolosTestSupport` target: `TemporaryDirectory`, `eventually`, `SeededNumbers`, builders, `SessionFixtureBuilder`, TTS fixtures.
2. `scripts/test-target.sh <Target> [--filter]`. (Done in step 3: `swift build --target <T>Tests` alone only compiles the test module, so the script runs the built bundle with SwiftPM's own test runner.)
3. A `HolosAppModel` library, so app tests don't need the executable.
4. `<Source>[+Feature]Tests` naming. Split the 3 test files over 2,000 lines along the same seams as their sources.
5. Replace the 200–500 ms sleeps with poll helpers.

---

## 6. Roadmap

All steps preserve behaviour unless marked. Sizes are non-test lines, with moved lines counted separately. "Verify" means the gate run `./scripts/test.sh --no-parallel` passes on the head commit with no test edits beyond imports and renames, plus what the row says. Checks that need the real app, the microphone or permissions are for the user after merge; agents never run them (AGENTS.md "Hard don'ts").

**Lanes** (different lanes touch different files and can run in parallel):

| Lane | Area |
|---|---|
| D | Docs |
| T | Test infrastructure |
| P | Persistence |
| A | App shell and jobs |
| R | Review |
| W | Recorder |
| C | Content |
| M | Module moves (edit Package.swift, so serialise with each other and with T) |

| # | Lane | Step | Files | Approach | Verify | Size | Status |
|---|---|---|---|---|---|---|---|
| 1 | D | AGENTS.md + module READMEs + size ratchet | `AGENTS.md`, `Sources/*/README.md`, `scripts/check-size.sh`, `contracts.md` | Rules from the audit; ratchet baseline | Script clean on main | about 600 docs, 0 Swift | merged (#125) |
| 2 | D | Delete §3.1–3.3; split meeting-design | `docs/` | First PR deletes, then 2 split PRs keeping §N.M; every citation of a moved section is rewritten to its new file in the same PR | Every `docs/meeting-design.md §` citation anywhere in the repository (Sources, Tests, `AGENTS.md`, module READMEs, `docs/`) resolves to a heading in the file it names | 3 docs PRs | in progress, 4 stacked PRs (the deletion is over the size cap in one): 2a deletes §3.1–3.2 and adds `scripts/check-doc-citations.py`; 2b (stacked) deletes §3.3; 2c and 2d split the rest |
| 3 | T | HolosTestSupport + test-target.sh | Package test targets, `Tests/HolosTestSupport` | Migrate Storage and Speakers tests first; others when touched | Same test count | about 60 non-test, about 800 test | merged (#119); HolosStorageTests moved, other targets move when touched |
| 4 | M | Extract HolosEvaluation target | `Evaluation/*` → `Sources/HolosEvaluation`; move `EvalStore.audioFingerprint` | `git mv` whole files; widen access; CLI-only dependency | Both products build; `nm` on HolosApp shows no Cloud symbols | about 150 | merged (#127) |
| 5 | P | `SessionPaths.folder`/`parse` + `VersionedFile<T>` | SessionPaths, TranscriptPointer, SpeakerSessionSnapshot; the 7 build and 5 parse sites | One builder and parser; unify the two schema decoders. **Changes behaviour:** the five parsers accepted different names, so one rule changes what some callers accept; pick the strictest rule that accepts all existing folders and test each caller | New parse tests | about 350 | merged (#128); the two CLI sites that still built `<id>.holos` directly (`RecordControl`, `People`) use `SessionPaths.folder` since step 7a (#130) |
| 6 | A | CommandRunner + shared outcome types | New `HolosMeeting/CommandRunner.swift`; the 4 `HolosApp+*` scheduler files; Codable outcomes; `DoctorReport` into the library | Async run, decode off main, `TemporaryArtifact` | CommandRunner tests with a fake executable; the user checks a summary and an echo job in the app after merge | about 500 | merged (#124) |
| 7 | P | TranscriptPublisher + `withMaintenanceArchive` | The 6 publishing stages, SessionRenameCommand | One publish function; scoped lock release | Existing fault-hook tests unchanged; add a table test | 2 × about 450 | in review: 7a `withMaintenanceArchive` (#130), 7b `TranscriptPublisher` (stacked on 7a) |
| 8 | R | Review file splits (moves only) | ReviewSession → Types/+Loading; TurnListView → one class per file; ReviewWindow → +Layout, SplitSheet, helper types | Moves plus access modifiers | `--color-moved` shows moves only | 3 × about 450 moved + about 60 | merged: `SplitSheet` and `TurnCellView` in their own files and `ReviewWindow+Joining` (#110); 8a `ReviewSession` types and loading (#141); 8b `TurnListView` one class per file (#142); 8c `ReviewWindow` layout and helper types (#143) |
| 9 | R | `ReviewRevision` token + pure `ReviewJournalClaim` + `ReviewExportScheduler` | `ReviewSession`: `wordMoves`/`movesRead`, `wordsEpoch` and the labels run (`projection.runID`), the claim in `adopt`, the "Exports" section; `WordEditTarget`, `ReviewJoinRequest`, `ReviewSplitRequest`, `FailedWordEdit`; `TurnListView.onEditWords` and `onKeepWordEdit` | Bundle the 3 counters into one value (`ReviewSession.revision`, carried as `seen`); pure claim function; the export timer and its state in one type. The session's own entry points keep their `seenMoves`/`seenEpoch`/`seenRun` parameters until step 11's `submit` | New claim tests; scheduler tests | about 500 | in review (#148) |
| 10 | R | `ReviewWordEditCoordinator` (no AppKit) | `ReviewWindow.swift` "Editing words" section (`editWords`, `trackWordChange`, `saveEdit`, `editUnsavedAgain`, `dismissUnsaved`) and "Window" section (`windowShouldClose`, `saveBeforeClose`, `keepAfterFailedClose`, `saveTypedEdit`, `beginClosing`); `ReviewClosing.swift` (`ReviewCloseGate`, `FailedWordEdit`, `ReviewCloseRecovery`, `UnsavedWordEdits`) | Pending edits, refusals and close gate behind a protocol; statics forward | Existing tests plus coordinator tests without a window | about 550 | not started |
| 11 | R | Operation lifecycle + `mutateQueue {}`, then `submit(command, seen:)` | `Operation` (`ReviewSessionTypes.swift`); `ReviewSession` "Queue" section (`enqueue`, `queued`, `drain`, `run(_:)`), `adopt` | The six flags are not one exclusive phase: `adopt` can mark a running operation both `superseded` and `overtaken` before `finish`, and `undone` / `savedUnreloaded` are independent. Use a lifecycle enum (queued, running, finished) plus separate fields for the combinable states; one mutation helper always recomputes and notifies | The 104 word-edit and 42 session tests, plus a table test of every flag combination `adopt` and undo produce today | 2 × about 400 | not started |
| 12 | W | RecordingWorkflow split + `RecorderExit` + one options mapping | RecordingWorkflow; MeetingController 32–33, 648–656; RecorderLauncher 59–78, 147–160; SessionImporter 311 | 12a moves, 12b exit owner (replaces 9 sites), 12c `MeetingVocabulary` and a single `RecordingOptions(settings:)`. **12c changes behaviour:** it removes the locale and mic divergence | Recorder tests with injected capture (`MeetingCapture`, `LiveSpeechSession` fakes); the user does a real record/stop after merge | 3 PRs: 450 moved / 450 / 200 | 12a moves (#133) and 12b `RecorderExitSequence` (#134) merged; 12c in review (#135) |
| 13 | M | Core cleanup | 9 app-only files → HolosAppModel; Core `DictationRerun.swift` → `DictationTextPipeline.swift`; Corrections I/O → Storage. `Lexicon` stays in Core: `TranscriptFixer` (Core) builds it and takes it in its signatures, and Dictation depends on Core, so moving it would make a cycle; to drop AppKit from Core, put its `NSSpellChecker` lookup behind a protocol injected from an upper target | `git mv`, imports | Build and suite | 2 × about 300 | in review: 13a `HolosAppModel` (the 8 whole app-only files; the audit's ninth was not a whole file) and Core's `DictationTextPipeline.swift`; 13b (stacked on 13a) `corrections.json` I/O and `FolderWatcher` into HolosStorage, and `NSSpellChecker` behind Core's `SpellChecking` in a new HolosSpelling target that the app and `voiceislocal` install at launch |
| 14 | A | BackgroundJobCoordinator | +DeepTranscription 176–487, +EchoCatchUp 63–287; then +MeetingSummary 146–372 and MeetingController 673–735 | One coordinator: lock probe, holds, preemption, retry, order; **add tests in the same PR** (none today) | Coordinator tests with a fake runner, including post-meeting job order; the user checks the order in the app after merge | 2 × about 800 | 14a merged: `BackgroundJobCoordinator` and final transcripts (#139), the echo catch-up (#140); 14b in review (#146): summaries on it. MeetingController's relabel stays on its own scheduler: it takes no lock and runs beside the jobs, so one-at-a-time would change it |
| 15 | A | CLI workflows into the library | `HolosCLI/Eval.swift` (lease, preparation, consent-then-upload orchestration) → `HolosEvaluation` command types; `HolosCLI/Speakers.swift` (sample refresh, export rewrites after an edit) → a `HolosMeeting` speaker-edit command | `*Command` types with `Request`/`Outcome`; the CLI keeps parsing, the consent prompt and printing | Library tests for the moved logic; CLI output unchanged | 2 × about 400 | 15a Speakers → `SpeakerEditCommand`: merged (#136); 15b Eval → `Eval*Command`: in review (#137) (step added after the audit) |

**Later, as files are touched:**
- Content splits (§2.5): lane C, 3 PRs, fully parallel.
- App pane splits, moves only: `SetupState`/`SetupAction` out of `SettingsPane.swift` and `ReadingVoicePopup` out of
  `ReadingPane.swift` (#138), ahead of the natural voices' app changes to them.
- VoiceProfileService: PeopleQueries → VoiceForgetting → VoiceSampleSync. First make the stale-names sites read names under the locks they write in (§3, "Snapshot read before the lock"); that is a race fix and changes behaviour.
- `SessionGeneration` stamp: changes behaviour. Every file that gets the stamp (`.generated.json`, `summary.json`
  (`MeetingSummaryRecord`), caches) needs a schema version bump and a rule for reading old files without it.
- Renaming `.speakers.lock` (it guards more than speakers): its own compatibility PR with an alias, after the
  lock-token refactor, never combined with it.
- Centralize the session-folder names still built outside `SessionPaths` (`SessionDeletion`'s `screen`,
  `eval/review`, `derived`; the HolosMeeting literals listed in AGENTS.md).
- `MeetingStatusSnapshot`, to take polling I/O off main.
- Move `DictationSession` out of the app delegate.
- `MeetingMenuPresenter`.
- A `FaultInjection` registry.

**Order of the outstanding steps** (1, 3, 4, 5 and 6 are merged):
- Step 7 is in progress. Step 8 can run in parallel (different lane).
- Lane R runs in order: 8, 9, 10, then 11 once 8–10 have merged and been used for a few days.
- Steps 2, 12, 13, 14 and 15 do not depend on the others (step 14 builds on 6, merged). Mind file overlaps:
  12 and 14 both edit `MeetingController`.
- Each lane runs one agent at a time; different lanes run in parallel. Steps that edit `Package.swift` (lane M)
  are serialized with each other and with lane T.

---

## 7. What not to do

| Don't | Why [J] |
|---|---|
| Rewrite ReviewSession or RecordingWorkflow, or combine a split and a redesign in one PR | Their behaviour encodes hundreds of review-found edge cases. A rewrite reopens all of them, as #93 showed (42 rounds). Move code first, then change one mechanism per PR |
| Convert the controllers to actors, or adopt SwiftUI or `@Observable`, during cleanup | It changes reentrancy points everywhere at once. Fix main-thread I/O by moving the reads off the main actor instead (`nonisolated async` readers or a detached task; a synchronous `nonisolated` call still runs on the main thread) |
| Split HolosMeeting into many targets at once | It forces hundreds of `public` changes and breaks `@testable` tests. Extract clean leaves only (Evaluation first) |
| Change on-disk formats or lock names inside a refactor | Users have existing sessions, and older recorder children can outlive the app. Format changes need a version bump, an old-version reader and their own PR. Lock renames need an alias |
| Mass-rename test files | Every in-flight worktree would conflict. Rename tests when their source file is split |
| Rewrite all docs in one pass | Split mechanically first, keeping the anchors, then rewrite each section alongside the code that changes |
| Add a protocol per type "for testability" | The existing seams work. Consolidate them instead |
| Gate refactor PRs on one clean Codex verdict | #104 got 5 clean verdicts before new findings appeared. For moves-only PRs, gate on `--color-moved` evidence and an unchanged test suite |

---

**Method:** the audit read a source export of `fa4bfa8` and the Codex inline review comments on the last 30
merged PRs (#85–#118), classified by hand; the bug-class counts in §3 come from that classification.