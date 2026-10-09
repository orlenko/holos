# Meeting recording: build plan and review log

The meeting design's build plan, kept as written: the user decisions and PR map (§0), the plan of each PR that the
feature files do not hold (§5.1, §5.2), waves and merge rules (§6), what was verified automatically and the hardware
checklist (§7), the resolutions log (§8), open questions (§9) and the design review log (§10). It describes the plan
when it was written, not the code: the sections that describe behaviour are in `docs/conventions.md` and
`docs/meeting/`, and [meeting-design.md](../meeting-design.md) lists the file each numbered section is in.

> **Renamed.** The product is now called Voice is Local: the app is built as `build/VoiceIsLocal.app`
> and the command-line tool is `voiceislocal` (bundled as `Contents/MacOS/voiceislocal`). This design
> predates the rename, so its `holos …` commands are now `voiceislocal …` and "Holos" in user-facing
> text means Voice is Local. Internal names are unchanged: `Holos*` modules, bundle IDs, the
> `Application Support/Holos` and `Logs/Holos` folders, `.holos` sessions, and `HOLOS_*` variables.

Status: implementation-ready design for PR1–PR11 of
[meeting-recording-plan.md](../meeting-recording-plan.md) (PR12, minutes, is out of scope).
Written 2026-09-23 from the code on branch `meeting-plan`, FluidAudio 0.17.1 sources
(`5c51c5c9`), and the user's decisions in ../meeting-recording-plan.md §8. Revised 2026-09-24 after a three-lens
design review (80 findings, meeting-plan-2026-09.md §10) and spike S1 ([speaker-evaluation.md](../speaker-evaluation.md)).
No product code exists for it yet.

Several engineers build this in parallel, one PR each, without talking to each other.
Everything they must agree on is fixed here: target graph, file formats, the contract
files (../meeting/session-format.md §3; the Swift sources are the contract), the seams between PRs (meeting-plan-2026-09.md §4), and each PR's file list and
"does not touch" list (§5). If a PR needs a contract change beyond what ../meeting/session-format.md §3.0 allows, it
stops and reports it; it does not edit a file owned by another PR.

## 0. Overview

### 0.1 User decisions this design implements

| # | Decision | Where it shows up |
|---|---|---|
| 1 | FluidAudio 0.17.1, pinned, checksummed, credited | ../meeting/post-processing.md §4.8, PR7a, `THIRD_PARTY_NOTICES.md`, About panel (PR4) |
| 2 | Remember voices: only from confirmed labels, with forget and export; on for new installs since 2026-10-06 ("if I label words with names, that's the whole point"); an existing setting is kept | ../meeting/people-voice.md §4.10, PR10. Voice embeddings are stored only as profile samples of people the user confirmed with voice learning on, extracted on demand (../meeting/people-voice.md §4.10); post-processing never persists them; names are not voiceprints and are always kept |
| 3 | Int16 audio now; AAC compaction later | PR2a (`AudioChunkWriter`); system audio is also recorded mono (../meeting/recorder.md §4.5) |
| 4 | Recorder = bundled `holos` CLI child of the app; in-process fallback allowed | ../meeting/recorder.md §4.1, §4.6, PR4 (`RecorderLauncher` with both implementations) |
| 5 | Sleep < 15 min resumes, else finalize at the sleep point | ../meeting/recorder.md §4.4, PR2b. Refinement to confirm: sleep that starts while *paused* keeps the meeting paused (meeting-plan-2026-09.md §9 Q1) |
| 6 | Dictation remains available during meeting recording; no dictation markers | ../meeting/recorder.md §4.12, PR4 |
| 7 | No live speaker labels in v1 | Diarization runs only after stop (../meeting/post-processing.md §4.7) |
| 8 | Consent is the user's responsibility; dismissible reminder in the start panel | PR4 start panel |
| 9 | Built-in laptop microphone; no device picker; no boundary-mic test | ../meeting/recorder.md §4.12. In-person meetings record the built-in microphone. Refinement to confirm: online calls record the system default input (the headset the call app uses), shown as a static label (meeting-plan-2026-09.md §9 Q2) |

### 0.2 PR map

| PR | Wave | Goal | New targets |
|---|---|---|---|
| PR6 | 0 | Contract files (../meeting/session-format.md §3), `AtomicFile`, `SessionPaths`, locks and lease, free space, `SessionSpeakerStore`, `SessionArchive` fixes (torn appends, transcript pointer, maintenance open) | — |
| PR1 | 1 | Move recording out of the CLI into `HolosMeeting`; capture and speech seams; lifecycle hook; post-processor skeleton | HolosMeeting |
| PR5a → PR5b → PR5c | 1 | `HolosSpeakers`: alignment and run builder (a); projection and carry-over (b); exporters, Otter parser, scoring (c) | HolosSpeakers (PR5a) |
| PR7a ∥ PR7b → PR7c | 2 | FluidAudio adapter and model install (a); renderer, post-processor, exports, `session diarize` (b); import, score, Otter evaluation (c) | HolosDiarization (PR7a) |
| PR2a → PR2b | 2 | Long recordings: recorder loop, files, control, disk, capture pump, stop path (a); sleep, power, device changes, watchdog, microphone selection (b) | — |
| PR3 | 3 | Recovery with the journal transcript, session catalog, delete audio / delete meeting | — |
| PR8 | 3 | `SpeakerEditor`, `holos speakers …`, `holos session export` | — |
| PR4 | 4 | Menu bar meeting controls, start panel, child launch/reattach, Meetings window, concurrent dictation, model install from the app, automatic relabel | — |
| PR10 | 4 | People (names and opt-in voiceprints), recognition as suggestions, People window, `holos people` | — |
| PR9 | 5 | Transcript review window | — |
| PR11 | 5 | Online-call refinements: echo filter, headphone warning | — |

