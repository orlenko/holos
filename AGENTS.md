# Working on Voice is Local

Voice is Local is a macOS menu bar app (`HolosApp`) and a command-line tool (`voiceislocal`, `HolosCLI`) in one
Swift package (Swift 6 language mode, macOS 27). The app's speech work runs on the Mac; only the developer
command `voiceislocal eval` can send audio to a cloud service. These rules apply to every change,
by agents and humans. Where this file and older docs disagree, this file wins; fix the doc in the same PR.

Read first: the `README.md` of each module you touch, then the doc sections its code cites.

- The meeting design is split by topic into `docs/conventions.md` (section 1) and one file per feature in
  `docs/meeting/`. They mostly describe current behaviour (`docs/conventions.md §1.2` is a build plan, and some
  subsections still name the PR that built them). Their 5.x subsections come from the build plan but hold behaviour
  the code cites, for example `docs/meeting/review-window.md §5.10` (Review window) and
  `docs/meeting/online-calls-echo.md §5.11` (online calls), so read the cited subsection, not the whole section.
  Sections keep their numbers, and `docs/meeting-design.md` lists the file each is in. The rest of the build plan
  and its review log are in `docs/archive/meeting-plan-2026-09.md`.
- `docs/design.md` describes the user-facing tools, one heading per feature. `docs/contracts.md` lists the
  cross-module contracts. `docs/status.md` says what is verified and what is pending.
- `docs/architecture-roadmap.md` lists the planned structural changes and their status. Check it before
  starting structural work, and update its Status column in your PR.

## Module map

Each target depends only on targets above it in this table (`Package.swift` is the source of truth). "May import"
lists Holos targets, then notable system or package frameworks.

| Target | Owns | Must not own | May import |
|---|---|---|---|
| [HolosCore](Sources/HolosCore/README.md) | Shared value types, `HolosJSON`, `HolosError`, `HolosPaths`, text processing (fixer, spoken code, seams, fillers, word list) | File I/O, locks, UI, engines | (none); Foundation, NaturalLanguage |
| [HolosStorage](Sources/HolosStorage/README.md) | Every path and lock inside a `<id>.holos` folder, `AtomicFile`, `SessionArchive`, the speaker, profile, history, word-list and screen-context stores, `corrections.json`'s file and lock, deletion | Transcript interpretation, capture, UI | Core |
| [HolosSpeech](Sources/HolosSpeech/README.md) | Apple `SpeechTranscriber`/`DictationTranscriber` adapter | Recording lifetime, session files, focus | Core; Speech, AVFoundation |
| [HolosSynthesis](Sources/HolosSynthesis/README.md) | Voice inventory and selection, rendering, playback, audiobook writing, `ExclusivePublisher`, the natural voice catalog and pack install (`NaturalVoiceModels`) | Document loading, meetings, FluidAudio | Core; AVFoundation, CryptoKit |
| [HolosContent](Sources/HolosContent/README.md) | Document and web extraction, the reading pipeline, the reading library and its files | Speech recognition, meetings | Core, Synthesis; AppKit, PDFKit, WebKit |
| [HolosAudio](Sources/HolosAudio/README.md) | Microphone/system capture, chunk writing, track rendering, screen capture, power | Transcripts, speaker names, UI | Core, Storage; AVFoundation, CoreAudio, ScreenCaptureKit, IOKit |
| [HolosDesktop](Sources/HolosDesktop/README.md) | Global hotkey, text insertion into other apps | Dictation logic, storage | Core; AppKit, ApplicationServices, Carbon |
| [HolosDictation](Sources/HolosDictation/README.md) | `DictationController` (one utterance at a time), Run Again, on-device fix | Insertion, windows | Core, Audio, Speech; FoundationModels |
| [HolosSpeakers](Sources/HolosSpeakers/README.md) | Pure speaker algorithms: alignment, runs, projection, carry-over, echo, recognition math, exports | Any file I/O, engines, names inferred from text | Core; Accelerate |
| [HolosSpelling](Sources/HolosSpelling/README.md) | `SystemSpellChecker` (`NSSpellChecker`), which each executable installs as Core's `SpellChecking` | The questions asked of it (`Lexicon`, `DictationSeams`) | Core; AppKit |
| [HolosMeeting](Sources/HolosMeeting/README.md) | Recorder workflow and state machine, `MeetingController`, post-processing, `ReviewSession`, summaries, people and voice profiles, import, catalog | AppKit, FluidAudio, WhisperKit, evaluation code, new path literals inside a session (existing ones: see below) | Core, Storage, Audio, Speech, Speakers; AVFoundation, Vision, NaturalLanguage |
| [HolosDiarization](Sources/HolosDiarization/README.md) | The FluidAudio diarizer adapter and model install/verification | Being linked by the app | Core; FluidAudio |
| [HolosWhisper](Sources/HolosWhisper/README.md) | WhisperKit deep transcription and model install | Being linked by the app | Core; WhisperKit, CoreML |
| [HolosPocket](Sources/HolosPocket/README.md) | The Pocket TTS natural-voice backend (FluidAudio) and its pinned download and check | Being linked by the app; which voices are offered | Core, Synthesis; FluidAudio |
| [HolosEvaluation](Sources/HolosEvaluation/README.md) | The reference evaluation behind `voiceislocal eval`: cloud and local runs, scoring, review | Being linked by the app; anything the recording path needs | Core, Storage, Audio, Speakers, Meeting; AVFoundation, CryptoKit |
| [HolosAppModel](Sources/HolosAppModel/README.md) | The app's own decisions without AppKit (settings search, setup assistant flow, permission buttons, launch, Copy Result) | AppKit, controllers, anything another library or the CLI needs | Core |
| [HolosApp](Sources/HolosApp/README.md) | AppKit views, windows, menus, wiring of controllers | Business logic, session-file layout, decoding CLI output by hand | All libraries except Diarization, Whisper, Pocket and Evaluation |
| [HolosCLI](Sources/HolosCLI/README.md) | Argument parsing and printing over library `*Command` types | A second copy of workflow logic | All libraries except Desktop; ArgumentParser |

