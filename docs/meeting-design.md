# Meeting recording: implementation design

Status: implementation-ready design for PR1–PR11 of
[meeting-recording-plan.md](meeting-recording-plan.md) (PR12, minutes, is out of scope).
Written 2026-09-23 from the code on branch `meeting-plan`, FluidAudio 0.17.1 sources
(`5c51c5c9`), and the user's decisions in plan §8. Revised 2026-09-24 after a three-lens
design review (80 findings, §10) and spike S1 ([speaker-evaluation.md](speaker-evaluation.md)).
No product code exists for it yet.

Several engineers build this in parallel, one PR each, without talking to each other.
Everything they must agree on is fixed here: target graph, file formats, the contract
files (§3, copy verbatim), the seams between PRs (§4), and each PR's file list and
"does not touch" list (§5). If a PR needs a contract change beyond what §3.0 allows, it
stops and reports it; it does not edit a file owned by another PR.

## 0. Overview

### 0.1 User decisions this design implements

| # | Decision | Where it shows up |
|---|---|---|
| 1 | FluidAudio 0.17.1, pinned, checksummed, credited | §4.8, PR7a, `THIRD_PARTY_NOTICES.md`, About panel (PR4) |
| 2 | Remember voices: opt-in, only from confirmed labels, with forget and export | §4.10, PR10. Voice embeddings are stored only as profile samples of people the user confirmed with voice learning on, extracted on demand (§4.10); post-processing never persists them; names are not voiceprints and are always kept |
| 3 | Int16 audio now; AAC compaction later | PR2a (`AudioChunkWriter`); system audio is also recorded mono (§4.5) |
| 4 | Recorder = bundled `holos` CLI child of the app; in-process fallback allowed | §4.1, §4.6, PR4 (`RecorderLauncher` with both implementations) |
| 5 | Sleep < 15 min resumes, else finalize at the sleep point | §4.4, PR2b. Refinement to confirm: sleep that starts while *paused* keeps the meeting paused (§9 Q1) |
| 6 | Dictation is paused during meeting recording; no dictation markers | §4.12, PR4 |
| 7 | No live speaker labels in v1 | Diarization runs only after stop (§4.7) |
| 8 | Consent is the user's responsibility; dismissible reminder in the start panel | PR4 start panel |
| 9 | Built-in laptop microphone; no device picker; no boundary-mic test | §4.12. In-person meetings record the built-in microphone. Refinement to confirm: online calls record the system default input (the headset the call app uses), shown as a static label (§9 Q2) |

### 0.2 PR map

| PR | Wave | Goal | New targets |
|---|---|---|---|
| PR6 | 0 | Contract files (§3), `AtomicFile`, `SessionPaths`, locks and lease, free space, `SessionSpeakerStore`, `SessionArchive` fixes (torn appends, transcript pointer, maintenance open) | — |
| PR1 | 1 | Move recording out of the CLI into `HolosMeeting`; capture and speech seams; lifecycle hook; post-processor skeleton | HolosMeeting |
| PR5a → PR5b → PR5c | 1 | `HolosSpeakers`: alignment and run builder (a); projection and carry-over (b); exporters, Otter parser, scoring (c) | HolosSpeakers (PR5a) |
| PR7a ∥ PR7b → PR7c | 2 | FluidAudio adapter and model install (a); renderer, post-processor, exports, `session diarize` (b); import, score, Otter evaluation (c) | HolosDiarization (PR7a) |
| PR2a → PR2b | 2 | Long recordings: recorder loop, files, control, disk, capture pump, stop path (a); sleep, power, device changes, watchdog, microphone selection (b) | — |
| PR3 | 3 | Recovery with the journal transcript, session catalog, delete audio / delete meeting | — |
| PR8 | 3 | `SpeakerEditor`, `holos speakers …`, `holos session export` | — |
| PR4 | 4 | Menu bar meeting controls, start panel, child launch/reattach, Meetings window, dictation pause, model install from the app, automatic relabel | — |
| PR10 | 4 | People (names and opt-in voiceprints), recognition as suggestions, People window, `holos people` | — |
| PR9 | 5 | Transcript review window | — |
| PR11 | 5 | Online-call refinements: echo filter, headphone warning | — |

`→` means stacked (the later PR branches from the earlier one); `∥` means parallel.
Spike S1 finished with verdict "go" (§4.8 uses its API facts and measurements). Spike S2
(recorder process and platform) is pending; it picks the default launcher and runs the
hardware checks in §7.2. S2 does not change any interface: the `waiting` phase (§4.2)
already covers ScreenCaptureKit stopping under screen lock, and §4.2 names the fallback
if it does.

### 0.3 What this revision changed

The review log (§10) lists every finding and its disposition. The larger changes:

- **Privacy.** Diarization runs hold no voice embeddings, and post-processing never
  persists them; a voiceprint is stored only as a profile sample of a person the user
  confirmed with voice learning on (§4.10). `speakers/voice/` exists only for hidden
  evaluation runs. Exports never contain vectors by
  default. Recognition only suggests names until thresholds are calibrated on the user's
  own confirmed meetings. Names are kept whatever the setting.
- **Recorder robustness.** A `waiting` phase with backoff replaces "three restarts then
  stop"; disk latency is taken out of the capture path; one session timeline anchored at
  the first captured frame; timeouts on every platform await; the processing lease is
  handed from the recorder to post-processing without a gap.
- **Correctness of edits.** Edits carry the view they were made against; a stale view is
  refused instead of silently editing a different turn. Speaker names carry over when a
  meeting is relabelled.
- **Plan of work.** PR6 moves to a wave 0 so every later PR can use its types; PR2, PR5,
  and PR7 are split into stacked or parallel parts; test fakes have one owner per wave.
- **Scope cut.** No meeting hotkey, no SRT/VTT, no `reassignRange`, no `--use-run`, no
  SIGHUP change, no block-wise diarization.
- **Scope added.** Delete audio / delete meeting, speaker-model install from the app,
  automatic relabel of interrupted sessions, a "Name Speakers" entry after a meeting,
  recognition vocabulary for meetings, protection for hand-edited exports.

## 1. Conventions

### 1.1 Targets and dependency graph

```
HolosCore ──────────────┬──────────────┬───────────────┬───────────────┐
  (values, contracts)   │              │               │               │
                   HolosStorage   HolosSpeech   HolosSpeakers (PR5a)  HolosDiarization (PR7a)
                        │              │               │               └── FluidAudio 0.17.1
                   HolosAudio          │               │
                        │              │               │
                   HolosMeeting (PR1) ─┴── uses Storage, Audio, Speech, Speakers
                        │
         ┌──────────────┴──────────────┐
      HolosCLI                      HolosApp
  (+ HolosDiarization)        (never HolosDiarization)
```

Rules:

- Only `HolosDiarization` imports FluidAudio, and inside it only the adapter files
  (`FluidDiarizer.swift`, `FluidModels.swift`, `Int16CAFSampleSource.swift`). Only
  `HolosCLI` links `HolosDiarization`. The app never links FluidAudio or CoreML
  diarization models: diarization always runs in a `holos` process (the recorder child,
  or `holos session diarize` spawned by the app). Resolution R1.
- FluidAudio 0.17.1 declares top-level `public enum AudioSource` and `public struct
  WordTiming`, which clash with `HolosCore.AudioSource` and `HolosSpeakers.WordTiming`.
  `HolosDiarization` never imports HolosSpeakers, and writes `HolosCore.AudioSource`
  wherever both modules are imported.
- `HolosMeeting` receives a diarizer as `any SpeakerDiarizer` (protocol in HolosCore),
  so its tests use `FakeDiarizer` and never load CoreML.
- `HolosSpeakers` depends on `HolosCore` only and does no file IO. Every algorithm in it
  is a pure function over values, testable without audio.
- `HolosStorage` owns every path and lock inside a session folder and the global
  profile store. It interprets no transcript content.
- `HolosApp` keeps AppKit views only. Controllers the app needs (`MeetingController`,
  `ReviewSession`) live in `HolosMeeting` as `@MainActor` classes without AppKit, like
  `DictationController` lives in `HolosDictation`, so they are unit-testable.

### 1.2 Package.swift after each wave

Wave 0 (PR6): no change.

Wave 1. PR5a adds the HolosSpeakers targets; PR1 adds HolosMeeting and, when it rebases
on PR5a (it merges last in the wave, §6), makes HolosMeeting depend on HolosSpeakers.
Final text of the changed lines:

```swift
        .target(name: "HolosSpeakers", dependencies: ["HolosCore"]),                                   // PR5a
        .target(name: "HolosMeeting", dependencies: [                                                  // PR1
            "HolosCore", "HolosStorage", "HolosAudio", "HolosSpeech", "HolosSpeakers",
        ]),
        .executableTarget(name: "HolosCLI", dependencies: [
            "HolosCore", "HolosSpeech", "HolosSynthesis", "HolosStorage", "HolosAudio", "HolosContent",
            "HolosMeeting",                                                                             // PR1
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], linkerSettings: /* unchanged */),
        .testTarget(name: "HolosSpeakersTests", dependencies: ["HolosSpeakers", "HolosCore"]),           // PR5a
        .testTarget(name: "HolosMeetingTests", dependencies: [                                          // PR1
            "HolosMeeting", "HolosCore", "HolosStorage", "HolosAudio", "HolosSpeakers",
        ]),
```

Wave 2 (PR7a only):

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.1"),
    ],
        .target(name: "HolosDiarization", dependencies: [
            "HolosCore", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .executableTarget(name: "HolosCLI", dependencies: [
            "HolosCore", "HolosSpeech", "HolosSynthesis", "HolosStorage", "HolosAudio", "HolosContent",
            "HolosMeeting", "HolosSpeakers", "HolosDiarization",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], linkerSettings: /* unchanged */),
        .testTarget(name: "HolosDiarizationTests", dependencies: [
            "HolosDiarization", "HolosSpeakers", "HolosSynthesis", "HolosAudio", "HolosCore",
        ]),
```

Keep FluidAudio's default traits. Its default `NemoTextProcessing` trait links a prebuilt
text-normalization xcframework (SwiftPM checksum `5fa8c10d…`, Apache-2.0) that the
diarizer does not use; S1 found that opting out with `traits: []` failed to link in an
incremental build (resolution R2). A later PR may retry the opt-out from a clean build.

Wave 3: no change. Wave 4 (PR4 and PR10 make this identical edit, so it merges cleanly):

```swift
        .executableTarget(name: "HolosApp", dependencies: [
            "HolosCore", "HolosAudio", "HolosSpeech", "HolosDesktop", "HolosDictation",
            "HolosStorage", "HolosSpeakers", "HolosMeeting",
        ]),
```

Wave 5: no change. Keep the existing `platforms: [.macOS("27.0")]` and
`swiftLanguageModes: [.v6]`. Build-cache note: S1 measured a clean release build of
FluidAudio plus a small probe at 70–80 s and a 1.6 GB `.build`; with ~24 GB free, run
`swift package clean` in stale worktrees and delete worktrees after merge.

### 1.3 Concurrency (Swift 6 strict mode)

- Values crossing any boundary are `struct`/`enum`, `Sendable`, `Equatable`, and
  `Codable` when persisted. Public structs declare explicit `public init`.
- One mutable owner per file tree is an `actor` (`SessionArchive` today; new:
  `StatusWriter`, `FluidDiarizer`).
- Stateless file IO is an `enum` namespace of `static` (nonisolated) functions that take
  locks explicitly (`SessionSpeakerStore`, `RecorderChannel`, `SessionExports`).
- `@MainActor` for anything that touches `AudioCapture`, AppKit, Carbon, or UI state:
  `RecordingWorkflow.run`'s control loop, `MeetingController`, `ReviewSession`, all
  windows. Audio frames are **consumed off the main actor**: the frame stream is
  `Sendable`, and a detached consumer task only copies frames into bounded queues
  (§4.3), so a main-thread stall in the app cannot overflow capture.
- Real-time callbacks only copy samples and yield to bounded streams (existing rule in
  `docs/contracts.md`). No `await`, file IO, or locks that can block in them.
- Small shared state uses `Mutex` from `Synchronization`, as `RecordingWorkflow` and
  `AudioCapture` already do. `@unchecked Sendable` and `nonisolated(unsafe)` are allowed
  only around a C handle or mmap region, with a comment stating the invariant.
- FluidAudio's `OfflineDiarizerManager` is a non-`Sendable` class. Create it, use it, and
  drop it inside one nonisolated async function; cache only the `Sendable`
  `OfflineDiarizerModels` in the actor.
- Progress callbacks are `@escaping @Sendable (…) -> Void`. A consumer that must see
  progress in order (status.json) feeds it into one `AsyncStream` read by one task, and
  finishes and awaits that task before writing its final state (§4.6).
- Every await on a platform API that can hang has a timeout (§4.6): stopping capture,
  finishing a speech session, and the sleep acknowledgement.
- Long loops (rendering, replay, diarization, rebuild) call `Task.checkCancellation()`
  per chunk or block. Cancelled work publishes nothing partial; runs, exports, and
  transcripts appear only by atomic rename.
- In the app, file work that can exceed ~10 ms (loading a 3 h projection, applying an
  edit, regenerating exports) runs off the main actor and returns a value to it.
  `ReviewSession` edits are `async` (§5.10).

### 1.4 Errors and exit codes

- Throw the existing `HolosError` (`invalidInput`, `unavailable`, `permissionDenied`,
  `incomplete`, `io`) with a message that says what to do next. Do not add cases to
  `HolosError` (Models.swift stays untouched by these PRs; resolution R3).
  Machine-readable reasons travel in data (`StopReason`, `ControlResult`,
  `PostProcessingState`), not in error types.
- `CancellationError` passes through unchanged.
- CLI exit codes: `0` success; `1` failure, including transcription incomplete and
  capture failure, exactly as today; `3` audio saved and the command otherwise did its
  job, but with a warning: an automatic stop (`diskLow`, `sleepTimeout`, `pauseTimeout`)
  or post-processing `partial`/`failed`. Print the explanation to stderr, then
  `throw ExitCode(3)`. ArgumentParser keeps `64` for usage errors. `docs/status.md`
  documents these.
- Stdout carries content and JSON (`--json`); progress and messages go to stderr
  (existing rule).

### 1.5 Logging

`os.Logger` with subsystem `ca.orlenko.holos.app` in every process (app and CLI), so
`log stream --predicate 'subsystem == "ca.orlenko.holos.app"'` shows both. Declare
`private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "…")`.

| Category | Used by |
|---|---|
| `recorder` | `RecordingWorkflow`, state machine, control inbox, status writer |
| `capture` | `AudioCapture`, `ChunkWriterPump`, `BuiltInMicrophone`, watchdog, frame continuity (drift) |
| `power` | power assertion, sleep/wake monitor |
| `storage` | `AtomicFile`, locks, `SessionSpeakerStore`, `SpeakerProfileStore`, deletion |
| `postprocess` | `MeetingPostProcessor`, `TrackRenderer`, exports |
| `diarization` | `FluidDiarizer`, model installer |
| `speakers` | `SpeakerEditor`, projection warnings, carry-over |
| `profiles` | enrollment, recognition |
| `meeting` | app-side `MeetingController`, launchers, automatic relabel |
| `review` | review window |
| `insertion` | existing dictation code (unchanged) |

Privacy: session IDs, counts, durations, byte sizes, phases, and error codes are
`privacy: .public`. Never log transcript text, speaker or profile names, marker labels,
vocabulary, or embeddings. Log user paths only as `privacy: .private`.

### 1.6 Files, JSON, IDs, schema versions

- Encode and decode every JSON file with `HolosJSON` (§3.1): ISO 8601 dates (second
  precision), sorted keys, pretty whole files, compact `\n`-terminated journal lines.
  Keys are the Swift property names (lowerCamelCase).
- **Nothing is ordered or chosen by a date.** Dates have one-second precision. Use the
  event journal's `sequence`, `ControlRequest.sentAtNanos`, file order in a journal, or
  an explicit pointer file (`transcripts/current.json`, `speakers/head.json`).
- IDs are `UUID().uuidString` (uppercase) for sessions, runs, edits, batches, control
  requests, profiles, and samples. They satisfy `SessionArchive.validToken`. Turn IDs
  are `T1…Tn` within a run; split parts are `T5/<editID>`. Speaker IDs are
  `<track>:S<n>`, `mic:me`, or `user:<UUID>`.
- Session times are `Double` seconds on the session timeline (§2.3). Wall-clock times
  are `Date`.
- Schema rules:
  1. Every persisted JSON object has a top-level `schemaVersion: Int`, starting at 1.
     Journal lines carry it per line.
  2. Within a version, writers may add optional fields; they never rename, remove, or
     change the meaning of a field. Readers ignore unknown keys (JSONDecoder default).
  3. A reader that meets a higher `schemaVersion` refuses the file with
     `HolosError.unavailable("… was written by a newer Holos …")`. Exception: the edits
     journal skips such lines and reports the count.
  4. `manifest.json` stays at version 1 and its fields are unchanged (the plan's
     requirement). New session facts go into new files (`meeting.json`, `status.json`,
     `postprocess.json`, `speakers/…`, `transcripts/current.json`).
  5. Sets that may grow and are read across processes of different builds are open
     string codes (`OpenStringCode`, §3.1): `RecorderWarningCode`, `StopReason`,
     `GapReason`, `PostProcessingStage`, `PostProcessingState`, `StageResult`,
     `TranscriptionState`. An older reader never fails on a new value. `RecorderPhase`
     is an enum that decodes unknown values as `.unknown` (treated as an active
     meeting). `ControlCommand` is closed: an unknown command is rejected. Enums with
     associated values persisted in runs (`LabelProvenance`, `TrackPolicy`) and in the
     journal (`SpeakerEditAction`) grow only with a schema bump: runs go to version 2;
     journal lines an older reader cannot decode are skipped and counted.
- Permissions: directories `0700`, files `0600`, as `SessionArchive` does today. Files in
  `exports/` are `0400` (§4.11). New folders inside a session are created lazily, so
  older archives stay valid.

### 1.7 Atomic writes and locks

`AtomicFile` (PR6, `Sources/HolosStorage/AtomicFile.swift`) replaces ad-hoc writers:

```swift
public enum AtomicFile {
    /// Writes a same-directory temporary file (O_CREAT|O_EXCL|O_CLOEXEC, `permissions`), fsyncs it,
    /// renames it over `url`, and fsyncs the directory. Leaves no temporary file on failure.
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws
    /// Like `write`, but fails with `HolosError.invalidInput` if `url` exists
    /// (renamex_np with RENAME_EXCL). For immutable files such as runs.
    public static func create(_ data: Data, at url: URL, permissions: mode_t = 0o600) throws
    /// Appends with O_APPEND|O_NOFOLLOW|O_CLOEXEC. Records the size first; on any failure (short write,
    /// ENOSPC, fsync error) truncates back to that size before throwing, so a failed append never
    /// leaves a partial line. Creates the file (0600) if missing. `sync: false` skips the fsync.
    /// An append that creates the file always fsyncs the folder; if it fails, it removes the file it created.
    public static func append(_ data: Data, to url: URL, permissions: mode_t = 0o600, sync: Bool = true) throws
    /// Creates `url` and missing parents as 0700 directories; refuses symlinks and non-directories.
    public static func ensurePrivateDirectory(_ url: URL) throws
    /// `write(HolosJSON.encoder().encode(value), to: url)`.
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL, permissions: mode_t = 0o600) throws
    /// Reads a regular file (lstat, no symlinks) of at most `maxBytes` and decodes it with HolosJSON.
    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL, maxBytes: Int = 64 << 20) throws -> T
}
```

No session-local file operation follows a symbolic link in place of a folder Holos owns. One
helper, `AtomicFile.openFolder` (`Sources/HolosStorage/FolderChain.swift`), opens every folder
from the session folder down relative to the one above it (`openat` with `O_NOFOLLOW`), and
`write`, `create`, `append`, reads (`readJSON`), listings, `removeTree`, the lock files
(`openat` on the session folder's descriptor), and `ensurePrivateDirectory` (each missing
folder made with `mkdirat`, `fchmod` on its descriptor, parent fsync'd) all start from it; a
link there, even one swapped in during the call, is refused with `invalidInput`. Nothing inside a
session is then touched by path: the speakers/voice backup exclusion is `fsetxattr` on the chain's
descriptor, `ProcessingLease` compares the device and inode (`fstat`) of the folder the chain opens,
and recovery reads a chunk's format and hash from one descriptor opened through the chain
(`ChunkFile`, `AudioFileOpenWithCallbacks`), refusing it when the path no longer leads to that file. A `create` whose folder fsync fails removes the new
file, so a retry is not refused as "already exists".

**Threat model.** Holos protects session data against crashes and kills at any point, against
concurrent Holos processes (the app, the recorder, CLI commands), and against accidental outside
changes to the sessions folder (a folder renamed, moved, or replaced by a sync tool, the Finder,
or a script while Holos works in it). It does not protect against a hostile process running as
the same user: such a process can already read, change, or delete every session directly, so no
check inside Holos can keep data from it. The descriptor-based checks (`openat` with
`O_NOFOLLOW`, device and inode comparisons, verifying an entry after a rename and rolling it
back when it is not the expected folder) exist so that Holos fails safely when the folder
changes under it: it writes nothing into a folder it did not make, reports success only for the
folder it verified, and says where anything it left behind is. The check-then-act windows that
remain (for example between checking an entry and renaming it by name, which macOS cannot bind
to a descriptor) are accepted; their consequence is closed by the check afterwards, not the
window itself. Review findings that need a same-user process racing those windows are out of
scope.

Locks are `flock` on files in the session folder, one open file description per holder.

| Lock file | Holders | Held for | How it is taken |
|---|---|---|---|
| `.writer.lock` | recorder's `SessionArchive` actor; `SessionArchive.recover`; `openForMaintenance` | capture start → `finish`; maintenance: one save | `LOCK_EX\|LOCK_NB`, retried every 20 ms for up to 1 s |
| `.processing.lock` (the processing lease) | recorder from just before `finish` until exit (§4.6); `holos session diarize`, `recover`, `delete`; the app's automatic relabel runs the CLI | one post-processing, rebuild, or deletion | `LOCK_EX\|LOCK_NB`, retried every 20 ms for up to 1 s |
| `.speakers.lock` | `SpeakerEditor`; `SessionExports.regenerate`; post-processor while publishing run, head, voice data, recognition | one write (milliseconds) | polled every 20 ms up to 2 s |
| `<support>/Speakers/profiles.lock` | `SpeakerProfileStore.update`; `withLockedDatabase` (recognition's saved comparison, a forget's per-meeting clean-up), always inside the speaker lock when both are held | one read-modify-write, or one read and the session write made from it | polled every 20 ms up to 2 s (PR10) |

Rules:

1. **Not re-entrant.** A second `open`+`flock` in the same process conflicts with the
   first, so never call an API that takes a lock the caller already holds. APIs that
   must run inside a held lock have a `…Locked` variant documented "caller holds the
   speaker lock"; the plain variant takes the lock itself.
2. **Order for waits.** Only the speaker and profile locks are waited on (2 s). Take
   them in the order speakers → profiles, and release the speaker lock before calling
   anything that regenerates exports (§4.9). Writer and lease acquisitions never wait
   more than 1 s, so they cannot deadlock. The recorder takes the lease while holding
   the writer (hand-off, §4.6). Maintenance takes the writer while holding the lease,
   only through `openForMaintenance(at:lease:)` and `recover(at:lease:)`, and only for
   the final save.
3. **Probes do not break acquisitions.** `isActive` and `isProcessing` take
   `LOCK_EX|LOCK_NB` and release at once. Because every acquisition retries for 1 s, a
   concurrent probe cannot make it fail.
4. **Close-on-exec.** Every lock and journal fd is opened with `O_CLOEXEC`. Every child
   process is spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT` plus explicit
   `posix_spawn_file_actions_adddup2`/`addopen` for fds 0, 1, and 2, so a child never
   inherits a lock.

```swift
/// Exclusive, long-lived claim on post-stop work for one session. Released by `release()` or deinit.
public final class ProcessingLease: Sendable {
    public let session: URL
    /// No operation can start under the lease afterwards. The lock is let go at once, or, while
    /// `openForMaintenance(at:lease:)` or `recover(at:lease:)` is running under it, when that call ends
    /// (release and every use are serialized on one mutex).
    public func release()
}
extension SessionArchive {
    /// Throws `HolosError.unavailable("Another Holos process is processing this session.")` after `retry`.
    public nonisolated static func acquireProcessingLease(at session: URL,
                                                          retry: Duration = .seconds(1)) throws -> ProcessingLease
    public nonisolated static func isProcessing(at session: URL) throws -> Bool
    /// Polls `flock(LOCK_EX|LOCK_NB)` every 20 ms up to `timeout`, runs `body`, unlocks.
    /// Throws `HolosError.unavailable("Speaker labels are being saved by another Holos window or command; try again.")`.
    public nonisolated static func withSpeakerLock<T>(at session: URL, timeout: Duration = .seconds(2),
                                                      _ body: () throws -> T) throws -> T
    /// Reopens an archive whose manifest is not "recording" and that has no writer, for maintenance
    /// writes (events, transcript revision, status). Requires the caller's lease for this session
    /// (`lease.session` must match); takes the writer lock (retry 1 s). Repairs a torn journal tail
    /// (truncates to the last newline, keeping a backup) before the first append.
    public static func openForMaintenance(at directory: URL, lease: ProcessingLease) throws -> SessionArchive
    /// The existing recovery, run under the caller's lease. `recover(at:)` keeps its signature and
    /// takes a lease itself.
    public nonisolated static func recover(at directory: URL, lease: ProcessingLease) async throws -> RecoveryReport
}
```

### 1.8 Tests

- Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), as in `Tests/`.
  One file per component, named `<Component>Tests.swift`; test names are behaviours
  (`tornEditLineIsRepairedOnNextAppend`).
- Temporary folders: `FileManager.default.temporaryDirectory/holos-<area>-<UUID>`,
  removed with `defer`. Tests generate audio (sine, clicks, silence) in code.
- The default suite never uses the microphone, permissions, IOKit power APIs, CoreAudio
  device lookup, the network, installed speech assets, diarization models, or the
  user's real data. Seams: `MeetingCapture`, `LiveSpeechSession`, `SpeakerDiarizer`,
  `SessionClock`, `FreeSpaceProvider`, `RecorderLauncher`, `SystemPowerEvents`,
  `findInputDevices`, `SpeakerProfileStore(directory:)`.
- `scripts/test.sh` (PR6) exports `HOLOS_DATA_DIR` and `HOLOS_SUPPORT_DIR` pointing at a
  fresh temporary folder (unless already set) and removes it on exit.
  `HolosPaths.supportRoot` (PR6) honours `HOLOS_SUPPORT_DIR`; every Application Support
  path in this design (`models`, `speakerProfiles`) is built from it.
- Dependency bundles have no live defaults in their memberwise initializers: only
  `RecordingDependencies.live(...)` touches hardware; tests use
  `RecordingDependencies.testing(...)` from `Fakes.swift`.
- Opt-in tests use `.enabled(if: ProcessInfo.processInfo.environment["HOLOS_…"] == "1")`
  so they report as skipped. Gates: `HOLOS_DIARIZATION_FIXTURE=1` (PR7a; models from
  `HOLOS_FIXTURE_MODELS_DIR`, default the real user model folder, after
  `holos setup --speakers`) and `HOLOS_SPEECH_FIXTURE=1` (PR2a; installed speech assets,
  no microphone).
- **Shared test helpers have one owner per wave.** Each test target has one
  `Fakes.swift` (and, from wave 2, one `SessionFixtures.swift` in HolosMeetingTests).
  Only the first-merged PR of a wave edits them (wave 1: PR1; wave 2: PR7b; wave 3:
  PR8; wave 4: PR4; wave 5: PR11). The other PRs declare their helpers `private` or
  `fileprivate` in their own test files, or in `<Component>TestSupport.swift` with names
  prefixed by the component (`rebuilderMakeSession`), so two branches never declare the
  same symbol.
- Run with `./scripts/test.sh --filter <Target>Tests`. `@MainActor` types get
  `@Test @MainActor` tests, as `DictationControllerTests` does.

### 1.9 Data-handling rules for implementers

- Do not launch or kill Holos.app, do not run `scripts/build-app.sh`, do not record from
  the microphone, do not trigger permission prompts. PRs that change those paths list
  manual checks instead (§7).
- The Otter references are private. Evaluation code and agents print counts,
  durations, and metrics only, never reference or hypothesis text or speaker names.
  Evaluation output goes under `.local/evaluation/` (ignored).
- Delete large temporary files you create (rendered audio, imported test sessions,
  model downloads in temp folders). Free disk is about 24 GB.

## 2. Session folder, global files, session time

### 2.1 Session folder

```
<SESSION-UUID>.holos/                      owner                        notes
  manifest.json                            SessionArchive               schema v1, unchanged
  events.jsonl                             SessionArchive               new kinds: §3.2; failed appends leave no partial line
  .writer.lock .processing.lock .speakers.lock  PR6                     flock files
  meeting.json                             PR2a (record), PR7c (import) MeetingInfo; absent in old archives
  vocabulary.json                          PR2a (record), PR7c (import) MeetingVocabulary; absent means none
  status.json                              PR2a                         RecorderStatus; kept after exit (phase exited)
  control/<REQUEST-UUID>.json              PR2a                         ControlRequest; deleted when handled; leftovers deleted at exit
  postprocess.json                         PR7b                         PostProcessingRecord
  audio/{mic,system}/NNNNNN.caf            AudioChunkWriter             Int16 from PR2a, system audio mono; Float32 still readable
  audio-deleted.json                       PR3                          written by Delete Audio; chunks are intentionally absent
  transcripts/<TRANSCRIPT-UUID>.json       SessionArchive               immutable revisions
  transcripts/current.json                 PR6 (saveTranscript)         TranscriptPointer: which revision is current
  transcripts/current.pending              PR6 (saveTranscript)         TranscriptPointer: the revision a save is publishing; removed when done
  speakers/runs/<RUN-UUID>.json            PR6 API, PR7b writes         immutable DiarizationRun; no voice embeddings
  speakers/head.json                       PR6 API                      SpeakerHead: current run
  speakers/edits.jsonl                     PR6 API, PR8 writes          SpeakerEdit journal; torn tail tolerated
  speakers/edits.torn-<UUID>.jsonl         PR6                          backup of a repaired torn tail
  speakers/voice/<RUN-UUID>.json           PR6 API, PR7b writes         SessionVoiceData; only with hidden forceVoiceData (evaluation)
  speakers/recognition/<RUN-UUID>.json     PR10                         RecognitionResult; distances, no vectors
  exports/transcript.{md,json,txt}         PR7b SessionExports          generated, mode 0400, never contain vectors
  exports/.generated.json                  PR7b                         SHA-256 of each generated file
  exports/edited-<YYYYMMDD-HHMMSS>.<ext>   PR7b                         a hand-edited export, moved aside before regeneration
  derived/<track>-16k.caf                  PR7b TrackRenderer           deletable cache; cleared at the start and end of post-processing
```

`SessionPaths` (PR6, `Sources/HolosStorage/SessionPaths.swift`) returns each URL, so no
PR spells a path by hand:

```swift
public enum SessionPaths {
    public static func manifest(_ session: URL) -> URL          // manifest.json
    public static func events(_ session: URL) -> URL            // events.jsonl
    public static func meetingInfo(_ session: URL) -> URL       // meeting.json
    public static func vocabulary(_ session: URL) -> URL        // vocabulary.json
    public static func status(_ session: URL) -> URL            // status.json
    public static func controlDirectory(_ session: URL) -> URL  // control/
    public static func postprocess(_ session: URL) -> URL       // postprocess.json
    public static func audioDeleted(_ session: URL) -> URL      // audio-deleted.json
    public static func transcripts(_ session: URL) -> URL       // transcripts/
    public static func transcript(_ id: String, in session: URL) -> URL
    public static func transcriptPointer(_ session: URL) -> URL // transcripts/current.json
    public static func runs(_ session: URL) -> URL              // speakers/runs/
    public static func run(_ id: String, in session: URL) -> URL
    public static func head(_ session: URL) -> URL              // speakers/head.json
    public static func edits(_ session: URL) -> URL             // speakers/edits.jsonl
    public static func voiceDirectory(_ session: URL) -> URL    // speakers/voice/
    public static func voiceData(_ runID: String, in session: URL) -> URL
    public static func recognition(_ runID: String, in session: URL) -> URL
    public static func exports(_ session: URL) -> URL           // exports/
    public static func export(_ fileExtension: String, in session: URL) -> URL // exports/transcript.<ext>
    public static func generatedExports(_ session: URL) -> URL  // exports/.generated.json
    public static func derived(_ session: URL) -> URL           // derived/
    public static func render(track: String, in session: URL) -> URL // derived/<track>-16k.caf
}
```

Integrity checks (`inspectRecovery`) keep looking only at the manifest, the journal, and
`audio/`; every new file and folder is outside them, so `derived/` and `speakers/` never
make an archive "need attention". When `audio-deleted.json` exists, missing chunk files
are expected and not reported (PR6).

### 2.2 Global files

```
<support> = HolosPaths.supportRoot = $HOLOS_SUPPORT_DIR, else ~/Library/Application Support/Holos
  Sessions/                                        HolosPaths.sessions (or $HOLOS_DATA_DIR; unchanged)
  Models/speaker-diarization-coreml@df2625ac79a7/  PR7a FluidModels.defaultDirectory, passed to FluidAudio as `directory:`
      speaker-diarization/                         FluidAudio's repo folder (Repo.diarizer.folderName): pinned files
          .fluidaudio-revision                     "df2625ac79a7ac6b65ad868fee6d80f320da4232\n"
  Speakers/profiles.json  profiles.lock            PR10: 0700 folder, 0600 files, excluded from Time Machine
~/Library/Logs/Holos/recorder-<SESSION-UUID>.log   PR4: stdout/stderr of the recorder child; deleted with the meeting
$TMPDIR/holos-vocabulary-<SESSION-UUID>.json       PR4: written 0600 by the app; the recorder copies it to vocabulary.json and deletes it
```

`HolosPaths.supportRoot` is added by PR6 in `Sources/HolosCore/SupportPaths.swift` (not
in `Models.swift`). `HolosPaths.models` (PR7a, in HolosDiarization) and
`HolosPaths.speakerProfiles` (PR10, in HolosStorage) are extensions built on it.

### 2.3 Session time

One timeline for everything: chunk times, transcript segment and word times,
diarization times (after the render time map, §4.7), markers, and gaps. An exported
`[01:12:03]` is 1 h 12 min after the first captured audio.

- **Origin.** Session time 0 is epoch 0's capture origin: `AudioCapture` sets
  `hostTimeOrigin` when capture starts, and epoch-0 frame times are measured from it.
  Before epoch 0 starts, the recorder has no session time (status `elapsedSeconds` 0);
  startup work (archive creation, speech-session setup, a first-run permission prompt)
  is not on the timeline.
- **Clock.** `ContinuousSessionClock(hostTimeOrigin:)` (PR2a) is created right after
  epoch 0's `start()` returns. It samples `mach_continuous_time()` and
  `mach_absolute_time()` together once, converts the host-time origin to continuous
  time, and `now()` returns continuous seconds since it. Continuous time keeps counting
  during sleep; host time does not, which is why later epochs take their offset from
  this clock. `ManualSessionClock` is the test double.
- **Epochs.** Each capture start is an epoch with a fresh `MeetingCapture`.
  `AudioCapture.start(…, timelineOffset:, timelineOffsetHostTime:)` sets its host-time
  origin to `offsetHostTime − timelineOffset`, where `offsetHostTime`
  (`CaptureRequest.offsetHostTime`) is the host time at which the recorder read the
  session clock for the offset (`hostNow` when nil, as for epoch 0). Frame times
  continue on the session timeline, and the capture's own setup time (ScreenCaptureKit's
  content query, the audio engine) is part of the gap before its first frame. Epoch
  k+1 uses `timelineOffset = max(clock.now(), lastFrameEnd + 0.01)`, where
  `lastFrameEnd` is the largest frame end on any track, so a new epoch never overlaps
  the previous one even if the audio clock ran ahead of the host clock.
- **Frame continuity** (`FrameContinuity`, PR2a, HolosAudio; used by `AudioChunkWriter`
  and `LiveTrack`). Within an epoch, per track, with `expected` = previous frame end:
  - `|start − expected| < 0.05 s`: contiguous. The samples follow directly; the frame's
    own time is ignored. Drift above 10 ms is logged (category `capture`) at most once a
    minute per track.
  - `start ≥ expected + 0.05`: a gap. The writer closes the chunk and records
    `audioDiscontinuity` with the pending reason (§4.3) or `timestampGap`.
  - `start ≤ expected − 0.05`: an overlap. The leading samples up to `expected` are
    dropped (the whole frame if it lies entirely before `expected`) and
    `timestampOverlap {track, previousEnd, nextStart, droppedSeconds}` is recorded.
    Audio is never written twice and no chunk starts before the previous one ends, so
    `TrackRenderer`, `SessionAudioComposition`, and `AppleSpeechSession.append` ("ordered
    and nonoverlapping") never see overlapping audio.
- **Speech sessions are rebased.** A `LiveSpeechSession` always sees frame times that
  start at 0. `LiveTrack` and `TrackReplayer` remember each session's base (the session
  time of its first frame) and add it to every returned segment and word time. This is
  correct whether SpeechAnalyzer reports times from the `AVAudioTime` it is given or
  from its first buffer; the opt-in `HOLOS_SPEECH_FIXTURE` test (PR2a) checks it with
  real speech. A new speech session starts at every epoch boundary and at every gap over
  1 s (resolution R19).
- **Watchdog time** is the session-clock time at which the consumer received a frame,
  not the frame's media time (§4.2).
- **Markers** use the session time at which the recorder handles the request (≤ 100 ms
  after it is written; R32).

### 2.4 Current transcript and run pairing

- The current transcript is named by `transcripts/current.json`
  (`TranscriptPointer {schemaVersion, transcriptID, updatedAt}`, PR6), which
  `SessionArchive.saveTranscript` rewrites atomically after writing each revision.
  `SessionArchive.currentTranscriptID(at:)` reads it. Saving an existing revision again is
  refused unless `transcripts/current.pending` names it (a save that failed after creating
  it); a later save replaces that marker, so an older revision is never republished. Archives from before PR6 have at
  most one transcript (`holos session retranscribe` writes outside the archive); if a
  legacy archive has several and no pointer, the newest `createdAt` wins and a warning
  is logged.
- The current run is named by `speakers/head.json`. A run references segments of
  `run.transcriptID`, so `SpeakerSessionSnapshot` loads **that** transcript, not the
  current one. If they differ, the snapshot reports `transcriptChanged` and the UI says
  "The transcript changed after speakers were labelled. Label speakers again to update
  them." The post-processor relabels in that case (§4.7 stage 3).
- On load, every turn span is validated (the segment exists and
  `0 ≤ first < end ≤ effectiveWords.count`). A run with any invalid span is reported as
  unusable (`runProblem`), exports fall back to speaker-less output, and nothing traps.
- Every fallback or skipped piece of data in a snapshot (an unusable head, run, or run
  transcript; stale edits; a changed transcript; unreadable or torn journal lines; an
  unreadable recognition result; a damaged meeting.json; skipped event log entries) is in
  `SpeakerSnapshotDiagnostics`, whose notes every command that shows or writes speaker
  labels prints on stderr. An unusable head says the labels were left out and to run
  `holos session diarize --force`, which replaces a damaged `head.json` too. After an edit
  or undo, the diagnostics merge the journal as read before the append, since the append
  repairs a torn last line (`SpeakerSnapshotDiagnostics.merging`).