`→` means stacked (the later PR branches from the earlier one); `∥` means parallel.
Meeting languages came after wave 5, outside this map: one language per meeting (LANG1),
then several detected after the recording (LANG2); ../meeting/languages.md §4.14 describes both.
Spike S1 finished with verdict "go" (../meeting/post-processing.md §4.8 uses its API facts and measurements). Spike S2
(recorder process and platform) is pending; it picks the default launcher and runs the
hardware checks in meeting-plan-2026-09.md §7.2. S2 does not change any interface: the `waiting` phase (../meeting/recorder.md §4.2)
already covers ScreenCaptureKit stopping under screen lock, and ../meeting/recorder.md §4.2 names the fallback
if it does.

### 0.3 What this revision changed

The review log (§10) lists every finding and its disposition. The larger changes:

- **Privacy.** Diarization runs hold no voice embeddings, and post-processing never
  persists them; a voiceprint is stored only as a profile sample of a person the user
  confirmed with voice learning on (../meeting/people-voice.md §4.10). `speakers/voice/` exists only for hidden
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

## 4. Integration seams

Later PRs build against these seams; earlier PRs provide them or a stub with the final
signature.

## 5. PRs

Each section lists: goal, files, API, formats/CLI/UI, tests (name: input → expected),
acceptance, and what the PR must not touch. "Add" means a new file; "Change" means an
existing file. Signatures are the contract; bodies are the implementer's. When the
compiler demands a small annotation change (for example `Sendable` on a protocol),
make it without changing names or shapes and say so in the PR description. Every PR
description ends with a "Docs note" paragraph for the PR that writes the wave's
`README.md` and `docs/status.md` updates (meeting-plan-2026-09.md §6).

### 5.1 PR6: Contracts and storage foundations (wave 0)

**Goal.** Put in place everything the later PRs share: the three contract files, atomic
writes, session paths, locks and the processing lease, free space, speaker storage in
the session, and the `SessionArchive` fixes the review found (torn appends, corrupt
journal lines, a transcript pointer, maintenance opens under a lease).

**Files.**

- Add `Sources/HolosCore/HolosJSON.swift`, `MeetingModels.swift`, `SpeakerModels.swift`
  (the contract, ../meeting/session-format.md §3.0), and `Sources/HolosCore/SupportPaths.swift`
  (`extension HolosPaths { public static var supportRoot: URL }`: `$HOLOS_SUPPORT_DIR`
  if set and non-empty, else `applicationSupport`).
- Add `Sources/HolosStorage/AtomicFile.swift` (../conventions.md §1.7), `SessionPaths.swift` (../meeting/session-format.md §2.1),
  `SessionLocks.swift` (`ProcessingLease`, lease, speaker lock, retry helper),
  `SessionSpeakerStore.swift`, `FreeSpace.swift` (`FreeSpaceProvider`,
  `VolumeFreeSpace`, `FixedFreeSpace` for tests), `TranscriptPointer.swift`.