Two library targets live under `Tests/` and only test targets depend on them: `HolosTestSupport` (HolosCore only)
and `HolosSessionTestSupport` (adds HolosStorage); see `Tests/HolosTestSupport/README.md`.

Known exceptions today (not precedents; do not add to them):

- Session paths are also built outside HolosStorage: HolosEvaluation's `EvalPaths` (`eval/`, `derived/eval-cloud/`); and names inside a session in HolosMeeting:
  `stop.request` (`RecordingWorkflow`), `control/<id>.json` (`RecorderChannel`), `derived/deep-<track>-16k.caf`
  (`DeepTranscriptionStage`), `echo/frames-<hash>.bin` (`EchoAnalysisStage`), `exports/edited-<stamp>.<ext>`
  (`SessionExports`).
- `HolosApp` holds the dictation session, and 13 of its files import `HolosStorage`.
- `CommandPrinted` (`HolosApp+Meeting.swift`) still reads the result line (`summary`, `message`, `runID`) of the
  JSON that `session recover`, `diarize` and `delete` print (and `rename`, besides its typed outcome) as
  `[String: Any]` with `JSONSerialization`. The other outputs the app reads (`doctor`, `deep-transcribe`,
  `summarize`, `echo-analyze`) are decoded into their library types through `CommandRunner`.
- `WebArticleExtractor` embeds several hundred lines of JavaScript in Swift strings (over the 50-line cap below).

## Where new code goes

- Pure algorithm over values: `HolosSpeakers` (speaker-related) or `HolosCore`. No I/O, no clocks, no globals.
- A file inside a session folder: a `SessionPaths` function in `HolosStorage`, used through `AtomicFile`. Add no
  new file-name literals for session files anywhere else (the existing ones are listed above).
- A controller the app needs: an `@MainActor` class without AppKit in `HolosMeeting` or `HolosDictation`, so tests
  can drive it. `HolosApp` gets the view and the wiring only.
