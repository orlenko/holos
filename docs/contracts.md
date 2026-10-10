# Component and data contracts

The contracts between targets and processes as the code implements them. Ownership (what each target owns, must
not own, and may import) is the module map in [AGENTS.md](../AGENTS.md#module-map), with details in each
`Sources/<Module>/README.md`. The meeting design is [conventions.md](conventions.md) and the files in [meeting/](meeting/).

Prefer concrete structs, enums and actors; add a protocol only at a real seam (an engine, the hardware, a child
process, a clock). Do not build a plugin framework.

## Seams

The main protocols that exist, and what implements them (not exhaustive; search for `protocol` before adding a new seam):

| Protocol | Target | Live implementation | Used for |
|---|---|---|---|
| `SpeakerDiarizer` | HolosCore | `FluidDiarizer` (HolosDiarization) | Diarization; tests use `FakeDiarizer` |
| `DeepTranscriber` | HolosCore | `WhisperKitTranscriber` (HolosWhisper) | Deep transcription after a meeting |
| `MeetingCapture` | HolosMeeting | `LiveMeetingCapture`, `IndependentMeetingCapture` | The recorder's audio capture; tests use fakes |
| `LiveSpeechSession` | HolosMeeting | `AppleSpeechSession` (HolosSpeech) | Live recognition during a recording |
| `RecorderLauncher` | HolosMeeting | `ChildProcessLauncher`, `InProcessLauncher` | How the app starts a recorder |
| `SessionClock` | HolosMeeting | `ContinuousSessionClock` (`ManualSessionClock` in tests) | Session time |
| `RecorderStopSource` | HolosMeeting | `SignalStopController`, `ManualStopSource` | Stop requests |
| `RecordingReporter` | HolosMeeting | `ConsoleReporter` (HolosCLI) | Recording progress |
| `SystemPowerEvents`, `PowerAssertionHandle` | HolosAudio | `SystemPowerMonitor`, `PowerAssertion` | Sleep and wake |
| `FreeSpaceProvider` | HolosStorage | `VolumeFreeSpace` (`FixedFreeSpace` in tests) | Disk policy |
| `DictationAudioRecording` | HolosStorage | `DictationAudioWriter` (HolosAudio) | Lets the dictation history finish or discard a dictation's audio without depending on HolosAudio |
| `ReadingAudioRenderer`, `ReadingAudioJoiner`, `ReadingPlayback` | HolosContent | `NativeSpeechRenderer`, `AudioBookJoiner`, `AVAudioPlayer` | Reading pipeline and player |
| `EchoAudioSource` | HolosSpeakers | `RenderedEchoAudio` (HolosMeeting), `InMemoryEchoAudio` | Acoustic echo analysis over values |

## Processes

- The app never links FluidAudio or WhisperKit. It runs `voiceislocal` children through `ProcessSpawner`
  (close-on-exec by default, own session): the recorder (`record start --session-id …`, unless the app's
  in-process recorder mode is on) and maintenance commands (`session diarize`, `deep-transcribe`, `summarize`,
  `echo-analyze`, `recover`, `delete`, `rename`; `setup --speakers`, `setup --whisper`, `doctor --json`).
- App ↔ recorder talk through files in the private session folder, not sockets or XPC
  (`docs/meeting/recorder.md §4.1`): the app or CLI writes one allowlisted, versioned request (`stop`, `pause`,
  `resume`, `marker`) for an exact session ID as `control/<UUID>.json`; the recorder applies it at most once and
  acknowledges it in `status.json`, which it rewrites as a heartbeat. SIGINT and SIGTERM stop gracefully.
- The recorder owns the archive's writer lock and hands the processing lease to post-processing; a child it starts
  can inherit the lease (`--lease-fd`). `InProcessLauncher` runs the same workflow inside the app, and still runs
  diarization in a child.

## Capture and recognition

- `PCMFrame` owns its samples and timing. Audio capture callbacks (`AudioCapture`) copy borrowed buffers before
  returning and only enqueue into bounded queues: no `await`, file I/O, resampling or model work in them (short
  `Mutex` sections only).
- Queues are bounded with explicit overflow handling: dictation's capture fails on overflow
  (`CaptureOverflow.fail`); a meeting drops, counts, and records the gap as a discontinuity (`.dropAndCount`,
  `ChunkWriterPump`). Recorded chunks never fill missing audio with fabricated samples; renders made for
  analysis do insert silence for gaps (`RenderedTrack.timeMap` maps their times back).
- Recognition results are `TranscriptUpdate` values (a segment plus `isFinal`). `TranscriptReducer` replaces
  provisional segments over the same interval, never duplicates them, and refuses to replace finalized audio. Empty
  final results add no text.
- Feed a recognition session from one task; `AppleSpeechSession.append` applies backpressure, outside the audio
  callback.

## Persistence

- While a recording runs, the recorder's `SessionArchive` actor (holding the writer lock) is the only writer of
  `manifest.json`, `events.jsonl` and the transcripts; other files in the folder have their own writers (the
  recorder's `StatusWriter` for `status.json`, the app's live-transcript corrections in `live-hints.json`).
  HolosStorage writes through `AtomicFile` (write, fsync, rename, folder fsync). Event sequence numbers never
  decrease; a failed append is truncated back, and a damaged line is skipped and counted. Details and lock
  rules: `docs/conventions.md §1.6`, `docs/conventions.md §1.7`.
- Encoding: session files and the HolosStorage stores (speaker data, profiles, dictation history, word list) use
  `HolosJSON`. Exceptions today: `corrections.json` (`CorrectionList`, plain `JSONEncoder`); the reading
  pipeline's files (`ReadingManifest`, the output reservation's `.holos-output-*.lock` and `.takeover` records) and
  the reading library's `library.json`, which use their own encoders; and some `UserDefaults` values (review
  maintenance entries, the meeting-source notice; plain `JSONEncoder`).
