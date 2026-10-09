# Working on Voice is Local

Voice is Local is a macOS menu bar app (`HolosApp`) and a command-line tool (`voiceislocal`, `HolosCLI`) in one
Swift package (Swift 6 language mode, macOS 27). All speech work runs on the Mac. These rules apply to every change,
by agents and humans. Where this file and older docs disagree, this file wins; fix the doc in the same PR.

Read first: the `README.md` of each module you touch, then the doc sections its code cites.

- `docs/meeting-design.md` §1 (conventions), §2 (session folder), §4 (integration seams) describe current
  behaviour. §0 and §5–§10 are the build plan and review log; §5.10 (Review window) and §5.11 (online calls)
  still hold behaviour the code cites, so read the cited subsection, not the whole plan.
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
| [HolosStorage](Sources/HolosStorage/README.md) | Every path and lock inside a `<id>.holos` folder, `AtomicFile`, `SessionArchive`, the speaker, profile, history, word-list and screen-context stores, deletion | Transcript interpretation, capture, UI | Core |
| [HolosSpeech](Sources/HolosSpeech/README.md) | Apple `SpeechTranscriber`/`DictationTranscriber` adapter | Recording lifetime, files, focus | Core; Speech, AVFoundation |
| [HolosSynthesis](Sources/HolosSynthesis/README.md) | Voice inventory and selection, rendering, playback, audiobook writing, `ExclusivePublisher` | Document loading, meetings | Core; AVFoundation |
| [HolosContent](Sources/HolosContent/README.md) | Document and web extraction, the reading pipeline, the reading library and its files | Speech recognition, meetings | Core, Synthesis; AppKit, PDFKit, WebKit |
| [HolosAudio](Sources/HolosAudio/README.md) | Microphone/system capture, chunk writing, track rendering, screen capture, power | Transcripts, speaker names, UI | Core, Storage; AVFoundation, CoreAudio, ScreenCaptureKit, IOKit |
| [HolosDesktop](Sources/HolosDesktop/README.md) | Global hotkey, text insertion into other apps | Dictation logic, storage | Core; AppKit, ApplicationServices, Carbon |
| [HolosDictation](Sources/HolosDictation/README.md) | `DictationController` (one utterance at a time), Run Again, on-device fix | Insertion, windows | Core, Audio, Speech; FoundationModels |
| [HolosSpeakers](Sources/HolosSpeakers/README.md) | Pure speaker algorithms: alignment, runs, projection, carry-over, echo, recognition math, exports | Any file I/O, engines, names inferred from text | Core; Accelerate |
| [HolosMeeting](Sources/HolosMeeting/README.md) | Recorder workflow and state machine, `MeetingController`, post-processing, `ReviewSession`, summaries, people and voice profiles, import, catalog, evaluation | AppKit, FluidAudio, WhisperKit, path literals inside a session | Core, Storage, Audio, Speech, Speakers; AVFoundation, Vision, NaturalLanguage |
| [HolosDiarization](Sources/HolosDiarization/README.md) | The FluidAudio diarizer adapter and model install/verification | Being linked by the app | Core; FluidAudio |
| [HolosWhisper](Sources/HolosWhisper/README.md) | WhisperKit deep transcription and model install | Being linked by the app | Core; WhisperKit, CoreML |
| [HolosApp](Sources/HolosApp/README.md) | AppKit views, windows, menus, wiring of controllers | Business logic, session-file layout, decoding CLI output by hand | All libraries except Diarization and Whisper |
| [HolosCLI](Sources/HolosCLI/README.md) | Argument parsing and printing over library `*Command` types | A second copy of workflow logic | All libraries except Desktop; ArgumentParser |

Known exceptions, not precedents: `HolosCore` holds `Lexicon` (AppKit), `Corrections` (file I/O, flock) and
app-only flows (`SetupAssistantFlow`, `SettingsSearch`, `PermissionButtons`, …); `HolosMeeting/Evaluation` is
CLI-only code in the app's link graph; the dictation session and the background-job schedulers
(`HolosApp+DeepTranscription`, `+MeetingSummary`, `+EchoCatchUp`) live in `HolosApp`; 13 `HolosApp` files import
`HolosStorage`. Do not add to these.

## Where new code goes

- Pure algorithm over values: `HolosSpeakers` (speaker-related) or `HolosCore`. No I/O, no clocks, no globals.
- A file inside a session folder: a `SessionPaths` function in `HolosStorage`, used through `AtomicFile`. No file
  name literals for session files anywhere else.