- A CLI command: the logic as a `*Command` type (with `Request`/`Outcome`) in the library; `HolosCLI` parses and
  prints.
- Anything that needs FluidAudio or WhisperKit: `HolosDiarization`/`HolosWhisper`/`HolosPocket`, reached by the app
  only through a `voiceislocal` child process.
- Evaluation and cloud comparison code: `HolosEvaluation` (of the products, only `HolosCLI` links it).
- An app-only decision that needs no AppKit (what a settings row, the Setup Assistant or a menu item does):
  `HolosAppModel`, tested in `HolosAppModelTests` without building the app.

## Size caps

| What | Cap |
|---|---|
| Source file (`Sources/`) | 600 lines soft, 1,000 hard; a file already over the hard cap may not grow |
| Test file | 1,000 lines for new files (not checked yet) |
| Type | 25 stored properties, 60 methods |
| Function | 80 lines |
| Embedded script (JavaScript in a Swift string) | 50 lines; longer goes to `Resources/` with `.embedInCode` |

`scripts/check-size.sh` enforces the file cap against `scripts/size-baseline.txt` (every source file over 600
lines and its count). It fails when a file over 1,000 lines has grown past its entry or a file without an entry
is over 1,000; it warns for a file without an entry over 600 and for a listed file that grew but stays within
1,000. A missing or unreadable baseline, one whose entries do not match its `# entries: N` line, or a source
file it cannot read, is an error. It takes well under a second and is not part of `scripts/test.sh`; run it
before every PR. After shrinking a file, run `scripts/check-size.sh --update-baseline` to lower its entry. The
update is refused while the check fails or while any file in the baseline has grown: name each grown file
(`--update-baseline --allow-growth <path>`) and explain it in the PR description. `--allow-growth` only covers
growth that ends at or below 1,000 lines; growth past 1,000 lines and a new file over 1,000 lines are never
accepted. A file moved whole (`git mv`) keeps its entry, so rename the path in `scripts/size-baseline.txt` in
the same PR. The type and function caps are review rules; nothing checks them yet.

## Invariants at type level