## 3. Contract files (wave 0; copy verbatim)

### 3.0 Rules

- PR6 adds all three files, byte-identical to the blocks below, in wave 0. Every later
  PR builds on them. They were type-checked together with the current HolosCore sources
  (`swiftc -typecheck -swift-version 6`), and the §3.4 examples were produced by
  encoding these types with `HolosJSON`, on 2026-09-24.
- Copy each block's contents exactly and end the file with one newline. The resulting
  files have these SHA-256 digests (check with `shasum -a 256 Sources/HolosCore/<file>`):

  | File | SHA-256 |
  |---|---|
  | `HolosJSON.swift` | `721b80c44e897f7f7c1d3b9323628972043e2d11db02774124041630c38c43c1` |
  | `MeetingModels.swift` | `cd48ccea4f0f22068f8974411706ef8b52951239cfe1bbe37db19e2443e0903e` |
  | `SpeakerModels.swift` | `da49758f5582b0fe112fb1c2dbb2e35bdd0faee411eae5453009d6823f0510ef` |

  One way to extract them:

  ```sh
  python3 - <<'PY'
  import re, pathlib
  doc = pathlib.Path("docs/meeting-design.md").read_text()
  for name in ["HolosJSON.swift", "MeetingModels.swift", "SpeakerModels.swift"]:
      body = re.search(r"### 3\.\d `Sources/HolosCore/" + re.escape(name) + r"`\n\n```swift\n(.*?)\n```\n", doc, re.S).group(1)
      pathlib.Path("Sources/HolosCore/" + name).write_text(body + "\n")
  PY
  ```

- The `// MARK: - Voice data` comment in `SpeakerModels.swift` says voice data is
  "written only while Remember voices is on". That comment predates the privacy fix and is
  kept only to preserve the frozen digest. §4.10 governs: normal post-processing never
  writes `speakers/voice/`; only hidden evaluation runs (`forceVoiceData`) do.
- After wave 0 a contract file changes only additively: a new optional field (with a
  default in the initializer) or a new static constant of an open code, made by the PR
  that needs it and stated in its description. Anything else is a design change: stop
  and report it. The digests describe the wave-0 text.
- Types a PR needs beyond these go into that PR's own target, not into these files.

### 3.1 `Sources/HolosCore/HolosJSON.swift`

```swift
import Foundation

/// JSON conventions shared by every Holos file: ISO 8601 dates, sorted keys, unescaped slashes.
/// Whole files are pretty-printed; journal lines are compact and end with a newline.
/// Decoders ignore unknown keys, so a newer writer may add optional fields within a schema version.
/// Dates have one-second precision: never order records by a date (use sequence numbers or pointers).
public enum HolosJSON {
    /// Encoder for whole files (`pretty == true`) or single journal lines (`pretty == false`).
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decoder matching `encoder(pretty:)`.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes `value` as one compact JSON object followed by "\n", for append-only journals.
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder(pretty: false).encode(value)
        data.append(0x0A)
        return data
    }
}

/// A string code that tolerates values written by a newer Holos: it is encoded as a bare JSON string,
/// and any string decodes (compare with the type's static constants; unknown values compare unequal).
public protocol OpenStringCode: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    init(rawValue: String)
}

extension OpenStringCode {
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
```

### 3.2 `Sources/HolosCore/MeetingModels.swift`

```swift
import Foundation

// Contract file added by PR6 in wave 0 (docs/meeting-design.md §3.2). Value types shared by the recorder
// process, the CLI, and the menu bar app. No logic beyond trivial derived properties.

// MARK: - Open string codes

/// Recorder warnings shown in the menu and `holos record status`. Open string code.
public struct RecorderWarningCode: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Free space fell below 2 GB.
    public static let diskLow = RecorderWarningCode("diskLow")
    /// A track delivered no audio for more than 3 seconds.
    public static let trackStalled = RecorderWarningCode("trackStalled")
    /// Capture resumed after a system sleep shorter than 15 minutes; the gap is marked.
    public static let resumedAfterSleep = RecorderWarningCode("resumedAfterSleep")
    /// Capture restarted after an audio configuration change.
    public static let deviceChanged = RecorderWarningCode("deviceChanged")
    /// Live transcription fell behind; the rest is transcribed from saved audio after stop.
    public static let transcriptionBehind = RecorderWarningCode("transcriptionBehind")
    /// Laptop speakers are the output during a call, so remote voices reach the microphone (PR11).
    public static let echoRisk = RecorderWarningCode("echoRisk")
    /// Audio capture is not running and the recorder is retrying (phase `waiting`).
    public static let audioUnavailable = RecorderWarningCode("audioUnavailable")
    /// A call recording continues without the microphone because no input device is available.
    public static let microphoneUnavailable = RecorderWarningCode("microphoneUnavailable")
    /// The disk could not keep up, so some audio was dropped; the gap is marked.
    public static let audioDropped = RecorderWarningCode("audioDropped")
}

/// Why capture ended. Open string code.
public struct StopReason: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A stop control request (app, `holos record stop`, or legacy stop.request).
    public static let requested = StopReason("requested")
    /// SIGINT or SIGTERM.
    public static let signal = StopReason("signal")
    /// `--duration` elapsed.
    public static let duration = StopReason("duration")
    /// Free space fell below 500 MB.
    public static let diskLow = StopReason("diskLow")
    /// The system slept for 15 minutes or more while recording; the recording ends at the sleep point.
    public static let sleepTimeout = StopReason("sleepTimeout")
    /// Audio stayed unavailable for 10 minutes (phase `waiting`).
    public static let captureFailed = StopReason("captureFailed")
    /// Capture never started.
    public static let startFailed = StopReason("startFailed")
    /// The meeting stayed paused (including sleep while paused) for 6 hours.
    public static let pauseTimeout = StopReason("pauseTimeout")
    /// Written by a maintenance command into the status of a recorder that died.
    public static let interrupted = StopReason("interrupted")
}

// MARK: - Archive status strings (manifest.json "status")

/// Values of `SessionManifest.status`. The manifest keeps a String for schema-v1 compatibility.
public enum ArchiveStatus {
    public static let recording = "recording"
    public static let processing = "processing"
    public static let complete = "complete"
    public static let audioOnly = "audioOnly"
    public static let transcriptionIncomplete = "transcriptionIncomplete"
    public static let incomplete = "incomplete"
    public static let failed = "failed"
    public static let interrupted = "interrupted"
    /// Interrupted, then recovered with a rebuilt transcript (PR3).
    public static let recovered = "recovered"
}

// MARK: - Event kinds (events.jsonl "kind"); details are [String: String]

/// Event kinds. Details keys are listed per kind; numbers are written with `String(Double)`.
public enum MeetingEventKind {
    /// track, relativePath, start, sampleRate, channels
    public static let chunkOpened = "chunkOpened"
    /// hostTimeOrigin; from PR2 also epoch, timelineOffset
    public static let captureStarted = "captureStarted"
    /// track, text, start, end; from PR2 also segmentID and words (compact JSON array of TimedWord)
    public static let transcriptFinalized = "transcriptFinalized"
    /// track, previousEnd, nextStart, reason (a GapReason raw value, or timestampGap | formatChanged)
    public static let audioDiscontinuity = "audioDiscontinuity"
    /// track, previousEnd, nextStart, droppedSeconds: leading samples that would overlap the previous chunk were dropped
    public static let timestampOverlap = "timestampOverlap"
    /// error
    public static let startFailed = "startFailed"
    /// error; from PR2 also epoch
    public static let captureFailed = "captureFailed"
    /// at, reason, attempt, retryInSeconds: capture is not running and will be retried
    public static let captureWaiting = "captureWaiting"
    /// transcriptionErrors; from PR2 also reason (StopReason)
    public static let captureStopped = "captureStopped"
    /// chunks, unrecovered, previousStatus
    public static let archiveRecovered = "archiveRecovered"
    /// at
    public static let paused = "paused"
    /// at, epoch
    public static let resumed = "resumed"
    /// at, requestID, label (optional)
    public static let marker = "marker"
    /// at, phaseBeforeSleep (recording | paused | waiting)
    public static let systemWillSleep = "systemWillSleep"
    /// at, sleptSeconds, action (resume | wait | finalize)
    public static let didWake = "didWake"
    /// track, at, reason
    public static let deviceChanged = "deviceChanged"
    /// epoch, at, reason, timelineOffset
    public static let captureRestarted = "captureRestarted"
    /// freeBytes, action (warn | stop)
    public static let diskLow = "diskLow"
    /// track, silentSeconds
    public static let trackStalled = "trackStalled"
    /// track
    public static let trackResumed = "trackResumed"
    /// track, from: session time of the first audio that live transcription did not receive
    public static let transcriptionBehind = "transcriptionBehind"
    /// id, command, result
    public static let controlHandled = "controlHandled"
    /// file, reason
    public static let controlRejected = "controlRejected"
    /// transcriptID, journalSegments, replayedSeconds (PR3)
    public static let transcriptRebuilt = "transcriptRebuilt"
}

// MARK: - Meeting setup (meeting.json, vocabulary.json)

public enum MeetingMode: String, Codable, Sendable, CaseIterable {
    /// Microphone only (the built-in microphone); the microphone track is diarized.
    case inPerson
    /// Microphone (the system default input) and system audio; the system track is diarized.
    case call
}

public enum MeetingOrigin: String, Codable, Sendable {
    case recorded
    case imported
}

/// How a meeting was set up. Written once to `meeting.json` when a recording or import starts.
public struct MeetingInfo: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sessionID: String
    public var mode: MeetingMode
    /// In a call, also diarize the microphone track because other people share the room.
    /// `holos session diarize --others-in-room | --no-others-in-room` overrides it per run.
    public var othersInRoom: Bool
    /// Bundle ID whose audio the system track captures, when filtered with `--app`.
    public var applicationBundleID: String?
    public var origin: MeetingOrigin
    /// Original file name for `holos session import`; nil for recordings.
    public var importedFileName: String?
    /// Number of people the user expects, passed to the diarizer as a hint (optional).
    public var expectedSpeakers: Int?
    public var createdAt: Date

    public init(schemaVersion: Int = 1, sessionID: String, mode: MeetingMode, othersInRoom: Bool,
                applicationBundleID: String? = nil, origin: MeetingOrigin = .recorded,
                importedFileName: String? = nil, expectedSpeakers: Int? = nil, createdAt: Date = Date()) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.mode = mode
        self.othersInRoom = othersInRoom; self.applicationBundleID = applicationBundleID
        self.origin = origin; self.importedFileName = importedFileName
        self.expectedSpeakers = expectedSpeakers; self.createdAt = createdAt
    }

    /// Settings assumed for archives created before meeting.json existed.
    public static func inferred(sessionID: String, source: AudioSource, createdAt: Date) -> MeetingInfo {
        MeetingInfo(sessionID: sessionID, mode: source == .microphone ? .inPerson : .call,
                    othersInRoom: false, createdAt: createdAt)
    }
}

/// Contents of `vocabulary.json`: names and terms the recognizer should prefer (contextual strings).
/// Written once when a recording or import starts; at most 1,000 entries of at most 100 characters.
public struct MeetingVocabulary: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var strings: [String]

    public init(schemaVersion: Int = 1, strings: [String]) {
        self.schemaVersion = schemaVersion; self.strings = strings
    }
}

// MARK: - Control requests (control/<id>.json)

public enum ControlCommand: String, Codable, Sendable, CaseIterable {
    case stop, pause, resume, marker
}

/// One request from the app or CLI to a running recorder. Published atomically as
/// `control/<id>.json`; the recorder applies it at most once and deletes the file.
public struct ControlRequest: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int
    /// UUID string; also the file name.
    public var id: String
    /// Must equal the session folder's ID or the request is rejected.
    public var sessionID: String
    public var command: ControlCommand
    /// Marker label, at most 200 characters; ignored for other commands.
    public var label: String?
    public var createdAt: Date
    /// `mach_continuous_time` in nanoseconds when the request was written. The recorder applies
    /// requests in (sentAtNanos, id) order; the value is comparable across processes on one Mac.
    public var sentAtNanos: UInt64?
    /// "app" or "cli".
    public var sender: String

    public init(schemaVersion: Int = 1, id: String = UUID().uuidString, sessionID: String,
                command: ControlCommand, label: String? = nil, createdAt: Date = Date(),
                sentAtNanos: UInt64? = nil, sender: String) {
        self.schemaVersion = schemaVersion; self.id = id; self.sessionID = sessionID
        self.command = command; self.label = label; self.createdAt = createdAt
        self.sentAtNanos = sentAtNanos; self.sender = sender
    }
}

public enum ControlResult: String, Codable, Sendable {
    /// The command changed recorder state (or added a marker).
    case applied
    /// Valid but had no effect, e.g. pause while paused, or any command after capture stopped.
    case ignored
    /// Invalid for this session or phase; `message` says why.
    case rejected
}

public struct ControlAck: Codable, Sendable, Equatable {
    public var id: String
    public var command: ControlCommand
    public var result: ControlResult
    public var message: String?
    public var handledAt: Date

    public init(id: String, command: ControlCommand, result: ControlResult, message: String? = nil,
                handledAt: Date = Date()) {
        self.id = id; self.command = command; self.result = result
        self.message = message; self.handledAt = handledAt
    }
}

// MARK: - Post-processing (postprocess.json; mirrored in status.json)

/// Post-processing stage. Open string code.
public struct PostProcessingStage: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let transcript = PostProcessingStage("transcript")
    public static let render = PostProcessingStage("render")
    public static let diarize = PostProcessingStage("diarize")
    public static let align = PostProcessingStage("align")
    public static let recognize = PostProcessingStage("recognize")
    public static let export = PostProcessingStage("export")
}

public struct PostProcessingProgress: Codable, Sendable, Equatable {
    public var stage: PostProcessingStage
    public var track: String?
    /// 0...1 within the stage (and track), when known.
    public var fraction: Double?
    /// Short user-facing text, e.g. "Labelling speakers (system audio)…". Never transcript text.
    public var message: String

    public init(stage: PostProcessingStage, track: String? = nil, fraction: Double? = nil, message: String) {
        self.stage = stage; self.track = track; self.fraction = fraction; self.message = message
    }
}

/// Result of one stage. Open string code.
public struct StageResult: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let succeeded = StageResult("succeeded")
    public static let skipped = StageResult("skipped")
    public static let failed = StageResult("failed")
}

public struct StageOutcome: Codable, Sendable, Equatable {
    public var stage: PostProcessingStage
    public var result: StageResult
    public var message: String?
    public var seconds: Double

    public init(stage: PostProcessingStage, result: StageResult, message: String? = nil, seconds: Double = 0) {
        self.stage = stage; self.result = result; self.message = message; self.seconds = seconds
    }
}

/// Overall post-processing state. Open string code.
public struct PostProcessingState: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let running = PostProcessingState("running")
    /// Every applicable stage succeeded (expected skips allowed, §4.7).
    public static let succeeded = PostProcessingState("succeeded")
    /// Exports were written but a speaker stage was skipped or failed.
    public static let partial = PostProcessingState("partial")
    public static let failed = PostProcessingState("failed")
    /// Nothing to do (e.g. audio-only session with no transcript).
    public static let skipped = PostProcessingState("skipped")
}

/// Contents of `postprocess.json`, and the value `MeetingPostProcessor.run` returns.
public struct PostProcessingRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sessionID: String
    public var state: PostProcessingState
    public var progress: PostProcessingProgress?
    public var stages: [StageOutcome]
    /// The run that became `speakers/head.json`, if any.
    public var runID: String?
    /// The transcript the run was built from.
    public var transcriptID: String?
    /// The microphone-track choice used for this run (from meeting.json unless overridden).
    public var othersInRoom: Bool?
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var message: String?

    public init(schemaVersion: Int = 1, sessionID: String, state: PostProcessingState,
                progress: PostProcessingProgress? = nil, stages: [StageOutcome] = [], runID: String? = nil,
                transcriptID: String? = nil, othersInRoom: Bool? = nil, pid: Int32, startedAt: Date,
                updatedAt: Date, message: String? = nil) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.state = state
        self.progress = progress; self.stages = stages; self.runID = runID
        self.transcriptID = transcriptID; self.othersInRoom = othersInRoom; self.pid = pid
        self.startedAt = startedAt; self.updatedAt = updatedAt; self.message = message
    }
}

// MARK: - Recorder status (status.json)

public enum RecorderPhase: String, Codable, Sendable, CaseIterable {
    case starting, recording, paused, waiting, sleeping, stopping, transcribing, postprocessing, exited
    /// A phase written by a newer Holos. Decoded from any unrecognized value; never written.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecorderPhase(rawValue: raw) ?? .unknown
    }

    /// True from launch until capture has stopped. Dictation stays paused while this is true.
    public var isMeetingActive: Bool {
        switch self {
        case .starting, .recording, .paused, .waiting, .sleeping, .stopping, .unknown: true
        case .transcribing, .postprocessing, .exited: false
        }
    }
}

/// Live transcription state of one track. Open string code.
public struct TranscriptionState: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Live transcription is keeping up.
    public static let live = TranscriptionState("live")
    /// Live transcription stopped; the rest is transcribed from saved audio after stop.
    public static let behind = TranscriptionState("behind")
    /// `--record-only`, or live transcription could not start.
    public static let off = TranscriptionState("off")
}

public struct TrackStatus: Codable, Sendable, Equatable {
    /// "mic" or "system".
    public var track: String
    public var transcription: TranscriptionState
    /// Session time of the end of the last captured frame.
    public var lastFrameSeconds: Double?
    /// Session time of the end of the last finalized phrase.
    public var lastFinalizedSeconds: Double?
    public var sampleRate: Double?
    public var channels: Int?
    public var stalled: Bool
    /// Seconds of captured audio waiting to be written to disk.
    public var backlogSeconds: Double?

    public init(track: String, transcription: TranscriptionState, lastFrameSeconds: Double? = nil,
                lastFinalizedSeconds: Double? = nil, sampleRate: Double? = nil, channels: Int? = nil,
                stalled: Bool = false, backlogSeconds: Double? = nil) {
        self.track = track; self.transcription = transcription; self.lastFrameSeconds = lastFrameSeconds
        self.lastFinalizedSeconds = lastFinalizedSeconds; self.sampleRate = sampleRate
        self.channels = channels; self.stalled = stalled; self.backlogSeconds = backlogSeconds
    }
}

public struct RecorderWarning: Codable, Sendable, Equatable {
    public var code: RecorderWarningCode
    /// Short user-facing text; never transcript text.
    public var message: String
    public var since: Date

    public init(code: RecorderWarningCode, message: String, since: Date = Date()) {
        self.code = code; self.message = message; self.since = since
    }
}

public struct RecorderExit: Codable, Sendable, Equatable {
    /// The manifest status written at finish (see `ArchiveStatus`).
    public var archiveStatus: String
    public var reason: StopReason
    public var message: String?
    /// nil when post-processing did not run.
    public var postprocessing: PostProcessingState?
    /// The post-processing record's message, e.g. "No speaker labels: speaker models are not installed."
    public var postprocessingMessage: String?

    public init(archiveStatus: String, reason: StopReason, message: String? = nil,
                postprocessing: PostProcessingState? = nil, postprocessingMessage: String? = nil) {
        self.archiveStatus = archiveStatus; self.reason = reason; self.message = message
        self.postprocessing = postprocessing; self.postprocessingMessage = postprocessingMessage
    }
}

/// Contents of `status.json`, rewritten atomically by the recorder at least once per second
/// (a heartbeat from launch until exit) and on every phase change. Kept after exit with `phase == .exited`.
public struct RecorderStatus: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sessionID: String
    public var name: String
    public var pid: Int32
    public var phase: RecorderPhase
    /// Increments on every write, so a reader can detect a stalled writer.
    public var sequence: Int
    public var startedAt: Date
    public var updatedAt: Date
    public var source: AudioSource
    /// Name of the input device recorded on the microphone track, for display.
    public var microphoneName: String?
    /// Session time now: time since capture first started, including pauses and sleep.
    public var elapsedSeconds: Double
    /// Audio actually captured on the longest track.
    public var recordedSeconds: Double
    public var bytesWritten: Int64
    public var freeBytes: Int64?
    public var tracks: [TrackStatus]
    /// Last finalized phrase, at most 200 characters. The session folder is private (0700).
    public var lastPhrase: String?
    public var warnings: [RecorderWarning]
    public var markers: Int
    public var progress: PostProcessingProgress?
    /// The 32 most recent acknowledgements, newest last.
    public var handledRequests: [ControlAck]
    /// Set only when `phase == .exited`.
    public var exit: RecorderExit?

    public init(schemaVersion: Int = 1, sessionID: String, name: String, pid: Int32, phase: RecorderPhase,
                sequence: Int, startedAt: Date, updatedAt: Date, source: AudioSource,
                microphoneName: String? = nil, elapsedSeconds: Double = 0, recordedSeconds: Double = 0,
                bytesWritten: Int64 = 0, freeBytes: Int64? = nil, tracks: [TrackStatus] = [],
                lastPhrase: String? = nil, warnings: [RecorderWarning] = [], markers: Int = 0,
                progress: PostProcessingProgress? = nil, handledRequests: [ControlAck] = [],
                exit: RecorderExit? = nil) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.name = name; self.pid = pid
        self.phase = phase; self.sequence = sequence; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.source = source; self.microphoneName = microphoneName; self.elapsedSeconds = elapsedSeconds
        self.recordedSeconds = recordedSeconds; self.bytesWritten = bytesWritten; self.freeBytes = freeBytes
        self.tracks = tracks; self.lastPhrase = lastPhrase; self.warnings = warnings; self.markers = markers
        self.progress = progress; self.handledRequests = handledRequests; self.exit = exit
    }
}
```

### 3.3 `Sources/HolosCore/SpeakerModels.swift`

```swift
import Foundation

// Contract file added by PR6 in wave 0 (docs/meeting-design.md §3.3). Speaker value types, the diarizer
// boundary, the edit journal record, and per-session voice data. No FluidAudio types.
// Adding a case to an enum persisted in runs (LabelProvenance, TrackPolicy, WordTimingQuality,
// RecognitionTier) requires DiarizationRun.schemaVersion 2.

// MARK: - Vectors

/// A Float32 vector encoded in JSON as base64 of little-endian IEEE 754 values, so 256-d
/// speaker embeddings stay compact and round-trip bit-exactly.
public struct FloatVector: Codable, Sendable, Equatable {
    public var values: [Float]

    public init(_ values: [Float]) { self.values = values }

    public var count: Int { values.count }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let data = Data(base64Encoded: text), data.count % 4 == 0 else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected base64 of little-endian Float32 values.")
        }
        let bytes = [UInt8](data)
        var decoded: [Float] = []
        decoded.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            var bits = UInt32(bytes[index])
            bits |= UInt32(bytes[index + 1]) << 8
            bits |= UInt32(bytes[index + 2]) << 16
            bits |= UInt32(bytes[index + 3]) << 24
            decoded.append(Float(bitPattern: bits))
            index += 4
        }
        values = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * 4)
        for value in values {
            let bits = value.bitPattern
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        var container = encoder.singleValueContainer()
        try container.encode(Data(bytes).base64EncodedString())
    }
}

// MARK: - Diarization engine boundary (not persisted as-is)

/// Identifies an embedding space. Voiceprints from different models are never compared.
public struct EmbeddingModelID: Codable, Sendable, Hashable {
    public var id: String
    public var revision: String

    public init(id: String, revision: String) { self.id = id; self.revision = revision }
}

/// A downloaded model pinned by revision and content digest.
public struct ModelDescriptor: Codable, Sendable, Equatable {
    public var id: String
    public var revision: String
    /// Tree digest of the model folder (HolosDiarization `ModelTreeDigest`).
    public var sha256: String

    public init(id: String, revision: String, sha256: String) {
        self.id = id; self.revision = revision; self.sha256 = sha256
    }
}

/// Engine provenance recorded in every run.
public struct DiarizationEngineInfo: Codable, Sendable, Equatable {
    public var engine: String
    public var engineVersion: String
    public var models: [ModelDescriptor]
    public var embeddingModel: EmbeddingModelID
    public var embeddingDimension: Int
    /// Flattened engine settings, for reproducibility only.
    public var configuration: [String: String]

    public init(engine: String, engineVersion: String, models: [ModelDescriptor],
                embeddingModel: EmbeddingModelID, embeddingDimension: Int, configuration: [String: String]) {
        self.engine = engine; self.engineVersion = engineVersion; self.models = models
        self.embeddingModel = embeddingModel; self.embeddingDimension = embeddingDimension
        self.configuration = configuration
    }
}

/// Optional speaker-count constraints for the engine.
public struct SpeakerCountHint: Codable, Sendable, Equatable {
    public var minimum: Int?
    public var maximum: Int?
    public var exactly: Int?

    public init(minimum: Int? = nil, maximum: Int? = nil, exactly: Int? = nil) {
        self.minimum = minimum; self.maximum = maximum; self.exactly = exactly
    }
}

public struct DiarizationRequest: Sendable, Equatable {
    /// Mono audio (a `TrackRenderer` output). Output times are seconds from the file's first frame;
    /// the post-processor maps them to session time with the render's time map.
    public var audio: URL
    /// "mic" or "system".
    public var track: String
    public var speakers: SpeakerCountHint?

    public init(audio: URL, track: String, speakers: SpeakerCountHint? = nil) {
        self.audio = audio; self.track = track; self.speakers = speakers
    }
}

/// One engine segment in seconds of the request's audio. `speaker` is the engine label, e.g. "S1".
public struct RawDiarizationSegment: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var quality: Double?

    public init(speaker: String, start: Double, end: Double, quality: Double? = nil) {
        self.speaker = speaker; self.start = start; self.end = end; self.quality = quality
    }
}

/// One per-window embedding for an engine speaker, in seconds of the request's audio.
public struct EmbeddingWindow: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var vector: FloatVector

    public init(speaker: String, start: Double, end: Double, vector: FloatVector) {
        self.speaker = speaker; self.start = start; self.end = end; self.vector = vector
    }
}

public struct DiarizerOutput: Sendable, Equatable {
    public var segments: [RawDiarizationSegment]
    /// Engine speaker label → centroid in the embedding space.
    public var centroids: [String: FloatVector]
    public var windows: [EmbeddingWindow]
    public var processingSeconds: Double

    public init(segments: [RawDiarizationSegment], centroids: [String: FloatVector],
                windows: [EmbeddingWindow], processingSeconds: Double) {
        self.segments = segments; self.centroids = centroids
        self.windows = windows; self.processingSeconds = processingSeconds
    }
}

/// The only boundary between Holos and a diarization engine.
/// Implementations: `FluidDiarizer` (HolosDiarization) and `FakeDiarizer` (HolosSpeakers, for tests).
public protocol SpeakerDiarizer: Sendable {
    /// Engine and model provenance. Throws `HolosError.unavailable` when models are missing or fail verification.
    func engineInfo() async throws -> DiarizationEngineInfo

    /// Diarizes one track. `progress` receives 0...1 from any thread. Throws `CancellationError` when cancelled.
    func diarize(_ request: DiarizationRequest,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput
}

// MARK: - Diarization run (speakers/runs/<runID>.json). Contains no voice embeddings.

public struct DiarizationSegment: Codable, Sendable, Equatable {
    public var track: String
    /// Session-local cluster ID "<track>:<engine label>", e.g. "system:S2".
    public var clusterID: String
    /// Session time.
    public var start: Double
    public var end: Double
    /// Number of other clusters on this track whose segments intersect this one.
    public var overlapCount: Int
    public var quality: Double?

    public init(track: String, clusterID: String, start: Double, end: Double, overlapCount: Int = 0,
                quality: Double? = nil) {
        self.track = track; self.clusterID = clusterID; self.start = start; self.end = end
        self.overlapCount = overlapCount; self.quality = quality
    }
}

public struct ClusterSummary: Codable, Sendable, Equatable {
    public var clusterID: String
    public var track: String
    public var speechSeconds: Double

    public init(clusterID: String, track: String, speechSeconds: Double) {
        self.clusterID = clusterID; self.track = track; self.speechSeconds = speechSeconds
    }
}

/// How the post-processor treated one track.
public enum TrackPolicy: Codable, Sendable, Equatable {
    /// Diarized; turns carry cluster IDs.
    case diarized
    /// Not diarized; every word belongs to one speaker (the microphone in a call is "Me").
    case channel(speakerID: String, displayName: String)
    /// Not analysed, e.g. no audio or no words on this track.
    case skipped(reason: String)
}

public struct TrackDiarization: Codable, Sendable, Equatable {
    public var track: String
    public var policy: TrackPolicy
    public var segments: [DiarizationSegment]
    public var clusters: [ClusterSummary]

    public init(track: String, policy: TrackPolicy, segments: [DiarizationSegment] = [],
                clusters: [ClusterSummary] = []) {
        self.track = track; self.policy = policy; self.segments = segments; self.clusters = clusters
    }
}

public struct AlignmentParameters: Codable, Sendable, Equatable {
    /// A word outside every segment joins the nearest segment within this distance.
    public var gapSnapSeconds: Double
    /// A run of at most this many words labelled B between A words goes back to A…
    public var flickerMaxWords: Int
    /// …when the run spans at most this many seconds,
    public var flickerMaxSeconds: Double
    /// …the pauses to the A words on both sides are at most this long,
    public var flickerMaxGapSeconds: Double
    /// …the run lies within this distance of an A/B diarization segment boundary,
    public var flickerBoundarySeconds: Double
    /// …and no B segment at least this long covers the run.
    public var flickerMinOwnSegmentSeconds: Double
    /// A pause longer than this starts a new turn even for the same speaker.
    public var turnPauseSeconds: Double
    /// Another cluster overlapping a word by at least min(overlapMinSeconds, overlapMinFraction × word) marks overlap.
    public var overlapMinSeconds: Double
    public var overlapMinFraction: Double
    /// Search ±this many seconds for a constant offset between word times and diarization times; 0 disables.
    public var offsetSearchSeconds: Double
    public var offsetStepSeconds: Double
    /// Echo filter window in seconds (PR11); nil disables the filter.
    public var echoWindowSeconds: Double?
    /// Minimum run of consecutive matching words treated as echo (PR11).
    public var echoMinRunWords: Int

    public init(gapSnapSeconds: Double, flickerMaxWords: Int, flickerMaxSeconds: Double,
                flickerMaxGapSeconds: Double, flickerBoundarySeconds: Double, flickerMinOwnSegmentSeconds: Double,
                turnPauseSeconds: Double, overlapMinSeconds: Double, overlapMinFraction: Double,
                offsetSearchSeconds: Double, offsetStepSeconds: Double,
                echoWindowSeconds: Double?, echoMinRunWords: Int) {
        self.gapSnapSeconds = gapSnapSeconds; self.flickerMaxWords = flickerMaxWords
        self.flickerMaxSeconds = flickerMaxSeconds; self.flickerMaxGapSeconds = flickerMaxGapSeconds
        self.flickerBoundarySeconds = flickerBoundarySeconds
        self.flickerMinOwnSegmentSeconds = flickerMinOwnSegmentSeconds
        self.turnPauseSeconds = turnPauseSeconds
        self.overlapMinSeconds = overlapMinSeconds; self.overlapMinFraction = overlapMinFraction
        self.offsetSearchSeconds = offsetSearchSeconds; self.offsetStepSeconds = offsetStepSeconds
        self.echoWindowSeconds = echoWindowSeconds; self.echoMinRunWords = echoMinRunWords
    }

    public static let v1 = AlignmentParameters(
        gapSnapSeconds: 0.5, flickerMaxWords: 2, flickerMaxSeconds: 0.4,
        flickerMaxGapSeconds: 0.25, flickerBoundarySeconds: 0.3, flickerMinOwnSegmentSeconds: 0.3,
        turnPauseSeconds: 1.5, overlapMinSeconds: 0.1, overlapMinFraction: 0.5,
        offsetSearchSeconds: 0.5, offsetStepSeconds: 0.02, echoWindowSeconds: nil, echoMinRunWords: 3)
}

public struct AlignmentInfo: Codable, Sendable, Equatable {
    /// Bumped whenever the algorithm gives different output for the same input.
    public var version: Int
    public var parameters: AlignmentParameters
    /// Per diarized track: seconds added to diarization times before alignment (0 when not estimated).
    public var trackOffsets: [String: Double]

    public init(version: Int, parameters: AlignmentParameters, trackOffsets: [String: Double] = [:]) {
        self.version = version; self.parameters = parameters; self.trackOffsets = trackOffsets
    }
}

/// A word position: an index into `WordTiming.effectiveWords(of:)` for one transcript segment.
public struct WordRef: Codable, Sendable, Hashable {
    public var segmentID: String
    public var word: Int

    public init(segmentID: String, word: Int) { self.segmentID = segmentID; self.word = word }
}

/// Half-open word range `[first, end)` within one transcript segment's effective words.
public struct WordSpan: Codable, Sendable, Equatable {
    public var segmentID: String
    public var first: Int
    public var end: Int

    public init(segmentID: String, first: Int, end: Int) {
        self.segmentID = segmentID; self.first = first; self.end = end
    }
}

public enum WordTimingQuality: String, Codable, Sendable {
    /// Every word has recognizer timing.
    case measured
    /// Times were spread evenly across an untimed segment.
    case estimated
    /// Both kinds occur in the turn.
    case mixed
}

/// A machine-built turn. Text and timing stay in the transcript; the turn only references words.
public struct SpeakerTurn: Codable, Sendable, Equatable, Identifiable {
    /// "T1", "T2", … in (start, track) order within the run.
    public var id: String
    public var track: String
    public var start: Double
    public var end: Double
    /// Initial speaker; nil means unknown.
    public var speakerID: String?
    /// Diarizer cluster that won the words; nil for channel or unknown turns.
    public var clusterID: String?
    public var spans: [WordSpan]
    public var overlap: Bool
    public var otherClusters: [String]
    /// Share of the turn's word time covered by the chosen cluster, 0...1 (1 for channel turns).
    public var assignmentScore: Double
    public var timing: WordTimingQuality

    public init(id: String, track: String, start: Double, end: Double, speakerID: String?, clusterID: String?,
                spans: [WordSpan], overlap: Bool = false, otherClusters: [String] = [],
                assignmentScore: Double, timing: WordTimingQuality) {
        self.id = id; self.track = track; self.start = start; self.end = end; self.speakerID = speakerID
        self.clusterID = clusterID; self.spans = spans; self.overlap = overlap
        self.otherClusters = otherClusters; self.assignmentScore = assignmentScore; self.timing = timing
    }
}

public enum RecognitionTier: String, Codable, Sendable {
    /// Applied automatically and shown as "Jim (auto)". Produced only with calibrated thresholds (§4.10).
    case likely
    /// Shown in the review window as "Maybe Jim" with Confirm; never exported.
    case possible
}

/// Where a speaker's label came from.
public enum LabelProvenance: Codable, Sendable, Equatable {
    case diarizer
    case channelAssumption
    case recognized(distance: Double, tier: RecognitionTier)
    case userConfirmed
    case userRenamed
}

public struct SessionSpeaker: Codable, Sendable, Equatable, Identifiable {
    /// "mic:S1", "system:S2", "mic:me", or "user:<uuid>" for speakers created by edits.
    public var id: String
    /// N in "Speaker N": 1-based, by first turn start across both tracks.
    public var ordinal: Int
    public var displayName: String?
    public var profileID: String?
    public var provenance: LabelProvenance
    public var clusterIDs: [String]

    public init(id: String, ordinal: Int, displayName: String? = nil, profileID: String? = nil,
                provenance: LabelProvenance, clusterIDs: [String] = []) {
        self.id = id; self.ordinal = ordinal; self.displayName = displayName
        self.profileID = profileID; self.provenance = provenance; self.clusterIDs = clusterIDs
    }
}

/// Words left out of every turn, e.g. microphone echo of system audio (PR11).
public struct DroppedWords: Codable, Sendable, Equatable {
    public var spans: [WordSpan]
    public var reason: String

    public init(spans: [WordSpan], reason: String) { self.spans = spans; self.reason = reason }
}

/// Immutable result of diarizing and aligning one transcript revision. Holds no voice embeddings.
public struct DiarizationRun: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int
    /// UUID string; also the file name.
    public var id: String
    public var sessionID: String
    public var createdAt: Date
    /// The `Transcript.id` whose segments the turns reference.
    public var transcriptID: String
    /// Nil when no track was diarized (channel-only sessions).
    public var engine: DiarizationEngineInfo?
    public var alignment: AlignmentInfo
    public var tracks: [TrackDiarization]
    public var speakers: [SessionSpeaker]
    public var turns: [SpeakerTurn]
    public var droppedWords: [DroppedWords]

    public init(schemaVersion: Int = 1, id: String = UUID().uuidString, sessionID: String,
                createdAt: Date = Date(), transcriptID: String, engine: DiarizationEngineInfo?,
                alignment: AlignmentInfo, tracks: [TrackDiarization], speakers: [SessionSpeaker],
                turns: [SpeakerTurn], droppedWords: [DroppedWords] = []) {
        self.schemaVersion = schemaVersion; self.id = id; self.sessionID = sessionID
        self.createdAt = createdAt; self.transcriptID = transcriptID; self.engine = engine
        self.alignment = alignment; self.tracks = tracks; self.speakers = speakers; self.turns = turns
        self.droppedWords = droppedWords
    }
}

/// Contents of `speakers/head.json`: the run that exports and the review window use.
public struct SpeakerHead: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runID: String
    public var updatedAt: Date

    public init(schemaVersion: Int = 1, runID: String, updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion; self.runID = runID; self.updatedAt = updatedAt
    }
}

// MARK: - Voice data (speakers/voice/<runID>.json). Biometric; written only while "Remember voices" is on.

/// Mean embedding of one turn's speech, used for enrollment.
public struct TurnEmbedding: Codable, Sendable, Equatable {
    public var turnID: String
    public var speechSeconds: Double
    public var vector: FloatVector

    public init(turnID: String, speechSeconds: Double, vector: FloatVector) {
        self.turnID = turnID; self.speechSeconds = speechSeconds; self.vector = vector
    }
}

/// Voice embeddings for one run. Deleted by Forget All Voices, Delete Audio, and Delete Meeting;
/// Forget <person> removes the entries of that person's speakers.
public struct SessionVoiceData: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runID: String
    public var sessionID: String
    public var createdAt: Date
    public var embeddingModel: EmbeddingModelID
    /// Cluster ID → centroid.
    public var centroids: [String: FloatVector]
    public var turnEmbeddings: [TurnEmbedding]

    public init(schemaVersion: Int = 1, runID: String, sessionID: String, createdAt: Date = Date(),
                embeddingModel: EmbeddingModelID, centroids: [String: FloatVector],
                turnEmbeddings: [TurnEmbedding]) {
        self.schemaVersion = schemaVersion; self.runID = runID; self.sessionID = sessionID
        self.createdAt = createdAt; self.embeddingModel = embeddingModel; self.centroids = centroids
        self.turnEmbeddings = turnEmbeddings
    }
}

// MARK: - Edit journal (speakers/edits.jsonl)

/// Speaker IDs in actions are session speaker IDs; `nil` as a target means "unknown speaker".
public enum SpeakerEditAction: Codable, Sendable, Equatable {
    /// Sets or clears (`name == nil`) the display name.
    case rename(speakerID: String, name: String?)
    /// Links the speaker to a person (a profile); a confirmed label.
    case linkProfile(speakerID: String, profileID: String)
    /// "Not Jim" for this session only.
    case rejectProfile(speakerID: String, profileID: String)
    /// Moves every turn of `from` to `into`; `from` disappears.
    case merge(from: String, into: String)
    case reassignTurns(turnIDs: [String], to: String?)
    /// Splits before `at`; the second part gets ID "<turnID>/<editID>".
    case splitTurn(turnID: String, at: WordRef)
    /// Creates `speakerID` ("user:<uuid>") and moves the turns to it.
    case newSpeaker(speakerID: String, name: String?, turnIDs: [String])
    case excludeFromEnrollment(turnIDs: [String])
    /// Undo: the projection skips the referenced edit.
    case revert(editID: String)
}

/// One append-only journal line. Edits never change the run; the projection applies them.
public struct SpeakerEdit: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int
    public var id: String
    public var baseRunID: String
    public var at: Date
    /// "app", "cli", or "carry" (carried over from an earlier run, §4.9).
    public var source: String
    public var action: SpeakerEditAction
    /// Fingerprint of the prior value in the editor's view (docs/meeting-design.md §4.9);
    /// a mismatch at write time refuses the edit, and at projection time makes it stale.
    public var expected: String?
    /// Edits appended by one `SpeakerEditor.apply` share this ID; undo reverts the whole batch.
    public var batchID: String?

    public init(schemaVersion: Int = 1, id: String = UUID().uuidString, baseRunID: String, at: Date = Date(),
                source: String, action: SpeakerEditAction, expected: String? = nil, batchID: String? = nil) {
        self.schemaVersion = schemaVersion; self.id = id; self.baseRunID = baseRunID; self.at = at
        self.source = source; self.action = action; self.expected = expected; self.batchID = batchID
    }
}

// MARK: - Recognition (speakers/recognition/<runID>.json). Distances only, no vectors.

public struct RecognitionThresholds: Codable, Sendable, Equatable {
    /// Cosine distance at or below which a match can be `likely`; 0 disables `likely`…
    public var likelyMaxDistance: Double
    /// …if the next-best profile is at least this much farther.
    public var likelyMinMargin: Double
    /// Cosine distance at or below which a match is at least `possible`.
    public var possibleMaxDistance: Double
    /// Samples with less speech are weak and cannot produce `likely`.
    public var minSampleSeconds: Double

    public init(likelyMaxDistance: Double, likelyMinMargin: Double, possibleMaxDistance: Double,
                minSampleSeconds: Double) {
        self.likelyMaxDistance = likelyMaxDistance; self.likelyMinMargin = likelyMinMargin
        self.possibleMaxDistance = possibleMaxDistance; self.minSampleSeconds = minSampleSeconds
    }
}

public struct SpeakerMatch: Codable, Sendable, Equatable {
    /// Machine speaker in the run.
    public var speakerID: String
    public var profileID: String
    /// Profile name when recognition ran; the projection prefers the current name.
    public var profileName: String
    public var distance: Double
    public var tier: RecognitionTier

    public init(speakerID: String, profileID: String, profileName: String, distance: Double, tier: RecognitionTier) {
        self.speakerID = speakerID; self.profileID = profileID; self.profileName = profileName
        self.distance = distance; self.tier = tier
    }
}

/// Two or more speakers of one session matched the same profile.
public struct MergeSuggestion: Codable, Sendable, Equatable {
    public var speakerIDs: [String]
    public var profileID: String

    public init(speakerIDs: [String], profileID: String) {
        self.speakerIDs = speakerIDs; self.profileID = profileID
    }
}

public struct RecognitionResult: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runID: String
    public var createdAt: Date
    public var embeddingModel: EmbeddingModelID
    public var thresholds: RecognitionThresholds
    public var matches: [SpeakerMatch]
    public var mergeSuggestions: [MergeSuggestion]
    /// Profiles left out because their embedding model differs from the run's.
    public var skippedProfiles: [String]

    public init(schemaVersion: Int = 1, runID: String, createdAt: Date = Date(), embeddingModel: EmbeddingModelID,
                thresholds: RecognitionThresholds, matches: [SpeakerMatch], mergeSuggestions: [MergeSuggestion] = [],
                skippedProfiles: [String] = []) {
        self.schemaVersion = schemaVersion; self.runID = runID; self.createdAt = createdAt
        self.embeddingModel = embeddingModel; self.thresholds = thresholds; self.matches = matches
        self.mergeSuggestions = mergeSuggestions; self.skippedProfiles = skippedProfiles
    }
}

// MARK: - Timeline annotations for exports

/// Why audio is missing for an interval. Open string code. The raw values are also the
/// `reason` strings of `audioDiscontinuity` events (§3.2).
public struct GapReason: OpenStringCode {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let paused = GapReason("paused")
    public static let sleep = GapReason("sleep")
    public static let deviceChanged = GapReason("deviceChanged")
    public static let captureRestarted = GapReason("captureRestarted")
    /// Capture was not running while the recorder waited for audio (phase `waiting`).
    public static let audioUnavailable = GapReason("audioUnavailable")
    /// Audio was dropped because the disk could not keep up.
    public static let overflow = GapReason("overflow")
    /// An unexplained timestamp gap longer than 1 second (exports only; not an event reason).
    public static let audioGap = GapReason("audioGap")
    /// Reserved for a later `holos session redact`; not written in v1.
    public static let redacted = GapReason("redacted")
}

public struct TimelineGap: Codable, Sendable, Equatable {
    /// Nil when every track is missing audio.
    public var track: String?
    public var start: Double
    public var end: Double
    public var reason: GapReason

    public init(track: String? = nil, start: Double, end: Double, reason: GapReason) {
        self.track = track; self.start = start; self.end = end; self.reason = reason
    }
}

public struct TimelineMarker: Codable, Sendable, Equatable {
    public var at: Double
    public var label: String?

    public init(at: Double, label: String? = nil) { self.at = at; self.label = label }
}
```