- Versions: most top-level persisted JSON objects carry `schemaVersion`. Exceptions today: `events.jsonl` lines
  (`ArchiveEvent`), `corrections.json`, the reading output reservation records (`ReadingOutputReservation.Record`),
  the deep-transcription lock's holder record (`DeepTranscriptionLock.Holder`), and these `UserDefaults` values:
  review maintenance entries, the meeting-source notice, the Summarize Again queue
  (`MeetingSummarySchedule.Request`). Growable code sets read across builds are `OpenStringCode`s;
  `RecorderPhase` is an enum that decodes unknown values as `.unknown`.
- A version newer than the reader knows is handled per file (the rule is `docs/conventions.md §1.6`, rule 3):
  - Whole files are refused with `HolosError.unavailable` by the readers that need them: the transcript pointer
    and revisions, `meeting.json`, `status.json`, `postprocess.json`, the speaker head and runs, `summary.json`,
    `audio-deleted.json`, `exports/.generated.json`, `live-hints.json`, `words.json`, the people store. A reader
    that only uses a file as an optional input may treat a newer one as absent instead (post-processing with a
    newer `echo/mask.json`).
  - Line files keep going: the speaker edit journal skips and counts newer lines; the forget journal skips them
    when reading and keeps them when compacting; dictation history keeps them unshown and loads the rest.
  - The reading library shows a newer `library.json` read-only. The deep-transcription queue (`UserDefaults`) is
    dropped unless its version is 1.
  - HolosEvaluation's records under `eval/` carry `schemaVersion`, but most are read without checking it
    (`EvalStore.read`; a cloud run's `run.json` is decoded and rewritten when the run resumes). Local run records
    refuse a newer version, and a reviewer's decisions file must be version 1.
- New persisted files use `HolosJSON`, carry `schemaVersion`, and refuse newer versions.
- Speaker edits go to an append-only journal (`speakers/edits.jsonl`; a torn last line is backed up and cut off
  before the next append); `SpeakerProjection` applies it to a run. An edit that no longer
  applies is reported as stale, never applied blindly.

## Dictation and insertion

- `DictationController` runs one utterance at a time: `idle → preparing → listening → finalizing → result` (or
  `failed`). Listening has no duration limit; startup and finalization time out.
- `InsertionTarget` snapshots the focused app, element and selection at key-down; insertion rechecks it. A changed
  target gives `targetChanged`; text that cannot be inserted gives `needsCopy` and waits for the user's Copy. An
  Accessibility insertion makes exactly one write attempt (never a retry), and nothing writes to the clipboard
  on its own.
- The language-model fix (`TranscriptFixer`) keeps a reply only when `AIFixGuard` accepts it as a small word-level
  edit. A separate "often heard as" term pass (`choosingTerms`) then runs on the accepted fix, or on the chunk as
  recognized when the fix was rejected, so a rejected fix can still return changed text through that pass.

## Synthesis and documents

- A render takes exact text and at most one voice. A named voice that is missing fails explicitly and is never
  replaced by another; a render that names none uses an English system voice (`NativeSpeechRenderer`).
- Finished files are published with `ExclusivePublisher`, which never replaces an existing file. Where the volume
  supports an exclusive rename (`renamex_np` with `RENAME_EXCL`) the file appears whole. Elsewhere (some exFAT and
  network volumes) it creates the destination with `O_EXCL` and copies into it, so a partly written file is
  visible until the copy ends; a failed copy is removed, and a reading's manifest keeps `publishing` so a copy cut
  off by a crash is recognized and removed when the reading is resumed. A reading resumes from its cache of
  rendered parts.
- Extraction failures are explicit; no extractor substitutes a summary for the text.

## Errors and output

- Throw `HolosError` (`invalidInput`, `unavailable`, `permissionDenied`, `incomplete`, `io`) with a message that
  says what to do next. Do not add cases; machine-readable reasons travel in data (`StopReason`, `ControlResult`,
  `PostProcessingState`).
- The rule for new code is that `CancellationError` passes through unchanged (`docs/conventions.md §1.4`).
  Known exception: `ReadingPipeline` turns any failure while rendering or joining parts, cancellation included,
  into `HolosError.incomplete` after a best-effort save of its manifest, so a stopped reading reports "Reading
  stopped at part …".
- Transcription failure after a successful recording keeps and names the saved audio.
- CLIs put content and JSON on stdout and progress on stderr; exit codes are in `docs/conventions.md §1.4`.
- Logs use `Logger(subsystem: "ca.orlenko.holos.app", …)`. Never log transcript text, names, vocabulary or
  embeddings; user paths only as `.private` (`docs/conventions.md §1.5`).