- A stateful type gets an `Invariants:` block in its doc comment: numbered rules, stated as rules ("every queue
  change recomputes the projection and notifies"), not as the race that found them. Body comments cite them
  ("invariant 3"). Few types do this today; add the block when you change a stateful type.
- Prefer making a rule impossible to break over documenting it: a type that can only be built valid, an enum
  phase instead of several booleans, a scoped `with…` function instead of a manual release.

## Threading and locks

The concurrency rules in `docs/conventions.md §1.3` and the lock rules in `docs/conventions.md §1.7`
apply. In short:

- Swift 6 strict concurrency. Values crossing a boundary are `Sendable` structs or enums. Small shared state uses
  `Mutex` (Synchronization). `@unchecked Sendable` and `nonisolated(unsafe)` are allowed only for a narrow
  wrapper whose safety the code states in a comment next to it: a C handle or mmap region, an immutable value, or
  a non-`Sendable` framework object confined to one task, one actor, or a lock (for example
  `WhisperKitTranscriber`, `SingleBufferFeed`, `OpenedPlayback`). Never use them to silence a warning on shared
  mutable state.
- **Target state:** `@MainActor` types do no file system work; readers run off the main actor (a
  `nonisolated async` function or a detached task; a synchronous `nonisolated` call still runs on the main
  thread) and return snapshots. Today, for example, `MeetingController` reads `status.json` and probes locks on
  the main actor while it follows a meeting; do not add more. (`CommandRunner` already reads command output off
  the main actor.) Work that can exceed about 10 ms already must run off the main actor
  (`docs/conventions.md §1.3`).
- Locks are `flock` files and are **not re-entrant**. Order for waits: speakers → profiles. Use the scoped APIs
  (`SessionArchive.withSpeakerLock`, `withSpeakerLockAsync`, `withMaintenanceArchive`,
  `SpeakerProfileStore.update`/`withLockedDatabase`, `ProcessingLease`). A new function that must run under a lock is named `…Locked` and says "Caller holds the
  … lock"; some existing ones say so only in their doc comment (`SessionSpeakerStore`). **Target state:** lock
  requirements become token parameters (`withSessionLock { tx in … }`), not comments.
- Read data that a write depends on inside the same lock as the write (names for exports:
  `SessionExports.regenerate(session:people:)`, not names read earlier).
- No new `try?` on writes or removals. Throw, or log and report the leftover.
- Give every await on a platform API that can hang a timeout, call `Task.checkCancellation()` in long loops, and
  publish nothing partial from cancelled work (`docs/conventions.md §1.3`).

## Shared primitives (use these; do not write another)

Exist today:

- Session files: `SessionPaths`, `AtomicFile` (`write`, `create`, `append`, `readJSON`, `readIfPresent`,
  `removeTree`), `AtomicFile.openFolder` (no symlink following; internal to HolosStorage), `SessionArchive`
  (`openForMaintenance(at:lease:)`, `recover(at:lease:)`), `TranscriptPointer`.
- Session folder names: `SessionPaths.folder(for:in:)` / `folderName(for:)` build `<id>.holos`;
  `SessionPaths.parse(folderName:)` gives the ID of an `<uppercase UUID>.holos` name; `isSessionFolderName` (any
  `<something>.holos`, renamed folders included) and `isListedSessionFolderName` (the same, not hidden) decide what
  counts as a session folder.
- Versioned JSON files: `VersionedFile<T: ValidatedDecodable>` (bounded read, newer `schemaVersion` refused before
  decoding, `HolosJSON`, then `validate`). The transcript pointer and `SessionFiles`' transcript, `meeting.json` and
  `postprocess.json` readers use it; the other versioned readers are not yet migrated (they share
  `SchemaVersion.decode` or check the version by hand; `Sources/HolosStorage/README.md`).
- Locks: `SessionArchive.acquireProcessingLease` / `ProcessingLease`, `withSpeakerLock`, `isProcessing`,
  `SpeakerProfileStore.update`/`withLockedDatabase`. Maintenance writes go through
  `SessionArchive.withMaintenanceArchive(at:lease:)`, which releases the writer lock however its body ends, not
  through `openForMaintenance` and a manual `releaseLock()`.
- JSON and errors: `HolosJSON` (session files and the HolosStorage stores; new persisted files use it too; the
  exceptions today are listed in `docs/contracts.md` "Persistence"), `OpenStringCode` (growable codes),
  `HolosError` (do not add cases; reasons travel in data).
- Roots: `HolosPaths.sessions` (honours `HOLOS_DATA_DIR`), `HolosPaths.supportRoot` (honours `HOLOS_SUPPORT_DIR`).
- Sessions: `SessionLocator.resolve` (ID or prefix to folder), `SessionCatalog.list`.
- Child processes: `ProcessSpawner` (the `posix_spawn` helper every child of the app and libraries goes through;
  close-on-exec default, own session). The one other spawn is `voiceislocal eval` running `/usr/bin/open`.
- Running a background job on meetings (one at a time on this Mac, held back by meetings, Review and the
  background job lock, stopped when a meeting starts, retried when turned down): a `BackgroundJobKind` run by
  `BackgroundJobCoordinator` (HolosMeeting; final transcripts, echo analyses and summaries). `MeetingController`'s
  automatic relabel keeps its own scheduler: it runs beside those jobs, not one at a time with them.
- Running a `voiceislocal` command from the app and reading its output: `CommandRunner` (`start` returns a
  `CommandHandle` to stop it with SIGTERM; `run` awaits it), which writes its output to `TemporaryArtifact`s,
  decodes it off the main actor into a `CommandResult`, and removes the files. Decode into the library's own types:
  `DoctorReport`, `PostProcessingRecord`, `SessionSummarizeCommand.Outcome`, `SessionEchoAnalyzeCommand.Outcome`,
  `SessionRenameCommand.Outcome`. Long-running installs whose progress is read while they run (`setup --speakers`,
  `setup --whisper`, `setup --natural-voices`) and the natural-voice `say` helper go through `MaintenanceLauncher`
  directly.
- Making a new transcript current, or carrying the speaker head over to it: `TranscriptPublisher.publish`
  (HolosMeeting; the checks run under the writer and speaker locks, then one write order and its repair).
- Exports: `SessionExports.regenerate(session:people:)`. Reading files: `ExclusivePublisher.publish`.
- What the Review window showed when the person acted (word moves followed, words epoch, labels run):
  `ReviewRevision`, from `ReviewSession.revision`. Edit fields, splits and joins carry it as one value; do not add
  another loose counter beside it.
- Logging: `Logger(subsystem: "ca.orlenko.holos.app", category: …)`; categories and privacy rules in
  `docs/conventions.md §1.5`.

Planned, see the [architecture roadmap](docs/architecture-roadmap.md) (`docs/architecture-roadmap.md §3` and
`docs/architecture-roadmap.md §6`; none of these exist yet, so do not reference them as if they did):
`SessionGeneration` (derived-data stamps), `Drainable` (pending work at close and quit), one revision-stamped Review
entry point (`ReviewSession.submit(_:seen:)`), a lock-token type.

## Tests

- Run tests only through `./scripts/test.sh` or `./scripts/test-target.sh <Target>Tests [--filter …]` (both always
  point `HOLOS_DATA_DIR` and `HOLOS_SUPPORT_DIR` at a fresh temporary folder, replacing values set in the shell,
  and load the Testing macro plugin;
  `test-target.sh` builds only that target and its dependencies). Gate run: `./scripts/test.sh --no-parallel`. A
  plain `swift test` can touch real data; never use it.
- Shared helpers live in `Tests/HolosTestSupport` (`TemporaryDirectory`, `PollBudget`, `eventually`,
  `FileInspection`, `SeededNumbers`, transcript and audio fixtures) and `Tests/HolosSessionTestSupport`
  (`SessionFixtureBuilder`); see `Tests/HolosTestSupport/README.md`. Use them in new tests; HolosStorageTests and
  HolosSpeakersTests have moved to them, HolosMeetingTests uses the shared `TemporaryDirectory` and `PollBudget`
  (its `eventually` stays local: it polls on the main actor), and other targets still have local copies that go
  when the target is next touched.
- Swift Testing only (`@Test`, `#expect`, `#require`). Test names describe behaviour.
- Name new files `<Source>Tests.swift` or `<Source>+<Feature>Tests.swift` so the tests for a file can be found.
  Rename old ones when their source file is split, not in bulk.
- Add no wall-clock upper bounds and no new wall-clock deadline loops. Existing ones: `PollBudgetTests`' 60 s
  ceiling on a cancelled wait, `SessionDeletionTests`' check that a deletion marker's date is within 60 s of now,
  lower bounds that a lock wait lasted its timeout (`SessionLocksTests`), and `ContinuousClock` deadline loops in
  `SessionArchiveTests`, `StatusWriterTests`, `StopPathTests` and `RecordingCancellationTests`. Wait with
  `PollBudget` / `eventually` and bound tests with `.timeLimit`. Add no sleep over 50 ms outside a poll helper.
- Mark a suite `.serialized` only with a comment naming the shared resource.
- Keep the default suite off the microphone, permission prompts, the network, speech-recognition assets,
  downloaded models and the user's data. Use the seams (`MeetingCapture`, `LiveSpeechSession`, `SpeakerDiarizer`,
  `SessionClock`, `FreeSpaceProvider`, `RecorderLauncher`, `SystemPowerEvents`, `SpeakerProfileStore(directory:)`,
  an injected `UserDefaults` suite). Gate real-model and real-asset tests on a `HOLOS_*` environment variable
  with `.enabled(if:)`, so they report as skipped (a few older ones return early instead). What the default suite
  does touch today: the Mac's installed text-to-speech voices (`NativeSpeechRendererTests`), child processes
  (small test scripts and system tools in `LeaseHandOffTests`, `LauncherTests`, `CommandRunnerTests`,
  `ReadingPipelineTests`, and some `MeetingControllerTests`, `ReviewSessionTests` and `ReviewWordEditTests`), and
  an offline `WKWebView` (`WebArticleTests`).
