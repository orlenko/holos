# Conventions

The rules every meeting component follows: targets, concurrency, errors, logging, files and JSON, atomic writes
and locks, tests, and data handling. §1.2 is the build plan's package history.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](meeting-design.md) lists the file each is in.

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

- Encode and decode every JSON file with `HolosJSON` (`HolosJSON.swift`): ISO 8601 dates (second
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
     string codes (`OpenStringCode`, `HolosJSON.swift`): `RecorderWarningCode`, `StopReason`,
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
| `.processing.lock` (the processing lease) | recorder from just before `finish` until exit (§4.6); `holos session diarize`, `recover`, `delete`, `rename` (§4.17, with the writer lock through `openForMaintenance`); the app's automatic relabel runs the CLI | one post-processing, rebuild, deletion, or rename | `LOCK_EX\|LOCK_NB`, retried every 20 ms for up to 1 s |
| `.speakers.lock` | `SpeakerEditor`; `SessionExports.regenerate`; post-processor while publishing run, head, voice data, recognition, and a merged transcript (§4.14, inside the writer lock) | one write (milliseconds) | polled every 20 ms up to 2 s |
| `<support>/Speakers/profiles.lock` | `SpeakerProfileStore.update`; `withLockedDatabase` (recognition's saved comparison, a forget's per-meeting clean-up, a meeting summary's save, §4.17), always inside the speaker lock when both are held | one read-modify-write, or one read and the session write made from it | polled every 20 ms up to 2 s (PR10) |

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