- A controller the app needs: an `@MainActor` class without AppKit in `HolosMeeting` or `HolosDictation`, so tests
  can drive it. `HolosApp` gets the view and the wiring only.
- A CLI command: the logic as a `*Command` type (with `Request`/`Outcome`) in the library; `HolosCLI` parses and
  prints.
- Anything that needs FluidAudio or WhisperKit: `HolosDiarization`/`HolosWhisper`, reached by the app only through
  a `voiceislocal` child process.
- Evaluation and cloud comparison code: `HolosMeeting/Evaluation` until the `HolosEvaluation` target exists
  ([roadmap](docs/architecture-roadmap.md) step 4). App-only models stay in `HolosApp` (no `HolosAppModel`
  target yet; step 13).

## Size caps

| What | Cap |
|---|---|
| Source file (`Sources/`) | 600 lines soft, 1,000 hard; a file already over the hard cap may not grow |
| Test file | 1,000 lines for new files (not checked yet) |
| Type | 25 stored properties, 60 methods |
| Function | 80 lines |
| Embedded script (JavaScript in a Swift string) | 50 lines; longer goes to `Resources/` with `.embedInCode`, like `Readability.js` |

`scripts/check-size.sh` enforces the file cap against `scripts/size-baseline.txt` (every source file over 600
lines and its count). It fails when a file over 1,000 lines has grown past its entry or a file without an entry
is over 1,000; it warns for a file without an entry over 600. It takes well under a second and is not part of
`scripts/test.sh`; run it before every PR. After shrinking a file, run
`scripts/check-size.sh --update-baseline` to lower its entry. Raising an entry needs a reason in the PR description.
The type and function caps are review rules; nothing checks them yet.

## Invariants at type level