- Change `Sources/HolosStorage/SessionArchive.swift`:
  - `create(root:name:source:locale:backend:id:)` with `id: String? = nil` (must be a
    UUID string; refuses an existing folder).
  - The writer lock is acquired with the 1 s retry (../conventions.md §1.7 rule 3), fd `O_CLOEXEC` (already).
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
    currentTranscriptID(at:) throws -> String?` (../meeting/session-format.md §2.4).
  - `openForMaintenance(at:lease:)`, `recover(at:lease:)` (../conventions.md §1.7); `recover(at:)` keeps
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
| `contractExamplesRoundTrip` | each ../meeting/session-format.md §3.4 example | decodes; re-encoding gives the same bytes |
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

**Acceptance.** `swift build` and `./scripts/test.sh` pass; the suite writes nothing under the real
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
    skeleton (../meeting/post-processing.md §4.7: final initializer and `run(session:lease:progress:)`, returning a
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
  (`subcommands:` one per line), `Package.swift` (../conventions.md §1.2 wave 1), `docs/contracts.md`
  (ownership table: `HolosMeeting` replaces `HolosWorkflows`, add `HolosSpeakers` and
  `HolosDiarization`; the "local app/session control" paragraph points to
  docs/meeting/recorder.md §4.1).
- Add `Tests/HolosMeetingTests/RecordingWorkflowTests.swift`, `Tests/HolosMeetingTests/Fakes.swift`.
- Docs: PR1 merges last in wave 1 and writes the wave-1 `README.md` and
  `docs/status.md` notes for PR1 and PR5a–c.

**API.**

```swift
public struct CaptureRequest: Sendable, Equatable {
    public var source: AudioSource
    public var applicationBundleID: String?
    /// Session time of this epoch's first frame (../meeting/session-format.md §2.3). PR1 always passes 0; PR2a uses it.
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
    /// Contextual strings for every speech session of this recording (../meeting/recorder.md §4.12).
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
    /// finishes the archive, and runs the hook under the lease (../meeting/recorder.md §4.6 steps 5–8).
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

**`Fakes.swift`** (PR1; later edited only per ../conventions.md §1.8): `FakeCaptureFactory` (hands out a new
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
| 1 | PR5a → PR5b → PR5c → PR1 | `Package.swift`: PR5a adds HolosSpeakers; PR1 adds HolosMeeting and, rebasing last, the HolosMeeting → HolosSpeakers dependency (../conventions.md §1.2). `HolosMeetingTests/Fakes.swift`: PR1. | PR1 resolves `Package.swift` to ../conventions.md §1.2 and writes the wave-1 notes |
| 2 | PR7a → PR7b → PR2a → PR2b → PR7c | `Package.swift`, `PostProcessing.swift`, `Doctor.swift`: PR7a only. `MeetingPostProcessor.swift`: PR7b only. `Session.swift` `subcommands:`: PR7b adds `Diarize`, PR7c adds `Import`, `Score`. `RecordingWorkflow.swift`, `LiveTrack.swift`, `TrackReplayer.swift`, `Record.swift`, `ChunkWriter.swift`, `AudioCapture.swift`: PR2a, then PR2b. `Fakes.swift` and `SessionFixtures.swift`: PR7b. | PR7c writes the wave-2 notes |
| 3 | PR8 → PR3 | `Session.swift` `subcommands:` (PR8 adds `Export`; PR3 adds `List`, `Delete`): keep all. `Fakes.swift`, `SessionFixtures.swift`: PR8. | PR3 writes the wave-3 notes |
| 4 | PR4 → PR10 | `Package.swift` HolosApp dependencies (identical edit). `HolosApp.swift` and `HolosApp+Meeting.swift`: PR4 owns; PR10 adds one menu line and one vocabulary expression. `Fakes.swift`, `SessionFixtures.swift`: PR4. | PR10 writes the wave-4 notes |
| 5 | PR11 → PR9 | `docs/meeting-validation.md`: separate sections created by PR4. `Fakes.swift`, `SessionFixtures.swift`: PR11. | PR9 writes the wave-5 notes |

Conflict rules:

- Subcommand arrays and dependency lists: keep both sides, one item per line, and
  compare with the final text in this document.
- A contract file (../meeting/session-format.md §3) changed beyond what §3.0 allows is a bug: stop and report it.
- Never resolve a conflict by deleting another PR's tests.
- Final subcommand lists after wave 5:
  - `holos`: `Doctor, Setup, Transcribe, Record, Session, Speakers, People, Voices, Say, Read`
  - `holos record`: `Start, Status, Stop, Pause, Resume, Marker`
  - `holos session`: `Inspect, List, Recover, Retranscribe, Diarize, Import, Export, Score, Delete`,
    then `Languages` (LANG2, ../meeting/languages.md §4.14)
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
| H10 | PR2 | Record into a small disk image (`hdiutil create -size 2g`, `HOLOS_DATA_DIR` on it) | start warns or refuses per ../meeting/recorder.md §4.5; recording stops by itself below 500 MB with audio saved; speaker labelling is skipped with the disk message |
| H11 | PR2 | Pause a meeting, close the lid for 20 minutes, open it | the meeting is still paused; Resume continues it in the same session |
| H12 | PR4 | During a meeting, hold Right Option in a text field | dictation inserts normally; both meeting tracks continue; sleep still requires explicit enable |
| H13 | PR4 | Quit during a recording: each choice | behaves as ../meeting/app-controls.md §5.8 |
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
| R1 | HolosMeeting depends on HolosDiarization (../meeting-recording-plan.md §2)? | No. HolosMeeting takes `any SpeakerDiarizer`; only HolosCLI links HolosDiarization; the app never links FluidAudio and runs diarization in a `holos` child. |
| R2 | FluidAudio's default trait links a prebuilt text-normalization binary | Keep default traits: S1 found `traits: []` failed to link (incremental build). The binary is Apache-2.0 and credited. |
| R3 | New error types for disk full, capture gap, etc.? | Keep `HolosError`; carry reasons as data (`StopReason`, warnings, `ControlResult`). |
| R4 | `record start --status-file` | Dropped: `status.json` is always written. |
| R5 | `status.json` "removed at finish" | Kept after exit with `phase: exited` so a relaunched app can show the outcome; staleness is judged by locks, pid, and the heartbeat. |
| R6 | How does the app find the child's session? | The app assigns it with `--session-id`. |
| R7 | Post-processing before or after `archive.finish`? | After, with the processing lease taken before `finish` and handed to post-processing (../meeting/recorder.md §4.6). |
| R8 | `withProcessingLock` "for one write" vs long processing | Two locks: `withSpeakerLock` (one write) and `ProcessingLease` (one run, or one recover → rebuild → post-process chain). |
| R9 | Re-diarization and existing edits | Names, profile links, and rejections carry to the new run by shared speech time, and time kept out of voice learning stays out; other turn-level edits stay in the journal under the old run and are reported as not carried. `--force` is required to replace an edited head. `--use-run` is deferred. |
| R10 | Are turns persisted or recomputed? | Persisted in the immutable run, so edit targets (turn IDs, word refs) never shift. |
| R11 | Per-segment embeddings (S1 question) | FluidAudio 0.17.1's segment `embedding` is the cluster centroid; per-window embeddings come from `exposeChunkEmbeddings`; turn embeddings are averaged from those windows. They are persisted only in `speakers/voice/` while "Remember voices" is on. Superseded by the Codex review (§10.1): embeddings are never persisted by post-processing; samples are extracted on demand for confirmed people. |
| R12 | `--portable` and privacy | No session export contains vectors; `--portable` is gone. `holos people export` includes embeddings only with `--include-voiceprints` and a warning. |
| R13 | "Mic = Me" and condition tags in PR11 | Mic = Me is a track policy in PR5a/PR7b; condition tags ship with samples in PR10; PR11 keeps echo removal and the headphone warning. |
| R14 | "Notify" after resuming from sleep | Menu and status-item warning only; no user notifications (they need a new permission). |
| R15 | Dark wake and closed lid | Resume only with the lid open; `sleepStart` and the phase before sleep are set only on the transition into sleep; the 15-minute limit uses continuous time and also triggers from the 1 s tick. |
| R16 | Keep dictation available for terminal-started recordings? | Yes. The idle rescan follows the meeting without changing dictation. |
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
| R41 | Block-wise diarization fallback (../meeting-recording-plan.md §4 step 3) | Not built: S1 measured 1.8 GB peak RSS for 3 h in one pass; tracks run one at a time. Revisit only for recordings longer than 3 h. |
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
   AVAudioEngine microphone capture in calls is the follow-up (../meeting/recorder.md §4.2).
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
| C1 | blocker | Three fast retries end the meeting on brief audio loss; `RecorderPhase` could not grow after wave 1 | Accepted. `RecorderPhase.waiting`, `audioUnavailable` warning and gap reason, `captureWaiting` event in the wave-0 contract; backoff 0.5 → 30 s; immediate retry on wake, lid open, unlock, device-list change; finish only after 10 min without audio; only `SCStreamError.userStopped` counts as a user stop (../meeting/recorder.md §4.2). A separate AVAudioEngine microphone in calls waits for S2 (no interface change). Tests `failFiveTimesThenRecover`, `waitingTimesOutAfterTenMinutes`, `retryOnScreenUnlockAndDeviceChange`. |
| C2 | blocker | Rebuild refuses its own lease; lease → writer breaks lock order; locks released between recover steps | Accepted. `openForMaintenance(at:lease:)`, `recover(at:lease:)`, and lease parameters on rebuild and post-processing; one lease across recover → rebuild → post-process; lock rules restated (../conventions.md §1.7); moved into PR6. Tests `recoverRebuildAndPostProcessUnderOneLease`, `rebuildSavesWhileHoldingItsOwnLease`. |
| C3 | major | Disk stalls (fsync, manifest rewrite) end the capture | Accepted, with one change: `ChunkWriterPump` (60 s per track) and an off-main consumer remove disk from the capture path; capture overflow drops and marks `overflow`; journal group commit once per second (PR6). Chunk registration stays on the writer task, where the pump absorbs its latency. Tests `pumpAbsorbsSlowWriter`, `pumpDropsBeyondCapacityAndMarksOverflow`, `captureOverflowDoesNotFail`. |
| C4 | major | Clock starts before capture; overlapping epochs and chunks | Accepted. Session time 0 = epoch 0's capture origin; clock anchored there; epoch offset `max(now, lastFrameEnd + 0.01)`; 50 ms continuity; overlaps trimmed with `timestampOverlap`; watchdog on arrival time (../meeting/session-format.md §2.3). Tests `sessionTimeStartsAtFirstCapture`, `epochOffsetNeverOverlaps`, `overlapIsTrimmedAndRecorded`, `slowStartIsNotAStall`, `rendererTrimsOverlappingChunks`, `compositionTrimsOverlappingChunks`. |
| C5 | major | One dropped frame discards hours of live words and forces a full replay | Accepted. `TranscriptCoverage` in the normal stop path (PR2a) and in recovery; `transcriptionBehind {from}`; replay from coverage − 2 s only; next speech session created before capture restarts; live queue sized in seconds (../meeting/recorder.md §4.6). Test `liveOverflowKeepsLiveWordsAndReplaysOnlyTheRest`. |
| C6 | major | New speech sessions may report times from their first buffer | Accepted and made independent of the answer: every speech session is rebased to 0 and its base added back (../meeting/session-format.md §2.3); opt-in `HOLOS_SPEECH_FIXTURE` test before PR2a merges. Test `speechSessionsAreRebased`, `speechFixtureTimesAreAbsolute`. |
| C7 | major | Restarts skip `stopCapture`; late ends from an old epoch count | Accepted. Every restart is stop then start; `captureEnded(epoch:)`; other epochs ignored. Tests `configurationChangeStopsThenRestarts`, `staleEpochEndIsIgnored`. |
| C8 | major | Dark wake resets the sleep start and forgets a pause | Accepted (../meeting/recorder.md §4.4). Tests `darkWakeKeepsSleepStart`, `pausedStaysPausedThroughDarkWake`. |
| C9 | major | Control requests ordered by second-precision dates | Accepted. `ControlRequest.sentAtNanos` in the contract; order `(sentAtNanos, id)`; senders wait for the previous ack. Test `inboxOrdersBySentAtNotCreatedAt`. |
| C10 | major | A short write leaves a corrupt line in `events.jsonl` | Accepted (PR6): appends truncate back on failure; readers skip and count corrupt lines; maintenance open repairs a torn tail. Tests `failedAppendLeavesNoPartialLine`, `corruptMiddleEventLineIsSkippedAndCounted`, `maintenanceOpenRepairsTornTail`. |
| C11 | major | Post-processing after a disk-low stop fills the disk | Accepted. Render only with free ≥ render + 1 GB; skipped after a `diskLow` stop; no `process(url)` fallback. Tests `diskLowStopSkipsRender`, `lowFreeSpaceSkipsRender`, `renderCheckNeedsOneGigabyteHeadroom`. |
| C12 | major | Editor computes its own precondition, so stale views edit the wrong turn | Accepted (with B3): `apply(view:)`, head check, fingerprints from the caller's view, refusal writes nothing (../meeting/speaker-labels.md §4.9). Tests `editAgainstReplacedHeadIsRefused`, `concurrentReassignIsRefused`. |
| C13 | major | Flicker smoothing gives isolated short replies to the chair | Accepted. Gap, boundary, and own-segment conditions; three new `AlignmentParameters` fields. Tests `isolatedShortReplyIsKept`, `boundaryFlickerIsSmoothed`, `flickerCoveredByOwnSegmentIsKept`. |
| C14 | major | Split and range edits reuse the whole turn's embedding | Accepted (first option). Split parts are `modified` and excluded from enrollment; merged turns qualify (B19). `reassignRange` is removed (P15). Tests `splitThenReassignKeepsOtherVoiceOut`, `mergeKeepsTurnsInSample`. |
| C15 | major | Current transcript chosen by date; run spans index another transcript | Accepted (with B4). `transcripts/current.json`; the snapshot loads `run.transcriptID`; `transcriptChanged`; span validation (../meeting/session-format.md §2.4). Tests `transcriptPointerFollowsLatestSave`, `snapshotLoadsRunTranscriptAndFlagsChange`, `invalidSpanMakesRunUnusable`. |
| C16 | major | Regenerating exports inside the speaker lock deadlocks on itself | Accepted (with B12). Regeneration after release; `regenerateLocked`; stage 6 releases before stage 8. Tests `exportsRegenerateAfterLockRelease`, `regenerateLockedRunsInsideTheLock`. |
| C17 | major | No lock held between finish and post-processing; probes break acquisitions | Accepted. Lease before `finish`; `status.json` heartbeat; 1 s retries on writer and lease. Tests `leaseTakenBeforeFinish`, `heartbeatKeepsStatusFresh`, `leaseAcquisitionSurvivesAProbe`. |
| C18 | major | Reducer fails starts during permission prompts and never recovers | Accepted (with B2, B13). Child-process liveness while starting, 5 s hint, 120 s timeout with SIGTERM, fresh status returns to `active`, `send` refuses without a manifest, `finishing` + dead → idle, no "Recover" text when nothing was saved (../meeting/app-controls.md §5.8). Tests `missingFolderWhileStartingIsNotFailure`, `startTimesOutAfterTwoMinutes`, `freshStatusRecoversFromFailed`, `childExitBeforeRecordingShowsLogTail`, `channelSendRefusesWithoutManifest`. |
| C19 | major | Unbounded awaits on platform stops and speech finish | Accepted. `StopTimeouts` (5 s; 30 s + 0.05 × audio); sleep acknowledged after chunks close. Tests `hungCaptureStopTimesOut`, `hungSpeechFinishTimesOut`, `loopAcknowledgesAfterClosingChunks`. |
| C20 | minor | Rebuild seam duplicates or loses words; journal holes; date-based idempotence | Accepted. Word-level merge; journal drops recorded as `transcriptionBehind`; idempotence by event sequence. Tests `uncoveredTailIsReplayedAtWordLevel`, `journalDropRecordsBehind`, `recoveryIsIdempotent`. |
| C21 | minor | Fingerprints read recognition; forgotten people still shown | Accepted. Journal-only fingerprints; matches for unknown profiles ignored; forgetting regenerates affected exports. Tests `fingerprintIgnoresRecognition`, `forgottenProfileMatchIsIgnored`. |
| C22 | minor | Children inherit lock descriptors | Accepted (../conventions.md §1.7 rule 4). Tests `lockDescriptorsAreCloseOnExec`, `spawnedChildInheritsNoLocks`. |
| C23 | minor | Late progress overwrites `exited` | Accepted. One ordered stream; `StatusWriter` ignores updates after `finish`. Tests `progressIsMirroredInOrder`, `updatesAfterExitAreIgnored`. |
| C24 | minor | Long pauses render hours of silence | Accepted. Render gap compression with a time map; idle-sleep assertion released while paused; 6 h pause limit. Tests `rendererCompressesLongGaps`, `timeMapSplitsSegmentsAcrossCompressedGap`, `pauseTimesOutAfterSixHours`. |
| C25 | minor | Constant timing bias between words and segments | Accepted. Per-track offset estimate recorded in `AlignmentInfo.trackOffsets`; PR7c reports the measured offsets. Tests `offsetEstimateRecoversShift`, `offsetIsZeroWithFewWords`. |
| C26 | minor | Review edits block the main actor | Accepted (with B29). `async` edits on a serial queue with an optimistic projection. Test `projectionUpdatesBeforeWriteCompletes`. |
| C27 | minor | Closed enums in shared files break older readers | Accepted. `OpenStringCode` for stage, state, result, transcription state; `RecorderPhase.unknown`; schema-bump rule for enums persisted in runs (../conventions.md §1.6). Tests `openCodesDecodeUnknownValues`, `unknownPhaseIsActive`. |
| C28 | minor | `TrackReplayer` has no start offset; shared fakes unowned | Accepted. `replay(from:)` in PR1's API (test `replayFromSkipsEarlierAudio`); helper ownership rule (../conventions.md §1.8). |
| C29 | minor | In-process fallback consumes frames on the main thread | Accepted. Off-main consumer, `beginActivity`, in-process quit waits for the transcript (../meeting/recorder.md §4.1, ../meeting/app-controls.md §5.8). |
| P1 | blocker | Every diarized meeting stores voiceprints of everyone, whatever the setting | Accepted. Runs and cluster summaries hold no vectors; `SessionVoiceData` in `speakers/voice/` only while "Remember voices" is on, excluded from backups, removed by every forget and delete path (`SpeakerModels.swift`, ../meeting/people-voice.md §4.10). "Recompute voice data" is not built: relabelling with the setting on, with names carried over, gives the same result. Tests `runHoldsNoVectors`, `rememberOffMeansNoVoiceDataAndNoRecognition`, `forgetAllRemovesVoiceFilesKeepsNames`. |
| P2 | blocker | Regenerated exports overwrite the user's text fixes | Accepted. Exports are a 0400 generated cache with `.generated.json`; edited files are moved aside; "Open Transcript" is a Quick Look preview; "Save Transcript As…" gives the editable copy (../meeting/exports.md §4.11). Test `regenerateMovesHandEditedExportAside`. |
| P3 | major | JSON export includes centroids by default; bulk voiceprint export | Accepted for sessions: no session export ever contains vectors (the flag is removed rather than inverted). Rejected for `people export --include-voiceprints`: decision 2 includes "forget and export"; it stays opt-in, off by default, with a stderr warning. Test `jsonExportIsDeterministicAndHasNoVectors`, `peopleExportOmitsEmbeddingsByDefault`. |
| P4 | major | Calls record the laptop microphone instead of the headset | Accepted, to confirm (Q2): calls use the system default input; the missing-built-in refusal applies only in person (../meeting/recorder.md §4.12). Tests `callUsesSystemDefault`, `callStartAllowedWithoutBuiltInMic`; H21. |
| P5 | major | With Remember off, names never carry across meetings | Accepted. People without samples; `link` always creates the profile; name combo box; "This is me" (`isSelf`); People window lists everyone (../meeting/people-voice.md §4.10). Tests `linkWithoutRememberKeepsTheName`, `markSelfCreatesOneSelfProfile`. |
| P6 | major | A modal per person and no bulk confirm | Accepted. Footer checkbox "Learn voices of people I name in this meeting"; "Confirm All Suggestions" as one batch (`SpeakerEdit.batchID` added to the contract). Tests `confirmAllIsOneEdit`, `footerToggleControlsSampleWrites`, `confirmAllIsOneUndo`. |
| P7 | major | Uncalibrated automatic names; merged-cluster voiceprints | Accepted (with B6). Suggestions only until `holos people calibrate --apply` (≥ 3 meetings); PR7c cross-recording calibration; enrollment outlier pass. Tests `likelyIsOffByDefault`, `mergedClusterSampleDropsOutlierTurns`, `calibrationNeedsThreeMeetings`. |
| P8 | major | Merged quiet speakers need turn-by-turn fixes; relabel drops names | Accepted in part. (a) PR7c evaluates min/max hints. (b) `MeetingInfo.expectedSpeakers` in the contract; the start-panel field only if (a) shows a benefit. (c) Replaced: "Find More Speakers…" relabels with a higher minimum count instead of 2-means over stored turn embeddings, which would keep voiceprints of everyone (conflicts with P1). (d) Names carry over by shared speech time rather than centroids (centroids are not kept; ../meeting/speaker-labels.md §4.9). (e) H20. |
| P9 | major | Nothing deletes or expires meetings | Accepted. Delete Audio, Delete Meeting (Trash, recorder log, optional forget of samples), mono system audio (0.35 GB/h), storage footer, Clean Up (../meeting/retention-deletion.md §4.13). Automatic expiry is not added (Q12). Tests `deleteAudioKeepsTranscript`, `moveToTrashRemovesRecorderLog`. |
| P10 | major | Shutdown during labelling leaves it undone; no path to naming | Accepted. Automatic relabel, "Name Speakers — …" menu item with a status-item dot, stop alert text (../meeting/app-controls.md §5.8). Tests `autoRelabelPicksInterruptedRecentUnedited`, `exitedStatusFinishesAndOffersNaming`; H22. |
| P11 | major | No vocabulary for meeting transcription | Accepted. `contextualStrings` in `LiveSpeechFactory` (PR1) and through replay, rebuild, import; `vocabulary.json`; app hand-off file (../meeting/recorder.md §4.12). Tests `vocabularyReachesSpeechFactory`, `importPassesVocabulary`, `vocabularyFileIsPrivate`. |
| P12 | major | A paused meeting that sleeps 15 min is split in two | Accepted, to confirm (Q1): sleep while paused stays paused, up to the 6 h pause limit. Test `pausedSleepOverFifteenMinutesStaysPaused`; H11. |
| P13 | major | An unpaused in-camera item cannot be removed | Accepted in part. `GapReason.redacted` reserved and the scrub list written down (../meeting/retention-deletion.md §4.13). The command is deferred (Q7): it rewrites the journal and audio chunks and deserves its own PR; `GapReason` is an open code, so adding it later changes no contract. |
| P14 | minor | The hotkey skips the consent reminder and checks | Accepted: the meeting hotkey is dropped from v1 (file, effects, tests, old H11). |
| P15 | minor | SRT/VTT and `reassignRange` are extra scope | Accepted: formats md, txt, json; `reassignRange` removed from the contract; `--from/--until` removed. |
| P16 | minor | Markdown and text split one report into many blocks | Accepted: `TranscriptExporter.blocks` merges consecutive turns of one speaker. Tests `consecutiveSameSpeakerTurnsExportAsOneBlock`, `blocksBreakAtGapMarkerAndLongSilence`. |
| P17 | minor | Dictation menu items stay live; sleep and meeting pauses conflict; terminal meetings missed | Accepted (../meeting/recorder.md §4.12). Test `controllerFindsTerminalMeetingAfterLaunch`; H12. |
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
| B6 | major | 0.65 comes from another pipeline and model | Merged into P7 (../meeting/people-voice.md §4.10 explains why 0.65 does not apply). |
| B7 | major | Default suite reaches IOKit, CoreAudio, and real profiles | Accepted. `findInputDevices` seam; inert defaults for dependencies added after PR1; `HOLOS_SUPPORT_DIR` via `supportRoot` and `scripts/test.sh`; `profiles:` parameters; `FluidModels.status(directory:pinned:)`. Test `supportRootHonoursEnvironment`. |
| B8 | major | Parallel PRs collide on shared test helpers | Accepted: one owner per wave for `Fakes.swift` and `SessionFixtures.swift`; others `fileprivate` or prefixed (../conventions.md §1.8); PR1's `FakeCapture` covers epochs, offsets, and scripted errors. |
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
| B19 | minor | Merged turns count as reassigned | Accepted: cluster-membership definition (../meeting/speaker-labels.md §4.9). Test `mergedTurnsAreNotReassigned`. |
| B20 | minor | Terminal-started meetings after launch go unnoticed | Merged into P17. |
| B21 | minor | `saveTranscript` overwrites speaker exports with legacy ones | Accepted: `saveTranscript(_:writeLegacyExports:)` in PR6; new code passes false. Test `saveTranscriptCanSkipLegacyExports`. |
| B22 | minor | Controls sent after capture stops are never acknowledged | Accepted: post-loop polling acknowledges `ignored`; leftovers deleted at exit; stop does not cancel post-processing. Test `commandsAfterStopAreIgnored`. |
| B23 | minor | `TrackReplayer` lacks `from:` | Merged into C28. |
| B24 | minor | FluidAudio's `AudioSource` and `WordTiming` clash with Holos types | Accepted (../conventions.md §1.1); verified in the checkout. |
| B25 | minor | No switch for `exclusiveSegments`; evaluation transcribes per configuration | Accepted in part: hidden `--exclusive-segments` and `--voice-data`; one transcribed import is reused for every configuration with `--force`. Rejected: diarizing sessions without a transcript, which would need runs without a `transcriptID` to save one transcription per recording. |
| B26 | minor | Model folder layout and revision marker unspecified | Accepted: paths relative to `<dir>/speaker-diarization/`; `status` checks `.fluidaudio-revision`; `config.json` and `provenance.json` pinned via the Hugging Face tree API (../meeting/post-processing.md §4.8). |
| B27 | minor | Unneeded CLI behaviour changes | Accepted: exit 1 kept for incomplete transcription; SIGHUP unchanged (Q6); `session score` hidden; `--use-run` deferred. Rejected for `transcript.txt`: the speaker-less text has no consumer in the repo (the evaluator runs `holos transcribe`), and speaker-labelled text is one of the plan's formats (R23). |
| B28 | minor | Losing the call-mode microphone ends the whole recording | Accepted: restart without the microphone, warn, retry with it on a device change. Test `callWithoutAnyInputRecordsSystemOnly`. |
| B29 | minor | `ReviewSession` edits are synchronous on the main actor | Merged into C26. |
| S1 | — | Fold spike S1 into PR7 | Done in ../meeting/post-processing.md §4.8: the FluidAudio API actually used, configuration, cache layout and pinning, memory (one pass per track, tracks in sequence, no block-wise fallback), embeddings (segment embedding = centroid; chunk embeddings for turns; persisted only as opt-in voice data), accuracy to expect, and the license and citation text for `THIRD_PARTY_NOTICES.md` and the About panel. |

### 10.1 Codex review of the design (PR #4)

| Comment | Disposition |
|---|---|
| In-process mode released the lease before spawning the diarizer, leaving a window with no lock | Accepted. The lease descriptor is inherited by the child at fd 3 (`--lease-fd 3`) and the parent closes its copy only after a successful spawn (../meeting/recorder.md §4.1). Test `inProcessLeaseHandoffHasNoGap`. |
| The vocabulary temp file leaked when launch failed or the child exited early | Accepted. `MeetingController` deletes it on launch failure, child exit, and first status; stale files are swept at launch (../meeting/recorder.md §4.12). Three PR4 tests. |
| `markSelf` had no consent flag for voice learning | Accepted. `learnVoice:` added to `VoiceProfileService.markSelf`; `ReviewSession.markSelf` passes `learnVoices` (../meeting/people-voice.md §4.10, PR10). Test `markSelfHonoursLearnVoice`. |
| (second pass) Voice data for every diarized speaker was persisted before anyone was confirmed | Accepted. Post-processing never persists embeddings; recognition uses them in memory. Samples are extracted on demand for the confirmed speaker only (`VoiceSampleExtractor`, hidden `holos speakers embed`) (../meeting/people-voice.md §4.10). Tests `rememberOnStoresNoVoiceData`, `enrollExtractsOnlyTheConfirmedSpeaker`, `enrollWithoutAudioKeepsNameOnly`. This also settles open question Q9 (retention of unnamed speakers' voice data): there is none. |
| (second pass) A crash during Forget could strand voice data with no way to retry | Accepted. Forget writes a tombstone to `forget-journal.jsonl` before touching the store; `resumePendingForgets` finishes pending work at app launch and CLI start (../meeting/people-voice.md §4.10). Tests `forgetResumesAfterCrashBetweenStoreAndSessions`, `forgetJournalReplayIsIdempotent`. |
| (second pass) note | The contract file comment on `SessionVoiceData` (../meeting/session-format.md §3) still says "written only while Remember voices is on". Contract files are frozen by their ../meeting/session-format.md §3.0 digests and wave 0 already copied them, so the comment is left as is; the rules in ../meeting/people-voice.md §4.10 govern. |
| (second pass) The diarize command did not accept the inherited lease | Accepted. Hidden `--lease-fd N` with descriptor validation (../meeting/speaker-labels.md §5.5 PR7b CLI). Tests `diarizeAdoptsInheritedLease`, `diarizeRefusesForeignLeaseFd`. |
| (third pass) A PR10 test and the initializer note still required voice files when Remember voices is on | Accepted. Test renamed `rememberOnWritesRecognitionOnly` (no voice file); initializer note corrected; ../meeting/session-format.md §3.0 notes the frozen contract comment is superseded by ../meeting/people-voice.md §4.10. |
| (third pass) Most edit actions had no fingerprint, so stale edits could act on split or reassigned turns | Accepted. Fingerprints for reject, merge, split, newSpeaker, and excludeFromEnrollment (../meeting/speaker-labels.md §4.9 table). Tests `staleExcludeAfterSplitIsRefused`, `staleMergeAfterReassignIsRefused`, `staleRejectAfterRelinkIsRefused`. |
| (third pass) On-demand extraction kept only windows contained in a turn, so short turns never enrolled | Accepted. Overlap-weighted selection as in `TurnEmbeddings.compute` (../meeting/people-voice.md §4.10). Test `extractorUsesOverlappingWindowsForShortTurns`. |
| (third pass) A zero `likelyMaxDistance` still allowed `likely` at distance 0 | Accepted. `likely` requires `calibratedThresholds != nil` (../meeting/people-voice.md §4.10 step 4–5). Test `identicalVectorIsOnlyPossibleUntilCalibrated`. |
| (fourth pass) Enrollment methods were synchronous with no way to reach the async extractor | Accepted. `link`, `confirmAll`, `markSelf`, `refreshSamples` are `async` and take `extractor: (any VoiceSampleExtractor)?`; `SpeakerEditor.apply` returns `needsSampleRefresh` for callers to await; the app injects `SubprocessVoiceSampleExtractor` (hidden `holos speakers embed`, JSON on stdout only), the CLI injects `FluidVoiceSampleExtractor` (../meeting/people-voice.md §4.10). `VoiceEnrollment.sample` takes `turnEmbeddings`. |
| (fourth pass) Time overlap alone could mix another speaker's slot vector from a shared 10 s window into a sample | Accepted. The extractor maps each turn to the fresh pass's dominant `speakerId` and uses only that slot's `ChunkEmbedding`s; turns without a dominant speaker get none (../meeting/people-voice.md §4.10). Tests `extractorIgnoresOtherSpeakerSlotInSharedWindow`, `extractorSkipsTurnsWithoutADominantSpeaker`. |
| (fifth pass) Concurrent sample refreshes could let an older extraction overwrite a newer sample | Accepted. Generation check (head run + journal length) under speaker lock then `profiles.lock` before upsert; retry up to 3 times; samples stamped with their generation (../meeting/people-voice.md §4.10). Tests `staleRefreshDoesNotOverwriteNewerSample`, `refreshGivesUpAfterThreeChanges`. |
| (fifth pass) `SpeakerEditor.apply`/`undoLast` declared no refresh flag | Accepted. Both return `SpeakerEditResult { snapshot, needsSampleRefresh }` (../meeting/exports.md §5.7). |
| (fifth pass) Open question Q9 still described retaining unnamed speakers' voice data | Accepted. Q9 marked resolved (§9). |
