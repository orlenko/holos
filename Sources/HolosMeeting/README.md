# HolosMeeting

Meetings end to end, without AppKit: recording, the app's controllers, everything after the stop, Review, people
and voice profiles. `docs/meeting-design.md` section 4 is the spec; `docs/meeting-design.md §4.1` is the
recorder ↔ app protocol.

**Owns** (by folder)
- Recorder (top level): `RecordingWorkflow.run` (the recorder loop the `voiceislocal record start` child runs; its
  `Recorder` is split by concern into `Recorder+Capture`, `+Power`, `+Status` and `+Stop`; `RecorderExitSequence`, with
  `ExitRetry` and `ExitStatusWait`, is the one place that writes `exited` and lets go of the locks still held then;
  `EpochPlan` and `EpochMonitor` have their own files),
  `RecorderMachine` (its pure state machine), `ControlInbox` (`control/<uuid>.json` requests), `StatusWriter`
  (`status.json`), `LiveTrack` / `LiveTranscript` / `LiveText` / `LiveHints`, `DiskPolicy`, `TrackReplayer`,
  seams `MeetingCapture`, `LiveSpeechSession`, `SessionClock`, `RecorderStopSource`.
- App-side control: `MeetingController` (`@MainActor`) with the pure `MeetingReducer`; `RecorderChannel` (reads
  status, sends requests); `RecorderLauncher` (`ChildProcessLauncher`, `InProcessLauncher`; both take their options
  from `RecordingOptions(settings:…)`), `MaintenanceLauncher`,
  and `ProcessSpawner` (the one `posix_spawn` helper). `CommandRunner` runs a `voiceislocal` command for the app
  through `MaintenanceLauncher`, with its output in `TemporaryArtifact`s, decoded off the main actor into a
  `CommandResult`; `CommandHandle` stops it with SIGTERM until it is reaped. `DoctorReport` is what `doctor --json`
  prints and the app reads; the `Session*Command.Outcome` types play the same role for the session commands.
- `PostProcessing/`: `MeetingPostProcessor` and its stages (render, echo, diarize, align, recognize, export), the
  language, word-fix, live-hint and deep-transcription stages, `TranscriptPublisher` (the one path that makes a new
  transcript current, used by those stages and Review's word edits), `SessionExports`, `SpeakerSessionSnapshot`, and
  the library side of the `voiceislocal session …` commands (`Session*Command`).
- `Review/`: `ReviewSession` (`@MainActor`), playback, learning, paragraphs, maintenance.
- `Summary/`: titles and summaries (`MeetingSummarizer`, `SessionSummarizeCommand`, `SessionRenameCommand`).
- People and sessions: `VoiceProfileService`, `SpeakerEditor`, `SpeakerEditCommand` (the library side of the
  `voiceislocal speakers` edits: one change on a `LoadedSpeakers` view, then the exports rewritten and the voice
  samples from the meeting brought in step), `SessionCatalog`, `SessionLocator`,
  `SessionImporter`, `SessionRecoveryCommand`, `DeepTranscriptionQueue`, `EchoCatchUp`.

**Must not own:** AppKit or windows, FluidAudio or WhisperKit (diarization and deep transcription run in a
`voiceislocal` child), evaluation code (`HolosEvaluation`, which depends on this target), network access,
new file-name literals inside a session (add a `SessionPaths` function instead). Existing ones still built here:
`stop.request` (`RecordingWorkflow`), `control/<id>.json` (`RecorderChannel`), `derived/deep-<track>-16k.caf`
(`DeepTranscriptionStage`), `echo/frames-<hash>.bin` (`EchoAnalysisStage`), `exports/edited-<stamp>.<ext>`
(`SessionExports`). Session folder names come from `SessionPaths` (`folder(for:in:)`, `parse(folderName:)`,
`isListedSessionFolderName`).

**Depends on:** HolosCore, HolosStorage, HolosAudio, HolosSpeech, HolosSpeakers. AVFoundation, Vision (screen OCR),
NaturalLanguage, CryptoKit.

**Invariants**
- The recorder holds the session's writer lock while it records and hands the processing lease to
  post-processing (`docs/meeting-design.md §4.6`). `status.json` says `exited` before the recorder lets go of its
  last lock.
- Post-processing writes its files through `AtomicFile` (atomic rename). The rule that cancelled work publishes
  nothing partial is `docs/meeting-design.md §1.3`; lock rules are `docs/meeting-design.md §1.7`.
- `ReviewSession` and `MeetingController` are `@MainActor` and testable without a window.

**Known size debt:** `ReviewSession` (3,872 lines), `RecordingWorkflow`, `VoiceProfileService`. Do not grow them;
move code out first, in a moves-only PR.

**Tests:** `Tests/HolosMeetingTests` (`./scripts/test-target.sh HolosMeetingTests`). Target-local helpers:
`Fakes.swift` (its own `eventually`, which polls on the main actor, and fakes), `SessionFixtures.swift`,
`RecorderTestSupport.swift`; `TemporaryDirectory` and `PollBudget` come from `HolosTestSupport`.