- Temporary folders go under `FileManager.default.temporaryDirectory` and are removed with `defer`.

## Docs and comments

- State current behaviour in the present tense. No PR numbers, waves, dates, "used to", "now", or "the user
  asked" in docs or code comments. History belongs in git and PR descriptions. The one exception is
  `docs/architecture-roadmap.md`: a dated audit snapshot whose findings cite PRs and review rounds as evidence,
  and whose §6 Status column tracks steps by PR. Its guidance (what to do next, how to verify) stays current.
- Cite specs as `docs/<file>.md §N.M`, or `docs/design.md "<Heading>"` for docs without numbers. A citation must
  resolve to an existing heading. A `§N.M` cites the last Markdown file named before it in its paragraph, list item,
  table row or comment block, so after naming another file, name the cited one again. A table that lists another
  file's sections without naming it in every row (`docs/architecture-roadmap.md §4.3` lists the meeting design's
  old numbers) goes between `<!-- citations: <file>.md -->` and `<!-- /citations -->`: a bare `§N.M` there cites
  that file, and once that file is an index (`docs/meeting-design.md`), the file its table maps the number to.
  Elsewhere in docs, a `§N.M` with no file named before it names a heading of its own file; cite another file's
  section by its path relative to the citing file (`../<file>.md §<N.M>`). `scripts/check-doc-citations.py` checks
  all of this in under a second (`--self-test` runs its own cases). Run it before every PR that moves a section or
  adds a citation.