### 3.4 JSON examples

Generated by encoding the contract types above with `HolosJSON` (pretty files use
JSONEncoder's `"key" : value` spacing). Real embeddings are 256-dimensional.

#### meeting.json

```json
{
  "applicationBundleID" : "us.zoom.xos",
  "createdAt" : "2026-09-23T14:00:00Z",
  "mode" : "call",
  "origin" : "recorded",
  "othersInRoom" : false,
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10"
}
```

#### vocabulary.json

```json
{
  "schemaVersion" : 1,
  "strings" : [
    "Maria Chen",
    "strata",
    "bylaw 12"
  ]
}
```

#### control/7C0E….json (marker)

```json
{
  "command" : "marker",
  "createdAt" : "2026-09-23T15:02:03Z",
  "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
  "label" : "Budget vote",
  "schemaVersion" : 1,
  "sender" : "app",
  "sentAtNanos" : 912345678901234,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10"
}
```

#### status.json (recording)

```json
{
  "bytesWritten" : 715000000,
  "elapsedSeconds" : 3723.6,
  "freeBytes" : 22800000000,
  "handledRequests" : [
    {
      "command" : "marker",
      "handledAt" : "2026-09-23T15:02:03Z",
      "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
      "result" : "applied"
    }
  ],
  "lastPhrase" : "…",
  "markers" : 1,
  "microphoneName" : "AirPods Pro",
  "name" : "Council meeting",
  "phase" : "recording",
  "pid" : 48211,
  "recordedSeconds" : 3601.2,
  "schemaVersion" : 1,
  "sequence" : 3724,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "source" : "mic+system",
  "startedAt" : "2026-09-23T14:00:00Z",
  "tracks" : [
    {
      "backlogSeconds" : 0.2,
      "channels" : 1,
      "lastFinalizedSeconds" : 3719.8,
      "lastFrameSeconds" : 3723.5,
      "sampleRate" : 48000,
      "stalled" : false,
      "track" : "mic",
      "transcription" : "live"
    },
    {
      "backlogSeconds" : 0.1,
      "channels" : 1,
      "lastFinalizedSeconds" : 2410,
      "lastFrameSeconds" : 3723.4,
      "sampleRate" : 48000,
      "stalled" : false,
      "track" : "system",
      "transcription" : "behind"
    }
  ],
  "updatedAt" : "2026-09-23T15:02:04Z",
  "warnings" : [
    {
      "code" : "transcriptionBehind",
      "message" : "System audio transcription is behind; it will finish after you stop.",
      "since" : "2026-09-23T14:40:11Z"
    }
  ]
}
```

#### status.json (exited)

```json
{
  "bytesWritten" : 2072000000,
  "elapsedSeconds" : 10795.2,
  "exit" : {
    "archiveStatus" : "complete",
    "postprocessing" : "succeeded",
    "reason" : "requested"
  },
  "freeBytes" : 21400000000,
  "handledRequests" : [
    {
      "command" : "marker",
      "handledAt" : "2026-09-23T15:02:03Z",
      "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
      "result" : "applied"
    }
  ],
  "markers" : 1,
  "microphoneName" : "AirPods Pro",
  "name" : "Council meeting",
  "phase" : "exited",
  "pid" : 48211,
  "recordedSeconds" : 10790,
  "schemaVersion" : 1,
  "sequence" : 11020,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "source" : "mic+system",
  "startedAt" : "2026-09-23T14:00:00Z",
  "tracks" : [

  ],
  "updatedAt" : "2026-09-23T17:03:40Z",
  "warnings" : [

  ]
}
```

#### postprocess.json (running)

```json
{
  "othersInRoom" : false,
  "pid" : 48211,
  "progress" : {
    "fraction" : 0.42,
    "message" : "Labelling speakers (system audio)…",
    "stage" : "diarize",
    "track" : "system"
  },
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "stages" : [
    {
      "result" : "succeeded",
      "seconds" : 0.4,
      "stage" : "transcript"
    },
    {
      "result" : "succeeded",
      "seconds" : 21.7,
      "stage" : "render"
    }
  ],
  "startedAt" : "2026-09-23T17:00:00Z",
  "state" : "running",
  "transcriptID" : "9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A",
  "updatedAt" : "2026-09-23T17:00:40Z"
}
```

#### speakers/head.json

```json
{
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "updatedAt" : "2026-09-23T17:01:40Z"
}
```

#### speakers/runs/5C1D….json (no voice embeddings)

```json
{
  "alignment" : {
    "parameters" : {
      "echoMinRunWords" : 3,
      "flickerBoundarySeconds" : 0.3,
      "flickerMaxGapSeconds" : 0.25,
      "flickerMaxSeconds" : 0.4,
      "flickerMaxWords" : 2,
      "flickerMinOwnSegmentSeconds" : 0.3,
      "gapSnapSeconds" : 0.5,
      "offsetSearchSeconds" : 0.5,
      "offsetStepSeconds" : 0.02,
      "overlapMinFraction" : 0.5,
      "overlapMinSeconds" : 0.1,
      "turnPauseSeconds" : 1.5
    },
    "trackOffsets" : {
      "system" : 0.06
    },
    "version" : 1
  },
  "createdAt" : "2026-09-23T17:01:40Z",
  "droppedWords" : [

  ],
  "engine" : {
    "configuration" : {
      "clusteringThreshold" : "0.6",
      "exclusiveSegments" : "false",
      "exposeChunkEmbeddings" : "true"
    },
    "embeddingDimension" : 256,
    "embeddingModel" : {
      "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
      "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    },
    "engine" : "FluidAudio.OfflineDiarizerManager",
    "engineVersion" : "0.17.1",
    "models" : [
      {
        "id" : "FluidInference/speaker-diarization-coreml",
        "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        "sha256" : "<tree digest>"
      }
    ]
  },
  "id" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "speakers" : [
    {
      "clusterIDs" : [

      ],
      "displayName" : "Me",
      "id" : "mic:me",
      "ordinal" : 1,
      "provenance" : {
        "channelAssumption" : {

        }
      }
    },
    {
      "clusterIDs" : [
        "system:S1"
      ],
      "id" : "system:S1",
      "ordinal" : 2,
      "provenance" : {
        "diarizer" : {

        }
      }
    },
    {
      "clusterIDs" : [
        "system:S2"
      ],
      "id" : "system:S2",
      "ordinal" : 3,
      "provenance" : {
        "diarizer" : {

        }
      }
    }
  ],
  "tracks" : [
    {
      "clusters" : [

      ],
      "policy" : {
        "channel" : {
          "displayName" : "Me",
          "speakerID" : "mic:me"
        }
      },
      "segments" : [

      ],
      "track" : "mic"
    },
    {
      "clusters" : [
        {
          "clusterID" : "system:S1",
          "speechSeconds" : 2472.3,
          "track" : "system"
        },
        {
          "clusterID" : "system:S2",
          "speechSeconds" : 1323,
          "track" : "system"
        }
      ],
      "policy" : {
        "diarized" : {

        }
      },
      "segments" : [
        {
          "clusterID" : "system:S1",
          "end" : 19.4,
          "overlapCount" : 0,
          "quality" : 0.91,
          "start" : 12,
          "track" : "system"
        },
        {
          "clusterID" : "system:S2",
          "end" : 25,
          "overlapCount" : 1,
          "quality" : 0.84,
          "start" : 18.9,
          "track" : "system"
        }
      ],
      "track" : "system"
    }
  ],
  "transcriptID" : "9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A",
  "turns" : [
    {
      "assignmentScore" : 0.97,
      "clusterID" : "system:S1",
      "end" : 18.7,
      "id" : "T1",
      "otherClusters" : [

      ],
      "overlap" : false,
      "spans" : [
        {
          "end" : 17,
          "first" : 0,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000001"
        }
      ],
      "speakerID" : "system:S1",
      "start" : 12.1,
      "timing" : "measured",
      "track" : "system"
    },
    {
      "assignmentScore" : 0.88,
      "clusterID" : "system:S2",
      "end" : 24.8,
      "id" : "T2",
      "otherClusters" : [
        "system:S1"
      ],
      "overlap" : true,
      "spans" : [
        {
          "end" : 21,
          "first" : 17,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000001"
        },
        {
          "end" : 9,
          "first" : 0,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000002"
        }
      ],
      "speakerID" : "system:S2",
      "start" : 19,
      "timing" : "measured",
      "track" : "system"
    }
  ]
}
```

#### speakers/voice/5C1D….json (evaluation sessions only, hidden forceVoiceData; 2-d vectors shown, real ones are 256-d)

```json
{
  "centroids" : {
    "system:S1" : "fPKwPbN78rw=",
    "system:S2" : "CtejPK5H4T0="
  },
  "createdAt" : "2026-09-23T17:01:40Z",
  "embeddingModel" : {
    "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
    "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
  },
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "turnEmbeddings" : [
    {
      "speechSeconds" : 6.6,
      "turnID" : "T1",
      "vector" : "uB4FPgrXo7w="
    }
  ]
}
```

#### speakers/recognition/5C1D….json

```json
{
  "createdAt" : "2026-09-23T17:01:41Z",
  "embeddingModel" : {
    "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
    "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
  },
  "matches" : [
    {
      "distance" : 0.21,
      "profileID" : "D4C3B2A1-1111-4222-8333-944455566677",
      "profileName" : "Jim",
      "speakerID" : "system:S1",
      "tier" : "possible"
    },
    {
      "distance" : 0.33,
      "profileID" : "E5F6A7B8-1111-4222-8333-944455566677",
      "profileName" : "Maria",
      "speakerID" : "system:S2",
      "tier" : "possible"
    }
  ],
  "mergeSuggestions" : [

  ],
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "skippedProfiles" : [

  ],
  "thresholds" : {
    "likelyMaxDistance" : 0,
    "likelyMinMargin" : 0.1,
    "minSampleSeconds" : 20,
    "possibleMaxDistance" : 0.4
  }
}
```

#### speakers/edits.jsonl (four lines: one two-line batch, then two single edits)

```json
{"action":{"linkProfile":{"profileID":"E5F6A7B8-1111-4222-8333-944455566677","speakerID":"system:S2"}},"at":"2026-09-23T17:11:40Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","expected":"","id":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","schemaVersion":1,"source":"app"}
{"action":{"rename":{"name":"Maria","speakerID":"system:S2"}},"at":"2026-09-23T17:11:40Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","expected":"","id":"0B1C2D3E-4F50-4162-8374-95A6B7C8D9EA","schemaVersion":1,"source":"app"}
{"action":{"reassignTurns":{"to":"system:S1","turnIDs":["T7","T9"]}},"at":"2026-09-23T17:12:00Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"1B2C3D4E-5F60-4172-8384-95A6B7C8D9EA","expected":"system:S2,system:S2","id":"1B2C3D4E-5F60-4172-8384-95A6B7C8D9EA","schemaVersion":1,"source":"cli"}
{"action":{"splitTurn":{"at":{"segmentID":"A1B2C3D4-0000-4000-8000-000000000031","word":6},"turnID":"T12"}},"at":"2026-09-23T17:12:20Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"2C3D4E5F-6071-4283-9495-A6B7C8D9EAFB","id":"2C3D4E5F-6071-4283-9495-A6B7C8D9EAFB","schemaVersion":1,"source":"app"}
```

## 4. Integration seams

Later PRs build against these seams; earlier PRs provide them or a stub with the final
signature.

### 4.1 Recorder ↔ app protocol

Files, not sockets or XPC. The session folder is private (0700), which restricts access
to the user; every command is an allowlisted enum value with an exact session ID.

**Launch (child mode, PR4).** The app computes a session ID, writes the vocabulary file
(§4.12), then spawns:

```
Holos.app/Contents/MacOS/holos record start
    --session-id <UUID> --name <name> --source mic|mic+system [--app <bundle-id>]
    [--others-in-room] [--expected-speakers N] [--vocabulary-file <path>]
    --no-live-text --directory <HolosPaths.sessions>
```

- `posix_spawn` with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT` (§1.7 rule 4).
  fd 0 is `/dev/null`; fds 1 and 2 are `~/Library/Logs/Holos/recorder-<UUID>.log`
  (`O_WRONLY|O_APPEND|O_CREAT`, 0600). Never pipes: a pipe to a dead app would raise
  SIGPIPE in the recorder. With its own session the recorder gets no terminal SIGHUP
  and no signals sent to the app's process group.
- The recorder ignores SIGPIPE. SIGINT and SIGTERM stop gracefully (audio saved,
  post-processing runs). SIGHUP keeps today's default behaviour; changing it is open
  question Q6.
- The app reaps the child with `DispatchSource.makeProcessSource(identifier:eventMask: .exit)`
  plus `waitpid(pid, WNOHANG)`. After an app relaunch the recorder is no longer its
  child; liveness then comes from locks and `status.json` (below).
- Environment: inherited, plus `HOLOS_RECORDER_PARENT=app` (informational, logged).

**Files.**

| File | Writer | Reader | Rule |
|---|---|---|---|
| `meeting.json` | recorder at start | post-processor, app | written once, before capture starts |
| `vocabulary.json` | recorder at start (copy of `--vocabulary-file`, which it then deletes) | recorder, replay, rebuild, post-processing | written once |
| `status.json` | recorder `StatusWriter` actor | app, `holos record status` | atomic rewrite on every change and as a heartbeat every 1 s from launch until exit; `sequence` increments; kept after exit with `phase: exited` |
| `control/<UUID>.json` | app or CLI via `RecorderChannel.send` | recorder `ControlInbox` | published by rename from `control/.<UUID>.tmp`; polled every 100 ms while capture runs and every 1 s after it stops; applied at most once; `controlHandled` event; file deleted; `ControlAck` added to `status.json`; leftovers deleted at exit |
| `stop.request` | legacy `holos record stop` | recorder | still honoured as a stop request |
| `control.json` | — | — | no longer written (PR2a); `status.json` carries pid and start time |

`RecorderChannel` (PR2a, `Sources/HolosMeeting/RecorderChannel.swift`):

```swift
public enum RecorderLiveness: String, Sendable, Equatable {
    /// Writer lock held, and status.json absent or fresh with phase starting…transcribing.
    case capturing
    /// Processing lease held and status.json fresh with phase postprocessing (the recorder's own post-processing).
    case processing
    /// A lock is held by something else: recover, rebuild, `session diarize`, delete, or a stale status.
    case maintenance
    /// No lock held and status.json phase == exited.
    case exited
    /// No lock held and status.json missing or not exited: interrupted if the manifest says recording/processing.
    case dead
}

public enum RecorderChannel {
    /// Reads status.json; nil when absent. Throws on a newer schemaVersion.
    public static func readStatus(session: URL) throws -> RecorderStatus?
    /// Publishes one request atomically with `sentAtNanos` from mach_continuous_time; creates control/ (0700).
    /// Refuses (`unavailable`) when the session has no manifest yet (the recorder is still starting; stop it
    /// with SIGTERM instead), when status.json says exited, or when only a maintenance command holds the
    /// session (`maintenanceOnly`): no recorder would read or remove the request.
    @discardableResult
    public static func send(_ command: ControlCommand, label: String? = nil, session: URL,
                            sessionID: String, sender: String) throws -> ControlRequest
    /// Liveness is `maintenance` and status.json is missing or exited, or names a process that is gone. A live
    /// recorder with a stale status is not maintenance-only: it still answers `control/`.
    public static func maintenanceOnly(session: URL, now: Date = Date()) -> Bool
    /// Polls status.json every 50 ms for the request's ack.
    public static func waitForAck(_ request: ControlRequest, session: URL, timeout: Duration) async -> ControlAck?
    /// "Fresh" means updatedAt less than 10 s before `now` and kill(pid, 0) == 0.
    public static func liveness(session: URL, now: Date = Date()) -> RecorderLiveness
    /// For maintenance commands: when liveness is dead and status.json is not exited, rewrites it as exited
    /// (reason `interrupted`, archiveStatus from the manifest). Returns true if it rewrote.
    public static func markDeadRecorderExited(session: URL, now: Date = Date()) throws -> Bool
}
```

Senders wait for the previous state-changing request's ack before sending the next
(`waitForAck`, 3 s), unless the CLI was given `--no-wait`.

**Control inbox rules (recorder side, PR2a `ControlInbox`).** Consider only regular
files named `<UUID>.json` (no dot prefix, `lstat`, no symlinks), at most 4 KiB. Reject
(log `controlRejected`, delete) files that fail to decode, have `schemaVersion != 1`, a
different `sessionID`, or an unknown command. Truncate labels to 200 characters. Apply
in `(sentAtNanos ?? 0, id)` order, never by `createdAt`. Keep handled IDs in memory; a
repeated ID is acknowledged `ignored`.

| Command | recording | waiting | paused | sleeping | starting | after capture stopped |
|---|---|---|---|---|---|---|
| `stop` | applied → stopping | applied → stopping | applied → stopping | applied → stopping | applied (stops right after start) | ignored ("already stopping") |
| `pause` | applied → paused | applied → paused | ignored | rejected ("the computer is asleep") | rejected | ignored |
| `resume` | ignored | ignored ("already restarting audio") | applied → recording | rejected | rejected | ignored |
| `marker` | applied | applied | applied | applied | rejected | ignored |

**Reattach (PR4).** On launch, and every 3 s while idle, `MeetingController` looks for
a live meeting: it `stat`s `status.json` under `HolosPaths.sessions` and decodes only
files modified in the last 10 s. A session with a fresh status, liveness `capturing` or
`processing`, and phase `isMeetingActive` or `postprocessing` is the current meeting,
whoever started it (app or terminal). Only sessions under `HolosPaths.sessions` are
visible to the app.

**In-process fallback (decision 4).** `InProcessLauncher` (PR4) runs
`RecordingWorkflow.run` in a task inside the app with the same options. Frames are
consumed off the main actor (§1.3), and the launcher holds
`ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled])`
while recording so App Nap and timer coalescing do not apply. The recorder code writes
the same `status.json` and reads the same `control/`, so `MeetingController` does not
know which launcher is used. Post-processing still runs in a child, keeping FluidAudio
out of the app: the in-process `PostProcessHook` (§4.6) hands the processing lease to a
child without ever releasing it. It spawns
`holos session diarize <path> --after-recording --json --lease-fd 3` with a
`posix_spawn_file_actions_adddup2` that places the lease's lock descriptor at fd 3 in the
child (dup2 clears close-on-exec on the copy; `flock` locks belong to the open file
description, so the child now co-owns the held lock). Only after `posix_spawn` succeeds does
the parent close its own descriptor; the lock stays held by the child until it exits. With
`--lease-fd`, the child adopts that descriptor as its `ProcessingLease` instead of acquiring
one, and refuses to run if fd 3 is not a lock on this session's lease file. If the spawn
fails, the parent still holds the lease and records the failure itself. There is therefore
no moment when neither the writer lock nor the lease is held, so `liveness` never reads a
fresh `postprocessing` session as `dead`, and recovery, deletion, or relabelling cannot slip
in. The hook mirrors the child's `postprocess.json` progress into `status.json` and returns
its final record. Test `inProcessLeaseHandoffHasNoGap` (PR4): a probe polling
`SessionLocks.isProcessing` throughout the handoff never sees `false`. The mode is `UserDefaults "meetingRecorderMode"` = `child` (default) or
`inProcess`; S2 decides the default.

### 4.2 Recorder state machine

Owned by PR2a as a pure reducer, `RecorderMachine`
(`Sources/HolosMeeting/RecorderMachine.swift`). PR2a defines every input and effect and
implements everything except the sleep, watchdog, and device rules, which PR2b fills in
(stacked on PR2a). The `@MainActor` recorder loop feeds it inputs and executes its
effects in order.

```swift
public enum CaptureEnd: Sendable, Equatable {
    case requested                   // the stream finished after stopCapture
    case configurationChanged        // AVAudioEngineConfigurationChange
    case failed(message: String)     // any other error, including ScreenCaptureKit stopping by itself
    case startFailed(message: String)
    case userStoppedSharing          // SCStreamError.Code.userStopped only
}

public enum RecorderInput: Sendable, Equatable {
    /// The first frame of `epoch` arrived at session time `at`.
    case captureRunning(epoch: Int, at: Double)
    /// Ends from any epoch other than the current one are ignored (logged).
    case captureEnded(epoch: Int, CaptureEnd, at: Double)
    case control(ControlRequest, at: Double)
    case signal(at: Double)
    case durationElapsed(at: Double)
    case willSleep(at: Double)
    case didWake(at: Double, lidOpen: Bool)
    /// Lid opened, screen unlocked (`com.apple.screenIsUnlocked`), or the CoreAudio device list changed.
    case retryNow(reason: String, at: Double)
    /// Every 1 s. `lastFrameAt`: per track, the session time at which the consumer last received a frame.
    case tick(at: Double, lidOpen: Bool, freeBytes: Int64?, lastFrameAt: [String: Double])
}

public enum RecorderEffect: Sendable, Equatable {
    /// Stop capture (≤ 5 s), drain, close every open chunk with `reason` pending, send a boundary to each LiveTrack.
    case stopCapture(reason: GapReason)
    /// Start epoch `epoch` at timelineOffset max(clock.now(), lastFrameEnd + 0.01) (§2.3).
    case startCapture(epoch: Int)
    case recordEvent(kind: String, details: [String: String])
    case acknowledge(ControlAck)
    case warn(RecorderWarning)
    case clearWarning(RecorderWarningCode)
    /// IOAllowPowerChange for the pending willSleep, after chunks are closed.
    case allowSleep
    /// Take or release the idle-sleep assertion (released while paused).
    case holdPowerAssertion(Bool)
    /// Leave the loop; the stop path (§4.6) runs next.
    case finish(StopReason)
}

public struct RecorderMachine: Sendable, Equatable {
    public private(set) var phase: RecorderPhase       // starting, recording, paused, waiting, sleeping, stopping
    public private(set) var epoch: Int
    public private(set) var markers: Int
    public init()
    public mutating func handle(_ input: RecorderInput) -> [RecorderEffect]
}
```

```
            captureRunning(0)                       resume
 starting ─────────────────▶ recording ◀──────────────────────── paused ◀─┐
    │ capture ends before       │  ▲ │ pause                          ▲      │ pause
    ▼ its first frame           │  │ └────────────────────────────────┘      │
 finish(startFailed)            │  │ retry succeeds                         │
                 capture fails, │  │ (tick ≥ retryAt, or retryNow)          │
                 restart fails  ▼  │                                        │
                              waiting ─────────────────────────────────────┘
                                 │ unavailable ≥ 600 s → finish(captureFailed)
 recording / waiting / paused ── willSleep ──▶ sleeping ── didWake/tick ──▶ recording, paused, or finish(sleepTimeout)
 stop / signal / duration / diskLow < 500 MB / pause ≥ 6 h ──▶ finish(reason) → stopping → transcribing
                                                                 → (archive.finish) → postprocessing → exited
```

Rules the reducer encodes:

- **Epochs.** Every restart is `stopCapture(reason)` followed by `startCapture(epoch+1)`.
  No path starts a capture without first stopping the previous one, so each restart
  closes chunks with its reason and gives `LiveTrack` a boundary. Each epoch creates a
  fresh `MeetingCapture` (streams are single-use).
- **Start.** `starting` + `captureRunning(0)` → `recording`. A capture end for epoch 0
  before its first frame → `recordEvent(startFailed)`, `finish(startFailed)`. A stop
  request while starting is applied and finishes right after capture starts.
- **Restarts and `waiting`** (resolution for review finding C1):
  - `configurationChanged` while recording → `recordEvent(deviceChanged)`,
    `warn(deviceChanged)`, `stopCapture(.deviceChanged)`, `startCapture(epoch+1)`.
  - `failed` or `startFailed` for the current epoch → `recordEvent(captureFailed {epoch,
    error})`. If `attempt == 0`: `stopCapture(.captureRestarted)` and `startCapture(epoch+1)`
    at once (`attempt = 1`). Otherwise: `stopCapture(.audioUnavailable)` (chunks are
    already closed; this sets the gap's reason) → `waiting`,
    `retryAt = at + min(30, 0.5 × 2^(attempt−1))` (0.5, 1, 2, 4, … 30 s),
    `recordEvent(captureWaiting {at, reason, attempt, retryInSeconds})`,
    `warn(audioUnavailable)`. `unavailableSince` is set on the first failure and kept
    across attempts.
  - `waiting` + (`tick` with `at ≥ retryAt`, or `retryNow`) → `startCapture(epoch+1)`,
    `attempt += 1`, phase `recording`. The phase is `recording` while a start is in
    flight; a start failure comes back as `startFailed`.
  - An epoch that has delivered frames for 10 s resets `attempt` to 0, clears
    `unavailableSince`, and emits `clearWarning(audioUnavailable)`. This stops a
    fail-fast loop (start works, fails 10 ms later) from retrying at full speed.
  - `tick` with `at − unavailableSince ≥ 600` → `finish(captureFailed)`. Audio before
    the outage is saved.
  - `userStoppedSharing` → `finish(requested)`. Only `SCStreamError.Code.userStopped`
    maps to it; every other ScreenCaptureKit error is `failed`, so ScreenCaptureKit
    stopping under screen lock waits and retries (and `retryNow` fires on unlock).
- **Pause.** `pause` while recording or waiting → `stopCapture(.paused)` (recording
  only), `recordEvent(paused {at})`, `holdPowerAssertion(false)`, ack applied → `paused`
  (`pausedSince = at`; retries stop). `resume` → `recordEvent(resumed {at, epoch})`,
  `holdPowerAssertion(true)`, `startCapture(epoch+1)` → `recording`. A pause (including
  sleep while paused) lasting 6 h → `finish(pauseTimeout)`.
- **Disk** (§4.5) and **watchdog** (below) are evaluated on every 1 s `tick` while
  starting or recording (the watchdog once the epoch's capture has started), so an
  epoch 0 that never delivers its first frame is flagged and restarted like any other
  stall. The disk is also checked while waiting.
- **Watchdog** (`TrackWatchdog`, held in the machine; PR2b). A track's stall timer starts
  at the epoch's start time and is reset by every `lastFrameAt` update. No frame for
  3 s → `recordEvent(trackStalled {track, silentSeconds})`, `warn(trackStalled)`.
  Frames again → `recordEvent(trackResumed)`, `clearWarning` when no track is stalled.
  A **microphone** track stalled for 10 s → `stopCapture(.captureRestarted)`,
  `startCapture(epoch+1)`; if the stalled epoch delivered no frame on any track, audio
  counts as unavailable from then (`unavailableSince`), so the 600 s limit ends a
  recording whose restarts never bring audio back. The system track is never restarted for a stall
  (ScreenCaptureKit may deliver nothing during silence, open question Q4). Arrival times
  come from the session clock, which starts at epoch 0's origin, so a slow startup or a
  permission prompt never looks like a stall.
- **Sleep** (PR2b): §4.4.
- After `finish`, the loop exits and every later input is ignored; the stop path (§4.6)
  is sequential code in `RecordingWorkflow.run`.

Loop rules (PR2a): every 100 ms drain power events (`pendingEvents()`, §4.4), poll
`ControlInbox`, check the stop source and legacy `stop.request`, and check the
duration; every 1 s build `tick` and then `StatusWriter.update`. Execute effects in
order. `startCapture` in call mode with no input device at all (PR2b) starts
ScreenCaptureKit with `captureMicrophone = false`, warns `microphoneUnavailable`
("Microphone unavailable; recording call audio only"), and retries with the microphone
on the next `retryNow` for a device-list change.

**If S2 shows ScreenCaptureKit stops under screen lock**, the waiting phase already
keeps the meeting alive and marks the gap. If that loses too much of the in-room
microphone, a follow-up captures the call-mode microphone with its own AVAudioEngine
`MeetingCapture` next to a system-only ScreenCaptureKit capture. No interface in this
document changes for that.

### 4.3 Capture → disk path

Disk latency never reaches the capture path (PR2a):

```
AudioCapture callback ─yield─▶ frames stream (4,096 buffers; overflow drops the buffer and counts it, never fails)
        │  consumer task (detached; never awaits disk or speech; stamps lastFrameAt)
        ├──▶ ChunkWriterPump.push   ≤ 60 s queued per track ─▶ writer task ─▶ AudioChunkWriter ─▶ SessionArchive
        └──▶ LiveTrack.push         ≤ 30 s queued per track ─▶ speech task ─▶ LiveSpeechSession
```

- `AudioCapture` no longer fails when its stream is full: it drops the buffer and
  increments `droppedBuffers`. The consumer sees the counter advance and calls
  `pump.noteGap(track:reason: .overflow)`.
- `ChunkWriterPump` (HolosAudio) queues frames per track, bounded by duration (60 s).
  `push` never blocks; when a track's queue is full it drops the frame, remembers the
  dropped interval, and the writer closes the chunk with pending reason `overflow`
  (event `audioDiscontinuity {reason: overflow}`); the loop warns `audioDropped`.
  `backlogSeconds` per track goes to `status.json`.
- Chunk registration stays as it is (hash, fsync, manifest rewrite every 30 s); it runs
  on the writer task, so a slow fsync only grows the backlog.
- `SessionArchive` journal group commit (PR6): the recorder calls
  `archive.setJournalSync(.interval(seconds: 1))`. Events are written with `write(2)`
  at once and fsync'd by the actor at most once per second, at `finish`, and at once
  for `captureStopped`, `archiveRecovered`, and `transcriptRebuilt`. A crash loses at
  most about 1 s of events; recovery already tolerates a torn tail. Other callers keep
  today's per-event fsync.
- `AudioChunkWriter` additions (PR2a): `bytesWritten()`, `lastFrameEnd`,
  `closeAll(expectingGap:)`, and `noteGap(track:reason:)`, which sets the reason of the
  track's next `audioDiscontinuity`. It applies `FrameContinuity` (§2.3).
- The `audioDiscontinuity.reason` strings are exactly the `GapReason` raw values
  (`paused`, `sleep`, `deviceChanged`, `captureRestarted`, `audioUnavailable`,
  `overflow`) plus the writer's own `timestampGap` and `formatChanged`. There is no
  second spelling.

### 4.4 Sleep and power (PR2b)

- `PowerAssertion` (`kIOPMAssertionTypePreventUserIdleSystemSleep`, named "Holos meeting
  recording") is held from `starting` through post-processing, except while paused
  (`holdPowerAssertion(false)`), so a meeting left paused lets the Mac idle-sleep. Lid
  close and forced sleep still happen.
- `SystemPowerMonitor` (HolosAudio): `IORegisterForSystemPower` on a dispatch queue. It
  buffers events in a `Mutex` and the loop drains them with `pendingEvents()` every
  100 ms. `canSleep` is allowed immediately by the monitor. `willSleep` is queued for
  the loop only while a loop is attached (`attach()` at loop start, `detach()` at loop
  exit); otherwise the monitor calls `IOAllowPowerChange` itself, so transcription and
  post-processing never delay a lid close. From the recorder's start until the loop
  attaches (`observe()`: permission prompts, speech setup, capture start), `willSleep`
  and `didWake` are still queued with their arrival times, and `willSleep` is allowed at
  once; the loop drains them first, after `captureStarted(epoch 0)`, so a sleep during
  the start stops epoch 0 and resumes in epoch 1, or ends the recording
  (`sleepTimeout`) after 15 minutes. Such events have negative session times (before
  epoch 0's origin); they are not clamped to 0, which would erase the sleep's length.
  Device-list and screen-unlock events (§4.2) are buffered from the moment the
  dependencies are made, so they have no such gap; the lid is polled, not observed.
- On `willSleep` the loop executes `stopCapture(.sleep)` as: ask capture to stop (wait at
  most 5 s), close every open chunk, then `allowSleep`, even if the platform stop has
  not returned. Budget under 7 s; macOS allows 30 s.
- Rules in the machine:
  - `willSleep` from `recording`, `waiting`, or `paused`: `recordEvent(systemWillSleep
    {at, phaseBeforeSleep})`, `stopCapture(.sleep)` if recording, → `sleeping`,
    `allowSleep`. `sleepStart` and `phaseBeforeSleep` are set **only** on this
    transition.
  - `willSleep` while already `sleeping` (a dark wake going back to sleep):
    `allowSleep` only. `sleepStart` and `phaseBeforeSleep` stay, so dark wakes neither
    restart the 15-minute count nor forget that the meeting was paused.
  - `didWake(at, lidOpen)`, `slept = at − sleepStart` on the continuous clock:
    - `phaseBeforeSleep == paused` → `paused` for any sleep length (the 6 h pause limit
      still applies); event `didWake {action: wait}`. The menu shows "Paused — Resume
      or Stop". (Refinement of decision 5; Q1.)
    - `slept ≥ 900` → `finish(sleepTimeout)`; event `didWake {action: finalize}`. The
      recording ends at the sleep point.
    - `slept < 900`, lid open → `startCapture(epoch+1)`, `warn(resumedAfterSleep)`
      ("Resumed after 4 min of sleep; the gap is marked"), event `didWake {action:
      resume}`; `unavailableSince` restarts.
    - `slept < 900`, lid closed (dark wake, or clamshell) → stay `sleeping`, event
      `didWake {action: wait}`. Each tick re-checks: lid open before 900 s → resume; 900 s
      reached → `finish(sleepTimeout)`.
- `lidOpen` is `AppleClamshellState == false` from `IOPMrootDomain` (absent counts as
  open). The lid opening while `waiting` sends `retryNow`.
- No system notifications in v1 (they would add a permission prompt; resolution R14).
  The app's `suspendForSessionChange` keeps affecting dictation only (§4.12).

### 4.5 Disk policy (PR2a)

Pure functions in `DiskPolicy` (`Sources/HolosMeeting/DiskPolicy.swift`); free space from
`FreeSpaceProvider` (PR6, HolosStorage; `VolumeFreeSpace` = `statfs` `f_bavail × f_bsize`
on the sessions volume). All sizes are decimal (1 GB = 10⁹ bytes), matching the UI.

```swift
public enum DiskVerdict: Sendable, Equatable { case ok, warn(String), refuse(String), stop(String) }