- A stateful type gets an `Invariants:` block in its doc comment: numbered rules, stated as rules ("every queue
  change recomputes the projection and notifies"), not as the race that found them. Body comments cite them
  ("invariant 3"). Few types do this today; add the block when you change a stateful type.
- Prefer making a rule impossible to break over documenting it: a type that can only be built valid, an enum
  phase instead of several booleans, a scoped `with…` function instead of a manual release.

## Threading and locks

The concurrency rules in `docs/meeting-design.md` §1.3 and the lock rules in §1.7 apply. In short:

- Swift 6 strict concurrency. Values crossing a boundary are `Sendable` structs or enums. Small shared state uses
  `Mutex` (Synchronization). `@unchecked Sendable` and `nonisolated(unsafe)` only around a C handle or an mmap
  region, with a comment stating the invariant.
- **Target state:** `@MainActor` types do no file system work; readers are `nonisolated` and return snapshots.
  Today `MeetingController` polls status files on the main actor and the app's job schedulers read output files
  there; do not add more. Work that can exceed about 10 ms already must run off the main actor (§1.3).
- Locks are `flock` files and are **not re-entrant**. Order for waits: speakers → profiles. Use the scoped APIs
  (`SessionArchive.withSpeakerLock`, `withSpeakerLockAsync`, `SpeakerProfileStore.update`/`withLockedDatabase`,
  `ProcessingLease`). A function that must run under a lock is named `…Locked` and says "Caller holds the speaker
  lock". **Target state:** lock requirements become token parameters (`withSessionLock { tx in … }`), not
  comments.
- Read data that a write depends on inside the same lock as the write (names for exports:
  `SessionExports.regenerate(session:people:)`, not names read earlier).
- No new `try?` on writes or removals. Throw, or log and report the leftover.
- Every await on a platform API that can hang has a timeout. Long loops call `Task.checkCancellation()`.
  Cancelled work publishes nothing partial.

## Shared primitives (use these; do not write another)

Exist today:

- Session files: `SessionPaths`, `AtomicFile` (`write`, `create`, `append`, `readJSON`, `readIfPresent`,
  `removeTree`), `AtomicFile.openFolder` (no symlink following), `SessionArchive` (`openForMaintenance(at:lease:)`,
  `recover(at:lease:)`), `TranscriptPointer`.
- Locks: `SessionArchive.acquireProcessingLease` / `ProcessingLease`, `withSpeakerLock`, `isProcessing`,
  `SpeakerProfileStore.update`/`withLockedDatabase`.
- JSON and errors: `HolosJSON` (every persisted file), `OpenStringCode` (growable codes), `HolosError` (do not add
  cases; reasons travel in data).
- Roots: `HolosPaths.sessions` (honours `HOLOS_DATA_DIR`), `HolosPaths.supportRoot` (honours `HOLOS_SUPPORT_DIR`).
- Sessions: `SessionLocator.resolve` (ID or prefix to folder), `SessionCatalog.list`.
- Child processes: `ProcessSpawner` (the one `posix_spawn` helper; close-on-exec default, own session).
- Exports: `SessionExports.regenerate(session:people:)`. Reading files: `ExclusivePublisher.publish`.
- Logging: `Logger(subsystem: "ca.orlenko.holos.app", category: …)`; categories and privacy rules in §1.5.

Planned, see the [architecture roadmap](docs/architecture-roadmap.md) §3 and §6 (none of these exist yet; do not
reference them as if they did): `TranscriptPublisher` and `withMaintenanceArchive` (one publish path for
transcripts), `CommandRunner` and `TemporaryArtifact` (spawn, decode, clean up), `VersionedFile<T>` (one schema-checked decoder), `SessionPaths.folder`/`parse` (one `<id>.holos` naming
rule), `SessionGeneration` (derived-data stamps), `Drainable` (pending work at close and quit), `ReviewRevision`
(revision-stamped Review commands), a lock-token type, `HolosTestSupport`, `scripts/test-target.sh`.

## Tests

- Run tests only through `./scripts/test.sh` (it points `HOLOS_DATA_DIR` and `HOLOS_SUPPORT_DIR` at a temporary
  folder and loads the Testing macro plugin). Focused run: `./scripts/test.sh --filter <Suite>`. Gate run:
  `./scripts/test.sh --no-parallel`. A plain `swift test` can touch real data; never use it.
- Swift Testing only (`@Test`, `#expect`, `#require`). Test names describe behaviour.
- Name new files `<Source>Tests.swift` or `<Source>+<Feature>Tests.swift` so the tests for a file can be found.
  Rename old ones when their source file is split, not in bulk.
- No wall-clock assertions and no elapsed-time bounds. Wait with poll budgets (`PollBudget`, `eventually` in
  `Tests/HolosMeetingTests/Fakes.swift`) and bound tests with `.timeLimit`. No sleep over 50 ms outside a poll
  helper.
- Mark a suite `.serialized` only with a comment naming the shared resource.
- The default suite uses no microphone, permissions, network, installed speech assets, models, or user data. Use
  the seams (`MeetingCapture`, `LiveSpeechSession`, `SpeakerDiarizer`, `SessionClock`, `FreeSpaceProvider`,
  `RecorderLauncher`, `SystemPowerEvents`, `SpeakerProfileStore(directory:)`, an injected `UserDefaults` suite).
  Real-model tests are opt-in with `.enabled(if:)` on a `HOLOS_*` environment variable.
- Temporary folders go under `FileManager.default.temporaryDirectory` and are removed with `defer`.

## Docs and comments

- State current behaviour in the present tense. No PR numbers, waves, dates, "used to", "now", or "the user
  asked" in docs or code comments. History belongs in git and PR descriptions. The one exception is the Status
  column of `docs/architecture-roadmap.md` §6, which tracks steps by PR.
- Cite specs as `docs/<file>.md §N.M`, or `docs/design.md "<Heading>"` for docs without numbers. A citation must
  resolve to an existing heading.
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
user data into code, tests, fixtures, docs, commit messages, or PRs. Tests generate their own text and audio.
Logs never contain transcript text, names, vocabulary or embeddings (§1.5).

## Hard don'ts

- Never play audio aloud (no `say` without `-o`, no `afplay`, no playback in tests). Render to files only.
- Never write dictated text to the clipboard automatically. Only Copy actions the user chooses (Copy Result, Copy
  Original, History's Copy) write it; a failed insertion returns `needsCopy` and waits for the user.
- Never read or write the user's data folder (`~/Library/Application Support/Holos`) from tests or scripts; use
  `scripts/test.sh`, which redirects both roots.
- Never launch, kill, or rebuild the user's running app, and do not run `scripts/build-app.sh`,
  `scripts/restart-app.sh` or `scripts/release-app.sh` unless the user asks. Do not record from the microphone or
  trigger permission prompts.
- Never change an on-disk format or a lock file name without a schema version bump and a reader for the old one.