- A PR that changes behaviour updates the cited section in the same PR.
- Comments explain why and state rules; they do not narrate review rounds.

## Pull requests

- At most about 1,000 changed non-test lines. Moved lines are counted separately; prove a move with
  `git diff --color-moved=dimmed-zebra --color-moved-ws=ignore-all-space` output in the PR description.
- Bigger work goes in stacked PRs, each building and passing on its own. Settle the design before opening the PR.
- A refactor PR changes no behaviour and no tests beyond imports and renames. Never mix a file split with a
  redesign, or a refactor with an on-disk format or lock-name change (formats need a version bump, an old-version
  reader and their own PR; lock renames need an alias).
- When two review findings fall in the same class, fix the shared mechanism, not each site.
- Gates before merge, all on the head commit: `./scripts/test.sh --no-parallel` passes, `scripts/check-size.sh`
  passes, the GitHub Codex review is clean, and a local astra review is clean. For a moves-only refactor, the
  `--color-moved` evidence and an unchanged test suite are also required.

## Privacy

The repository is public. Never copy meeting text, transcript lines, speaker or people names, vocabulary, or other
user data into code, tests, fixtures, docs, commit messages, or PRs. Tests generate their own text and audio;
opt-in tests that read private recordings get them from paths in `HOLOS_*` environment variables, never from
files committed to the repository.
Do not log transcript text, names, vocabulary or embeddings (`docs/conventions.md §1.5`).

## Hard don'ts

- Never play audio aloud (no `say` without `-o`, no `afplay`, no playback in tests). Render to files only.
- Never write dictated text to the clipboard automatically. Only Copy actions the user chooses (Copy Result, Copy
  Original, History's Copy) write it; a failed insertion returns `needsCopy` and waits for the user.
- Never read or write the user's data folder (`~/Library/Application Support/Holos`) from tests or scripts; use
  `scripts/test.sh`, which redirects both roots. One opt-in test reads from it today: `FluidDiarizerFixtureTests`
  loads the installed speaker models from there unless `HOLOS_FIXTURE_MODELS_DIR` is set.
- Never launch, kill, or rebuild the user's running app, and do not run `scripts/build-app.sh`,
  `scripts/restart-app.sh` or `scripts/release-app.sh` unless the user asks. Do not record from the microphone or
  trigger permission prompts.
- Never change an on-disk format or a lock file name without a schema version bump and a reader for the old one.