public enum DiskPolicy {
    /// Nominal Int16 capture: mic 48 kHz mono 345.6 MB/h; system 48 kHz mono 345.6 MB/h
    /// (ScreenCaptureKit channelCount = 1).
    public static func captureBytesPerHour(_ source: AudioSource) -> Int64
    /// 16 kHz mono Int16 render per diarized track: 115.2 MB/h (deleted after diarization).
    public static let renderBytesPerHour: Int64 = 115_200_000
    /// capture + render for every track, per hour.
    public static func budgetBytesPerHour(_ source: AudioSource) -> Int64
    /// refuse if free < 4 h budget + 2 GB; warn if free < 8 h budget + 2 GB.
    public static func startCheck(freeBytes: Int64, source: AudioSource) -> DiskVerdict
    /// stop if free < 500 MB; warn once below 2 GB; re-arm the warning after free > 2.5 GB.
    public static func runtimeCheck(freeBytes: Int64, warned: Bool) -> (verdict: DiskVerdict, warned: Bool)
    /// Post-processing: render allowed only if free ≥ renderBytes + 1 GB.
    public static func renderCheck(freeBytes: Int64, renderSeconds: Double, tracks: Int) -> Bool
    /// "≈1.0 GB for 3 h · 24.1 GB free" (capture only, one decimal).
    public static func estimateText(source: AudioSource, hours: Double, freeBytes: Int64) -> String
}
```

The budget holds whatever the microphone delivers: AVAudioEngine keeps the input device's
format (a stereo or 96 kHz interface), so the recorder's frame consumer converts every
track to 48 kHz mono (`RecordingFormatConverter` in HolosAudio: channels averaged, one
resampler per track and epoch) before the pump and the live tracks.

Worked values: mic 4 h budget = 4 × 460.8 MB + 2 GB = 3.84 GB, 8 h = 5.69 GB;
mic+system 4 h = 4 × (691.2 + 230.4) MB + 2 GB = 5.69 GB, 8 h = 9.37 GB. A 3 h
in-person meeting is about 1.04 GB, a 3 h call about 2.07 GB (it was 3.1 GB with stereo
system audio).

The runtime check runs on every 1 s tick (`statfs` is cheap). `stop` →
`recordEvent(diskLow {freeBytes, action: stop})` and `finish(diskLow)`; audio already on
disk is finalized normally, and post-processing skips rendering (§4.7 stage 4).

### 4.6 Stop path, transcript coverage, timeouts, hand-off (PR2a)

After `finish(reason)` the loop exits and `RecordingWorkflow.run` does, in order:

1. **Stop capture** with a 5 s timeout. On timeout, abandon the stream, log, and record
   `captureFailed {epoch, error: "Capture did not stop within 5 s"}`. Drain the consumer,
   let the pump drain into the writer, then `writer.closeAll`. When the epoch's stream had
   already ended by itself (the user stopped sharing, or capture failed), the stop is only
   cleanup: an error from it (ScreenCaptureKit refuses to stop a stopped stream) is logged,
   never reported as a capture failure.
2. Phase `stopping` → `transcribing`. **Finish live speech** per track with a timeout of
   30 s + 0.05 × the seconds fed to its current speech session. On timeout, cancel that
   session; segments it already finalized are kept. The same deadline also ends the finishes of
   earlier sessions (an epoch or gap that ended just before the stop) that are still running.
3. **Coverage.** For each track, `TranscriptCoverage.coverageEnd` (below). A track whose
   live transcription never fell behind keeps its live segments. Otherwise
   `TrackReplayer.replay(from: max(0, coverageEnd − 2))` transcribes only the rest, and
   `TranscriptCoverage.merge` joins the two at word level. Hours of live words are never
   thrown away because of one dropped frame. A replay that times out or fails after partial
   progress keeps the segments of its finished sessions and the finals the failed session
   reported; the track is recorded as a transcription error. `--record-only`: no transcript.
4. `archive.saveTranscript(transcript, writeLegacyExports: false)` (updates
   `transcripts/current.json`).
5. If a post-process hook is set, **acquire the processing lease** (retry 1 s) while
   still holding the writer lock. On failure, skip post-processing with the message
   "Another Holos process is labelling this meeting." The hook does not run, but the
   outcome and `RecorderExit` still carry a `.failed` post-processing record ("Speaker
   labelling was skipped: … Run holos session diarize on this session later."), so
   `Record.Start` exits 3 and the app shows it; only a `nil` hook gives no record.
6. `archive.finish(status)` releases the writer lock when the lease is held. There is no
   moment in which the session holds neither lock, so liveness never reads `dead` between
   capture and post-processing. Without the lease (no hook, or it could not be taken),
   and on every failure or cancellation path, `archive.finish(status, keepingLock: true)`
   keeps the writer lock until `phase: exited` is written (step 8).
7. Phase `postprocessing`; call the hook with the lease. Progress goes into one
   `AsyncStream` read by one task that updates `status.json` in order; after the hook
   returns, finish the stream and await that task.
8. Write `phase: exited` with `RecorderExit` (archive status, stop reason,
   post-processing state and message), then release the last lock (the writer lock or the
   lease), so liveness goes to `exited` without reading `dead` on the way. `StatusWriter`
   then stops its heartbeat and ignores later updates. A failed final write is retried
   (3 attempts, 100 ms × attempt apart); only a write that lands finishes the writer. If
   none does, the error is logged, the heartbeat resumes with the last phase, and the
   recorder keeps its last lock until the process exits, so the session reads busy, not
   dead, while it shuts down; after exit, recovery handles it like any unfinished status.
9. Release the power assertion; delete leftover `control/*.json`; return the outcome.

While steps 1–9 run, `ControlInbox` keeps polling once a second and acknowledges every
request `ignored` ("The recorder is already stopping."). A stop during post-processing
does not cancel it.

Requests are closed before the last poll. Right before step 8 the recorder creates
`control/.closed`, polls one last time (answering `ignored`), writes `exited`, and only
once `exited` is written deletes leftover requests and removes the marker.
`RecorderChannel.send` refuses when the marker exists; after publishing, it checks the
marker and then `status.json`. Either one makes it withdraw its request: a request it
removes is refused; one the recorder already took is answered by the last poll (or,
if `status.json` already says exited without its answer, was a deleted leftover and is
refused). The request file belongs to whoever unlinks it, so the inbox never handles a
request its sender withdrew.

**`StatusWriter` heartbeat.** The actor starts a 1 s timer at launch (phase `starting`)
and rewrites `status.json` every second until `exited`, independent of the loop, so
status stays fresh through transcription and post-processing.

**`LiveTrack`** (PR2a):
- Input is `enum LiveInput { case frame(PCMFrame), boundary }` on a queue bounded by
  duration (30 s of audio, not a buffer count).
- Overflow: record `transcriptionBehind {track, from}` (session time of the first
  dropped frame), set transcription `behind`, stop feeding live speech for the rest of
  the recording, and keep every segment already finalized.
- `boundary`: finish the current speech session (with the timeout above) and keep its
  segments. The next epoch's speech session is created while the previous epoch stops,
  before `startCapture`, so new frames never wait behind `AppleSpeechSession.make`. A
  failed creation records `transcriptionBehind {track, from: epoch start}`.
- Every `transcriptFinalized` event adds `segmentID` and `words` (compact `HolosJSON`
  array of `TimedWord`). The journal queue holds 4,096 segments; if it is full, the
  earliest dropped segment's start is remembered and recorded as `transcriptionBehind
  {track, from}` once the queue drains, so recovery knows where the journal has a hole.
- Speech sessions are rebased to 0 and created with the meeting vocabulary (§2.3,
  §4.12).

**`TranscriptCoverage`** (PR2a, `Sources/HolosMeeting/TranscriptCoverage.swift`, pure;
PR3 reuses it):

```swift
public enum TranscriptCoverage {
    /// End of the last live segment, capped at `behindFrom` (the earliest transcriptionBehind.from for
    /// the track). 0 when there are no live segments.
    public static func coverageEnd(live: [TranscriptSegment], behindFrom: Double?) -> Double
    /// Keeps live words that start before `coverageEnd` and replayed words that start at or after it.
    /// A segment cut at a word boundary keeps its ID for the first part and gets a new UUID for the second;
    /// text is cut at the kept words' UTF-16 offsets. Untimed segments are kept or dropped whole by midpoint.
    public static func merge(live: [TranscriptSegment], replayed: [TranscriptSegment],
                             coverageEnd: Double) -> [TranscriptSegment]
}
```

**Lifecycle hook** (type defined by PR1, status handling by PR2a):

```swift
/// Runs post-processing for a finished session under `lease`. Never throws: failures come back as a
/// `.failed` record with a message.
public typealias PostProcessHook = @Sendable (_ session: URL, _ lease: ProcessingLease,
    _ progress: @escaping @Sendable (PostProcessingProgress) -> Void) async -> PostProcessingRecord
```

`RecordingDependencies.postProcess: PostProcessHook?`. The CLI passes a hook that runs
`makeMeetingPostProcessor(options:).run(session:lease:progress:)`; the in-process app
passes the child-process hook of §4.1; `nil` (`--no-postprocess`, `--record-only`)
skips steps 5 and 7. `Record.Start` only maps the outcome to exit codes (§1.4), so the
CLI and the in-process app run the same lifecycle.

### 4.7 MeetingPostProcessor

`Sources/HolosMeeting/MeetingPostProcessor.swift`. PR1 creates it with its final
signatures; PR7b fills in the stages; PR10 adds voice data and recognition.

```swift
public struct PostProcessingOptions: Sendable, Equatable {
    public var speakers: SpeakerCountHint?
    /// Relabel even when the head run has edits. Names and links carry over (§4.9).
    public var force: Bool
    public var keepDerived: Bool
    /// Overrides meeting.json `othersInRoom` for this run.
    public var othersInRoom: Bool?
    /// Hidden engine settings for evaluation, e.g. ["exclusiveSegments": "true"]; recorded in the run.
    public var engineOverrides: [String: String]
    /// Write speakers/voice/<runID>.json even when "Remember voices" is off (hidden; evaluation sessions only).
    public var forceVoiceData: Bool
    /// The stop reason when called right after a recording; `diskLow` skips rendering.
    public var stopReason: StopReason?
    public init(speakers: SpeakerCountHint? = nil, force: Bool = false, keepDerived: Bool = false,
                othersInRoom: Bool? = nil, engineOverrides: [String: String] = [:], forceVoiceData: Bool = false,
                stopReason: StopReason? = nil)
}

public struct MeetingPostProcessor: Sendable {
    /// PR1: `run` returns a `.skipped` record and writes nothing. From PR7b: runs the stages below;
    /// `diarizer == nil` gives speaker-less exports and the setup hint.
    public init(diarizer: (any SpeakerDiarizer)? = nil, options: PostProcessingOptions = .init(),
                freeSpace: any FreeSpaceProvider = VolumeFreeSpace())
    /// Runs every stage for one finished session under `lease` (nil: acquire one, retry 1 s) and returns the
    /// final postprocess.json record. Throws only when it cannot start (still recording, lease held elsewhere,
    /// unreadable manifest, a postprocess.json written by a newer Holos); stage failures are recorded in the
    /// returned record.
    public func run(session: URL, lease: ProcessingLease?,
                    progress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> PostProcessingRecord
}
```

PR10 adds one initializer parameter, `profiles: SpeakerProfileStore? = nil`; with a
store whose `rememberVoices` is on, stage 7 runs on the in-memory voice data. Stage 6
never writes voice data for normal meetings (only with hidden `forceVoiceData`, §4.10).

Stages (PR7b):

| # | Stage | Does | On failure or not applicable |
|---|---|---|---|
| 0 | — | refuse if `SessionArchive.isActive` ("still recording"); use the given lease or acquire one; refuse (`unavailable`) an existing `postprocess.json` written by a newer Holos, never overwriting it (a damaged one is replaced); `RecorderChannel.markDeadRecorderExited`; delete leftover `derived/`; write `postprocess.json` `{state: running}` | throw |
| 1 | `transcript` | load the current transcript (`transcripts/current.json`, §2.4) | none → `skipped`, no exports; state `skipped` |
| 2 | — | track policies from `meeting.json` (or `MeetingInfo.inferred`), with `options.othersInRoom` overriding: a track is `diarized` if it is `system`, or the mode is `inPerson`, or others are in the room; otherwise `channel("mic:me", "Me")`; tracks without words are `skipped` | — |
| 3 | — | if a head run exists, was built from the current transcript, has applied edits, and `!force`: skip 4–7 with "Speaker labels were edited; relabel with --force (names carry over)". If the head was built from another transcript, relabel. | stages `skipped` |
| 4 | `render` | skip with "Not enough disk space to label speakers. Free some space, then use Label Speakers." when `stopReason == .diskLow` or `DiskPolicy.renderCheck` fails. Otherwise `TrackRenderer.render` each diarized track to `derived/<track>-16k.caf`, compressing long gaps (below) | failed → skip 5–7 |
| 5 | `diarize` | `nil` diarizer → `skipped`, "Speaker models are not installed. Install them from Setup, or run holos setup --speakers." Otherwise `diarizer.diarize` each rendered track, **one track at a time**, then map times to the session timeline with the render's time map. Speaker hint: `options.speakers`, else `meeting.json` `expectedSpeakers` n as `minimum: n − 1, maximum: n + 1` (or the form PR7c found best) | failed → skip 6–7 |
| 6 | `align` | `SpeakerRunBuilder.build` (PR5a, pure) → run (no embeddings) plus in-memory voice data. Under the speaker lock: `writeRun`; `writeHead`; `writeVoiceData` only with `forceVoiceData` (evaluation; never for normal meetings); append carry-over edits (§4.9) when the previous head had names, links, or rejections. Release the lock. | failed → skip 7 |
| 7 | `recognize` | PR10: when "Remember voices" is on and some profile has samples: `SpeakerRecognizer.recognize` on the in-memory centroids → `writeRecognition` (distances only) | failed → continue |
| 8 | `export` | `SessionExports.regenerate` (takes the speaker lock itself; stage 6 has released it) | failed → state `failed` |
| 9 | — | delete `derived/` whatever happened (unless `keepDerived`); write the final record; release the lease if `run` acquired it | — |

Final state: `succeeded` if every applicable stage succeeded; `partial` if export
succeeded but a speaker stage failed or was skipped because of existing edits or disk
space; `failed` if export failed. Expected skips (no diarized tracks, speaker models not
installed, "Remember voices" off) do not make the state `partial`, so a recording made
without speaker models still exits 0; the skip message is stored in the record, copied
to `RecorderExit.postprocessingMessage`, and shown in the app ("Saved Council meeting.
No speaker labels: speaker models are not installed. [Install…]"). An explicit
`holos session diarize` without verified models fails early (exit 1) with the setup
hint. `postprocess.json` writes are throttled to one per 250 ms plus every stage change.

**Render time map** (PR7b, in `TrackRenderer`). A meeting left paused for hours would
otherwise render hours of silence. Gaps longer than 60 s (including before the first
chunk) become 5 s of silence in the render. `RenderedTrack.timeMap` lists
`RenderSpan(renderStart, sessionStart, duration)` for the audio; `RenderTimeMap.map`
converts a `DiarizerOutput` back to session time: a time inside a span maps linearly, a
time inside inserted silence snaps to the nearest span edge, and a segment or window
that crosses inserted silence is split at the span edges with the silent part dropped.
Renders stay 16 kHz mono Int16; the diarizer reads them with `Int16CAFSampleSource`
(§4.8), never with a Float32 temporary copy.

Callers:

- `RecordingWorkflow.run` through `PostProcessHook` (§4.6): the CLI runs
  `MeetingPostProcessor` in the recorder process; the in-process app runs
  `holos session diarize --after-recording` in a child.
- `holos session diarize` (PR7b), `holos session recover` (PR3), `holos session import`
  (PR7c), and the app's Label Speakers, Find More Speakers, and automatic relabel
  (PR4, PR9) through `holos session diarize`.

### 4.8 SpeakerDiarizer, FluidDiarizer, FakeDiarizer

The protocol is in `SpeakerModels.swift` (§3.3). Implementations:

**`FakeDiarizer` (PR5a, `Sources/HolosSpeakers/FakeDiarizer.swift`)**, public so
HolosMeeting tests can use it:

```swift
public struct FakeDiarizer: SpeakerDiarizer {
    public var outputs: [String: DiarizerOutput]      // by track
    public var info: DiarizationEngineInfo
    public var error: HolosError?
    public init(outputs: [String: DiarizerOutput], info: DiarizationEngineInfo = .fake, error: HolosError? = nil)
    /// Throws `error` if set.
    public func engineInfo() async throws -> DiarizationEngineInfo
    /// Calls progress(0) then progress(1); returns outputs[request.track] or an empty output; throws `error` if set.
    public func diarize(_ request: DiarizationRequest,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput
    /// Speakers take turns of `turnSeconds` over [0, duration) in order; centroids are orthogonal
    /// unit vectors of `dimension`; one EmbeddingWindow per turn equal to its speaker's centroid.
    public static func alternating(speakers: [String], turnSeconds: Double, duration: Double,
                                   dimension: Int = 8) -> DiarizerOutput
}
extension DiarizationEngineInfo {
    /// engine "Fake", version "1", no models, embeddingModel ("fake", "1"), dimension 8.
    public static let fake: DiarizationEngineInfo
}
```

**`FluidDiarizer` (PR7a, `Sources/HolosDiarization/`).** Everything below comes from
spike S1: the FluidAudio 0.17.1 checkout (`5c51c5c9`) and runs on the three Otter
recordings plus a synthetic 3 h file ([speaker-evaluation.md](speaker-evaluation.md)).

FluidAudio API used, and nothing else:

| Purpose | FluidAudio 0.17.1 API |
|---|---|
| Load models, no network | `ModelHub.offlineMode = true`, then `OfflineDiarizerModels.load(from: directory, configuration: nil)` |
| Download (only in `holos setup --speakers`) | `ModelHub.offlineMode = false`, then `OfflineDiarizerModels.load(from: partialDirectory)`, which downloads the pinned revision into `<directory>/speaker-diarization/` |
| Manager | `OfflineDiarizerManager(config:)` and `initialize(models:)`; never `prepareModels`, whose failure path deletes the model folder and downloads again |
| Run | `process(audioSource:audioLoadingSeconds:progressCallback:)`; the callback reports `(chunksProcessed, totalChunks)` per 10 s window on an unspecified executor |
| Audio input | `protocol AudioSampleSource: Sendable { var sampleCount: Int { get }; func copySamples(into: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws }` |
| Config | `OfflineDiarizerConfig.default`; `exposeChunkEmbeddings`; `postProcessing.exclusiveSegments`; `clustering.threshold`; `withSpeakers(min:max:)`, `withSpeakers(exactly:)` |
| Result | `DiarizationResult { segments: [TimedSpeakerSegment], speakerDatabase: [String: [Float]]?, chunkEmbeddings: [ChunkEmbedding]?, timings: PipelineTimings? }` |
| Segment | `TimedSpeakerSegment { speakerId ("S1"…), embedding, startTimeSeconds: Float, endTimeSeconds: Float, qualityScore: Float }`; `embedding` is the cluster centroid, the same vector for every segment of a cluster |
| Window embedding | `ChunkEmbedding { speakerId, chunkIndex, speakerIndex, startTimeSeconds, endTimeSeconds, embedding256: [Float], rho128: [Double] }`, one per (10 s window, local speaker slot) |
| No speech | `OfflineDiarizationError.noSpeechDetected` → an empty `DiarizerOutput` |

```swift
public struct FluidDiarizerConfiguration: Sendable, Equatable {
    /// false keeps overlapping speech so alignment can mark overlap (FluidAudio default is true).
    public var exclusiveSegments: Bool
    /// nil uses FluidAudio's community-1 default (0.6, the best value S1 tried).
    public var clusteringThreshold: Double?
    public static let `default` = FluidDiarizerConfiguration(exclusiveSegments: false, clusteringThreshold: nil)
    /// Applies `PostProcessingOptions.engineOverrides` ("exclusiveSegments", "clusteringThreshold").
    public func overridden(by overrides: [String: String]) throws -> FluidDiarizerConfiguration
}

public actor FluidDiarizer: SpeakerDiarizer {
    public init(modelsDirectory: URL = FluidModels.defaultDirectory,
                configuration: FluidDiarizerConfiguration = .default)
    public func engineInfo() async throws -> DiarizationEngineInfo
    public func diarize(_ request: DiarizationRequest,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput
}

public struct PinnedFile: Sendable, Equatable {
    /// Relative to FluidModels.repoFolder(in:), e.g. "Embedding.mlmodelc/coremldata.bin".
    public let relativePath: String
    public let size: Int
    public let sha256: String
}

public enum ModelInstallStatus: Sendable, Equatable {
    case notInstalled
    case verified
    /// Files that are missing, the wrong size, or fail SHA-256; ".fluidaudio-revision" when the marker differs.
    case corrupt(files: [String])
}

public enum FluidModels {
    public static let repository = "FluidInference/speaker-diarization-coreml"
    /// The revision FluidAudio 0.17.1 pins for this repo (`Repo.diarizer.revision`).
    public static let revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    /// <supportRoot>/Models/speaker-diarization-coreml@df2625ac79a7; passed to FluidAudio as `directory:`.
    public static var defaultDirectory: URL { get }
    /// <directory>/speaker-diarization (FluidAudio's `Repo.diarizer.folderName`), where the files live.
    public static func repoFolder(in directory: URL) -> URL
    /// No network. Checks `.fluidaudio-revision` == revision and every pinned file's size and SHA-256.
    public static func status(directory: URL = defaultDirectory,
                              pinned: [PinnedFile] = PinnedModels.files) -> ModelInstallStatus
    /// Network. Downloads into "<directory>.partial-<UUID>", verifies against `pinned`, renames into place.
    /// Never leaves a partially verified directory at `directory`; deletes the partial folder on failure.
    public static func install(directory: URL = defaultDirectory, pinned: [PinnedFile] = PinnedModels.files,
                               progress: @escaping @Sendable (Double) -> Void) async throws
}
```

Adapter rules:

- **Memory and time: one pass per track, one track at a time.** S1 on this M4 Pro: 3 h
  in 35 s at 1.8 GB peak RSS (1.3 GB peak footprint); 89 min in 17 s at 0.95 GB. That
  is far under the plan's 4 GB trigger, so the block-wise fallback is not built
  (resolution R41). Running tracks one after another keeps the peak at one track's. A
  3 h call with both tracks diarized takes about 70 s plus rendering. CPU-only would be
  about 2.5× slower; compute units stay `.all` (FluidAudio keeps FBank on the CPU).
- **Configuration.** `OfflineDiarizerConfig.default` (clustering threshold 0.6, step
  ratio 0.2, minimum segment 1.0 s, Fa 0.07, Fb 0.8: the best of every setting S1 tried),
  then `exposeChunkEmbeddings = true` (S1: no change in output or memory),
  `postProcessing.exclusiveSegments = configuration.exclusiveSegments`, the speaker hint
  through `withSpeakers(min:max:)` or `withSpeakers(exactly:)`, and the threshold if set.
  S1 scored only `exclusiveSegments = true`. PR7c runs the Otter evaluation with both
  values; keep `false` (needed for overlap marking) unless joint-speech confusion rises
  by more than one percentage point on any recording, in which case the default becomes
  `true` and overlap marking is limited to what alignment infers.
- **Model files and cache.** The offline variant downloads, into
  `<defaultDirectory>/speaker-diarization/`: `Segmentation.mlmodelc`, `FBank.mlmodelc`,
  `Embedding.mlmodelc`, `PldaRho.mlmodelc` (folders), `plda-parameters.json`,
  `xvector-transform.json`, `config.json` (`{}`), `provenance.json`, and the
  `.fluidaudio-revision` marker; 21 MB. FluidAudio checks only presence and HTTP size,
  and in offline mode a marker that does not match the pinned revision makes the load
  throw `modelMissing`. First install took 11.2 s (download plus first Core ML load);
  loading from a fresh path 1.0 s; warm 0.15 s.
- **Loading.** `diarize` first calls `FluidModels.status`; anything but `.verified` throws
  `HolosError.unavailable("Speaker models are missing or damaged. Install them from Setup, or run holos setup --speakers.")`.
  `FluidDiarizer.init` sets `ModelHub.offlineMode = true`; only `FluidModels.install`,
  which runs in its own `holos setup --speakers` process, sets it to false. The actor
  caches the `Sendable` `OfflineDiarizerModels`; each `diarize` creates a local
  `OfflineDiarizerManager`, calls `initialize(models:)`, and runs inside a nonisolated
  async helper (§1.3).
- **Pinned checksums.** `Sources/HolosDiarization/PinnedModels.swift` lists
  `PinnedFile(relativePath, size, sha256)` for every downloaded file, relative to
  `repoFolder`. The 22 artifacts listed in the repo's `provenance.json` (which carries a
  SHA-256 per file; the S1 cache matches all 22) are pinned from it. `config.json` and
  `provenance.json` are not listed in `provenance.json`; pin their SHA-256 after checking
  them against the Hugging Face tree API at the pinned revision
  (`https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml/tree/df2625ac79a7ac6b65ad868fee6d80f320da4232?recursive=1`:
  `lfs.oid` is the SHA-256 of an LFS file; `oid` is the git blob SHA-1 of a small file).
  The PR7a implementer runs `HOLOS_RECORD_MODEL_MANIFEST=1 holos setup --speakers` (prints
  the manifest instead of verifying), checks each entry that way, and commits the list.
  `ModelTreeDigest` = SHA-256 over sorted lines `"<relativePath>\t<size>\t<sha256>\n"`;
  the run records one `ModelDescriptor` for the repo with that digest.
- **Audio source.** `Int16CAFSampleSource` implements `AudioSampleSource` over an mmap of
  the rendered CAF (data offset from `AudioFileGetProperty(kAudioFilePropertyDataOffset)`;
  requires 16 kHz, mono, 16-bit little-endian) and converts to Float in `copySamples`.
  The mmap wrapper is `@unchecked Sendable` with its invariant stated. There is no
  `process(url)` fallback: it would add a ~690 MB Float32 temporary copy for 3 h on a
  nearly full disk.
- **Mapping.** `TimedSpeakerSegment` → `RawDiarizationSegment(speaker: speakerId,
  start:, end:, quality: qualityScore)`; `speakerDatabase` → `centroids` (raw WeSpeaker
  256-d space, not PLDA space, so cosine comparison is meaningful); `chunkEmbeddings` →
  `windows` (`embedding256`); `timings.totalProcessingSeconds` → `processingSeconds`.
  These vectors stay in memory; only the post-processor decides whether any are
  persisted (§4.10).
- **engineInfo():** engine `FluidAudio.OfflineDiarizerManager`, version `0.17.1`, one
  `ModelDescriptor(id: FluidModels.repository, revision:, sha256: <tree digest>)`,
  `embeddingModel = EmbeddingModelID(id: "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
  revision: FluidModels.revision)`, dimension 256, flattened configuration.
- **Accuracy to expect.** Joint-speech confusion against Otter was 1.4–5.2 % on the real
  recordings and 11.2 % on the synthetic 3 h file. Speaker counts are approximate: on
  the 89-minute recording FluidAudio found 6 of 8 people with at least 30 s of speech,
  merging quieter or briefer speakers into others. The review window's New Speaker,
  split, and Find More Speakers tools matter more than merge (PR9).
- **License and credits.** PR7a writes `THIRD_PARTY_NOTICES.md` at the repo root:
  1. FluidAudio 0.17.1 (`https://github.com/FluidInference/FluidAudio`, tag v0.17.1,
     commit `5c51c5c9`): Apache License 2.0, with the full text of the checkout's
     `LICENSE`, and every file in its `ThirdPartyLicenses/` folder verbatim (VBx port,
     Apache 2.0; fastcluster, BSD-2-clause style; NemoTextProcessing binary v0.3.1,
     Apache 2.0; and the text-frontend notices that ship in the same module).
  2. The speaker diarization models, with this text:

     > Speaker labels use `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`,
     > `PldaRho.mlmodelc`, `plda-parameters.json`, and `xvector-transform.json` from
     > https://huggingface.co/FluidInference/speaker-diarization-coreml (revision
     > df2625ac79a7ac6b65ad868fee6d80f320da4232), downloaded by `holos setup --speakers`
     > and not included in the app. They are licensed under the Creative Commons
     > Attribution 4.0 International License (CC BY 4.0,
     > https://creativecommons.org/licenses/by/4.0/). They are modified Core ML conversions,
     > made by Fluid Inference, of the pyannote Community-1 speaker diarization pipeline
     > (pyannote, CC BY 4.0), which uses WeSpeaker speaker embeddings and PLDA parameters
     > licensed by BUT Speech@FIT under CC BY 4.0. The model card describes the
     > segmentation and embedding conversions as historically reconstructed, not
     > build-attested.
     >
     > Citations:
     > - Alexis Plaquet and Hervé Bredin. "Powerset multi-class cross entropy loss for
     >   neural speaker diarization." Proc. INTERSPEECH 2023.
     > - Hongji Wang, Chengdong Liang, Shuai Wang, Zhengyang Chen, Binbin Zhang, Xu Xiang,
     >   Yanlei Deng, and Yanmin Qian. "Wespeaker: A research and production oriented
     >   speaker embedding learning toolkit." ICASSP 2023.
     > - Federico Landini, Ján Profant, Mireia Diez, and Lukáš Burget. "Bayesian HMM
     >   clustering of x-vector sequences (VBx) in speaker diarization: theory,
     >   implementation and analysis on standard tasks." Computer Speech & Language, 2022.

  `holos setup --speakers` prints one credits line after installing ("Speaker models by
  Fluid Inference (pyannote, WeSpeaker, BUT Speech@FIT), CC BY 4.0; see
  THIRD_PARTY_NOTICES.md."). PR4's About panel embeds the model text above and the
  FluidAudio line as a string constant (the app has no resource bundle).

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
   `channelAssumption`; else `diarizer`.

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
  one profile is allowed (it yields a merge suggestion).
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
        /// rename / linkProfile / rejectProfile actions on the new run's speakers.
        public var actions: [SpeakerEditAction]
        /// Old speakers with a name, link, or rejection that matched nothing (IDs only).
        public var unmatchedSpeakers: [String]
        /// Turn-level edits (reassign, split, new speaker, exclude) that are not carried.
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
ID. User-created speakers carry by time like any other.

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
    /// Off by default. Governs voice samples, per-session voice data, and recognition. Never names.
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
  empty database (`rememberVoices: false`) when the file is missing.
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
  `profiles.lock` (`withLockedDatabase`, the §1.7 order), so every store change (a
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
  `holos speakers embed <session> --track <t> --turns <id,id,…> --json`, which prints the
  turn embeddings as JSON on stdout (a pipe, never a file) and writes nothing.
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
  at the start of every `holos people`, `speakers`, and `session` command and finishes any
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
  coordinate. §1.7 is not the reason: it excludes a hostile process running as the user,
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
  turns → no sample. Only the confirmed speaker's turns are ever sent to the extractor.
- **`VoiceProfileService`** (HolosMeeting, PR10) is the only code that writes profiles
  and samples:
  - `link(session:speakerID:to:view:learnVoice:extractor:store:)` (async) where `to` is an existing
    profile or a new name: creates or links the profile, appends `linkProfile` and
    `rename(name: profile.displayName)` in one batch (so the session keeps the name if
    the profile is later forgotten), and, if `learnVoice` and "Remember voices" is on
    and the session's audio exists, extracts and upserts the sample for
    `(profile, session)` through `VoiceSampleExtractor`. Samples come only
    from this call, never from automatic matches (decision 2).
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
    the lock, then takes the speaker lock, then `profiles.lock` (the §1.7 order), re-reads
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
    rewrite each affected voice file under that session's speaker lock (§1.7 rule 2).
- **Export.** `holos people export` writes names and sample metadata; embeddings only
  with `--include-voiceprints`, which prints a warning to stderr (decision 2 includes
  export). Session exports never contain vectors (§4.11).

### 4.11 Exports

`TranscriptExporter` (PR5c, pure) renders an `ExportDocument`; `SessionExports` (PR7b)
loads session files into one and writes `exports/`. v1 formats are Markdown, plain text,
and JSON.

```swift
public struct ExportMetadata: Sendable, Equatable {
    public var sessionID: String
    public var name: String
    public var createdAt: Date
    public var durationSeconds: Double           // max chunk end over tracks
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    public var timeZone: TimeZone                // for the header's local start time; tests pass UTC
}

public struct ExportDocument: Sendable, Equatable {
    public var metadata: ExportMetadata
    public var transcript: Transcript
    public var run: DiarizationRun?
    public var projection: SpeakerProjection?    // nil → one pseudo-turn per segment named by track
    public var gaps: [TimelineGap]
    public var markers: [TimelineMarker]
}

public enum ExportFormat: String, CaseIterable, Sendable { case md, json, txt }

public struct ExportBlock: Sendable, Equatable {
    public var speakerLabel: String
    public var start: Double
    public var turnIDs: [String]
    public var text: String
    public var overlapWith: [String]             // labels
}

public enum TranscriptExporter {
    public static func render(_ document: ExportDocument, format: ExportFormat) throws -> Data
    /// Turn text: from the first word's UTF-16 offset (or 0 for the segment's first word) to the next
    /// word's offset (or the end of the segment text), per span, joined with " ", trimmed.
    public static func text(of spans: [WordSpan], in transcript: Transcript) -> String
    /// Markdown and text blocks: consecutive turns of the same speaker are merged unless a gap, a marker,
    /// or more than 30 s of silence separates them.
    public static func blocks(_ document: ExportDocument) -> [ExportBlock]
}
```

Common rules: turns in `(start, track)` order; the speaker shown is `label` ("Jim",
"Jim (auto)", "Speaker 3", "Me"); unknown → "Unknown speaker"; without a projection,
names are "Microphone" and "System audio". Suggestions never appear in exports.
Timestamps are `HH:MM:SS` in Markdown.

- **Markdown** (`transcript.md`):

  ```
  # Council meeting

  - Date: 2026-09-23
  - Started: 14:00
  - Duration: 2:58:12
  - Participants: Jim (41:12), Speaker 2 (22:03), Me (15:40)

  **Jim** · 00:12:03

  We should move the vote to next week. The treasurer's report is ready.

  **Speaker 2** · 00:12:40 · overlapping with Jim

  Agreed, but …

  _[Recording paused 00:45:10–00:47:02]_

  _[Marker 01:02:03: Budget vote]_
  ```

  Gap lines by reason: paused "Recording paused", sleep "No audio: computer was asleep",
  deviceChanged/captureRestarted "Audio restarted", audioUnavailable "No audio:
  microphone unavailable", overflow and audioGap "Audio gap". A marker without a label
  prints `_[Marker 01:02:03]_`. Participants are sorted by talk time, descending.
- **Text** (`transcript.txt`): one block per `ExportBlock`: `"<label>  <time>"` (two
  spaces; `mm:ss` below one hour, e.g. `01:05`, and `h:mm:ss` from one hour, e.g.
  `1:02:05`), the text on one line, a blank line. No gap or marker lines and no footer,
  so `OtterTranscriptParser` and the evaluator's header regex (hours may have any number of digits)
  `^\s*\S.*\s{2,}(?:\d+:\d{2}:\d{2}|\d{1,2}:\d{2})\s*$` read it. It replaces the speaker-less
  text `saveTranscript` wrote before (R23).
- **JSON** (`transcript.json`, format `holos-transcript`, `schemaVersion` 1), per turn,
  with no vectors of any kind:

  ```json
  {
    "schemaVersion": 1, "format": "holos-transcript",
    "session": {"id": "…", "name": "…", "createdAt": "…", "durationSeconds": 10692.4,
                "source": "mic+system", "locale": "en-CA", "backend": "speech"},
    "transcriptID": "…", "runID": "…",
    "engine": { DiarizationEngineInfo }, "alignment": { AlignmentInfo },
    "speakers": [{"id": "system:S1", "ordinal": 2, "name": "Jim", "label": "Jim",
                  "provenance": {"userConfirmed": {}}, "automatic": false, "profileID": "…",
                  "talkSeconds": 2472.3, "turnCount": 88}],
    "turns": [{"id": "T1", "speakerID": "system:S1", "track": "system", "start": 12.1, "end": 18.7,
               "text": "…", "overlap": false, "otherSpeakers": [], "score": 0.97,
               "timing": "measured", "words": [{"segmentID": "…", "first": 0, "end": 17}]}],
    "gaps": [ TimelineGap ], "markers": [ TimelineMarker ],
    "edits": {"applied": 5, "stale": 0, "otherRuns": 0}
  }
  ```

  `otherSpeakers` maps `otherClusters` to current speaker IDs. `engine`, `alignment`,
  `runID` are `null` without a run.

**Generated files are protected, not overwritten.** `exports/` is a generated cache.
`SessionExports.regenerate` writes each file with mode 0400 and records its SHA-256 in
`exports/.generated.json`. Before writing, if a file on disk no longer matches its
recorded digest (someone edited it), it moves that file to
`exports/edited-<YYYYMMDD-HHMMSS>.<ext>` (0600) and returns it in `movedAside`; the
review window's status line and `holos session export --all` say so. The app's "Open
Transcript" shows a Quick Look preview; "Save Transcript As…" (NSSavePanel, default
`~/Documents/<meeting name>.md`, or `.txt`) makes the editable copy.

```swift
public enum SessionExports {
    /// Takes the speaker lock, loads the snapshot, writes exports/transcript.{md,json,txt}, releases the lock.
    @discardableResult
    public static func regenerate(session: URL, profileNames: [String: String] = [:]) throws -> ExportWriteResult
    /// Caller holds the speaker lock.
    @discardableResult
    public static func regenerateLocked(session: URL, profileNames: [String: String] = [:]) throws -> ExportWriteResult
    /// One format, not written anywhere.
    public static func render(_ format: ExportFormat, session: URL,
                              profileNames: [String: String] = [:]) throws -> Data
}
public struct ExportWriteResult: Sendable, Equatable {
    public var written: [URL]
    public var movedAside: [URL]
}
```

### 4.12 Dictation pause, microphone selection, vocabulary

**Dictation pause (decision 6, PR4).** `MeetingController.dictationShouldPause` is true
while the observed meeting's phase `isMeetingActive` (starting, recording, paused,
waiting, sleeping, stopping, unknown) or the controller is in `starting`.
`HolosAppDelegate` reacts:

- On pause: cancel any running utterance (`controller.cancel()`), stop the hotkey monitor
  (Right Option goes back to other apps), and keep the persisted `dictationEnabled`
  flag. The whole dictation block of the menu (status line, enable toggle, shortcut
  submenu, Copy/Discard, Correct Last Dictation) is replaced by one disabled line,
  "Dictation paused during meeting recording". This message takes precedence over every
  other dictation message.
- `handle(.began)`, `enable()`, and `changeShortcut` return early while paused.
- `suspendForSessionChange` also sets a `suspendedBySleep` flag (in memory) alongside
  what it does today.
- On resume (capture stopped: phase transcribing or later, or the recorder died): call
  `enable()` only if `dictationEnabled` is persisted and `suspendedBySleep` is false;
  otherwise show today's "Paused after sleep/session change — enable from the menu to
  resume".
- This applies to every live meeting the app sees, including one started from a
  terminal after launch (the idle rescan, §4.1; resolution R16). No dictation markers are
  written anywhere.

**Microphone selection (decision 9, PR2b).** `MicrophoneSelection { systemDefault,
builtIn }`:

- In-person (`--source mic`) records the built-in microphone. `BuiltInMicrophone.find()`
  (HolosAudio) returns the CoreAudio device whose transport type is
  `kAudioDeviceTransportTypeBuiltIn` and that has input streams. AVAudioEngine capture
  sets `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit` before
  reading the input format, and re-pins on every restart, so connecting AirPods does
  not move the recording.
- Online call (`--source mic+system`) records the **system default input**, the same
  device the call app uses (a headset records "Me" close up; the laptop microphone
  would pick up the room). ScreenCaptureKit captures it with `captureMicrophone = true`
  and no `microphoneCaptureDeviceID`, as `AudioCapture` does today. A default-device
  change is a configuration change: restart on the new default with a `deviceChanged`
  gap. With no input device at all, the call is recorded without the microphone (§4.2).
- The start panel shows the device as a static label: "Microphone: Built-in Microphone"
  (in person; red and Start disabled when missing: "The built-in microphone is
  unavailable. Open the lid and try again.") or "Microphone: AirPods Pro (system
  default)" (call). No device picker anywhere. `status.json` carries `microphoneName`.
- In person, if the built-in microphone disappears mid-recording (lid closed with an
  external display), the recorder enters `waiting` with "The built-in microphone is off.
  Open the lid to continue recording." and resumes on lid open.
- Dictation keeps the system default input (unchanged).
- Test seam: `findInputDevices: @Sendable () -> InputDevices` (`builtIn` and
  `systemDefault`, each `Device?`) in `RecordingDependencies` and
  `MeetingController.init`.

**Vocabulary (PR1 seam, PR2a recorder, PR4 app).** Meeting transcription gets the same
contextual strings dictation uses, so council members' names and strata terms are
recognized. `LiveSpeechFactory` takes `contextualStrings`; `RecordingOptions.vocabulary`
carries them; `TrackReplayer.replay`, `TranscriptRebuilder.rebuild`, and
`SessionImporter.importAudio` take them too. The app builds the list from
`CorrectionList.vocabulary` (PR4) plus known people's names (PR10), at most 1,000
entries of at most 100 characters, writes it 0600 to
`$TMPDIR/holos-vocabulary-<id>.json`, and passes `--vocabulary-file`. The recorder copies
it to `vocabulary.json` before its first `status.json` write and deletes the temporary file;
replay, rebuild, and import read `vocabulary.json`. Because the temporary file holds private
names and correction terms, the app side owns cleanup too: `MeetingController` deletes it
on `launchFailed`, when the child exits for any reason, and as soon as the first
`status.json` for that session appears (the recorder has copied it by then). On launch the
app also removes any `$TMPDIR/holos-vocabulary-*.json` older than one hour. A hand-off
file is removed by moving it into a new 0700 folder `.holos-remove-<device>.<inode>.<UUID>`
beside it and unlinking it there (`AtomicFile.readAndRemove`, `removeRegularFile`), so a
file renamed onto its name meanwhile is never deleted. If the process ends, or the unlink
fails, after the move, the same launch sweep finishes it: in each such folder older than
five minutes that is a real folder owned by this user with mode 0700, it removes `file`
only if it is the regular file the folder's name records (same device and inode), then the
folder if empty; anything else stays. Tests (PR4):
`vocabularyFileRemovedOnLaunchFailure` (spawn fails), `vocabularyFileRemovedOnEarlyExit`
(child exits before any status), `staleVocabularyFilesSwept`,
`strandedRemovalFolderIsFinishedBySweep`, `strandedRemovalSweepRemovesOnlyTheRecordedFile`.

### 4.13 Retention and deletion

Nothing expired meetings before; a 3 h call is about 2 GB even with mono system audio.

- **Storage (PR3, `Sources/HolosStorage/SessionDeletion.swift`).**
  `SessionDeletion.deleteAudio(session:lease:)` requires the lease and no writer, removes
  `audio/`, `derived/`, and `speakers/voice/`, and writes `audio-deleted.json`
  `{schemaVersion, sessionID, deletedAt, chunkCount, seconds}` (`sessionID` optional:
  markers written before it are accepted). The marker is decoded wherever it is read
  (`AudioDeletedRecord.read`/`isDeleted`): one from a newer Holos is refused; a damaged one,
  or another session's, does not count as deleted audio, and Delete Audio replaces it.
  Transcript, runs, edits, and exports
  stay. `SessionDeletion.moveToTrash(session:lease:)` moves the folder to the Trash
  (`FileManager.trashItem`) and deletes `~/Library/Logs/Holos/recorder-<id>.log`.
  Both hold the writer lock (retry 1 s; held means a recorder is running, so they refuse)
  for the whole deletion rather than probing it, because `SessionArchive.open(at:)` does
  not consult the lease; `moveToTrash` also holds the speaker lock from the voice data
  through the trash, so a speaker edit or export regeneration never runs in a folder being
  moved. Lock order: processing → writer → speakers.
  Every delete inside a session folder (these, PR7b's `derived/`, `current.pending`,
  `deleteVoiceData`) goes through `AtomicFile.removeTree(_:in:)` (PR6), never
  `FileManager.removeItem`: it opens each folder on the way with `O_NOFOLLOW`, so a
  symbolic link in place of `speakers/`, `audio/`, `derived/`, or `exports/` is refused
  instead of leading the delete outside the session, and links inside the tree are removed,
  not followed.
- **CLI (PR3).** `holos session delete <path> [--audio-only] --yes`.
- **Catalog (PR3).** `SessionSummary` reports `bytes`, `derivedBytes`, `audioDeleted`.
- **UI (PR4).** Meetings window buttons "Delete Audio (Keep Transcript)…" and "Delete
  Meeting…", a "Clean Up" for leftover `derived/` renders, and a footer "Meetings use
  12.4 GB · 21.3 GB free". The Delete Meeting alert says "Voice samples learned from
  this meeting stay until you forget them in People."; PR9 adds the checkbox "Also
  forget voice samples learned from this meeting" (`VoiceProfileService.forget(sessionID:)`).
  Review disables playback when audio was deleted.
- **Redaction is reserved, not built.** `GapReason.redacted` exists so a later
  `holos session redact --from --until` can mark removed audio without a contract
  change. That command must scrub: the audio chunks (zero the samples and re-hash through
  `openForMaintenance`), `transcriptFinalized` text and words in `events.jsonl`, every
  `transcripts/*.json` revision (write a new one without those words), the head run (a
  new run, names carried over), `exports/`, and `status.json` `lastPhrase`. Until then,
  the remedy for an unpaused in-camera item is Delete Meeting (open question Q7).

## 5. PRs

Each section lists: goal, files, API, formats/CLI/UI, tests (name: input → expected),
acceptance, and what the PR must not touch. "Add" means a new file; "Change" means an
existing file. Signatures are the contract; bodies are the implementer's. When the
compiler demands a small annotation change (for example `Sendable` on a protocol),
make it without changing names or shapes and say so in the PR description. Every PR
description ends with a "Docs note" paragraph for the PR that writes the wave's
`README.md` and `docs/status.md` updates (§6).

### 5.1 PR6: Contracts and storage foundations (wave 0)

**Goal.** Put in place everything the later PRs share: the three contract files, atomic
writes, session paths, locks and the processing lease, free space, speaker storage in
the session, and the `SessionArchive` fixes the review found (torn appends, corrupt
journal lines, a transcript pointer, maintenance opens under a lease).

**Files.**

- Add `Sources/HolosCore/HolosJSON.swift`, `MeetingModels.swift`, `SpeakerModels.swift`
  (§3, byte-identical), and `Sources/HolosCore/SupportPaths.swift`
  (`extension HolosPaths { public static var supportRoot: URL }`: `$HOLOS_SUPPORT_DIR`
  if set and non-empty, else `applicationSupport`).
- Add `Sources/HolosStorage/AtomicFile.swift` (§1.7), `SessionPaths.swift` (§2.1),
  `SessionLocks.swift` (`ProcessingLease`, lease, speaker lock, retry helper),
  `SessionSpeakerStore.swift`, `FreeSpace.swift` (`FreeSpaceProvider`,
  `VolumeFreeSpace`, `FixedFreeSpace` for tests), `TranscriptPointer.swift`.
- Change `Sources/HolosStorage/SessionArchive.swift`:
  - `create(root:name:source:locale:backend:id:)` with `id: String? = nil` (must be a
    UUID string; refuses an existing folder).
  - The writer lock is acquired with the 1 s retry (§1.7 rule 3), fd `O_CLOEXEC` (already).
  - `append` goes through `AtomicFile.append`, so a failed append truncates back and
    `nextSequence` is unchanged.
  - `setJournalSync(_ mode: JournalSync)` with `JournalSync { case everyEvent,
    interval(seconds: Double) }` (default `everyEvent`); with `interval`, events are
    written at once and fsync'd at most once per interval, at `finish`, and at once for
    `captureStopped`, `archiveRecovered`, `transcriptRebuilt`.
  - `public nonisolated static func readEvents(at:) throws -> EventJournal` with
    `EventJournal {events, tornTail, unreadableLines}`: reads only `events.jsonl`, no
    chunk hashing; a complete line that fails to decode is skipped and counted.
    `inspectRecovery` and `open` use the same tolerant reader (they no longer fail on a
    corrupt middle line; `RecoveryReport` gains `unreadableEventLines`).
  - `saveTranscript(_:writeLegacyExports: Bool = true)`: after writing the revision,
    rewrites `transcripts/current.json`; `public nonisolated static func
    currentTranscriptID(at:) throws -> String?` (§2.4).
  - `openForMaintenance(at:lease:)`, `recover(at:lease:)` (§1.7); `recover(at:)` keeps
    its signature and takes a lease itself, so it refuses while another process holds
    one.
  - `inspectRecovery` treats missing chunks as expected when `audio-deleted.json`
    exists.
- Change `scripts/test.sh`: export `HOLOS_DATA_DIR` and `HOLOS_SUPPORT_DIR` to a fresh
  `mktemp -d` folder unless already set; remove it on exit.
- Tests: `Tests/HolosCoreTests/ContractCodingTests.swift`;
  `Tests/HolosStorageTests/{AtomicFileTests, SessionLocksTests, SessionSpeakerStoreTests, TranscriptPointerTests}.swift`;
  cases added to `SessionArchiveTests.swift`.
- Docs: `docs/status.md` and `README.md` (PR6 is alone in wave 0).

**API.**

```swift
public struct EditJournal: Sendable, Equatable {
    public var edits: [SpeakerEdit]
    /// The file does not end with "\n"; the partial line was skipped.
    public var tornTail: Bool
    /// Complete lines skipped because they are corrupt or have a newer schemaVersion.
    public var unreadableLines: Int
}

/// Reads are lock-free (files are replaced atomically; the journal only grows).
/// Writes must run inside `SessionArchive.withSpeakerLock(at:)`.
public enum SessionSpeakerStore {
    public static func writeRun(_ run: DiarizationRun, session: URL) throws        // AtomicFile.create; creates speakers/runs lazily (0700)
    public static func readRun(id: String, session: URL) throws -> DiarizationRun
    public static func runIDs(session: URL) throws -> [String]                     // sorted
    public static func readHead(session: URL) throws -> SpeakerHead?
    public static func writeHead(_ head: SpeakerHead, session: URL) throws         // refuses a runID with no run file
    public static func readEdits(session: URL) throws -> EditJournal               // missing file → empty
    /// Repairs a torn tail first (copies the file to speakers/edits.torn-<UUID>.jsonl, truncates to the last
    /// newline), then appends all lines in one write and fsyncs.
    public static func appendEdits(_ edits: [SpeakerEdit], session: URL) throws
    public static func readRecognition(runID: String, session: URL) throws -> RecognitionResult?
    public static func writeRecognition(_ result: RecognitionResult, session: URL) throws   // replaces
    public static func readVoiceData(runID: String, session: URL) throws -> SessionVoiceData?
    /// Replaces; creates speakers/voice (0700) with isExcludedFromBackup = true.
    public static func writeVoiceData(_ data: SessionVoiceData, session: URL) throws
    public static func deleteVoiceData(session: URL) throws                        // removes speakers/voice/
}

public protocol FreeSpaceProvider: Sendable { func availableBytes(at url: URL) throws -> Int64 }
public struct VolumeFreeSpace: FreeSpaceProvider { public init() }           // statfs f_bavail × f_bsize
public struct FixedFreeSpace: FreeSpaceProvider { public init(_ bytes: Int64) }  // tests

/// Contents of transcripts/current.json.
public struct TranscriptPointer: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var transcriptID: String
    public var updatedAt: Date
}
```

Refuse (`HolosError.invalidInput`) run IDs and edit IDs that fail `validToken`, and runs
or voice data whose `sessionID` differs from the folder's manifest ID.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `openCodesDecodeUnknownValues` | `"minutes"` as `PostProcessingStage`, `"x"` as `StopReason` | decode; compare unequal to every constant; re-encode as the same string |
| `unknownPhaseIsActive` | `"fancyNew"` as `RecorderPhase` | `.unknown`; `isMeetingActive` |
| `floatVectorRoundTripsBitExactly` | [1, −0.0, NaN, 3.5] | bit patterns equal after encode/decode |
| `floatVectorRejectsBadBase64` | `"abc"` | `DecodingError` |
| `contractExamplesRoundTrip` | each §3.4 example | decodes; re-encoding gives the same bytes |
| `runRoundTripsAndRefusesOverwrite` | write run R twice | first ok; second throws; file mode 0600, folder 0700 |
| `headRefusesUnknownRun` | writeHead for a missing run | throws |
| `editsAppendAndReadInOrder` | append [e1], then [e2, e3] | read e1, e2, e3; tornTail false |
| `tornTailIsReportedThenRepairedOnAppend` | file ends mid-line; read; append e4 | read reports torn; after append a backup exists and the earlier lines plus e4 read cleanly |
| `newerSchemaLineIsSkippedAndCounted` | a line with schemaVersion 2 | skipped; unreadableLines 1 |
| `voiceDataIsPrivateAndNotBackedUp` | write voice data | file 0600, folder 0700, `isExcludedFromBackup` true; `deleteVoiceData` removes the folder |
| `speakerLockTimesOutForSecondHolder` | hold the lock; second call with timeout 0.1 s | throws `unavailable`; succeeds after release |
| `processingLeaseIsExclusive` | two acquisitions | second throws after the retry; `isProcessing` true; false after `release()` |
| `leaseAcquisitionSurvivesAProbe` | another descriptor holds LOCK_EX for 200 ms while `acquireProcessingLease` runs | acquisition succeeds |
| `leaseReleasedOnDeinit` | lease goes out of scope | `isProcessing` false |
| `lockDescriptorsAreCloseOnExec` | lease, speaker lock, writer lock | `fcntl(F_GETFD)` has `FD_CLOEXEC` |
| `failedAppendLeavesNoPartialLine` | internal write hook fails after 10 bytes (`@testable import`) | throws; file size unchanged; the next event appends and parses; sequence not skipped |
| `corruptMiddleEventLineIsSkippedAndCounted` | events.jsonl with a garbage line between two good ones | `readEvents` returns 2, `unreadableLines` 1; `inspectRecovery` and `open` succeed |
| `groupCommitKeepsEveryEvent` | `setJournalSync(.interval(seconds: 1))`; record 3 events; finish | 3 lines, all parse |
| `transcriptPointerFollowsLatestSave` | save A then B within one second | `currentTranscriptID` == B |
| `legacyArchiveWithoutPointer` | one transcript, no pointer | that transcript's ID |
| `saveTranscriptCanSkipLegacyExports` | `writeLegacyExports: false` | no files in `exports/` |
| `maintenanceOpenNeedsMatchingLease` | lease of another session; then the right lease | first throws `invalidInput`; second opens; writer lock released by `finish` |
| `maintenanceOpenRepairsTornTail` | journal ends mid-line | backup file exists; new events parse |
| `recoverRefusedWhileLeaseHeldElsewhere` | another descriptor holds the lease; `recover(at:)` | throws; archive unchanged |
| `oldArchiveInspectsClean` | archive without speakers/derived/status files | `needsAttention == false` |
| `newFoldersDoNotAffectIntegrity` | add speakers/, derived/x.caf, status.json, control/, transcripts/current.json | `needsAttention == false` |
| `deletedAudioIsExpected` | remove audio/, write audio-deleted.json | `needsAttention == false` |
| `createWithExplicitID` | `create(id: UUID)` | folder `<id>.holos`; manifest id matches |
| `createRefusesExistingOrInvalidID` | same id twice; id "../x" | throws |
| `readEventsSkipsHashing` | archive with a corrupt chunk | `readEvents` succeeds and returns the events |
| `atomicCreateRefusesExisting` / `atomicWriteLeavesNoTemporaryFiles` / `atomicWriteHonoursPermissions` | — | as named (0400 file readable, not writable) |
| `supportRootHonoursEnvironment` | `HOLOS_SUPPORT_DIR` set in a child process environment | `supportRoot` equals it |

**Acceptance.** `shasum -a 256` of the three contract files matches §3.0; `swift build`
and `./scripts/test.sh` pass; the suite writes nothing under the real
`~/Library/Application Support/Holos`.

**Does not touch.** HolosAudio, HolosSpeech, HolosDictation, HolosDesktop, HolosApp,
HolosCLI, `Models.swift`, `Package.swift`.

### 5.2 PR1: Extract HolosMeeting (wave 1)

**Goal.** Move recording out of `HolosCLI` into a library the app can also use, with
seams for capture, speech (with vocabulary), stop signals, console output, and the
post-processing hand-off. No user-visible behaviour change (the only new CLI surface is
`--no-postprocess`, which has nothing to skip yet).

**Files.**

- Add `Sources/HolosMeeting/`:
  - `RecordingWorkflow.swift`: moved from `Sources/HolosCLI/RecordingWorkflow.swift`, made public (API below).
  - `LiveTrack.swift`: moved, internal.
  - `TrackReplayer.swift`: the moved `replay`, public, with `from:` and `contextualStrings:`.
  - `StopSources.swift`: `RecorderStopSource`, `SignalStopController` (today's `StopController`), `ManualStopSource`.
  - `MeetingCapture.swift`: `CaptureRequest`, `MeetingCapture`, `LiveMeetingCapture`.
  - `LiveSpeechSession.swift`: protocol plus `extension AppleSpeechSession: LiveSpeechSession {}`.
  - `RecordingReporter.swift`.
  - `MeetingPostProcessor.swift`: `PostProcessingOptions`, `PostProcessHook`, and the
    skeleton (§4.7: final initializer and `run(session:lease:progress:)`, returning a
    `.skipped` record and writing nothing).
  - `LockedValue.swift`: the internal `LockedValue` helper, moved.
- Add `Sources/HolosCLI/ConsoleReporter.swift`, `Sources/HolosCLI/PostProcessing.swift`:
  `func makeMeetingPostProcessor(options: PostProcessingOptions = .init()) -> MeetingPostProcessor`
  (PR1 returns `MeetingPostProcessor(options: options)`) and
  `func makePostProcessHook(options: PostProcessingOptions) -> PostProcessHook` (calls it,
  turning a thrown error into a `.failed` record).
- Delete `Sources/HolosCLI/RecordingWorkflow.swift`.
- Change `Sources/HolosCLI/Record.swift` (Start calls the new API; adds
  `--no-postprocess`), `Sources/HolosCLI/Session.swift` (Retranscribe calls
  `TrackReplayer`; `subcommands:` written one per line), `Sources/HolosCLI/Holos.swift`
  (`subcommands:` one per line), `Package.swift` (§1.2 wave 1), `docs/contracts.md`
  (ownership table: `HolosMeeting` replaces `HolosWorkflows`, add `HolosSpeakers` and
  `HolosDiarization`; the "local app/session control" paragraph points to
  meeting-design §4.1).
- Add `Tests/HolosMeetingTests/RecordingWorkflowTests.swift`, `Tests/HolosMeetingTests/Fakes.swift`.
- Docs: PR1 merges last in wave 1 and writes the wave-1 `README.md` and
  `docs/status.md` notes for PR1 and PR5a–c.

**API.**

```swift
public struct CaptureRequest: Sendable, Equatable {
    public var source: AudioSource
    public var applicationBundleID: String?
    /// Session time of this epoch's first frame (§2.3). PR1 always passes 0; PR2a uses it.
    public var timelineOffset: Double
    public init(source: AudioSource, applicationBundleID: String? = nil, timelineOffset: Double = 0)
}

/// One capture epoch. `frames` is single-use: it finishes after `stop()` or throws on failure.
@MainActor public protocol MeetingCapture: AnyObject {
    nonisolated var frames: AsyncThrowingStream<CapturedAudio, Error> { get }
    var hostTimeOrigin: Double { get }
    func start(_ request: CaptureRequest) async throws
    func stop() async throws
}

/// Wraps `AudioCapture`. PR1 ignores `timelineOffset` (always 0); PR2a passes it through.
@MainActor public final class LiveMeetingCapture: MeetingCapture {
    public init(bufferCapacity: Int = 4096)
}

public protocol LiveSpeechSession: Sendable {
    func append(_ frame: PCMFrame) async throws
    func finish() async throws -> [TranscriptSegment]
    func cancel() async
}

public protocol RecordingReporter: Sendable {
    /// A finalized phrase. The CLI prints it (PR2a: unless --no-live-text).
    func phrase(_ segment: TranscriptSegment, track: String)
    /// A progress or warning line (stderr in the CLI).
    func message(_ text: String)
}

public protocol RecorderStopSource: Sendable {
    var shouldStop: Bool { get }
    /// Called once audio is durable, so a second signal ends processing immediately.
    func restoreDefaultHandlers()
}
public final class SignalStopController: RecorderStopSource { public init() }   // SIGINT, SIGTERM
public final class ManualStopSource: RecorderStopSource {                        // tests; in-process app
    public init()
    public func requestStop()
}

public struct RecordingOptions: Sendable, Equatable {
    public var name: String
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    public var root: URL
    public var duration: Double?
    public var recordOnly: Bool
    public var applicationBundleID: String?
    /// Contextual strings for every speech session of this recording (§4.12).
    public var vocabulary: [String]
    public init(name: String, source: AudioSource, locale: String, backend: SpeechBackend, root: URL,
                duration: Double? = nil, recordOnly: Bool = false, applicationBundleID: String? = nil,
                vocabulary: [String] = [])
}

public typealias LiveSpeechFactory = @Sendable (_ locale: String, _ backend: SpeechBackend,
    _ contextualStrings: [String],
    _ onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) async throws -> any LiveSpeechSession

public struct RecordingDependencies: Sendable {
    public var makeCapture: @MainActor @Sendable () -> any MeetingCapture
    public var makeSpeech: LiveSpeechFactory
    public var stop: any RecorderStopSource
    public var reporter: any RecordingReporter
    /// nil: no post-processing (--no-postprocess, --record-only).
    public var postProcess: PostProcessHook?
    /// No hardware defaults: tests use `.testing(...)` (Fakes.swift).
    public init(makeCapture: @escaping @MainActor @Sendable () -> any MeetingCapture,
                makeSpeech: @escaping LiveSpeechFactory, stop: any RecorderStopSource,
                reporter: any RecordingReporter, postProcess: PostProcessHook?)
    /// LiveMeetingCapture + AppleSpeechSession.make.
    public static func live(stop: any RecorderStopSource, reporter: any RecordingReporter,
                            postProcess: PostProcessHook?) -> RecordingDependencies
}

public struct RecordingOutcome: Sendable, Equatable {
    public var sessionID: String
    public var directory: URL
    /// The ArchiveStatus value written at finish.
    public var archiveStatus: String
    public var stopReason: StopReason
    public var transcriptID: String?
    public var transcriptErrors: [String]
    /// The hook's record; nil when post-processing did not run.
    public var postProcessing: PostProcessingRecord?
}

public enum RecordingWorkflow {
    /// Records until stop, saves audio and transcript, then (with a hook) takes the processing lease,
    /// finishes the archive, and runs the hook under the lease (§4.6 steps 5–8).
    /// Capture failure: marks the archive incomplete and throws `HolosError.incomplete` (as today).
    /// Transcription failure: does not throw; the outcome carries the errors.
    @MainActor public static func run(_ options: RecordingOptions,
                                      dependencies: RecordingDependencies) async throws -> RecordingOutcome
}

public enum TrackReplayer {
    /// Transcribes a track's finalized chunks from disk, starting at session time `from` (seeking inside the
    /// chunk that contains it). `makeSpeech` defaults to AppleSpeechSession.make.
    public static func replay(directory: URL, track: String, locale: String, backend: SpeechBackend,
                              contextualStrings: [String] = [], from start: Double = 0,
                              makeSpeech: LiveSpeechFactory? = nil) async throws -> [TranscriptSegment]
}
```

Properties that later PRs add to `RecordingDependencies` (PR2a: clock factory, free
space, power events, power assertion factory, input-device lookup) get **inert**
defaults (unlimited free space, no power events, no assertion, fake devices) so PR1's
tests keep compiling; only `.live(...)` installs the real ones.

`Record.Start.run` becomes: run the workflow with `.live(stop: SignalStopController(),
reporter: ConsoleReporter(), postProcess: noPostprocess || recordOnly ? nil :
makePostProcessHook(options: .init()))`; print `Saved <path>`; if `transcriptErrors` is
not empty, throw `HolosError.incomplete("Audio saved; transcription needs retry: …")`
exactly as today (exit 1).

**`Fakes.swift`** (PR1; later edited only per §1.8): `FakeCaptureFactory` (hands out a new
`FakeCapture` per epoch and records every `CaptureRequest`); `FakeCapture` (scripted
frames per track with start times on its own clock plus `timelineOffset`, an optional
error after N frames, an optional start error, an optional `stop()` that hangs for a
given time, a `droppedBuffers` counter); `FakeSpeechFactory` and `FakeSpeech` (scripted
segments per session with times relative to the session's first frame, records the
contextual strings and the frame times it was fed, an optional `finish()` delay or
hang); `CollectingReporter`; `TemporaryDirectory`; and
`RecordingDependencies.testing(captures:speech:postProcess:)`.

**Tests** (`HolosMeetingTests`):

| Test | Input | Expected |
|---|---|---|
| `recordOnlySavesAudioAndFinishesAudioOnly` | record-only; 3 mic frames of 0.1 s at 48 kHz; stop requested after they are consumed | outcome `audioOnly`; manifest `audioOnly`; 1 mic chunk of 14,400 frames; events include `captureStarted`, `captureStopped` |
| `captureFailureMarksArchiveIncompleteAndThrows` | 1 frame, then the stream throws | throws `HolosError.incomplete`; manifest `incomplete`; `captureFailed` event |
| `noFramesIsIncomplete` | stop immediately, no frames | throws `incomplete` with "No audio buffers" |
| `liveSegmentsBecomeTranscriptWithTrack` | FakeSpeech returns 2 segments for `mic` | status `complete`; transcript has 2 segments with `track == "mic"`; `transcriptID` set; `transcripts/current.json` names it |
| `liveSpeechFailureFallsBackToReplay` | first `makeSpeech` throws; replay factory returns 1 segment | status `complete`; transcript has the replayed segment |
| `durationStopsRecording` | `duration: 0.3`; capture keeps emitting | returns within 2 s; chunks present |
| `postProcessHookRunsUnderLeaseAfterFinish` | hook records `isActive` and `isProcessing` when called | hook sees `isActive == false`, `isProcessing == true`; outcome carries the hook's record; lease released afterwards |
| `noHookMeansNoLease` | `postProcess: nil` | outcome `postProcessing == nil`; no lease taken |
| `leaseHeldElsewhereSkipsPostProcessing`, `leaseErrorFailsPostProcessing` | hook set; the lease is held elsewhere, or taking it fails | hook not called; outcome and `status.json` exit carry `.failed` with a "Speaker labelling was skipped" message |
| `vocabularyReachesSpeechFactory` | `vocabulary: ["Maria Chen"]` | FakeSpeech saw `["Maria Chen"]` for live and replay sessions |
| `replayFromSkipsEarlierAudio` | chunks 0–30 s and 30–60 s; `replay(from: 40)` | first frame fed starts at 40.0 (± one buffer); none earlier |
| `postProcessorSkeletonIsSkipped` | `MeetingPostProcessor().run(session:lease: nil)` on a finished session | state `.skipped`; no `postprocess.json` written |

**Acceptance.** `swift build` and `./scripts/test.sh` pass; `holos record start --help`
is unchanged except `--no-postprocess`; `rg -n "AppleSpeechSession|AudioCapture" Sources/HolosCLI`
finds no recording logic left in the CLI (only `Doctor.swift` uses `AudioCapture.microphonePermission`).

**Does not touch.** `HolosAudio`, `HolosStorage`, `HolosSpeech`, `HolosDictation`,
`HolosDesktop`, `HolosApp`, the contract files, `Models.swift`, scripts.

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

### 5.4 PR2a and PR2b: Long-recording robustness (wave 2, stacked)

**Goal.** A 3 h recording survives, and its audio, transcript, and timeline stay correct.
PR2a: the recorder loop and its files (Int16 and mono system audio, the capture pump,
frame continuity, the session clock, `RecorderMachine` with control, restarts and the
`waiting` phase, disk policy, `status.json` with heartbeat, `control/`, the stop path
with coverage-based replay, timeouts, and the lifecycle around the post-process hook).
PR2b, stacked on PR2a: sleep and power, device changes, the stall watchdog, microphone
selection, and the environment events that retry a waiting recorder.

#### PR2a

**Files.**

- HolosAudio, add: `ChunkWriterPump.swift`, `FrameContinuity.swift`.
- HolosAudio, change: `ChunkWriter.swift` (Int16; `FrameContinuity`; `bytesWritten`,
  `lastFrameEnd`, `closeAll`, `noteGap`), `AudioCapture.swift` (timeline offset;
  overflow drops and counts instead of failing; ScreenCaptureKit `channelCount = 1`;
  only `SCStreamError.Code.userStopped` maps to `CaptureInterruption.userStoppedSharing`;
  declares `MicrophoneSelection`, used by PR2b).
- HolosMeeting, add: `SessionClock.swift`, `RecorderMachine.swift` (§4.2),
  `DiskPolicy.swift` (§4.5), `ControlInbox.swift`, `RecorderChannel.swift` (§4.1),
  `StatusWriter.swift`, `TranscriptCoverage.swift` (§4.6), `Timeouts.swift` (internal).
- HolosMeeting, change: `RecordingWorkflow.swift` (the loop runs `RecorderMachine`;
  epochs; off-main consumer; `meeting.json`, `vocabulary.json`, `status.json`; the stop
  path of §4.6), `LiveTrack.swift` (§4.6), `TrackReplayer.swift` (new speech session at
  each gap over 1 s; rebased sessions), `MeetingCapture.swift` (offset, microphone
  selection, `droppedBuffers`), `StopSources.swift` (ignore SIGPIPE).
- HolosCLI: change `Record.swift` (new flags; `stop` via control; `status` shows phase;
  exit codes); add `RecordControl.swift` (`pause`, `resume`, `marker`, registered in
  `Record`'s `subcommands:`).
- Docs: append a "Long recordings" section to `docs/hardware-validation.md` (H4–H10
  procedures from §7.2).
- Tests: `Tests/HolosAudioTests/{Int16ChunkTests, FrameContinuityTests, ChunkWriterPumpTests}.swift`;
  `Tests/HolosMeetingTests/{RecorderMachineTests, DiskPolicyTests, ControlInboxTests, RecorderChannelTests, StatusWriterTests, RecorderEpochTests, LiveTrackTests, TranscriptCoverageTests, StopPathTests, SpeechFixtureTests}.swift`,
  helpers in `RecorderTestSupport.swift` (`fileprivate` or prefixed `recorder…`, §1.8).

**API (additions).**

```swift
// HolosAudio
public enum MicrophoneSelection: Sendable, Equatable { case systemDefault, builtIn }
public enum CaptureInterruption: Error, Equatable, Sendable {
    case configurationChanged        // AVAudioEngineConfigurationChange (reported from PR2b)
    case userStoppedSharing          // SCStreamError.Code.userStopped only
}
extension AudioCapture {
    /// Existing callers (dictation) keep `start(source:applicationBundleID:)`, which calls this with
    /// offset 0 and `.systemDefault`.
    public func start(source: AudioSource, applicationBundleID: String?, timelineOffset: Double,
                      microphone: MicrophoneSelection) async throws
    /// Buffers dropped because the frame stream was full.
    public var droppedBuffers: Int { get }
}
public enum FrameContinuity {
    public enum Decision: Sendable, Equatable {
        case contiguous(driftSeconds: Double)
        case gap(seconds: Double)
        case overlap(dropFrames: Int)     // leading frames to drop; ≥ frameCount means drop the whole frame
    }
    /// §2.3 rules with the 0.05 s tolerance. `expected` nil means the first frame of the track.
    public static func classify(frameStart: Double, frameCount: Int, sampleRate: Double,
                                expected: Double?) -> Decision
}
public final class ChunkWriterPump: Sendable {
    public init(writer: AudioChunkWriter, capacitySeconds: Double = 60)
    /// Never blocks. Returns false when the frame was dropped because the track's queue is full.
    public func push(_ audio: CapturedAudio) -> Bool
    public func noteGap(track: String, reason: GapReason)
    public func backlogSeconds() -> [String: Double]
    /// Writes queued frames in order until `finish()` is called and the queue is empty.
    public func run() async throws
    public func finish()
}
extension AudioChunkWriter {
    /// Bytes of finalized chunks plus frames × channels × 2 of open chunks.
    public func bytesWritten() -> Int64
    public var lastFrameEnd: Double { get }
    /// Closes every open chunk; the next discontinuity event on each track carries `reason`.
    public func closeAll(expectingGap reason: GapReason) async throws
    public func noteGap(track: String, reason: GapReason)
}

// HolosMeeting
public protocol SessionClock: Sendable { func now() -> Double }
public struct ContinuousSessionClock: SessionClock { public init(hostTimeOrigin: Double) }   // §2.3
public final class ManualSessionClock: SessionClock { public init(_ start: Double = 0); public func advance(by: Double) }

public actor StatusWriter {
    /// Writes `initial` and starts the heartbeat (rewrite every `heartbeat` until `finish`).
    public init(session: URL, initial: RecorderStatus, heartbeat: Duration = .seconds(1)) throws
    /// Bumps sequence, sets updatedAt, writes atomically. Does nothing after `finish`.
    public func update(_ change: @Sendable (inout RecorderStatus) -> Void) throws
    /// Writes phase exited with `exit` and stops the heartbeat.
    public func finish(exit: RecorderExit) throws
    public func current() -> RecorderStatus
}

public struct ControlInbox: Sendable {
    public init(session: URL, sessionID: String)
    public enum Item: Sendable, Equatable { case request(ControlRequest), rejected(file: String, reason: String) }
    /// Reads and removes valid or invalid request files (rules in §4.1); returns them in (sentAtNanos, id) order.
    public mutating func poll() -> [Item]
}

public struct StopTimeouts: Sendable, Equatable {
    public var captureStop: Duration                    // 5 s
    public var speechFinishBase: Duration               // 30 s
    public var speechFinishPerAudioSecond: Double       // 0.05
    public static let standard: StopTimeouts
}
```

`RecordingOptions` gains `sessionID: String?` (validated UUID, passed to
`SessionArchive.create(id:)`), `othersInRoom: Bool`, `expectedSpeakers: Int?`,
`liveText: Bool`, and `microphone: MicrophoneSelection` (from PR2b: `.builtIn` for
`mic`, `.systemDefault` for `mic+system`). `CaptureRequest` gains `microphone`
(default `.systemDefault`). `RecordingDependencies` gains, with inert defaults (§5.2):
`makeClock: @Sendable (Double) -> any SessionClock`, `freeSpace: any FreeSpaceProvider`
(`FixedFreeSpace(.max)`), and `timeouts: StopTimeouts` (`.standard`); `.live(...)` sets
`ContinuousSessionClock` and `VolumeFreeSpace`.

**Behaviour.**

- Int16: `AudioChunkWriter` writes CAF with `AVFormatIDKey: kAudioFormatLinearPCM`,
  `AVLinearPCMBitDepthKey: 16`, `AVLinearPCMIsFloatKey: false`,
  `AVLinearPCMIsBigEndianKey: false`, interleaved, processing format Float32 (the file
  converts on write). Reading is unchanged (AVAudioFile's processing format), so old
  Float32 chunks still replay and recover. System audio is captured mono.
- Start sequence: validate `--session-id`; `DiskPolicy.startCheck` (refuse → throw
  `HolosError.unavailable` with the message, before creating the session); create the
  archive with the ID; write `meeting.json` and `vocabulary.json` (copy
  `--vocabulary-file`, then delete it); create `StatusWriter` (phase `starting`,
  heartbeat running); `archive.setJournalSync(.interval(seconds: 1))`; create live
  speech sessions; start capture epoch 0; create the session clock from its
  `hostTimeOrigin`; start the frame consumer off the main actor and the pump's writer
  task.
- Loop, effects, capture path, stop path, `LiveTrack`, and coverage: §4.2, §4.3, §4.6.
- `control.json` is no longer written. `stop.request` is still honoured.

**CLI.**

```
holos record start [--name N] [--source mic|system|mic+system] [--app BUNDLE] [--duration S]
                   [--record-only] [--no-postprocess] [--directory D] [--locale L] [--backend B]
                   [--session-id UUID] [--no-live-text] [--others-in-room] [--expected-speakers N]
                   [--vocabulary-file FILE]
holos record status [--directory D] [--json]
holos record stop <session-id> [--directory D] [--no-wait]
holos record pause <session-id> [--directory D] [--no-wait]
holos record resume <session-id> [--directory D] [--no-wait]
holos record marker <session-id> [--label TEXT] [--directory D] [--no-wait]
```

- `--others-in-room` is valid only with `mic+system`. `--session-id` must be a UUID with
  no existing folder. `--expected-speakers` is 1…20.
- Control commands publish a request, then wait up to 3 s for its `ControlAck` in
  `status.json` unless `--no-wait`. Output: `Paused Council meeting.` /
  `Marker added at 01:02:03.` / `Recorder did not respond within 3 s; the request stays
  queued.` (exit 1) / `Ignored: already paused.` (exit 0).
- `record status` keeps its tab-separated lines and appends `phase=<phase>
  elapsed=<h:mm:ss>` for live sessions; `--json` prints
  `[{id, status, name, chunks, phase?, elapsedSeconds?}]`.
- Exit codes per §1.4: 1 for transcription incomplete and capture failure (as today);
  3 for `diskLow`, `sleepTimeout`, `pauseTimeout`, and post-processing
  `partial`/`failed`.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `int16ChunkRoundTripWithinOneStep` | frames [0.5, −0.25, 0.999, −1.0, 0] mono 48 kHz | file `fileFormat.commonFormat == .pcmFormatInt16`; read-back error ≤ 1/32768 + 1e−6 |
| `int16HalvesChunkBytes` | 30 s mono | data size = 30 × 48,000 × 2 bytes (± header) |
| `float32ChunksStillReplay` | archive with a Float32 CAF written as in `SessionArchiveTests` | `TrackReplayer` with FakeSpeech reads all frames |
| `smallJitterIsContiguous` | frames 0–0.1 s, then 0.13–0.23 s | one chunk; no discontinuity event |
| `gapClosesChunk` | 0–0.1 s, then 0.2–0.3 s | two chunks; `audioDiscontinuity {reason: timestampGap}` |
| `overlapIsTrimmedAndRecorded` | 0–1.0 s, then 0.8–1.3 s | the second frame's first 0.2 s dropped; `timestampOverlap {droppedSeconds: 0.2}`; no chunk starts before the previous one ends |
| `pumpAbsorbsSlowWriter` | writer stalls 10 s while 20 s of frames are pushed | nothing dropped; backlog peaks ≥ 9 s; all audio written after the stall |
| `pumpDropsBeyondCapacityAndMarksOverflow` | writer stalls 70 s (capacity 60 s) | pushes return false after 60 s; one `audioDiscontinuity {reason: overflow}` per track; capture never ends; warning `audioDropped` |
| `captureOverflowDoesNotFail` | capture receiver with capacity 2, 5 yields (internal hook) | stream still open; `droppedBuffers == 3` |
| `startCheckRefusesWarnsAndAllows` | mic; free 3.0 / 5.0 / 10.0 GB | refuse / warn / ok |
| `runtimeWarnsOnceAndRearms` | free 1.9 GB twice, then 2.6 GB, then 1.9 GB | warn, ok, ok, warn |
| `runtimeStopsBelow500MB` | free 0.4 GB | `stop` |
| `renderCheckNeedsOneGigabyteHeadroom` | 1 h, 1 track; free 1.1 GB, then 1.2 GB | false, true |
| `pauseResumeTransitions` | recording + pause, pause again, resume | `stopCapture(.paused)`, event `paused`, `holdPowerAssertion(false)`, ack applied; then ack ignored; then `recordEvent(resumed)`, `holdPowerAssertion(true)`, `startCapture(epoch: 1)` |
| `stopIsIdempotent` | two stop requests | first applied + `finish(requested)`; second ignored |
| `markerWhilePausedIsApplied` | paused + marker "Vote" at 12.5 | event `marker {at: 12.5, label: Vote}`; markers 1 |
| `configurationChangeStopsThenRestarts` | recording + `captureEnded(0, .configurationChanged)` | `deviceChanged` event and warning; `stopCapture(.deviceChanged)` before `startCapture(epoch: 1)` |
| `staleEpochEndIsIgnored` | epoch 2 running; `captureEnded(1, .failed)` | no effects |
| `failuresBackOffIntoWaiting` | a failure, then four start failures | first restart immediate; then `waiting` with retries 0.5, 1, 2, 4 s later; `captureWaiting` events; no `finish` |
| `failFiveTimesThenRecover` | FakeCapture epochs 1–5 fail to start, epoch 6 delivers | recording resumes in epoch 6; one gap with reason `audioUnavailable`; no finish |
| `waitingTimesOutAfterTenMinutes` | audio unavailable from 100 s; ticks at 699 and 700 | still waiting at 699; `finish(captureFailed)` at 700 |
| `retryNowStartsImmediately` | waiting with a retry due 4 s later; `retryNow` after 1 s | `startCapture` at once |
| `attemptsResetAfterTenSecondsOfAudio` | fail, recover, run 10 s, fail again | the second restart is immediate again |
| `userStoppedSharingStops` | `captureEnded(.userStoppedSharing)` | `finish(requested)` |
| `pauseTimesOutAfterSixHours` | paused at 100; ticks at 21,699 and 21,700 | `finish(pauseTimeout)` at 21,700 |
| `inboxRejectsForeignSessionUnknownCommandSymlinkAndOversize` | four bad files + one good | good returned as `.request`; four `.rejected`; all five files removed |
| `inboxOrdersBySentAtNotCreatedAt` | pause and resume with the same `createdAt` second, resume's UUID sorting first, `sentAtNanos` pause < resume | pause applied, then resume |
| `inboxIgnoresTemporaryFiles` | `.X.tmp` and one request | tmp untouched; request returned |
| `commandsAfterStopAreIgnored` | pause request during the stop path | ack `ignored` "already stopping"; file deleted; no leftover files at exit |
| `channelSendRefusesWithoutManifest` | session folder without a manifest | throws `unavailable`; no `control/` created |
| `livenessDistinguishesMaintenance` | (a) writer held by the test, fresh status `recording`; (b) writer held, stale `exited` status; (c) no locks, stale `recording` | capturing; maintenance; dead |
| `deadRecorderStatusIsMarkedExited` | case (c) | status rewritten `exited`, reason `interrupted`, archiveStatus from the manifest |
| `heartbeatKeepsStatusFresh` | writer created, no updates for 2.5 s (heartbeat 1 s) | sequence ≥ 3; `updatedAt` advanced |
| `updatesAfterExitAreIgnored` | `finish(exit:)`, then `update` | file still `exited`; sequence unchanged |
| `progressIsMirroredInOrder` | hook sends 200 progress values quickly, then returns | the last status before `exited` shows the last value; `postprocessing` never follows `exited` |
| `epochsRecordDiscontinuityWithReason` | FakeCapture epoch 0 frames 0–1 s; pause; resume at 5 s | two chunks; `audioDiscontinuity {reason: paused}`; events `paused`, `resumed` |
| `discontinuityReasonsUseGapReasonStrings` | pause, device change, restart, overflow | event reasons exactly `paused`, `deviceChanged`, `captureRestarted`, `overflow` |
| `epochOffsetNeverOverlaps` | epoch 0's audio clock runs 0.3 s ahead of the session clock; restart | epoch 1 offset = `lastFrameEnd + 0.01`; its first chunk starts after epoch 0's last chunk ends |
| `sessionTimeStartsAtFirstCapture` | 5 s between workflow start and capture start; a marker when the session clock reads 2.0 | first chunk starts at 0; marker event `at: 2.0` |
| `liveTrackRestartsSpeechAtBoundary` | two epochs, FakeSpeech per session returning one segment each | transcript has both segments; two speech sessions created |
| `speechSessionsAreRebased` | epoch 1 at 3,605 s; FakeSpeech returns a word at 1.0–1.4 relative | transcript word at 3,606.0–3,606.4; FakeSpeech saw a first frame time of 0 |
| `nextSpeechSessionIsReadyBeforeCaptureRestarts` | resume with a FakeSpeech factory that takes 0.5 s | the factory call finishes before the new epoch's `start` is called |
| `liveOverflowKeepsLiveWordsAndReplaysOnlyTheRest` | live queue 1 s; speech blocked 3 s at 40 s of a 60 s recording | `transcriptionBehind {from ≈ 40}`; live words before 40 kept; `replay(from: ≈38)`; merged at word level with no duplicates |
| `coverageMergeSplitsStraddlingSegment` | coverage 55.2; replayed segment 54.0–57.0 with words at 54.1, 55.0, 55.3, 56.0 | replayed words 55.3 and 56.0 kept in a cut segment; live words intact |
| `finalizedEventCarriesWords` | FakeSpeech segment with 2 TimedWords | event details `segmentID`, `words` decode to the same TimedWords |
| `journalDropRecordsBehind` | journal queue capacity 2 (internal), 5 finals while the archive stalls | `transcriptionBehind {from: start of the first dropped segment}` after the queue drains |
| `hungCaptureStopTimesOut` | FakeCapture `stop()` hangs; `captureStop` 0.2 s | stop path continues; `captureFailed` event; archive finished |
| `hungSpeechFinishTimesOut` | FakeSpeech `finish()` hangs | session cancelled after the timeout; its finalized segments kept; the rest replayed |
| `leaseTakenBeforeFinish` | hook set; a poller reads liveness every 5 ms during the hand-off | the lease is held before the writer lock is released; liveness never reads `dead` |
| `statusEndsExitedAfterFakePostProcessor` | hook returns a `partial` record | `status.json` phase `exited`, `exit.postprocessing == partial`, message copied |
| `speechFixtureTimesAreAbsolute` (opt-in `HOLOS_SPEECH_FIXTURE=1`) | a phrase rendered with `NativeSpeechRenderer`, fed through `AppleSpeechSession` as epoch at 3,600 s and again after a 5 s gap | word starts within ±0.3 s of the true times in both |

**Acceptance.** All tests pass; `holos record --help` lists the new subcommands and
flags; `holos record status --json` decodes on a sessions folder containing a fixture
`status.json`; the PR description reports the opt-in speech fixture result (run by the
implementer; no microphone). Agents do not run a live recording.

**Does not touch.** `MeetingPostProcessor.swift`, `Sources/HolosCLI/PostProcessing.swift`,
`Session.swift`, `Doctor.swift`, `Package.swift`, `HolosStorage` (uses PR6's API only),
`HolosSpeakers`, contract files (except additions allowed by §3.0), `HolosDictation`,
`HolosApp`, `Fakes.swift`.

#### PR2b (stacked on PR2a)

**Files.**

- HolosAudio, add: `PowerAssertion.swift`, `SystemPowerMonitor.swift`,
  `BuiltInMicrophone.swift`, `AudioEnvironmentEvents.swift` (CoreAudio
  `kAudioHardwarePropertyDevices` listener and the `com.apple.screenIsUnlocked`
  distributed notification, buffered in a `Mutex`).
- HolosAudio, change: `AudioCapture.swift` (report `configurationChanged`; pin the
  built-in microphone for `.builtIn`; start ScreenCaptureKit without the microphone when
  asked).
- HolosMeeting, add: `TrackWatchdog.swift`. Change: `RecorderMachine.swift` (sleep,
  watchdog, device rules of §4.2 and §4.4), `RecordingWorkflow.swift` (power assertion,
  power events, lid state, environment events, input-device lookup, call without
  microphone).
- HolosCLI: change `Record.swift` (in person refuses a missing built-in microphone).
- Tests: `Tests/HolosMeetingTests/{SleepPolicyTests, WatchdogTests, MicrophoneSelectionTests}.swift`,
  `Tests/HolosAudioTests/BuiltInMicrophoneTests.swift` (pure classification only).

**API (additions).**

```swift
// HolosAudio
public struct InputDevice: Sendable, Equatable { public let id: UInt32; public let uid: String; public let name: String }
public struct InputDevices: Sendable, Equatable {
    public var builtIn: InputDevice?        // nil when absent (e.g. lid closed in clamshell mode)
    public var systemDefault: InputDevice?  // nil when the Mac has no input device
}
public enum BuiltInMicrophone {
    public static func devices() -> InputDevices
    /// Pure classification used by `devices()`, for tests.
    public static func isBuiltInInput(transportType: UInt32, inputStreamCount: Int) -> Bool
}
public final class PowerAssertion: Sendable {
    /// kIOPMAssertionTypePreventUserIdleSystemSleep named `reason`. Released by `release()` or deinit.
    public init(reason: String) throws
    public func release()
}
public enum PowerEvent: Sendable, Equatable {
    case willSleep(token: Int)     // the loop calls allowPowerChange(token:) after closing chunks
    case didWake
}
public protocol SystemPowerEvents: Sendable {
    /// Events buffered since the last call.
    func pendingEvents() -> [PowerEvent]
    func allowPowerChange(token: Int)
    /// AppleClamshellState from IOPMrootDomain; true when the property is absent.
    func isLidOpen() -> Bool
    /// While detached, the monitor acknowledges willSleep itself.
    func attach()
    func detach()
}
public final class SystemPowerMonitor: SystemPowerEvents { public init() throws; public func stop() }
public final class AudioEnvironmentEvents: Sendable {
    public init()
    /// "audioDevicesChanged" or "screenUnlocked", buffered since the last call.
    public func pendingReasons() -> [String]
    public func stop()
}

// HolosMeeting
public struct TrackWatchdog: Sendable, Equatable {
    public init(stallSeconds: Double = 3, restartSeconds: Double = 10)
    public mutating func startEpoch(at: Double, tracks: [String])
    /// Tracks that became stalled, tracks that recovered, and microphone tracks due for a restart.
    public mutating func evaluate(lastFrameAt: [String: Double], now: Double)
        -> (stalled: [String], resumed: [String], restart: [String])
}
```

`RecordingDependencies` gains, with inert defaults: `power: (any SystemPowerEvents)?`
(nil), `makePowerAssertion: @Sendable (String) -> PowerAssertion?` (returns nil),
`findInputDevices: @Sendable () -> InputDevices` (a fake built-in and default device),
and `environmentEvents: AudioEnvironmentEvents?` (nil). `.live(...)` installs the real
ones.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `sleepUnderFifteenMinutesResumes` | willSleep at 100; didWake at 700, lid open | `stopCapture(.sleep)`, `systemWillSleep`, `allowSleep`; then `startCapture(epoch: 1)`, `warn(resumedAfterSleep)`, `didWake {action: resume}` |
| `sleepOverFifteenMinutesFinalizes` | willSleep at 100; didWake at 1001 | `finish(sleepTimeout)`; no `startCapture` |
| `wakeWithLidClosedWaitsThenFinalizes` | didWake at 160, lid closed; tick at 999, then 1000 | stays sleeping; then `finish(sleepTimeout)` |
| `darkWakeKeepsSleepStart` | recording; willSleep 0; didWake 600 lid closed; willSleep 601; didWake 1,200 lid open | `finish(sleepTimeout)` |
| `pausedStaysPausedThroughDarkWake` | paused; willSleep; didWake lid closed; willSleep; didWake 300 s later lid open | phase `paused`; no `startCapture` |
| `pausedSleepOverFifteenMinutesStaysPaused` | paused; willSleep 100; didWake 2,000 | phase `paused`; no `finish` |
| `sleepWhileWaitingRetriesOnWake` | waiting; willSleep; didWake 60 s later, lid open | `startCapture` |
| `wakeThenStartFailureRetries` | didWake with the lid open; the new epoch fails to start twice | first retry at once, then `waiting` with backoff; no `finish` |
| `monitorAcknowledgesWhenDetached` | detached; willSleep | acknowledged by the monitor itself |
| `loopAcknowledgesAfterClosingChunks` | attached; willSleep; FakeCapture `stop()` hangs | chunks closed, then `allowPowerChange` within the capture-stop timeout |
| `watchdogFlagsAfterThreeSecondsAndClears` | mic last frame at 10.0; now 13.1, then a frame at 13.5 | stalled [mic]; then resumed [mic] |
| `stalledMicRestartsInNewEpoch` | mic last frame at 10.0; ticks to 20.1 | `trackStalled` at 13; `stopCapture(.captureRestarted)` then `startCapture(epoch+1)` at 20 |
| `systemTrackIsNeverRestartedForStall` | system silent 30 s | stalled warning only |
| `slowStartIsNotAStall` | 5 s startup delay before epoch 0; first frame at session 0.2 | no stall |
| `retryOnScreenUnlockAndDeviceChange` | waiting; environment reason `screenUnlocked` | `retryNow` → `startCapture` |
| `inPersonPinsBuiltInMicrophone` | devices: built-in + AirPods as default; source mic | capture request `.builtIn`; status `microphoneName` is the built-in name |
| `callUsesSystemDefault` | source mic+system | capture request `.systemDefault`; `microphoneName` is AirPods |
| `inPersonRefusesWithoutBuiltIn` | `builtIn == nil` | start throws "The built-in microphone is unavailable. Open the lid and try again."; no session folder |
| `callWithoutAnyInputRecordsSystemOnly` | `systemDefault == nil` on restart | capture starts without the microphone; `warn(microphoneUnavailable)`; after `audioDevicesChanged` with a device back, restarts with it |
| `builtInClassification` | (built-in, 1 input stream), (USB, 1), (built-in, 0) | true, false, false |

**Manual checks.** H4–H7, H9–H11, and H21 in §7.2, recorded in `docs/hardware-validation.md`.

**Does not touch.** Same list as PR2a.

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
- Add `THIRD_PARTY_NOTICES.md` (§4.8).
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
                             [--after-recording] [--json]
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
percentiles. The `exclusiveSegments` default follows §4.8. Temporary sessions and audio
are deleted.

**Does not touch.** HolosDiarization, `MeetingPostProcessor.swift`, HolosAudio,
`RecordingWorkflow.swift`, contract files, HolosApp.

### 5.6 PR3: Recovery, session catalog, deletion (wave 3)

**Goal.** After a recorder crash or power loss, rebuild the transcript from
`transcriptFinalized` events, transcribe only audio that was not covered, list sessions
with their state, post-process the result, and delete audio or whole meetings.

**Files.**

- Add `Sources/HolosMeeting/TranscriptRebuilder.swift`, `Sources/HolosMeeting/SessionCatalog.swift`,
  `Sources/HolosStorage/SessionDeletion.swift`, `Sources/HolosCLI/SessionList.swift`,
  `Sources/HolosCLI/SessionDelete.swift`.
- Change `Sources/HolosCLI/Session.swift` (Recover flow; add `List.self`, `Delete.self`),
  `Sources/HolosCLI/Record.swift` (`status` uses `SessionCatalog`).
- Tests: `Tests/HolosMeetingTests/{TranscriptRebuilderTests, SessionCatalogTests}.swift`,
  `Tests/HolosStorageTests/SessionDeletionTests.swift`.
- Docs: PR3 merges last in wave 3 and writes the wave-3 `README.md` and
  `docs/status.md` notes for PR3 and PR8.

**API.**

```swift
public struct RebuildReport: Sendable, Equatable {
    public var transcriptID: String
    public var journalSegments: Int
    /// Per track: session time up to which journal words are kept.
    public var coverageEnd: [String: Double]
    /// Per track: seconds of audio transcribed again.
    public var replayedSeconds: [String: Double]
    /// True when an earlier rebuild was reused (idempotent path).
    public var reused: Bool
}

public enum TranscriptRebuilder {
    /// Requires an inactive archive and the caller's lease. Replays without the writer lock; takes it only for
    /// the final save through `SessionArchive.openForMaintenance(at:lease:)`. `vocabulary` nil reads vocabulary.json.
    public static func rebuild(session: URL, lease: ProcessingLease, force: Bool = false, transcribe: Bool = true,
                               vocabulary: [String]? = nil, makeSpeech: LiveSpeechFactory? = nil,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> RebuildReport
}

public enum SessionState: String, Codable, Sendable {
    case recording, processing, interrupted, complete, audioOnly, transcriptionIncomplete,
         incomplete, failed, recovered, damaged
}
public enum SpeakerLabelState: String, Codable, Sendable {
    /// No postprocess.json.
    case none
    case running
    case labelled
    /// Post-processing finished without a run (e.g. speaker models not installed); see `labelMessage`.
    case notLabelled
    case failed
    case interrupted
    /// postprocess.json or speakers/head.json cannot be read (damaged, newer Holos, I/O); see `labelMessage`.
    case unreadable
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var directory: URL
    public var name: String
    public var createdAt: Date
    public var source: AudioSource
    public var origin: MeetingOrigin
    public var state: SessionState
    public var manifestStatus: String
    /// Longest track's total chunk duration.
    public var savedSeconds: Double
    public var chunkCount: Int
    /// Set once the current revision was read and holds this ID.
    public var transcriptID: String?
    /// Why the current transcript cannot be read (missing, damaged, other ID, newer Holos).
    public var transcriptProblem: String?
    public var speakerState: SpeakerLabelState
    public var labelMessage: String?
    public var runID: String?
    public var hasSpeakerEdits: Bool
    public var phase: RecorderPhase?
    public var pid: Int32?
    public var liveness: RecorderLiveness
    public var bytes: Int64
    public var derivedBytes: Int64
    public var audioDeleted: Bool
}

public enum SessionCatalog {
    /// Newest first. A folder whose manifest cannot be read is `damaged` (named by its folder).
    public static func list(root: URL = HolosPaths.sessions, now: Date = Date()) -> [SessionSummary]
    public static func summary(session: URL, now: Date = Date()) -> SessionSummary
}

public enum SessionDeletion {
    /// §4.13. Requires the lease and no writer.
    public static func deleteAudio(session: URL, lease: ProcessingLease) throws
    /// §4.13. `trash` defaults to FileManager.trashItem; `logDirectory` to ~/Library/Logs/Holos (tests inject both).
    public static func moveToTrash(session: URL, lease: ProcessingLease,
                                   logDirectory: URL = SessionDeletion.defaultLogDirectory,
                                   trash: (URL) throws -> Void = SessionDeletion.systemTrash) throws
}
```

**Rebuild algorithm.**

1. The caller holds the lease. Refuse if `isActive`. `RecorderChannel.markDeadRecorderExited`.
2. Read events with `SessionArchive.readEvents` (tolerant of a torn last line and corrupt
   lines). Collect `transcriptFinalized` per track. Events with `words` rebuild
   `TimedWord`s and keep `segmentID`; older events give segments without words. Drop
   exact duplicates `(track, start, end, text)`.
3. `coverageEnd[track] = TranscriptCoverage.coverageEnd(live: journal segments,
   behindFrom: earliest transcriptionBehind.from for the track)`. Live transcription is
   sequential, so everything before the last final was processed, unless a
   `transcriptionBehind` event marks a hole (live overflow or a dropped journal write),
   in which case coverage stops at the hole (resolution R20).
4. If `transcribe`: `TrackReplayer.replay(from: max(0, coverageEnd − 2))` with the
   session vocabulary; `TranscriptCoverage.merge` keeps journal words before coverage and
   replayed words from it on, cutting segments at word boundaries.
5. Sort by `(start, track)`; `openForMaintenance(at:lease:)`; append
   `transcriptRebuilding` with the details `transcriptRebuilt` will have (so a transcript
   a rebuild made current is never taken for one the recorder saved at stop);
   `saveTranscript(_:writeLegacyExports: false)` (pointer updated); set status
   `recovered`; append `transcriptRebuilt {transcriptID, journalSegments,
   replayedSeconds}`; `finish`. A failure after the save is reported, not thrown; the next
   rebuild (and recover, even for a session that keeps its saved transcript) finds the
   `transcriptRebuilding` naming the current transcript and finishes writing the missing
   status and event instead of rebuilding again.
6. Idempotence by sequence numbers, not dates: if a `transcriptRebuilt` event exists with
   a higher `sequence` than the last `archiveRecovered` event, its `transcriptID` is the
   current pointer, that revision decodes and holds its own ID, and `!force`, return it
   with `reused: true` and change nothing. A truncated, damaged, or mislabelled current
   revision is rebuilt. A current pointer or revision, or a `vocabulary.json` the replay
   would use, written by a newer Holos is refused (`unavailable`), even with `force`.

**State mapping (`SessionCatalog`).** Unreadable manifest → `damaged`. Manifest
`recording`/`processing`: liveness `capturing` → `recording`; `processing` or
`maintenance` → `processing`; else `interrupted`. Otherwise the manifest status maps 1:1.
Speaker state: `postprocess.json` `running` with liveness `processing` or `maintenance`
→ `running`; `running` otherwise → `interrupted`; `failed` → `failed`; a finished record
with a run → `labelled`; a finished record without a run → `notLabelled` with the record's
message; no record → `none`. A head counts as labels only when
`SpeakerSessionSnapshot.load` (the loader the exports and speaker commands use) loads its
run: the run and the transcript revision it was built from exist and decode, and every
span fits that transcript. A postprocess.json, speakers/head.json, head run, or run
transcript that exists but cannot be read (damaged, of another session, written by a
newer Holos, I/O), a head whose run or run transcript is missing, a span outside that
transcript, or a record that names a run while the head is missing → `unreadable` with
why, never the state of a session without it. `recover` validates the same files the same
way (one shared reader, `SavedSpeakerState`, which delegates to the snapshot loader)
before it decides to post-process, and refuses (`unavailable`) when one was written by a
newer Holos.

**Saved files are read, never only found.** Every versioned file recover, the catalog,
delete, relabel, and the exports read (meeting.json, vocabulary.json, postprocess.json,
`transcripts/current.json` and revisions, `speakers/head.json`, runs, recognition results,
`audio-deleted.json`, `exports/.generated.json`) is decoded with its version checked
first: newer → `unavailable`; a version below 1 or data that does not decode → damage,
never present-and-authoritative. A record that names a session (meeting.json,
postprocess.json, runs, voice data, and `audio-deleted.json` when it names one) is
checked against the manifest's ID; another session's is damage.
`manifest.json` stays strictly version 1 (schema rule 4).

**CLI.**

```
holos session list [--directory D] [--interrupted] [--json]
holos session recover <path> [--no-transcribe] [--no-postprocess] [--force]
holos session delete <path> [--audio-only] --yes
```

`session list` prints `ID  STATE  SAVED  SIZE  SPEAKERS  NAME` (SAVED as `h:mm:ss`).
`recover` takes the lease once and keeps it for `SessionArchive.recover(at:lease:)`,
`TranscriptRebuilder.rebuild(lease:)`, and `MeetingPostProcessor.run(lease:)`, so no
other process can start labelling in between. It prints, for example, `Recovered 212
chunks (1:46:10). Transcript rebuilt from 1812 saved phrases; transcribed 0:31 of
uncovered audio. Speaker labels: 9 speakers.` `delete` without `--yes` refuses with a
hint. Session arguments are paths, as today.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `rebuildUsesJournalWordsAndSegmentIDs` | events with 3 `transcriptFinalized` (words present) | 3 segments; words and IDs equal the event payloads |
| `legacyEventsProduceUntimedSegments` | events without `words` | segments with empty `words` |
| `tornJournalTailIsTolerated` | journal whose last line is cut | rebuild succeeds after `recover`; torn line ignored |
| `corruptMiddleLineIsTolerated` | a garbage line between finals | rebuild succeeds; the other finals kept |
| `coverageIsLastFinalizedEnd` | mic finals ending 40.0 and 55.2; system none | coverage mic 55.2, system 0 |
| `coverageStopsAtBehindEvent` | finals to 55.2; `transcriptionBehind {mic, from: 30}` | coverage mic 30 |
| `uncoveredTailIsReplayedAtWordLevel` | coverage 55.2; replayed segment 53.5–58.0 with words at 53.6, 54.8, 55.4, 57.0 | only 55.4 and 57.0 added; no duplicated words |
| `recoverRebuildAndPostProcessUnderOneLease` | recover → rebuild → post-process in one process; another descriptor tries the lease after each step | every attempt refused; the chain succeeds; lease released at the end |
| `rebuildSavesWhileHoldingItsOwnLease` | rebuild with a lease | succeeds; the writer lock is free afterwards |
| `recoveryIsIdempotent` | rebuild twice within one second | second returns `reused: true`; one `transcriptRebuilt` event; one new transcript file |
| `rebuildRefusesActiveRecording` | writer lock held with a fresh `recording` status | throws `unavailable` |
| `catalogMarksDeadRecorderInterrupted` | manifest `recording`, no locks, stale status.json | `interrupted` |
| `catalogShowsMaintenanceAsProcessing` | manifest `processing`, writer lock held, no status.json newer than 10 s | `processing`, not `recording` |
| `catalogReportsSavedDurationSizeAndSpeakerState` | chunks mic 0–30, 30–60; system 0–30; head present | savedSeconds 60; `labelled`; bytes > 0 |
| `catalogReportsNotLabelledWithMessage` | postprocess.json succeeded, diarize skipped (models) | `notLabelled`; message has the setup hint |
| `deleteAudioKeepsTranscript` | session with audio, run, voice data, derived | `audio/`, `derived/`, `speakers/voice/` gone; transcript, run, exports kept; `audio-deleted.json`; inspect clean; catalog `audioDeleted` |
| `deleteRefusedWhileRecording` | writer lock held | throws; nothing removed |
| `moveToTrashRemovesRecorderLog` | fake trash and temp log directory | folder handed to the fake trash; log file deleted |

**Does not touch.** `HolosSpeakers`, `SessionSpeakerStore`, `SpeakerEditor`,
`Speakers.swift`, `SessionExport.swift`, exporters, `MeetingPostProcessor.swift`,
`SessionArchive.swift`, `Package.swift`, `Fakes.swift` and `SessionFixtures.swift` (PR8
owns them in wave 3).

### 5.7 PR8: CLI speaker editing and re-export (wave 3)

**Goal.** One edit API used by the CLI now and the review window later, `holos speakers`
commands, and `holos session export`.

**Files.**

- Add `Sources/HolosMeeting/SpeakerEditor.swift`, `Sources/HolosMeeting/SpeakerSelector.swift`,
  `Sources/HolosMeeting/SessionLocator.swift`.
- Add `Sources/HolosCLI/Speakers.swift`, `Sources/HolosCLI/SessionExport.swift`.
- Change `Sources/HolosCLI/Holos.swift` (add `Speakers.self`), `Sources/HolosCLI/Session.swift`
  (add `Export.self`).
- Tests: `Tests/HolosMeetingTests/{SpeakerEditorTests, SpeakerSelectorTests}.swift`. PR8
  owns `Fakes.swift` and `SessionFixtures.swift` edits in wave 3.

**API.**

```swift
public enum SpeakerEditor {
    /// §4.9. Under the speaker lock: loads the current snapshot; refuses the batch (nothing written) when the
    /// head run is not `view.runID` or any action's fingerprint on `view` (applied sequentially) differs from the
    /// current state; checks every target exists (throws invalidInput otherwise); appends all lines with one
    /// batchID in one write. Then releases the lock and regenerates exports unless told not to.
    /// Throws unavailable when there is no head run.
    @discardableResult
    public static func apply(_ actions: [SpeakerEditAction], view: SpeakerProjection, session: URL, source: String,
                             regenerateExports: Bool = true,
                             profileNames: [String: String] = [:]) throws -> SpeakerEditResult
    /// Appends a revert for every edit of `view.lastUndoableBatchID` (same refusal rules).
    @discardableResult
    public static func undoLast(view: SpeakerProjection, session: URL, source: String,
                                regenerateExports: Bool = true) throws -> SpeakerEditResult
}

public struct SpeakerEditResult: Sendable {
    public var snapshot: SpeakerSessionSnapshot
    /// True when the batch changed a turn's speaker, turn boundaries, merges, exclusions, or links of a
    /// speaker whose profile has a sample from this session (PR10 sets it; always false before PR10).
    /// The caller must then `await VoiceProfileService.refreshSamples(session:extractor:store:)`.
    public var needsSampleRefresh: Bool
}

public enum SpeakerTarget: Sendable, Equatable { case speaker(String), unknown }

public enum SpeakerSelector {
    /// In order: exact speaker ID ("system:S2"); engine label if unique ("S2"); ordinal ("2", "Speaker 2");
    /// name (case-insensitive, unique); "unknown". Errors list the candidates.
    public static func speaker(_ text: String, in projection: SpeakerProjection) throws -> SpeakerTarget
    /// "T12" or "T12/…" exactly; or a time ("01:12:03", "12:03.5", "723.5") → the turn containing it,
    /// requiring `track` when both tracks have one there.
    public static func turn(_ text: String, track: String?, in projection: SpeakerProjection) throws -> String
    public static func time(_ text: String) throws -> Double
}

public enum SessionLocator {
    /// A path to a .holos folder, or a session UUID under `root`.
    public static func resolve(_ text: String, root: URL = HolosPaths.sessions) throws -> URL
}
```

Every CLI edit command loads the snapshot, resolves its selectors against that
snapshot's projection, and passes the same projection as `view`, so a relabel between
load and apply is refused rather than applied to a different turn.

**CLI.**

```
holos speakers list <session> [--turns] [--json]
holos speakers rename <session> <speaker> <name|--clear>
holos speakers merge <session> <from-speaker> <into-speaker>
holos speakers assign <session> <turn>... --to <speaker|unknown|new[:NAME]>
holos speakers split <session> <turn> (--at-word N | --at <time>)
holos speakers exclude <session> <turn>...
holos speakers undo <session>
holos session export <session> --format md|json|txt [--output FILE]
holos session export <session> --all
```

`speakers list` output:

```
Council meeting (3F2A9C1E…) · run 5C1D7E2A (FluidAudio 0.17.1) · 11 speakers · 343 turns · 5 changes

  #  Speaker     Name        Talk     Turns  Label
  1  mic:me      Me          15:40       60  channel
  2  system:S1   Jim         41:12       88  renamed
  3  system:S2   Speaker 3   22:03       51  diarizer   suggestion: Maybe Maria (0.33)
```

`--turns` adds `T12  00:12:03–00:12:40  system  Jim  0.92  overlap  <first 60 characters>`.
Each edit command prints one line (`Renamed system:S2 to Maria.`) and regenerates
exports. `new[:NAME]` creates `user:<UUID>`. `session export` writes to stdout without
`--output`; `--output` refuses to overwrite; `--all` rewrites `exports/` and prints its
path plus any moved-aside edited files. No export contains vectors.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `editJournalExportEndToEnd` | fixture session with a 2-speaker head run; rename `system:S1` "Jim" | one journal line with `expected == ""`; `exports/transcript.txt` has a `Jim  00:0…` header; Markdown has `**Jim**` |
| `missingTargetWritesNothing` | rename `system:S9` | throws; journal unchanged |
| `editAgainstReplacedHeadIsRefused` | view from run A; head moved to run B | throws "changed since this view was loaded"; journal unchanged |
| `concurrentReassignIsRefused` | view V shows T4 as S1; another apply reassigns T4 to S2; then reassign T4 from V | refused; nothing written |
| `unrelatedConcurrentEditStillApplies` | view V; another apply renames S3; then rename S1 from V | applied |
| `batchFingerprintsAreSequential` | one batch: rename S1 "A", rename S1 "B" | second line's `expected` is "A"; both share a batchID |
| `exportsRegenerateAfterLockRelease` | apply with `regenerateExports: true` | no lock timeout; exports updated |
| `undoRevertsNewestBatch` | batch (link + rename), then a reassign; undo; undo | first undo reverts the reassign; second reverts both batch lines |
| `concurrentEditorsSerialize` | two tasks × 20 renames of different speakers, each reloading its view, `regenerateExports: false` | 40 lines, all readable, none stale |
| `selectorResolvesIDsLabelsOrdinalsNames` | "system:S2", "S2", "3", "Speaker 3", "maria" | same speaker |
| `ambiguousSelectorListsCandidates` | "S1" when mic:S1 and system:S1 exist | throws, message lists both |
| `timeSelectorFindsTurn` | "00:12:05" on system | T12 |
| `exportFormatsRenderWithoutWriting` | `SessionExports.render(.txt)` | Data; `exports/` unchanged |

**Does not touch.** `SessionArchive.swift`, `Record.swift`, `TranscriptRebuilder.swift`,
`SessionCatalog.swift`, `MeetingPostProcessor.swift`, HolosApp, `Package.swift`,
README and `docs/status.md`.

### 5.8 PR4: Menu bar meeting controls (wave 4)

**Goal.** Start, watch, pause, mark, and stop meetings from the menu bar; launch the
bundled recorder as a child (or in-process); reattach after an app crash and notice
terminal-started meetings; prompt about interrupted sessions and relabel them
automatically; confirm quit during a recording; pause dictation while a meeting is
active; install speaker models from the app; list, open, save, and delete meetings; and
lead to naming speakers after a meeting.

**Files.**

- HolosMeeting, add: `MeetingReducer.swift` (pure), `MeetingController.swift`
  (`@MainActor`, no AppKit), `RecorderLauncher.swift` (`RecorderLauncher` protocol,
  `ChildProcessLauncher`, `InProcessLauncher`, `MaintenanceLauncher` for
  `holos session recover|diarize|delete` and `holos setup --speakers` children, and the
  shared `posix_spawn` helper), `AutoRelabelPolicy.swift` (pure).
- HolosApp, add: `HolosApp+Meeting.swift` (menu section, actions, dictation pause),
  `MeetingStartPanel.swift`, `MeetingsWindow.swift`, `LiveTranscriptWindow.swift`,
  `AboutCredits.swift`.
- HolosApp, change: `HolosApp.swift` (stored properties, launch hooks,
  `applicationShouldTerminate`, menu insertion points, dictation-pause guards,
  `suspendedBySleep`), `SetupWindow.swift` ("Speaker labels" row).
- Change `Resources/App-Info.plist` (`NSMicrophoneUsageDescription`: "Holos uses your
  microphone for push-to-talk dictation and for meeting recordings you start.";
  `CFBundleVersion` 3), `scripts/build-app.sh` (bundle the CLI), `Package.swift`
  (§1.2 wave 4, identical to PR10's edit).
- Add `docs/meeting-validation.md` with sections "Recording controls (PR4)", "Review
  window (PR9)", "Online calls (PR11)"; the last two contain only `Pending.`
- Tests: `Tests/HolosMeetingTests/{MeetingReducerTests, MeetingControllerTests, LauncherTests, AutoRelabelPolicyTests}.swift`.
  PR4 owns `Fakes.swift` and `SessionFixtures.swift` edits in wave 4.

**API.**

```swift
public struct MeetingStartSettings: Codable, Sendable, Equatable {
    public var name: String
    /// .microphone ("In person") or .microphoneAndSystem ("Online call").
    public var source: AudioSource
    public var applicationBundleID: String?
    public var othersInRoom: Bool
    public var expectedSpeakers: Int?
    public init(name: String, source: AudioSource, applicationBundleID: String? = nil, othersInRoom: Bool = false,
                expectedSpeakers: Int? = nil)
    /// "Meeting 2026-09-23 14:00" in `timeZone`.
    public static func defaultName(now: Date, timeZone: TimeZone) -> String
}

public enum MeetingState: Sendable, Equatable {
    case idle
    case starting(sessionID: String, since: Date, pid: Int32?)
    /// Recorder phase starting…stopping (including waiting and unknown).
    case active(sessionID: String, status: RecorderStatus)
    /// Capture stopped; transcribing or post-processing.
    case finishing(sessionID: String, status: RecorderStatus?)
    case failed(sessionID: String?, message: String)
}

public enum MeetingEvent: Sendable, Equatable {
    case startRequested(MeetingStartSettings, sessionID: String, at: Date)
    case launched(pid: Int32?, at: Date)
    case launchFailed(message: String)
    case statusRead(RecorderStatus?, liveness: RecorderLiveness, at: Date)
    case childExited(code: Int32, logTail: String?, at: Date)
    case tick(at: Date)
    case stopConfirmed
    case pauseRequested
    case resumeRequested
    case markerRequested(label: String?)
    case reattached(sessionID: String, status: RecorderStatus)
    case reviewOpened(sessionID: String)
    case dismissFailure
}

public enum MeetingEffect: Sendable, Equatable {
    case launch(MeetingStartSettings, sessionID: String)
    case send(ControlCommand, label: String?, sessionID: String)
    /// SIGTERM to the child: a graceful stop while starting, or the 120 s start timeout.
    case terminateChild(sessionID: String)
    case announce(String)                // first menu line / status item tooltip
    case setDictationPaused(Bool)
    case finished(sessionID: String, summary: String, speakersReady: Bool)
    /// "Name Speakers — <name>…" at the top of the menu and a dot on the status item, until reviewed.
    case offerNaming(sessionID: String, name: String)
    case clearNamingOffer(sessionID: String)
}

public struct MeetingReducer: Sendable, Equatable {
    public private(set) var state: MeetingState
    public var dictationShouldPause: Bool { get }
    public init()
    public mutating func reduce(_ event: MeetingEvent) -> [MeetingEffect]
}

@MainActor public protocol RecorderLauncher: AnyObject {
    /// Starts a recorder for `sessionID`; returns the child pid (nil for in-process).
    func launch(_ settings: MeetingStartSettings, sessionID: String, root: URL, vocabularyFile: URL?) throws -> Int32?
    func terminate(sessionID: String)
    var onExit: ((Int32, String?) -> Void)? { get set }      // exit code, last log line
}

@MainActor public final class ChildProcessLauncher: RecorderLauncher {
    /// Default: Bundle.main.bundleURL/Contents/MacOS/holos.
    public init(executable: URL, logDirectory: URL)
    /// ["record", "start", "--session-id", id, "--name", name, "--source", src, ("--app", id)?,
    ///  ("--others-in-room")?, ("--expected-speakers", n)?, ("--vocabulary-file", path)?,
    ///  "--no-live-text", "--directory", root.path]
    public static func arguments(_ settings: MeetingStartSettings, sessionID: String, root: URL,
                                 vocabularyFile: URL?) -> [String]
}
@MainActor public final class InProcessLauncher: RecorderLauncher { public init() }
@MainActor public final class MaintenanceLauncher {
    public init(executable: URL)
    /// Runs `holos <arguments> --json` detached (POSIX_SPAWN_SETSID, CLOEXEC); returns the pid.
    public func run(_ arguments: [String], onExit: @escaping @MainActor (Int32) -> Void) throws -> Int32
}

public enum AutoRelabelPolicy {
    /// Sessions to relabel now, at most one: origin recorded, created in the last 7 days, speaker state
    /// interrupted or none (or notLabelled for a reason other than missing models), no speaker edits,
    /// liveness exited or dead, fewer than 2 attempts; only when models are installed and no meeting is active.
    public static func candidates(_ summaries: [SessionSummary], attempts: [String: Int], modelsInstalled: Bool,
                                  meetingActive: Bool, now: Date) -> [SessionSummary]
}

@MainActor public final class MeetingController {
    public private(set) var reducer: MeetingReducer
    public var state: MeetingState { get }
    public var status: RecorderStatus? { get }
    public init(root: URL = HolosPaths.sessions, launcher: any RecorderLauncher, maintenance: MaintenanceLauncher?,
                freeSpace: any FreeSpaceProvider, findInputDevices: @escaping @Sendable () -> InputDevices,
                vocabulary: @escaping @MainActor () -> [String], modelsInstalled: @escaping @MainActor () -> Bool,
                now: @escaping @MainActor () -> Date = Date.init,
                onChange: @escaping @MainActor (MeetingState) -> Void,
                onEffect: @escaping @MainActor (MeetingEffect) -> Void)
    /// Finds a live meeting (§4.1), then polls its status every second; while idle, rescans every 3 s and runs
    /// the automatic relabel every 30 s.
    public func attachOnLaunch()
    /// Disk and microphone checks, writes the vocabulary file (0600), then launches. Throws with the start
    /// panel's error text.
    public func start(_ settings: MeetingStartSettings) throws
    public func confirmStop()
    public func pause()
    public func resume()
    public func addMarker(label: String?)
    public func reviewOpened(sessionID: String)
    /// Interrupted sessions not yet prompted about (SessionCatalog).
    public func interruptedSessions(excluding prompted: Set<String>) -> [SessionSummary]
}
```

**Reducer rules.**

- `startRequested` (idle) → `starting`, effects `launch`, `setDictationPaused(true)`. Not
  idle → `announce("A meeting is already recording.")`. `launched(pid)` records the pid.
  `launchFailed` → `failed(message)`, `setDictationPaused(false)`.
- While `starting`, liveness comes from the child process, not the folder: a missing
  folder or status is normal. `tick` 5 s after the start without a `recording` status →
  `announce("Waiting for permission…")` once. `tick` 120 s after →
  `terminateChild`, `failed("The recorder did not start within 2 minutes. Details:
  ~/Library/Logs/Holos/recorder-<id>.log")`, `setDictationPaused(false)`.
  `childExited` while starting → `failed(logTail ?? "The recorder stopped before
  recording started.")`, `setDictationPaused(false)`; no "Recover" text, because nothing
  was saved. `stopConfirmed` while starting → `terminateChild` (SIGTERM is a graceful
  stop).
- A fresh `statusRead` for the launched or attached session with phase `isMeetingActive`
  → `active` from any state, including `failed`; `setDictationPaused(true)` if dictation
  was resumed.
- `statusRead` phase `transcribing`/`postprocessing` → `finishing`,
  `setDictationPaused(false)`.
- `statusRead` phase `exited` → `idle`, `finished(id, summary, speakersReady)`, and
  `offerNaming` when speakers are ready (post-processing `succeeded` or `partial`, then
  checked against the saved labels by `MeetingController`). Summary: "Saved Council meeting (2:58:12).
  Speakers labelled." or the exit's post-processing message ("… No speaker labels:
  speaker models are not installed.").
- `active` + (liveness `dead`, or `childExited` without an `exited` status) →
  `failed("The recorder stopped unexpectedly. Recover the saved audio from Meetings.")`,
  `setDictationPaused(false)`.
- `finishing` + (liveness `dead`, or `childExited` without an `exited` status) → `idle`,
  `finished(summary: "Saved Council meeting. Speaker labelling stopped; Holos will retry
  it, or use Label Speakers in Meetings.", speakersReady: false)`.
- `stopConfirmed` in `active` → `send(.stop)` once; repeats while already stopping are
  ignored. `pause`/`resume`/`marker` → `send`.
- `reviewOpened` → `clearNamingOffer`. `dismissFailure` → `idle`.

**UI.**

Status item: idle shows the existing waveform icon (with a small dot while a naming
offer is pending). While active its title is `● 1:23:45` (red `record.circle.fill`
plus monospaced digits from `status.elapsedSeconds`), `⏸ 1:23:45` when paused,
`◌ 1:23:45` while waiting for audio, with `⚠` appended while a warning is present.
While finishing: `waveform` plus `…`.

Menu while recording (dictation items are replaced, §4.12):

```
● Recording — Council meeting                      (disabled)
  1:23:45 · 0.9 GB used · 22.8 GB free               (disabled)
  Microphone: Built-in Microphone                    (disabled)
  Transcription: live   |   behind — will finish after stop
  ⚠ <warning message>                                (one line per warning, disabled)
  Pause Recording            |   Resume Recording
  Add Marker…                                        (prompt for an optional label)
  Show Live Transcript…
  Stop and Save…
──────────────
Dictation paused during meeting recording            (disabled)
──────────────
Meetings…
Setup…
About Holos
Quit Holos
```

"Stop and Save…" asks: "Stop and save “Council meeting”?" with the informative text
"Holos then labels speakers, which takes about 2 minutes for a 3-hour meeting. Keep the
lid open until it finishes." `[Stop and Save]` `[Keep Recording]`.

Idle menu: `Name Speakers — Council meeting…` at the top while offered (PR4 opens the
Meetings window with that session selected; PR9 opens Review), then
`Start Meeting Recording…`, the dictation items as today, and `Meetings…` above
`Setup…`. While finishing: `Saving Council meeting — labelling speakers 42%` (from
`status.progress`).

Start panel (`NSPanel`, titled "New Meeting Recording", 460 × ~380, floating like Setup):

```
Name      [Meeting 2026-09-23 14:00                     ]
Type      (•) In person — microphone
          ( ) Online call — microphone and system audio
                App   [Any app                      ▾]   (running apps with a bundle ID)
                [ ] Others are in the room with me (label speakers on my microphone too)
Mic       Built-in Microphone   |   AirPods Pro (system default)    (static label; red if unavailable)
People    [   ] expected (optional)                    (shown only if PR7c found the hint helps)
Disk      ≈1.0 GB for 3 h · 24.1 GB free                (orange = warn, red = refuse)
Speakers  Speaker labels ready   |   Speaker models not installed [Install…]
ⓘ Tell everyone you are recording.  [ ] Don't show this again
                                             [Cancel]  [Start Recording]
```

Start is disabled when `DiskPolicy.startCheck` refuses or, in person, the built-in
microphone is missing. The last settings are saved in `UserDefaults` key
`meeting.lastSettings` (JSON of `MeetingStartSettings` without the name); the consent
reminder's dismissal in `meeting.consentReminderDismissed`. The "People expected" field
exists only if `docs/speaker-evaluation.md` (PR7c) shows that the speaker-count hint
lowers joint-speech confusion or recovers merged speakers; otherwise PR4 omits it and
`expectedSpeakers` stays nil.

Setup window: a "Speaker labels" row with the status from `holos doctor --json`
(`speakerModels`) and an `Install (21 MB download)` button that runs
`holos setup --speakers` through `MaintenanceLauncher` and shows its progress.

Meetings window (`NSWindow` 760 × 460, resizable): table with columns Name, Date,
Duration (`savedSeconds`), State, Speakers, Size; buttons under it: `Recover…`
(interrupted or damaged-but-readable), `Label Speakers` (speaker state none, notLabelled,
failed, interrupted; runs `holos session diarize <path>`), `Show in Finder`,
`Open Transcript` (Quick Look preview of `exports/transcript.md`),
`Save Transcript As…` (NSSavePanel: md or txt), `Delete Audio…`, `Delete Meeting…`, and
`Clean Up` when `derivedBytes > 0`. Footer: "Meetings use 12.4 GB · 21.3 GB free".
Double-click opens the Quick Look preview (PR9 changes it to Review). Refreshes every
2 s while visible. Button enablement is `MeetingActionPolicy.enabled`, the rules of the
commands behind the buttons: Recover when `SessionRecoveryCommand.rebuilds` would rebuild
(asked with the catalog's readable transcript, so a `transcriptionIncomplete` or `incomplete`
meeting whose transcript cannot be read qualifies) or the meeting is interrupted, never for a
damaged manifest or a transcript from a newer Holos; Label Speakers for speaker state none,
notLabelled, failed, or interrupted with a readable transcript and audio, not interrupted. No
lease-taking action while the app uses the meeting or another process holds it (liveness
capturing, processing, maintenance).

Live transcript window: read-only text view with the last 500 `transcriptFinalized`
events from `events.jsonl`, `[01:02:03] Mic: …`, refreshed every second, scrolled to the
end unless the user scrolled up.

Interrupted prompt: after `attachOnLaunch`, for each interrupted session not in
`UserDefaults "meeting.promptedInterrupted"`: alert "Holos found an interrupted
recording: Council meeting (1:12:40 saved)." `[Recover]` `[Later]`. Recover runs
`holos session recover <path>` via `MaintenanceLauncher`.

Automatic relabel: on launch and every 30 s while idle, `AutoRelabelPolicy.candidates`
picks at most one session and `MaintenanceLauncher` runs `holos session diarize <path>
--json`; attempts are counted in `UserDefaults "meeting.relabelAttempts"`. This covers a
Mac shut down or put to sleep while labelling.

Naming offer: derived from saved state, never emitted per path
(`MeetingController.refreshNamingOffer`, rule `NamingOfferPolicy.offer`). Among recorded
meetings with liveness exited or dead whose labels are ready and were made in the last 7 days
(`SessionSummary.labelsReadyAt`, the head run's `createdAt`), the one labelled last is offered,
unless its speakers were edited or the user opened the offer for that run (UserDefaults
`meeting.namingOffersDismissed`, session ID → run ID; another run of the meeting is offered
again). It is derived on launch, when a followed recording finishes, and whenever the app's use
of a meeting ends (`endUsing`: a Meetings command, the interrupted prompt's Recover, Clean Up,
Save Transcript As…, the automatic relabel), so a meeting labelled after Holos quit, by a
command in a terminal, or by any of those paths is offered, also after a relaunch. Each change
is reported once, as `offerNaming` or `clearNamingOffer`; `reviewOpened` dismisses it.

Meetings in use: `MeetingController.sessionsInUse` (session ID → what the app is doing) is the
one set of meetings the app works on. Every operation of the app that takes a meeting's
processing lease, or reads it for the user, holds an entry while it runs (`beginUsing` refuses a
second one): Recover, Label Speakers, Delete Audio, Delete Meeting, the interrupted prompt's
Recover, Clean Up, Save Transcript As…, and the automatic relabel. The relabel skips these
meetings, every Meetings action refuses them, and the State column shows what is running.

Labels are ready (a finished meeting's `speakersReady`, the naming offer, the Label Speakers
result) only when `SavedSpeakerState` finds them usable, the validation the catalog, recovery,
and the exports share (`MeetingController.speakerLabelsReady`, run off the main actor);
`speakers/head.json` alone is not enough.

Launched recorders: the pid and start time of each recorder child are kept in
`UserDefaults "meeting.launchedRecorders"` until its exit is seen. A start timed out while a
permission prompt is open leaves a child with no session folder; after a quit or crash the
relaunched app refuses a new start ("The last recording is still stopping…") while that pid
still names a process with the saved start time.

Quit (`applicationShouldTerminate`) while `active`: alert "A meeting is recording."
Child mode: `[Stop and Save]` (send stop; `.terminateLater`; reply once the status phase
is `transcribing` or later, at most 10 s; the recorder finishes labelling on its own),
`[Keep Recording]` (quit the app only), `[Cancel]`. In-process mode: `[Stop and Save]`
shows progress and replies once the recording in the app has ended, at most 10 minutes;
`[Cancel]`. Labelling continues in its child: once the recording's post-process hook has
handed the lease over, the quit calls `InProcessLauncher.leaveLabellingToItsChild()`,
which cancels the recording task; the hook stops mirroring the child and returns a
`running` record, and the recording writes `exited` (post-processing `running`) before it
ends. Replying at phase `postprocessing` alone would kill the app while the recording
still waits for the child, leaving `status.json` stuck in `postprocessing`. The readiness
rule is `QuitReadiness.ready`; any quit while a recording still runs in the app waits.
Test `quitLeavesLabellingToTheChildAndEndsTheRecording`. An in-process
recording whose exited status could not be written yet (`ExitRetry` still retrying it and
holding the locks) has not ended: `InProcessLauncher` keeps it running, reports its exit
only once `status.json` says exited (or the retry stops because the folder is gone, as a
failure), and a quit waits for it the same way (`isRecording` stays true, `isWritingExit`).
Test `inProcessRecordingEndsOnlyOnceItsExitedStatusIsWritten`.

About Holos: `NSApp.orderFrontStandardAboutPanel(options: [.credits: …])` with the
credits text of §4.8 embedded as a string constant (the app has no resource bundle).

**Dictation pause.** §4.12. `HolosAppDelegate` gains `setDictationPaused(_ paused: Bool)`
called from `MeetingEffect.setDictationPaused`.

**Vocabulary.** The app passes `vocabulary: { corrections.vocabulary }` (the list
dictation uses). PR10 extends this closure with known people's names.

**build-app.sh.** Build both products (`swift build --product HolosApp` and
`--product holos`), copy `holos` to `Holos.app/Contents/MacOS/holos`, sign it with
`codesign --force --sign - --identifier ca.orlenko.holos.cli`, then sign the bundle as
today. Refuse to rebuild while a recorder runs from the bundle
(`pgrep -f "$PWD/build/Holos.app/Contents/MacOS/holos"`), with the same message style as
the existing app check: replacing the binary would invalidate the running recorder's
signature in the middle of a meeting.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `startLaunchesAndPausesDictation` | `startRequested` | `starting`; effects `launch`, `setDictationPaused(true)` |
| `recordingStatusMakesActive` | status phase `recording` | `active` |
| `missingFolderWhileStartingIsNotFailure` | liveness `dead`, no status, 3 s after start | still `starting` |
| `waitingForPermissionHint` | `tick` 6 s after start, no status | `announce("Waiting for permission…")` once |
| `startTimesOutAfterTwoMinutes` | `tick` 121 s after start | `terminateChild`; `failed` with the log path; `setDictationPaused(false)` |
| `childExitBeforeRecordingShowsLogTail` | `childExited(1, "The built-in microphone is unavailable…")` | `failed` with that text; no "Recover" |
| `freshStatusRecoversFromFailed` | `failed(id)`, then a fresh `recording` status for `id` | `active`; `setDictationPaused(true)` |
| `stopWhileStartingTerminatesChild` | `stopConfirmed` in `starting` | `terminateChild` |
| `captureStopResumesDictation` | status phase `transcribing` | `finishing`; `setDictationPaused(false)` |
| `exitedStatusFinishesAndOffersNaming` | phase `exited`, exit `complete`, post-processing succeeded | `idle`; `finished` with the name; `offerNaming` |
| `finishingDeadGoesIdle` | `finishing`; liveness `dead` | `idle`; `finished` with "Speaker labelling stopped…" |
| `deadRecorderFails` | `active`; liveness `dead` | `failed` with "Recover" text |
| `stopConfirmedSendsOnce` | `stopConfirmed` twice | one `send(.stop)` |
| `reviewOpenedClearsOffer` | offer pending; `reviewOpened` | `clearNamingOffer` |
| `launcherArguments` | mic+system, app `us.zoom.xos`, othersInRoom, expected 8, vocabulary file | exact argument array above |
| `spawnedChildInheritsNoLocks` | hold the speaker lock; spawn `/bin/sleep 2` with the launcher's spawn helper; release | a second descriptor acquires the lock at once |
| `controllerReattachesToLiveSession` | temp root with a fresh status and the writer lock held by the test | `attachOnLaunch` → `active` |
| `controllerFindsTerminalMeetingAfterLaunch` | idle; a new session's fresh status appears | `active` within one rescan |
| `controllerWritesControlFiles` | active; `pause()` | a valid `control/<id>.json` with command `pause` and `sentAtNanos` |
| `startRefusedOnLowDisk` | free 2 GB; mic | `start` throws; no launch |
| `inPersonStartRefusedWithoutBuiltInMic` | `builtIn == nil`; in person | throws; no launch |
| `callStartAllowedWithoutBuiltInMic` | `builtIn == nil`, default AirPods; call | launches |
| `vocabularyFileIsPrivate` | start with vocabulary ["Maria Chen"] | temp file 0600 with that list; path in the arguments |
| `autoRelabelPicksInterruptedRecentUnedited` | interrupted (recent, no edits), labelled, interrupted with edits, interrupted 10 days old, notLabelled (models missing) | only the first |
| `autoRelabelWaitsForModelsAndIdle` | models missing; or a meeting active; or 2 attempts | none |

**Manual checks.** H1–H3, H12, H13, H17, H19, H22 in §7, written into
`docs/meeting-validation.md`.

**Does not touch.** HolosSpeakers, profile store, `PeopleWindow*`, `RecordingWorkflow.swift`
internals (public API only), HolosDiarization, `MeetingPostProcessor.swift`,
`SpeakerEditor.swift`, CLI sources, README and `docs/status.md` (PR10 writes the wave-4
docs from PR4's "Docs note").

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
holos people list [--json]                 # "Remember voices: off" header, then one line per person
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
| `profileStoreIsPrivateLockedAndNotBackedUp` | two concurrent updates | both applied; 0600 / 0700; `isExcludedFromBackup` |
| `peopleExportOmitsEmbeddingsByDefault` | export | no `embedding` keys |
| `calibrationNeedsThreeMeetings` | 2 meetings with links | `--apply` refused |
| `calibrationPercentiles` | synthetic same/different distances | likely at the 1st and possible at the 5th percentile of different-person distances |

**Does not touch.** `MeetingController`, `MeetingStartPanel.swift`, `MeetingsWindow.swift`,
`build-app.sh`, `RecordingWorkflow.swift`, `Record.swift`, `Fakes.swift`.

### 5.10 PR9: Transcript review window (wave 5)

**Goal.** Name the speakers of a 3 h meeting in about 10 minutes: see speakers and
turns, play audio, reassign, merge, split, confirm suggestions in bulk, find more
speakers, undo, export.

**Files.**

- Add `Sources/HolosMeeting/Review/ReviewSession.swift` (`@MainActor`, no AppKit),
  `Sources/HolosMeeting/Review/SessionAudioComposition.swift`.
- Add `Sources/HolosApp/Review/`: `ReviewWindow.swift`, `SpeakerSidebarView.swift`,
  `TurnListView.swift`, `ReviewPlayer.swift`.
- Change `Sources/HolosApp/MeetingsWindow.swift` (`Review…` button; double-click opens
  Review when the session is labelled; the Delete Meeting alert gains "Also forget voice
  samples learned from this meeting"), `Sources/HolosApp/HolosApp+Meeting.swift` (the
  "Name Speakers — …" item opens Review and reports `reviewOpened`).
- Fill the "Review window (PR9)" section of `docs/meeting-validation.md`. PR9 merges
  last in wave 5 and writes the wave-5 `README.md` and `docs/status.md` notes for PR9 and
  PR11.
- Tests: `Tests/HolosMeetingTests/{ReviewSessionTests, AudioCompositionTests}.swift`.

**API.**

```swift
@MainActor public final class ReviewSession {
    /// Loads the snapshot off the main actor. `exportDelay` debounces export regeneration.
    public init(session: URL, profiles: SpeakerProfileStore?, maintenance: MaintenanceLauncher?,
                exportDelay: Duration = .seconds(2)) async throws
    public private(set) var snapshot: SpeakerSessionSnapshot
    /// What the window shows: updated at once by each edit (`SpeakerProjection.applying`), then replaced by the
    /// editor's result.
    public private(set) var projection: SpeakerProjection
    public var onChange: (() -> Void)?
    /// "Learn voices of people I name in this meeting"; defaults to the global "Remember voices" setting.
    public var learnVoices: Bool
    public func turns(matching query: String) -> [ProjectedTurn]            // case-insensitive text search
    public func nextUncertain(after turnID: String?) -> ProjectedTurn?        // wraps around
    /// Up to three clips from the speaker's longest non-overlapped turns:
    /// [start + 0.25, min(end, start + 4.25)], or the whole turn when shorter.
    public func sampleClips(for speakerID: String) -> [ClosedRange<Double>]
    /// The first 60 characters of the speaker's two longest turns.
    public func previews(for speakerID: String) -> [String]
    public func knownPeople() -> [SpeakerProfile]
    /// Edits run in order on a serial queue off the main actor (SpeakerEditor, regenerateExports: false).
    /// A refused edit reloads the snapshot and throws. Pushes undo; schedules exports.
    public func apply(_ actions: [SpeakerEditAction]) async throws
    public func undo() async throws                                           // this window's newest batch
    public func link(speakerID: String, to target: ProfileTarget) async throws   // learnVoice: learnVoices
    public func confirmAllSuggestions() async throws
    public func markSelf(speakerID: String) async throws   // passes learnVoices to VoiceProfileService.markSelf
    public func rejectSuggestion(speakerID: String) async throws
    /// `holos session diarize --force --min-speakers <current + 1>`; names carry over (§4.9).
    public func findMoreSpeakers() async throws
    /// `holos session diarize --force --others-in-room` (call recordings).
    public func labelMicrophoneSpeakers() async throws
    /// Regenerates exports now if an edit is pending. Call when the window closes.
    public func close() async
}
public enum SessionAudioComposition {
    /// One composition track per session track; every chunk inserted at its session start time, trimmed so
    /// that no chunk overlaps the previous one.
    public static func make(session: URL, manifest: SessionManifest) throws -> AVMutableComposition
}
```

**UI** (`NSWindow` 1100 × 720, min 900 × 560, title "<name> — Review"):

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ [▶] 01:12:03 / 2:58:12  [Next Uncertain ⌘']  [Assign to… ▾]  [Split Turn]  [🔍 Search]  [Export ▾] │
├──────────────────────────────┬───────────────────────────────────────────────────────────────┤
│ SPEAKERS  [Confirm All (3)]  │ 01:12:03  [Jim ▾]         We should move the vote to next week. │
│ [Jim            ▾]    41:12  │ 01:12:40  [Speaker 3 ▾] ⚠ overlap  Agreed, but the budget…      │
│   "We should move the vote…" │ 01:13:05  [Unknown ▾] ⚠  …                                     │
│   ▶ Play samples             │                                                               │
│ [Speaker 3      ▾]    22:03  │                                                               │
│   Maybe Maria [Confirm] [Not Maria]                                                          │
│   This is me · Merge into… ▾ │                                                               │
│ Me                    15:40  │                                                               │
├──────────────────────────────┴───────────────────────────────────────────────────────────────┤
│ [x] Learn voices of people I name in this meeting    11 speakers · 343 turns · 5 changes · saved 17:12 │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

- Sidebar row: a name combo box (known people, most recently used first; Return links
  or creates the person; empty clears the name), talk time, the first 60 characters of
  the speaker's two longest turns, Play samples, a suggestion "Maybe Maria" with
  Confirm / Not Maria, "Jim (auto)" with Not Jim once calibrated, "This is me", Merge
  into… Speakers with no turns are hidden (except user-created ones).
- Turn row: timestamp button (plays from there), speaker pop-up (all speakers, known
  people, "Unknown", "New Speaker…"), warning glyph for uncertain turns, text
  (wrapping). Multi-select with ⇧/⌘.
- Keys: Space play/pause; ↑/↓ move selection; 1–9 assign the selection to the speaker
  with that ordinal; ⌘' next uncertain; ⌘Z undo; ⌘F search; ⌘E export menu.
- Menu "Speakers": Confirm All Suggestions, Find More Speakers… (explains that names
  carry over and turn-level changes do not), Label Speakers on My Microphone (call
  recordings recorded without "others in the room").
- Export ▾: "Save As…" (NSSavePanel; Markdown, text, or JSON) and "Copy as Markdown".
- No modal prompts for voices: the footer checkbox decides whether naming a person
  learns their voice.
- Status line in plain words: "5 changes · 2 could not be applied (show)", "Your edited
  transcript.md was kept as edited-20260923-171200.md", "The transcript changed after
  speakers were labelled. [Label Again]", and "Audio deleted; playback is off."
- Heavy work (snapshot load, edits, export regeneration) runs off the main actor (§1.3).

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `nextUncertainWrapsInTimeOrder` | uncertain T3, T9 | after T9 → T3 |
| `searchIsCaseInsensitive` | "BUDGET" | turns containing "budget" |
| `sampleClipsPickLongestNonOverlapped` | turns 10 s, 6 s (overlap), 3 s, 8 s | clips from the 10 s, 8 s, 3 s turns; lengths 4, 4, 3 |
| `previewsShowTwoLongestTurns` | turns of 3 lengths | the two longest, each ≤ 60 characters |
| `assignSelectionIsOneBatch` | assign T4, T5, T6 | one `reassignTurns` line |
| `projectionUpdatesBeforeWriteCompletes` | editor delayed 0.5 s (test seam) | `projection` shows the change at once; the snapshot updates later |
| `refusedEditReloads` | head changed underneath | `apply` throws; snapshot reloaded to the new head |
| `undoIsLastInFirstOut` | two edits, two undos | reverts in reverse order |
| `confirmAllIsOneUndo` | 3 suggestions; confirm all; undo | all three links reverted |
| `exportsRegenerateAfterDelayAndOnClose` | edit with 0.1 s delay; then edit and close | exports updated after the delay; close flushes |
| `compositionPlacesChunksAtSessionTimes` | chunks 0–30, 30–60, 65–95 (mic) | composition segments at those times; total 95 s |
| `compositionTrimsOverlappingChunks` | legacy chunks 0–30 and 29.8–60 | second inserted from 30.0; no overlap; total 60 s |

**Manual.** H14 and H20 in §7.

**Does not touch.** HolosSpeakers algorithms, `MeetingStartPanel.swift`, `HolosApp.swift`,
profile store, CLI, `Package.swift`, `Fakes.swift` and `SessionFixtures.swift` (PR11 owns
them in wave 5).

### 5.11 PR11: Online-call refinements (wave 5)

**Goal.** Cleaner call transcripts: drop microphone echo of system audio, hide
microphone clusters that are mostly echo, and warn when laptop speakers are the output.
("Mic = Me" is a track policy in PR5a/PR7b and condition-tagged samples ship in PR10;
resolution R13.)

**Files.**

- Add `Sources/HolosSpeakers/EchoFilter.swift`, `Sources/HolosAudio/OutputRoute.swift`.
- Change `Sources/HolosSpeakers/SpeakerRunBuilder.swift` (apply the filter when
  `parameters.echoWindowSeconds != nil`; a microphone cluster with at least 60 % of its
  words dropped as echo is not listed and its remaining turns become unknown speaker),
  `Sources/HolosMeeting/PostProcessing/SpeakerAnalysis.swift` (call sessions use
  `AlignmentParameters.v1` with `echoWindowSeconds = 1.0`),
  `Sources/HolosApp/MeetingStartPanel.swift` (warning line),
  `Sources/HolosMeeting/RecordingWorkflow.swift` (set `echoRisk` at start and after
  device changes in call mode), `Sources/HolosCLI/Record.swift` (stderr warning).
- Fill "Online calls (PR11)" in `docs/meeting-validation.md`, including the hybrid case
  of H16.
- Tests: `Tests/HolosSpeakersTests/EchoFilterTests.swift`, `Tests/HolosAudioTests/OutputRouteTests.swift`
  (pure classification only). PR11 owns `Fakes.swift` and `SessionFixtures.swift` edits
  in wave 5.

**API.**

```swift
public enum EchoFilter {
    /// Microphone spans to drop: runs of at least `echoMinRunWords` consecutive mic words whose normalized
    /// text (lowercased, letters and digits only) equals, in order, consecutive system words, each mic word
    /// within ±echoWindowSeconds of its system counterpart.
    public static func echoSpans(transcript: Transcript, parameters: AlignmentParameters) -> [WordSpan]
}
public struct OutputRoute: Sendable, Equatable {
    public var name: String
    public var isBuiltInSpeakers: Bool
    /// Default output device: transport built-in and data source 'ispk' → speakers; 'hdpn' → headphones.
    public static func current() -> OutputRoute?
    /// Pure classification used by `current()`, for tests.
    public static func classify(transportType: UInt32, dataSource: UInt32?) -> Bool
}
```

Dropped words go to `run.droppedWords` with reason `echo` and appear in no turn and no
export. Warning text (start panel, CLI, `echoRisk`): "The laptop speakers are playing
the call, so other people's voices also reach your microphone. Headphones give a
cleaner transcript."

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `threeWordEchoRunIsDropped` | system "we should vote now" at 10.0–11.2; mic same words at 10.3–11.5 | mic span of 4 words dropped |
| `singleMatchingWordIsKept` | mic "yes" matching system "yes" | kept |
| `outsideWindowIsKept` | same words 1.5 s later | kept |
| `droppedWordsExcludedFromTurnsAndExports` | run with echo | words absent from turns and Markdown; listed in `droppedWords` |
| `echoHeavyMicClusterIsHidden` | mic cluster with 70 % of its words dropped as echo | cluster not listed; its remaining turns unknown speaker |
| `inPersonSessionsDoNotFilter` | meeting mode inPerson | no spans |
| `builtInSpeakersClassification` | ('bltn', 'ispk'), ('bltn', 'hdpn'), (USB, nil) | true, false, false |

**Does not touch.** `Sources/HolosApp/Review/*`, `ReviewSession.swift`, `MeetingsWindow.swift`,
`SpeakerProjection.swift`, `Package.swift`, README and `docs/status.md` (PR9 writes the
wave-5 docs from PR11's "Docs note").

## 6. Waves and merge rules

Every wave branches from `main` after the previous wave has merged. Within a wave, `∥`
PRs are independent and `→` PRs are stacked (the later one branches from the earlier
one's branch and is rebased after it merges). The listed merge order decides who
rebases. After each merge, `swift build` and `./scripts/test.sh` must pass on `main`.
Delete each worktree and its `.build` (about 1.6 GB with FluidAudio) after its PR
merges; free disk is about 24 GB.

| Wave | PRs, merge order | Shared files and owner | Last-merged PR does |
|---|---|---|---|
| 0 | PR6 | none | writes its own README/status notes |
| 1 | PR5a → PR5b → PR5c → PR1 | `Package.swift`: PR5a adds HolosSpeakers; PR1 adds HolosMeeting and, rebasing last, the HolosMeeting → HolosSpeakers dependency (§1.2). `HolosMeetingTests/Fakes.swift`: PR1. | PR1 resolves `Package.swift` to §1.2 and writes the wave-1 notes |
| 2 | PR7a → PR7b → PR2a → PR2b → PR7c | `Package.swift`, `PostProcessing.swift`, `Doctor.swift`: PR7a only. `MeetingPostProcessor.swift`: PR7b only. `Session.swift` `subcommands:`: PR7b adds `Diarize`, PR7c adds `Import`, `Score`. `RecordingWorkflow.swift`, `LiveTrack.swift`, `TrackReplayer.swift`, `Record.swift`, `ChunkWriter.swift`, `AudioCapture.swift`: PR2a, then PR2b. `Fakes.swift` and `SessionFixtures.swift`: PR7b. | PR7c writes the wave-2 notes |
| 3 | PR8 → PR3 | `Session.swift` `subcommands:` (PR8 adds `Export`; PR3 adds `List`, `Delete`): keep all. `Fakes.swift`, `SessionFixtures.swift`: PR8. | PR3 writes the wave-3 notes |
| 4 | PR4 → PR10 | `Package.swift` HolosApp dependencies (identical edit). `HolosApp.swift` and `HolosApp+Meeting.swift`: PR4 owns; PR10 adds one menu line and one vocabulary expression. `Fakes.swift`, `SessionFixtures.swift`: PR4. | PR10 writes the wave-4 notes |
| 5 | PR11 → PR9 | `docs/meeting-validation.md`: separate sections created by PR4. `Fakes.swift`, `SessionFixtures.swift`: PR11. | PR9 writes the wave-5 notes |

Conflict rules:

- Subcommand arrays and dependency lists: keep both sides, one item per line, and
  compare with the final text in this document.
- A contract file (§3) that differs from its §3.0 digest without an allowed addition is
  a bug: stop and report it.
- Never resolve a conflict by deleting another PR's tests.
- Final subcommand lists after wave 5:
  - `holos`: `Doctor, Setup, Transcribe, Record, Session, Speakers, People, Voices, Say, Read`
  - `holos record`: `Start, Status, Stop, Pause, Resume, Marker`
  - `holos session`: `Inspect, List, Recover, Retranscribe, Diarize, Import, Export, Score, Delete`
  - `holos speakers`: `List, Rename, Merge, Assign, Split, Exclude, Undo, Link, Me, Reject`
  - `holos people`: `List, Remember, Rename, Merge, Forget, Export, Calibrate`

Documentation ownership:

| File | Owner |
|---|---|
| `README.md`, `docs/status.md` | the last-merged PR of each wave, covering every PR of the wave (the others put a "Docs note" in their descriptions) |
| `docs/contracts.md` | PR1 |
| `docs/design.md`, `docs/implementation.md` | PR10 |
| `docs/hardware-validation.md` | PR2a appends "Long recordings"; S2 results go here too (not a PR) |
| `docs/meeting-validation.md` | PR4 creates; PR9 and PR11 fill their sections |
| `docs/voice-profile-validation.md` | PR10 |
| `THIRD_PARTY_NOTICES.md` | PR7a |
| `docs/speaker-evaluation.md` | S1 (not a PR); PR7a appends fixture numbers; PR7c appends its evaluation and calibration numbers |

## 7. What is verified automatically and what needs the user's hardware

### 7.1 Automated (agents may run these)

| Area | Check |
|---|---|
| Build | `swift build` of all targets after every PR; `swift build --target HolosSpeakers` has no FluidAudio |
| Contracts | `shasum -a 256 Sources/HolosCore/{HolosJSON,MeetingModels,SpeakerModels}.swift` matches §3.0 after wave 0 |
| Unit tests | every test in §5, via `./scripts/test.sh --filter <Target>Tests` and the full suite, with `HOLOS_DATA_DIR` and `HOLOS_SUPPORT_DIR` in a temporary folder |
| Recorder logic | state machine (restarts, waiting, sleep, dark wake, pause limit), disk policy, control inbox ordering, liveness, status heartbeat, epochs, frame continuity, capture pump, stop-path timeouts, coverage-based replay, lease hand-off, all with fakes |
| Storage | locks, lease, close-on-exec, atomic writes, failed appends, corrupt journal lines, transcript pointer, old archives inspect clean, Int16 round trip, deletion |
| Speakers | alignment (flicker rules, offset estimate), projection, compare-and-append, carry-over, exporters (block merging, no vectors, evaluator regex), DER, recognition tiers, enrollment |
| Post-processing | end to end with `FakeDiarizer` on generated audio and transcripts; render gap compression; disk skip; voice data only when allowed; exports protected; failures recorded |
| Model verification | tree digests, revision marker, and pinned-manifest checks on fake files; with models installed, `holos doctor` reports `verified` |
| Opt-in fixtures | `HOLOS_DIARIZATION_FIXTURE=1`: 3 synthetic voices → 3 clusters, DER < 10 % (needs `holos setup --speakers`, which downloads models; no microphone). `HOLOS_SPEECH_FIXTURE=1`: rebased speech sessions give absolute word times within ±0.3 s (installed speech assets; no microphone) |
| Otter evaluation | `swift scripts/evaluate-references.swift --reference-format otter --speakers [--calibrate] …` on the three private recordings: speaker counts, agreement confusion per configuration, runtime, peak RSS, track offsets, calibration percentiles. Counts and metrics only; temporary sessions deleted. |
| CLI on imported audio | `holos session import` of a generated or Otter file, then `session diarize`, `speakers list`, `speakers rename`, `session export`, `session delete --audio-only`, all without a microphone |

### 7.2 Hardware checklist (the user; recorded in the docs named)

| ID | PR | Check | Pass |
|---|---|---|---|
| H1 | S2, PR4 | Start a meeting from the menu; note which app macOS names in the microphone and screen/system-audio prompts; rebuild the app and repeat | prompts name Holos; while a prompt is open the menu says "Waiting for permission…"; recording works; note whether permission survives a rebuild |
| H2 | PR4 | `kill -9` Holos.app one minute into a recording; wait; relaunch | recorder keeps writing (`status.json` `sequence` grows); relaunched menu shows the meeting with the right elapsed time; Stop works; no audio gap |
| H3 | PR3, PR4 | `kill -9` the recorder process | within 10 s the menu says it stopped; Meetings shows "interrupted" with the saved duration; Recover rebuilds the transcript; loss ≤ one 30 s chunk |
| H4 | S2, PR2 | Lock the screen for 10 minutes during mic and mic+system recordings | recording continues; or, if system audio stops, the menu shows "Audio unavailable", recording resumes after unlock without any action, and the export marks the gap |
| H5 | PR2 | Close the lid on power for 2 minutes, reopen | capture resumes in the same session; the menu shows the resume warning; Markdown has a "computer was asleep" line |
| H6 | PR2 | Close the lid on battery for 20 minutes while recording | recording ends at the sleep point; after wake the transcript and labels exist |
| H7 | PR2 | Connect and disconnect AirPods during an in-person recording, then during a call recording | in person: stays on the built-in microphone (listen to the chunks), no stall over 3 s; call: follows the new default with an "Audio restarted" gap |
| H8 | S2, PR7 | A real in-person meeting (≥ 3 people, ≥ 20 min) on the laptop microphone | audio intelligible; speaker count within ±1 of the people who spoke |
| H9 | PR2, PR7 | 3 h soak, mic+system, audio playing | recorder RSS growth < 100 MB/h (`ps -o rss` hourly); ≈ 0.69 GB/h written; system audio is a proper mono mix; no unexplained `audioDiscontinuity`; labelled transcript ≤ 5 min after stop; diarization peak RSS < 4 GB |
| H10 | PR2 | Record into a small disk image (`hdiutil create -size 2g`, `HOLOS_DATA_DIR` on it) | start warns or refuses per §4.5; recording stops by itself below 500 MB with audio saved; speaker labelling is skipped with the disk message |
| H11 | PR2 | Pause a meeting, close the lid for 20 minutes, open it | the meeting is still paused; Resume continues it in the same session |
| H12 | PR4 | During a meeting, hold Right Option in a text field | no dictation; the key reaches the app; the menu shows only "Dictation paused during meeting recording"; dictation works again after stop |
| H13 | PR4 | Quit during a recording: each choice | behaves as §5.8 |
| H14 | PR9 | Import the 89-min Otter meeting and label it from scratch in the review window | done in under 10 minutes |
| H15 | PR10 | Turn on Remember voices; confirm a speaker in meeting A; record or import meeting B with that person | B suggests them ("Maybe …"); Forget removes the suggestion next time |
| H16 | PR11 | A call on laptop speakers; then a hybrid call (laptop speakers, two people in the room, "Others are in the room" checked) | warning shown; echoed phrases absent; room speakers labelled on the microphone track; no speaker made only of echo |
| H17 | PR4 | Consent reminder "Don't show this again" | stays hidden on the next start |
| H18 | S1/PR7 | User hand-labels a 10–15 min slice of the 89-min meeting | DER (0.25 s collar) ≤ 20 % on that slice; speaker count within ±1 on all three Otter meetings |
| H19 | PR4, PR7 | Record a meeting before installing speaker models; then install from Setup | the finished message says "No speaker labels: speaker models are not installed"; Setup installs them; Label Speakers then works |
| H20 | PR9 | A real 3 h council meeting | all speakers named in ≤ 10 minutes of the user's time; note how many Find More Speakers, split, and merge actions were needed |
| H21 | PR2 | A call with AirPods | the "Me" track is the headset microphone (listen); room sounds are not on it |
| H22 | PR4 | Stop a meeting and shut the Mac down at once; start it again and open Holos | the meeting is labelled automatically within a minute or two |

## 8. Resolutions log

Ambiguities in the plan, resolved here. R1–R42 date from the first draft (updated where
the review changed them); R43 onward come from the review (§10).

| ID | Question | Resolution |
|---|---|---|
| R1 | HolosMeeting depends on HolosDiarization (plan §2)? | No. HolosMeeting takes `any SpeakerDiarizer`; only HolosCLI links HolosDiarization; the app never links FluidAudio and runs diarization in a `holos` child. |
| R2 | FluidAudio's default trait links a prebuilt text-normalization binary | Keep default traits: S1 found `traits: []` failed to link (incremental build). The binary is Apache-2.0 and credited. |
| R3 | New error types for disk full, capture gap, etc.? | Keep `HolosError`; carry reasons as data (`StopReason`, warnings, `ControlResult`). |
| R4 | `record start --status-file` | Dropped: `status.json` is always written. |
| R5 | `status.json` "removed at finish" | Kept after exit with `phase: exited` so a relaunched app can show the outcome; staleness is judged by locks, pid, and the heartbeat. |
| R6 | How does the app find the child's session? | The app assigns it with `--session-id`. |
| R7 | Post-processing before or after `archive.finish`? | After, with the processing lease taken before `finish` and handed to post-processing (§4.6). |
| R8 | `withProcessingLock` "for one write" vs long processing | Two locks: `withSpeakerLock` (one write) and `ProcessingLease` (one run, or one recover → rebuild → post-process chain). |
| R9 | Re-diarization and existing edits | Names, profile links, and rejections carry to the new run by shared speech time; turn-level edits stay in the journal under the old run and are reported as not carried. `--force` is required to replace an edited head. `--use-run` is deferred. |
| R10 | Are turns persisted or recomputed? | Persisted in the immutable run, so edit targets (turn IDs, word refs) never shift. |
| R11 | Per-segment embeddings (S1 question) | FluidAudio 0.17.1's segment `embedding` is the cluster centroid; per-window embeddings come from `exposeChunkEmbeddings`; turn embeddings are averaged from those windows. They are persisted only in `speakers/voice/` while "Remember voices" is on. Superseded by the Codex review (§10.1): embeddings are never persisted by post-processing; samples are extracted on demand for confirmed people. |
| R12 | `--portable` and privacy | No session export contains vectors; `--portable` is gone. `holos people export` includes embeddings only with `--include-voiceprints` and a warning. |
| R13 | "Mic = Me" and condition tags in PR11 | Mic = Me is a track policy in PR5a/PR7b; condition tags ship with samples in PR10; PR11 keeps echo removal and the headphone warning. |
| R14 | "Notify" after resuming from sleep | Menu and status-item warning only; no user notifications (they need a new permission). |
| R15 | Dark wake and closed lid | Resume only with the lid open; `sleepStart` and the phase before sleep are set only on the transition into sleep; the 15-minute limit uses continuous time and also triggers from the 1 s tick. |
| R16 | Pause dictation for terminal-started recordings? | Yes, for any live meeting under the default sessions root, found by the idle rescan. |
| R17 | "Built-in mic only" when AirPods connect | In person: pinned to the built-in microphone. Calls: the system default input (Q2). |
| R18 | What does pause do? | Stops capture (the microphone indicator goes off) and releases the idle-sleep assertion; session time keeps running; the gap is marked; 6 h paused ends the recording. |
| R19 | SpeechAnalyzer and timestamp jumps (plan risk) | A new speech session at every epoch boundary or gap over 1 s, and every session is rebased to 0 with its base added back. |
| R20 | Transcript coverage for recovery | Prefix up to the last finalized segment end per track, capped at the earliest `transcriptionBehind`; `transcriptFinalized` events carry `segmentID` and `words`. |
| R21 | Disk checks "at each chunk close" | Every 1 s tick; the budget includes the 16 kHz render; rendering needs 1 GB of headroom. |
| R22 | Exit status for saved-with-problems | `3` for automatic stops and partial or failed post-processing; transcription incomplete keeps exit `1`. |
| R23 | `exports/transcript.txt` content | Speaker blocks in the Otter layout (was speaker-less text). New code saves transcripts with `writeLegacyExports: false`. |
| R24 | How to diarize the Otter recordings with Holos | `holos session import` plus hidden `holos session score` (numbers and hashed labels only). |
| R25 | DER against Otter | Otter turns include silence, so the Otter metric is "agreement" over frames where both sides have a speaker; full DER only on the synthetic fixture and the user's hand-labelled slice. |
| R26 | Recognition when "Remember voices" is off | Off disables voice data, samples, and recognition. Names are still kept. |
| R27 | Name loss after forgetting a profile | Linking also appends a rename, so sessions keep the confirmed name. |
| R28 | Uncertain names in exports | An automatic name shows as "Jim (auto)" in the UI and exports; suggestions are never exported. v1 produces no automatic names until calibrated. |
| R29 | Meetings window has no PR in the plan | PR4 builds it; PR9 adds Review. |
| R30 | Signals | Recorder ignores SIGPIPE; SIGINT and SIGTERM stop gracefully; SIGHUP unchanged (Q6). |
| R31 | Stop path | `holos record stop` sends a control request; `stop.request` still honoured; `control.json` no longer written. |
| R32 | Marker time | Session time when the recorder handles the request (≤ 100 ms after it is written). |
| R33 | Rebuilding while a recorder runs from the bundle | `build-app.sh` refuses, like it does for the app. |
| R34 | Echo filter false positives on "yes"/"okay" | Only runs of 3 or more matching words are dropped. |
| R35 | Speakers with no turns | Hidden, except user-created ones. |
| R36 | Speaker-lock wait | 2 s timeout, then a "try again" error; editors regenerate exports after releasing the lock. |
| R37 | IDs | `T<n>` turns; split parts `<id>/<editID>`; `user:<UUID>` speakers; one `batchID` per editor call. |
| R38 | Journal order and time precision | File order is authoritative in journals; control requests by `sentAtNanos`; nothing is ordered by a date. |
| R39 | Recognition thresholds | Suggestions only by default; `possibleMaxDistance` from PR7c's cross-recording calibration; `likely` only after `holos people calibrate --apply`. FluidAudio's 0.65 does not apply. |
| R40 | Where do shared value types go? | The three contract files, all added by PR6 in wave 0. |
| R41 | Block-wise diarization fallback (plan §4 step 3) | Not built: S1 measured 1.8 GB peak RSS for 3 h in one pass; tracks run one at a time. Revisit only for recordings longer than 3 h. |
| R42 | Keeping diarization offline and models verified | `OfflineDiarizerModels.load` + `initialize` under `ModelHub.offlineMode = true` (never `prepareModels`); verify the revision marker and every file's SHA-256. |
| R43 | Brief audio loss | `waiting` phase with backoff and immediate retries on wake, lid, unlock, and device changes; the meeting ends only after 10 minutes without audio. |
| R44 | Disk latency during capture | Capture pump (60 s per track), off-main consumer, journal group commit; overflow drops and marks audio instead of failing. |
| R45 | Session time origin | Epoch 0's capture origin; epoch offsets never overlap; 50 ms continuity rule. |
| R46 | Hand-off from recording to labelling | Lease before `finish`; `status.json` heartbeat; lifecycle in `RecordingWorkflow` for both launchers. |
| R47 | Liveness during maintenance | `maintenance` liveness; maintenance commands mark a dead recorder's status `exited`. |
| R48 | Stale edit views | Compare-and-append against the caller's view; refused edits write nothing. |
| R49 | Voice embeddings of every participant | Stored only in `speakers/voice/` while "Remember voices" is on; never in runs or exports. Superseded by the Codex review (§10.1): embeddings are never persisted by post-processing; samples are extracted on demand for confirmed people. |
| R50 | Names without voiceprints | People exist without samples; names carry across meetings whatever the setting. |
| R51 | Export formats | Markdown, text, JSON; md and txt merge consecutive turns of one speaker; hand-edited exports are moved aside, never overwritten. |
| R52 | Retention | Delete Audio and Delete Meeting; system audio recorded mono. No automatic expiry in v1 (Q12). |
| R53 | Labelling interrupted by shutdown | Automatic relabel; a "Name Speakers" menu entry after each meeting. |
| R54 | Recognition vocabulary | The dictation vocabulary (and known people's names) reaches every meeting speech session. |
| R55 | Sleep while paused | Stays paused (up to the 6 h pause limit); to confirm (Q1). |
| R56 | Call-mode microphone | System default input; to confirm (Q2). |
| R57 | Long pauses and render size | Gaps over 60 s become 5 s in the render; times map back. |
| R58 | Timing bias between speech and diarization | Estimated per track (±0.5 s) and recorded in the run. |
| R59 | PR structure | Wave 0 for PR6; PR5, PR7, and PR2 split into parts; one owner per wave for shared test helpers. |
| R60 | Scope cut from the first draft | Meeting hotkey, SRT/VTT, `reassignRange`, `--use-run`, the SIGHUP change. |
| R61 | Removing an in-camera discussion | `GapReason.redacted` reserved and the scrub list written down; the command is a follow-up (Q7). |

## 9. Open questions

None of these blocks wave 0 or wave 1. Q1, Q2, Q6–Q8, and Q12 are the user's choices (Q9 is resolved);
Q3–Q5 are answered by S2 and hardware runs; Q10–Q11 by PR7c and a later build
experiment.

1. **Sleep while paused (refines decision 5).** The design keeps a paused meeting paused
   through any sleep, up to 6 hours of pause, instead of ending it after 15 minutes
   asleep. Council breaks and in-camera items then do not split the meeting. Confirm.
2. **Call microphone (refines decision 9).** Online calls record the system default
   input (a headset or AirPods if the call uses them); in-person meetings record the
   built-in microphone. Confirm.
3. **S2:** does macOS credit microphone and system-audio permission to Holos.app for the
   bundled child (decides the default launcher)? Does ScreenCaptureKit keep delivering
   under screen lock? If not, the `waiting` phase keeps the meeting alive; a separate
   AVAudioEngine microphone capture in calls is the follow-up (§4.2).
4. Does ScreenCaptureKit deliver buffers of silence when nothing is playing? If not, the
   system-track stall warning must be reworded or suppressed (the system track is never
   restarted for a stall).
5. Does pinning AVAudioEngine's input to the built-in device hold when AirPods connect on
   macOS 27, and does ScreenCaptureKit's `channelCount = 1` give a proper mono mix? (H7,
   H9.)
6. **SIGHUP.** Today closing the terminal kills a terminal-started recorder (the audio up
   to the last chunk is recoverable). Keep that, or treat SIGHUP as a graceful stop?
   The app-launched recorder is not affected either way.
7. **Redaction.** Build `holos session redact` and a Review command "Remove Selection
   from Recording…" as a follow-up after v1?
8. **Automatic names.** v1 only suggests names. `likely` (applied as "Jim (auto)")
   needs `holos people calibrate --apply` on at least 3 confirmed meetings. Is a hidden
   command acceptable, or should the People window offer "Calibrate from my meetings"?
9. **Voice data of unnamed speakers.** Resolved (Codex review, §10.1): post-processing
   never persists voice data for anyone; a voiceprint is stored only as a sample of a
   person the user confirmed with voice learning on. Nothing to expire.
10. FluidAudio's default trait links a prebuilt text-normalization binary the diarizer
    never uses (R2). A clean-build retry of the opt-out could drop it.
11. **PR7c measurements:** whether `exclusiveSegments = false` keeps agreement with Otter;
    whether a speaker-count hint recovers merged speakers (decides the "People expected"
    field); the calibration distances; and how much agreement drops in a real 3 h
    meeting (S1's synthetic 3 h file rose from 5.2 % to 11.2 % confusion; H20).
12. **Retention.** v1 deletes only when the user asks. Add an optional "delete audio
    after N days" later?

## 10. Design review log

A three-lens review (correctness, product, buildability) of the first draft produced 80
findings (4 blockers, 39 majors, 37 minors). Each is listed with its disposition. IDs:
C = correctness, P = product, B = buildability. "Merged" points to the finding that
carries the change.

Facts checked locally while applying them: the FluidAudio 0.17.1 checkout
(`OfflineDiarizerManager`, `OfflineDiarizerModels.load`, `AudioSampleSource`,
`ChunkEmbedding`, `withSpeakers`, `ModelHub.offlineMode`, `SpeakerManager.speakerThreshold
= 0.65`, top-level `AudioSource` and `WordTiming`), the S1 model cache
(`speaker-diarization/`, `.fluidaudio-revision`, `config.json` = `{}`, per-file SHA-256 in
`provenance.json`), the model card's `NOTICE.md` and `README.md` citations at
`df2625ac`, and the Holos sources the findings cite (`AudioCapture` fails on overflow;
`LiveTrack` uses 64-frame and 128-segment queues; `ChunkWriter` tolerates one sample;
`SessionArchive.append`, `saveTranscript` and its legacy exports;
`AppleSpeechSession.make(contextualStrings:)`; `changeShortcut` and
`suspendForSessionChange` in `HolosApp.swift`; "Human edits are retained on
reprocessing" in `docs/contracts.md`).

| ID | Sev | Finding | Disposition |
|---|---|---|---|
| C1 | blocker | Three fast retries end the meeting on brief audio loss; `RecorderPhase` could not grow after wave 1 | Accepted. `RecorderPhase.waiting`, `audioUnavailable` warning and gap reason, `captureWaiting` event in the wave-0 contract; backoff 0.5 → 30 s; immediate retry on wake, lid open, unlock, device-list change; finish only after 10 min without audio; only `SCStreamError.userStopped` counts as a user stop (§4.2). A separate AVAudioEngine microphone in calls waits for S2 (no interface change). Tests `failFiveTimesThenRecover`, `waitingTimesOutAfterTenMinutes`, `retryOnScreenUnlockAndDeviceChange`. |
| C2 | blocker | Rebuild refuses its own lease; lease → writer breaks lock order; locks released between recover steps | Accepted. `openForMaintenance(at:lease:)`, `recover(at:lease:)`, and lease parameters on rebuild and post-processing; one lease across recover → rebuild → post-process; lock rules restated (§1.7); moved into PR6. Tests `recoverRebuildAndPostProcessUnderOneLease`, `rebuildSavesWhileHoldingItsOwnLease`. |
| C3 | major | Disk stalls (fsync, manifest rewrite) end the capture | Accepted, with one change: `ChunkWriterPump` (60 s per track) and an off-main consumer remove disk from the capture path; capture overflow drops and marks `overflow`; journal group commit once per second (PR6). Chunk registration stays on the writer task, where the pump absorbs its latency. Tests `pumpAbsorbsSlowWriter`, `pumpDropsBeyondCapacityAndMarksOverflow`, `captureOverflowDoesNotFail`. |
| C4 | major | Clock starts before capture; overlapping epochs and chunks | Accepted. Session time 0 = epoch 0's capture origin; clock anchored there; epoch offset `max(now, lastFrameEnd + 0.01)`; 50 ms continuity; overlaps trimmed with `timestampOverlap`; watchdog on arrival time (§2.3). Tests `sessionTimeStartsAtFirstCapture`, `epochOffsetNeverOverlaps`, `overlapIsTrimmedAndRecorded`, `slowStartIsNotAStall`, `rendererTrimsOverlappingChunks`, `compositionTrimsOverlappingChunks`. |
| C5 | major | One dropped frame discards hours of live words and forces a full replay | Accepted. `TranscriptCoverage` in the normal stop path (PR2a) and in recovery; `transcriptionBehind {from}`; replay from coverage − 2 s only; next speech session created before capture restarts; live queue sized in seconds (§4.6). Test `liveOverflowKeepsLiveWordsAndReplaysOnlyTheRest`. |
| C6 | major | New speech sessions may report times from their first buffer | Accepted and made independent of the answer: every speech session is rebased to 0 and its base added back (§2.3); opt-in `HOLOS_SPEECH_FIXTURE` test before PR2a merges. Test `speechSessionsAreRebased`, `speechFixtureTimesAreAbsolute`. |
| C7 | major | Restarts skip `stopCapture`; late ends from an old epoch count | Accepted. Every restart is stop then start; `captureEnded(epoch:)`; other epochs ignored. Tests `configurationChangeStopsThenRestarts`, `staleEpochEndIsIgnored`. |
| C8 | major | Dark wake resets the sleep start and forgets a pause | Accepted (§4.4). Tests `darkWakeKeepsSleepStart`, `pausedStaysPausedThroughDarkWake`. |
| C9 | major | Control requests ordered by second-precision dates | Accepted. `ControlRequest.sentAtNanos` in the contract; order `(sentAtNanos, id)`; senders wait for the previous ack. Test `inboxOrdersBySentAtNotCreatedAt`. |
| C10 | major | A short write leaves a corrupt line in `events.jsonl` | Accepted (PR6): appends truncate back on failure; readers skip and count corrupt lines; maintenance open repairs a torn tail. Tests `failedAppendLeavesNoPartialLine`, `corruptMiddleEventLineIsSkippedAndCounted`, `maintenanceOpenRepairsTornTail`. |
| C11 | major | Post-processing after a disk-low stop fills the disk | Accepted. Render only with free ≥ render + 1 GB; skipped after a `diskLow` stop; no `process(url)` fallback. Tests `diskLowStopSkipsRender`, `lowFreeSpaceSkipsRender`, `renderCheckNeedsOneGigabyteHeadroom`. |
| C12 | major | Editor computes its own precondition, so stale views edit the wrong turn | Accepted (with B3): `apply(view:)`, head check, fingerprints from the caller's view, refusal writes nothing (§4.9). Tests `editAgainstReplacedHeadIsRefused`, `concurrentReassignIsRefused`. |
| C13 | major | Flicker smoothing gives isolated short replies to the chair | Accepted. Gap, boundary, and own-segment conditions; three new `AlignmentParameters` fields. Tests `isolatedShortReplyIsKept`, `boundaryFlickerIsSmoothed`, `flickerCoveredByOwnSegmentIsKept`. |
| C14 | major | Split and range edits reuse the whole turn's embedding | Accepted (first option). Split parts are `modified` and excluded from enrollment; merged turns qualify (B19). `reassignRange` is removed (P15). Tests `splitThenReassignKeepsOtherVoiceOut`, `mergeKeepsTurnsInSample`. |
| C15 | major | Current transcript chosen by date; run spans index another transcript | Accepted (with B4). `transcripts/current.json`; the snapshot loads `run.transcriptID`; `transcriptChanged`; span validation (§2.4). Tests `transcriptPointerFollowsLatestSave`, `snapshotLoadsRunTranscriptAndFlagsChange`, `invalidSpanMakesRunUnusable`. |
| C16 | major | Regenerating exports inside the speaker lock deadlocks on itself | Accepted (with B12). Regeneration after release; `regenerateLocked`; stage 6 releases before stage 8. Tests `exportsRegenerateAfterLockRelease`, `regenerateLockedRunsInsideTheLock`. |
| C17 | major | No lock held between finish and post-processing; probes break acquisitions | Accepted. Lease before `finish`; `status.json` heartbeat; 1 s retries on writer and lease. Tests `leaseTakenBeforeFinish`, `heartbeatKeepsStatusFresh`, `leaseAcquisitionSurvivesAProbe`. |
| C18 | major | Reducer fails starts during permission prompts and never recovers | Accepted (with B2, B13). Child-process liveness while starting, 5 s hint, 120 s timeout with SIGTERM, fresh status returns to `active`, `send` refuses without a manifest, `finishing` + dead → idle, no "Recover" text when nothing was saved (§5.8). Tests `missingFolderWhileStartingIsNotFailure`, `startTimesOutAfterTwoMinutes`, `freshStatusRecoversFromFailed`, `childExitBeforeRecordingShowsLogTail`, `channelSendRefusesWithoutManifest`. |
| C19 | major | Unbounded awaits on platform stops and speech finish | Accepted. `StopTimeouts` (5 s; 30 s + 0.05 × audio); sleep acknowledged after chunks close. Tests `hungCaptureStopTimesOut`, `hungSpeechFinishTimesOut`, `loopAcknowledgesAfterClosingChunks`. |
| C20 | minor | Rebuild seam duplicates or loses words; journal holes; date-based idempotence | Accepted. Word-level merge; journal drops recorded as `transcriptionBehind`; idempotence by event sequence. Tests `uncoveredTailIsReplayedAtWordLevel`, `journalDropRecordsBehind`, `recoveryIsIdempotent`. |
| C21 | minor | Fingerprints read recognition; forgotten people still shown | Accepted. Journal-only fingerprints; matches for unknown profiles ignored; forgetting regenerates affected exports. Tests `fingerprintIgnoresRecognition`, `forgottenProfileMatchIsIgnored`. |
| C22 | minor | Children inherit lock descriptors | Accepted (§1.7 rule 4). Tests `lockDescriptorsAreCloseOnExec`, `spawnedChildInheritsNoLocks`. |
| C23 | minor | Late progress overwrites `exited` | Accepted. One ordered stream; `StatusWriter` ignores updates after `finish`. Tests `progressIsMirroredInOrder`, `updatesAfterExitAreIgnored`. |
| C24 | minor | Long pauses render hours of silence | Accepted. Render gap compression with a time map; idle-sleep assertion released while paused; 6 h pause limit. Tests `rendererCompressesLongGaps`, `timeMapSplitsSegmentsAcrossCompressedGap`, `pauseTimesOutAfterSixHours`. |
| C25 | minor | Constant timing bias between words and segments | Accepted. Per-track offset estimate recorded in `AlignmentInfo.trackOffsets`; PR7c reports the measured offsets. Tests `offsetEstimateRecoversShift`, `offsetIsZeroWithFewWords`. |
| C26 | minor | Review edits block the main actor | Accepted (with B29). `async` edits on a serial queue with an optimistic projection. Test `projectionUpdatesBeforeWriteCompletes`. |
| C27 | minor | Closed enums in shared files break older readers | Accepted. `OpenStringCode` for stage, state, result, transcription state; `RecorderPhase.unknown`; schema-bump rule for enums persisted in runs (§1.6). Tests `openCodesDecodeUnknownValues`, `unknownPhaseIsActive`. |
| C28 | minor | `TrackReplayer` has no start offset; shared fakes unowned | Accepted. `replay(from:)` in PR1's API (test `replayFromSkipsEarlierAudio`); helper ownership rule (§1.8). |
| C29 | minor | In-process fallback consumes frames on the main thread | Accepted. Off-main consumer, `beginActivity`, in-process quit waits for the transcript (§4.1, §5.8). |
| P1 | blocker | Every diarized meeting stores voiceprints of everyone, whatever the setting | Accepted. Runs and cluster summaries hold no vectors; `SessionVoiceData` in `speakers/voice/` only while "Remember voices" is on, excluded from backups, removed by every forget and delete path (§3.3, §4.10). "Recompute voice data" is not built: relabelling with the setting on, with names carried over, gives the same result. Tests `runHoldsNoVectors`, `rememberOffMeansNoVoiceDataAndNoRecognition`, `forgetAllRemovesVoiceFilesKeepsNames`. |
| P2 | blocker | Regenerated exports overwrite the user's text fixes | Accepted. Exports are a 0400 generated cache with `.generated.json`; edited files are moved aside; "Open Transcript" is a Quick Look preview; "Save Transcript As…" gives the editable copy (§4.11). Test `regenerateMovesHandEditedExportAside`. |
| P3 | major | JSON export includes centroids by default; bulk voiceprint export | Accepted for sessions: no session export ever contains vectors (the flag is removed rather than inverted). Rejected for `people export --include-voiceprints`: decision 2 includes "forget and export"; it stays opt-in, off by default, with a stderr warning. Test `jsonExportIsDeterministicAndHasNoVectors`, `peopleExportOmitsEmbeddingsByDefault`. |
| P4 | major | Calls record the laptop microphone instead of the headset | Accepted, to confirm (Q2): calls use the system default input; the missing-built-in refusal applies only in person (§4.12). Tests `callUsesSystemDefault`, `callStartAllowedWithoutBuiltInMic`; H21. |
| P5 | major | With Remember off, names never carry across meetings | Accepted. People without samples; `link` always creates the profile; name combo box; "This is me" (`isSelf`); People window lists everyone (§4.10). Tests `linkWithoutRememberKeepsTheName`, `markSelfCreatesOneSelfProfile`. |
| P6 | major | A modal per person and no bulk confirm | Accepted. Footer checkbox "Learn voices of people I name in this meeting"; "Confirm All Suggestions" as one batch (`SpeakerEdit.batchID` added to the contract). Tests `confirmAllIsOneEdit`, `footerToggleControlsSampleWrites`, `confirmAllIsOneUndo`. |
| P7 | major | Uncalibrated automatic names; merged-cluster voiceprints | Accepted (with B6). Suggestions only until `holos people calibrate --apply` (≥ 3 meetings); PR7c cross-recording calibration; enrollment outlier pass. Tests `likelyIsOffByDefault`, `mergedClusterSampleDropsOutlierTurns`, `calibrationNeedsThreeMeetings`. |
| P8 | major | Merged quiet speakers need turn-by-turn fixes; relabel drops names | Accepted in part. (a) PR7c evaluates min/max hints. (b) `MeetingInfo.expectedSpeakers` in the contract; the start-panel field only if (a) shows a benefit. (c) Replaced: "Find More Speakers…" relabels with a higher minimum count instead of 2-means over stored turn embeddings, which would keep voiceprints of everyone (conflicts with P1). (d) Names carry over by shared speech time rather than centroids (centroids are not kept; §4.9). (e) H20. |
| P9 | major | Nothing deletes or expires meetings | Accepted. Delete Audio, Delete Meeting (Trash, recorder log, optional forget of samples), mono system audio (0.35 GB/h), storage footer, Clean Up (§4.13). Automatic expiry is not added (Q12). Tests `deleteAudioKeepsTranscript`, `moveToTrashRemovesRecorderLog`. |
| P10 | major | Shutdown during labelling leaves it undone; no path to naming | Accepted. Automatic relabel, "Name Speakers — …" menu item with a status-item dot, stop alert text (§5.8). Tests `autoRelabelPicksInterruptedRecentUnedited`, `exitedStatusFinishesAndOffersNaming`; H22. |
| P11 | major | No vocabulary for meeting transcription | Accepted. `contextualStrings` in `LiveSpeechFactory` (PR1) and through replay, rebuild, import; `vocabulary.json`; app hand-off file (§4.12). Tests `vocabularyReachesSpeechFactory`, `importPassesVocabulary`, `vocabularyFileIsPrivate`. |
| P12 | major | A paused meeting that sleeps 15 min is split in two | Accepted, to confirm (Q1): sleep while paused stays paused, up to the 6 h pause limit. Test `pausedSleepOverFifteenMinutesStaysPaused`; H11. |
| P13 | major | An unpaused in-camera item cannot be removed | Accepted in part. `GapReason.redacted` reserved and the scrub list written down (§4.13). The command is deferred (Q7): it rewrites the journal and audio chunks and deserves its own PR; `GapReason` is an open code, so adding it later changes no contract. |
| P14 | minor | The hotkey skips the consent reminder and checks | Accepted: the meeting hotkey is dropped from v1 (file, effects, tests, old H11). |
| P15 | minor | SRT/VTT and `reassignRange` are extra scope | Accepted: formats md, txt, json; `reassignRange` removed from the contract; `--from/--until` removed. |
| P16 | minor | Markdown and text split one report into many blocks | Accepted: `TranscriptExporter.blocks` merges consecutive turns of one speaker. Tests `consecutiveSameSpeakerTurnsExportAsOneBlock`, `blocksBreakAtGapMarkerAndLongSilence`. |
| P17 | minor | Dictation menu items stay live; sleep and meeting pauses conflict; terminal meetings missed | Accepted (§4.12). Test `controllerFindsTerminalMeetingAfterLaunch`; H12. |
| P18 | minor | "Jim?" means two things; jargon in the status line | Accepted: "Jim (auto)" everywhere; "Maybe Maria — Confirm" only in the UI; plain status text. Test `autoLabelAndNoSuggestionsInExports`. |
| P19 | minor | People window promises too much; Remember off keeps samples silently | Accepted: backup exclusion and honest text; forget prompt when unchecking; consent line. Test `profileStoreIsPrivateLockedAndNotBackedUp`. |
| P20 | minor | Export destination unspecified; speakers identifiable only by audio | Accepted: Save As… and Copy as Markdown; text previews in the sidebar. Test `previewsShowTwoLongestTurns`. |
| P21 | minor | Speaker models can be installed only from a terminal | Accepted (with B10): Setup row, start-panel status, finished message, doctor field. Test `doctorJSONReportsSpeakerModels`; H19. |
| P22 | minor | "Others in the room" cannot be changed after the fact | Accepted: `--others-in-room` / `--no-others-in-room` recorded in `postprocess.json`; "Label Speakers on My Microphone" in Review; hybrid case in H16; echo-heavy microphone clusters hidden (PR11). Tests `othersInRoomOverride`, `echoHeavyMicClusterIsHidden`. |
| B1 | major | Only the CLI writes the post-processing and exited phases | Accepted. `PostProcessHook` in `RecordingDependencies` (PR1); `RecordingWorkflow.run` owns the lifecycle and status (PR2a); the in-process hook runs `session diarize` in a child. PR6 moved to wave 0 so PR1 can name `ProcessingLease`. Test `statusEndsExitedAfterFakePostProcessor`. |
| B2 | major | `finishing` never ends; stale status trusted during maintenance | Accepted. `finishing` + dead → idle; `maintenance` liveness; `markDeadRecorderExited`; reattach needs a fresh status. Tests `finishingDeadGoesIdle`, `livenessDistinguishesMaintenance`, `deadRecorderStatusIsMarkedExited`, `catalogShowsMaintenanceAsProcessing`. |
| B3 | major | Edits resolve against whatever head exists; lost updates | Merged into C12; sequential fingerprints within a batch. Test `batchFingerprintsAreSequential`. |
| B4 | major | Snapshot pairs the head run with a different transcript | Merged into C15; stage 3 relabels when the transcript changed. Test `changedTranscriptRelabels`. |
| B5 | major | Two spellings of gap reasons across PR2 and PR7 | Accepted: `GapReason` raw values are the event strings; unknown reasons → `audioGap`; `closeAll` on every restart. Tests `discontinuityReasonsUseGapReasonStrings`, `timelineReaderMapsEveryReason`, `timelineReaderSplitsGapAtPauseEvents`. |
| B6 | major | 0.65 comes from another pipeline and model | Merged into P7 (§4.10 explains why 0.65 does not apply). |
| B7 | major | Default suite reaches IOKit, CoreAudio, and real profiles | Accepted. `findInputDevices` seam; inert defaults for dependencies added after PR1; `HOLOS_SUPPORT_DIR` via `supportRoot` and `scripts/test.sh`; `profiles:` parameters; `FluidModels.status(directory:pinned:)`. Test `supportRootHonoursEnvironment`. |
| B8 | major | Parallel PRs collide on shared test helpers | Accepted: one owner per wave for `Fakes.swift` and `SessionFixtures.swift`; others `fileprivate` or prefixed (§1.8); PR1's `FakeCapture` covers epochs, offsets, and scripted errors. |
| B9 | major | PR3's rebuild cannot take its own locks | Merged into C2. |
| B10 | major | App users cannot install models or learn why labels are missing | Merged into P21. |
| B11 | major | PR5, PR7, PR2 are too large | Accepted: PR5a → PR5b → PR5c; PR7a ∥ PR7b → PR7c; PR2a → PR2b; plus wave 0 for PR6 (§0.2, §6). |
| B12 | minor | `regenerate` inside the editor's lock | Merged into C16. |
| B13 | minor | Start timeout fires during permission prompts | Merged into C18. |
| B14 | minor | Same-second control requests | Merged into C9. |
| B15 | minor | Session clock anchored before capture | Merged into C4. |
| B16 | minor | The machine cannot express watchdog restarts | Accepted: `tick(lastFrameAt:)`, watchdog state in the machine, stop-then-start restart. Tests `stalledMicRestartsInNewEpoch`, `watchdogFlagsAfterThreeSecondsAndClears`. |
| B17 | minor | Power events cannot be polled; lid closes wait 30 s after the loop | Accepted: `pendingEvents()`, `attach`/`detach`, the monitor acknowledges while detached. Tests `monitorAcknowledgesWhenDetached`, `loopAcknowledgesAfterClosingChunks`. |
| B18 | minor | Renders left behind after a crash | Accepted: `derived/` cleared at stage 0 and stage 9; Clean Up in Meetings; catalog reports `derivedBytes`. Test `derivedClearedAtStartAndEnd`. |
| B19 | minor | Merged turns count as reassigned | Accepted: cluster-membership definition (§4.9). Test `mergedTurnsAreNotReassigned`. |
| B20 | minor | Terminal-started meetings after launch go unnoticed | Merged into P17. |
| B21 | minor | `saveTranscript` overwrites speaker exports with legacy ones | Accepted: `saveTranscript(_:writeLegacyExports:)` in PR6; new code passes false. Test `saveTranscriptCanSkipLegacyExports`. |
| B22 | minor | Controls sent after capture stops are never acknowledged | Accepted: post-loop polling acknowledges `ignored`; leftovers deleted at exit; stop does not cancel post-processing. Test `commandsAfterStopAreIgnored`. |
| B23 | minor | `TrackReplayer` lacks `from:` | Merged into C28. |
| B24 | minor | FluidAudio's `AudioSource` and `WordTiming` clash with Holos types | Accepted (§1.1); verified in the checkout. |
| B25 | minor | No switch for `exclusiveSegments`; evaluation transcribes per configuration | Accepted in part: hidden `--exclusive-segments` and `--voice-data`; one transcribed import is reused for every configuration with `--force`. Rejected: diarizing sessions without a transcript, which would need runs without a `transcriptID` to save one transcription per recording. |
| B26 | minor | Model folder layout and revision marker unspecified | Accepted: paths relative to `<dir>/speaker-diarization/`; `status` checks `.fluidaudio-revision`; `config.json` and `provenance.json` pinned via the Hugging Face tree API (§4.8). |
| B27 | minor | Unneeded CLI behaviour changes | Accepted: exit 1 kept for incomplete transcription; SIGHUP unchanged (Q6); `session score` hidden; `--use-run` deferred. Rejected for `transcript.txt`: the speaker-less text has no consumer in the repo (the evaluator runs `holos transcribe`), and speaker-labelled text is one of the plan's formats (R23). |
| B28 | minor | Losing the call-mode microphone ends the whole recording | Accepted: restart without the microphone, warn, retry with it on a device change. Test `callWithoutAnyInputRecordsSystemOnly`. |
| B29 | minor | `ReviewSession` edits are synchronous on the main actor | Merged into C26. |
| S1 | — | Fold spike S1 into PR7 | Done in §4.8: the FluidAudio API actually used, configuration, cache layout and pinning, memory (one pass per track, tracks in sequence, no block-wise fallback), embeddings (segment embedding = centroid; chunk embeddings for turns; persisted only as opt-in voice data), accuracy to expect, and the license and citation text for `THIRD_PARTY_NOTICES.md` and the About panel. |

### 10.1 Codex review of the design (PR #4)

| Comment | Disposition |
|---|---|
| In-process mode released the lease before spawning the diarizer, leaving a window with no lock | Accepted. The lease descriptor is inherited by the child at fd 3 (`--lease-fd 3`) and the parent closes its copy only after a successful spawn (§4.1). Test `inProcessLeaseHandoffHasNoGap`. |
| The vocabulary temp file leaked when launch failed or the child exited early | Accepted. `MeetingController` deletes it on launch failure, child exit, and first status; stale files are swept at launch (§4.12). Three PR4 tests. |
| `markSelf` had no consent flag for voice learning | Accepted. `learnVoice:` added to `VoiceProfileService.markSelf`; `ReviewSession.markSelf` passes `learnVoices` (§4.10, PR10). Test `markSelfHonoursLearnVoice`. |
| (second pass) Voice data for every diarized speaker was persisted before anyone was confirmed | Accepted. Post-processing never persists embeddings; recognition uses them in memory. Samples are extracted on demand for the confirmed speaker only (`VoiceSampleExtractor`, hidden `holos speakers embed`) (§4.10). Tests `rememberOnStoresNoVoiceData`, `enrollExtractsOnlyTheConfirmedSpeaker`, `enrollWithoutAudioKeepsNameOnly`. This also settles open question Q9 (retention of unnamed speakers' voice data): there is none. |
| (second pass) A crash during Forget could strand voice data with no way to retry | Accepted. Forget writes a tombstone to `forget-journal.jsonl` before touching the store; `resumePendingForgets` finishes pending work at app launch and CLI start (§4.10). Tests `forgetResumesAfterCrashBetweenStoreAndSessions`, `forgetJournalReplayIsIdempotent`. |
| (second pass) note | The contract file comment on `SessionVoiceData` (§3) still says "written only while Remember voices is on". Contract files are frozen by their §3.0 digests and wave 0 already copied them, so the comment is left as is; the rules in §4.10 govern. |
| (second pass) The diarize command did not accept the inherited lease | Accepted. Hidden `--lease-fd N` with descriptor validation (§5.5 PR7b CLI). Tests `diarizeAdoptsInheritedLease`, `diarizeRefusesForeignLeaseFd`. |
| (third pass) A PR10 test and the initializer note still required voice files when Remember voices is on | Accepted. Test renamed `rememberOnWritesRecognitionOnly` (no voice file); initializer note corrected; §3.0 notes the frozen contract comment is superseded by §4.10. |
| (third pass) Most edit actions had no fingerprint, so stale edits could act on split or reassigned turns | Accepted. Fingerprints for reject, merge, split, newSpeaker, and excludeFromEnrollment (§4.9 table). Tests `staleExcludeAfterSplitIsRefused`, `staleMergeAfterReassignIsRefused`, `staleRejectAfterRelinkIsRefused`. |
| (third pass) On-demand extraction kept only windows contained in a turn, so short turns never enrolled | Accepted. Overlap-weighted selection as in `TurnEmbeddings.compute` (§4.10). Test `extractorUsesOverlappingWindowsForShortTurns`. |
| (third pass) A zero `likelyMaxDistance` still allowed `likely` at distance 0 | Accepted. `likely` requires `calibratedThresholds != nil` (§4.10 step 4–5). Test `identicalVectorIsOnlyPossibleUntilCalibrated`. |
| (fourth pass) Enrollment methods were synchronous with no way to reach the async extractor | Accepted. `link`, `confirmAll`, `markSelf`, `refreshSamples` are `async` and take `extractor: (any VoiceSampleExtractor)?`; `SpeakerEditor.apply` returns `needsSampleRefresh` for callers to await; the app injects `SubprocessVoiceSampleExtractor` (hidden `holos speakers embed`, JSON on stdout only), the CLI injects `FluidVoiceSampleExtractor` (§4.10). `VoiceEnrollment.sample` takes `turnEmbeddings`. |
| (fourth pass) Time overlap alone could mix another speaker's slot vector from a shared 10 s window into a sample | Accepted. The extractor maps each turn to the fresh pass's dominant `speakerId` and uses only that slot's `ChunkEmbedding`s; turns without a dominant speaker get none (§4.10). Tests `extractorIgnoresOtherSpeakerSlotInSharedWindow`, `extractorSkipsTurnsWithoutADominantSpeaker`. |
| (fifth pass) Concurrent sample refreshes could let an older extraction overwrite a newer sample | Accepted. Generation check (head run + journal length) under speaker lock then `profiles.lock` before upsert; retry up to 3 times; samples stamped with their generation (§4.10). Tests `staleRefreshDoesNotOverwriteNewerSample`, `refreshGivesUpAfterThreeChanges`. |
| (fifth pass) `SpeakerEditor.apply`/`undoLast` declared no refresh flag | Accepted. Both return `SpeakerEditResult { snapshot, needsSampleRefresh }` (§5.7). |
| (fifth pass) Open question Q9 still described retaining unnamed speakers' voice data | Accepted. Q9 marked resolved (§9). |
