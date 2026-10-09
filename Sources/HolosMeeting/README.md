# HolosMeeting

Meetings end to end, without AppKit: recording, the app's controllers, everything after the stop, Review, people
and voice profiles. docs/meeting-design.md §4 is the spec; §4.1 is the recorder ↔ app protocol.

**Owns** (by folder)
- Recorder (top level): `RecordingWorkflow.run` (the recorder loop the `voiceislocal record start` child runs),
  `RecorderMachine` (its pure state machine), `ControlInbox` (`control/<uuid>.json` requests), `StatusWriter`
  (`status.json`), `LiveTrack` / `LiveTranscript` / `LiveText` / `LiveHints`, `DiskPolicy`, `TrackReplayer`,
  seams `MeetingCapture`, `LiveSpeechSession`, `SessionClock`, `RecorderStopSource`.
- App-side control: `MeetingController` (`@MainActor`) with the pure `MeetingReducer`; `RecorderChannel` (reads
  status, sends requests); `RecorderLauncher` (`ChildProcessLauncher`, `InProcessLauncher`), `MaintenanceLauncher`,
  and `ProcessSpawner` (the one `posix_spawn` helper).
- `PostProcessing/`: `MeetingPostProcessor` and its stages (render, echo, diarize, align, recognize, export), the
  language, word-fix, live-hint and deep-transcription stages, `SessionExports`, `SpeakerSessionSnapshot`, and the
  library side of the `voiceislocal session …` commands (`Session*Command`).
- `Review/`: `ReviewSession` (`@MainActor`), playback, learning, paragraphs, maintenance.
- `Summary/`: titles and summaries (`MeetingSummarizer`, `SessionSummarizeCommand`, `SessionRenameCommand`).
- People and sessions: `VoiceProfileService`, `SpeakerEditor`, `SessionCatalog`, `SessionLocator`,
  `SessionImporter`, `SessionRecoveryCommand`, `DeepTranscriptionQueue`, `EchoCatchUp`.
- `Evaluation/`: local and cloud transcription comparison for `voiceislocal eval` (CLI only; the only network code in this target).

**Must not own:** AppKit or windows, FluidAudio or WhisperKit (diarization and deep transcription run in a
`voiceislocal` child), file-name literals inside a session (use `SessionPaths`).

**Depends on:** HolosCore, HolosStorage, HolosAudio, HolosSpeech, HolosSpeakers. AVFoundation, Vision (screen OCR),
NaturalLanguage, CryptoKit.

**Invariants**
- One recorder per session; it owns the writer lock and hands the processing lease to post-processing (§4.6).
  `status.json` says `exited` before the recorder lets go of its last lock.
- Post-processing publishes by atomic rename; cancelled work leaves nothing partial. Lock rules: §1.7.
- `ReviewSession` and `MeetingController` are `@MainActor` and testable without a window.

**Known size debt:** `ReviewSession` (3,872 lines), `RecordingWorkflow`, `VoiceProfileService`. Do not grow them;
move code out first, in a moves-only PR.

**Tests:** `Tests/HolosMeetingTests`. Shared helpers: `Fakes.swift` (`PollBudget`, `eventually`, fakes),
`SessionFixtures.swift`, `RecorderTestSupport.swift`.
