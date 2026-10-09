# Component and data contracts

The contracts between targets and processes as the code implements them. Ownership (what each target owns, must
not own, and may import) is the module map in [AGENTS.md](../AGENTS.md#module-map), with details in each
`Sources/<Module>/README.md`. The full meeting design is [meeting-design.md](meeting-design.md) §1–§4.

Prefer concrete structs, enums and actors; add a protocol only at a real seam (an engine, the hardware, a child
process, a clock). Do not build a plugin framework.

## Seams

The protocols that exist, and what implements them:

| Protocol | Target | Live implementation | Used for |
|---|---|---|---|
| `SpeakerDiarizer` | HolosCore | `FluidDiarizer` (HolosDiarization) | Diarization; tests use `FakeDiarizer` |
| `DeepTranscriber` | HolosCore | `WhisperKitTranscriber` (HolosWhisper) | Deep transcription after a meeting |
| `MeetingCapture` | HolosMeeting | `LiveMeetingCapture`, `IndependentMeetingCapture` | Recording without hardware in tests |
| `LiveSpeechSession` | HolosMeeting | `AppleSpeechSession` (HolosSpeech) | Live recognition during a recording |
| `RecorderLauncher` | HolosMeeting | `ChildProcessLauncher`, `InProcessLauncher` | How the app starts a recorder |
| `SessionClock` | HolosMeeting | `ContinuousSessionClock` (`ManualSessionClock` in tests) | Session time |
| `RecorderStopSource` | HolosMeeting | `SignalStopController`, `ManualStopSource` | Stop requests |
| `RecordingReporter` | HolosMeeting | `ConsoleReporter` (HolosCLI) | Recording progress |
| `SystemPowerEvents`, `PowerAssertionHandle` | HolosAudio | `SystemPowerMonitor`, `PowerAssertion` | Sleep and wake |
| `FreeSpaceProvider` | HolosStorage | `VolumeFreeSpace` (`FixedFreeSpace` in tests) | Disk policy |
| `ReadingAudioRenderer`, `ReadingAudioJoiner`, `ReadingPlayback` | HolosContent | `NativeSpeechRenderer`, `AudioBookJoiner`, `AVAudioPlayer` | Reading pipeline and player |
| `EchoAudioSource` | HolosSpeakers | `RenderedEchoAudio` (HolosMeeting), `InMemoryEchoAudio` | Acoustic echo analysis over values |

## Processes

- The app never links FluidAudio or WhisperKit. It runs `voiceislocal` children through `ProcessSpawner`
  (close-on-exec by default, own session): the recorder (`record start --session-id …`) and maintenance commands
  (`session diarize`, `deep-transcribe`, `summarize`, `echo-analyze`, `recover`, `delete`, `rename`;
  `setup --speakers`, `setup --whisper`, `doctor --json`).
- App ↔ recorder talk through files in the private session folder, not sockets or XPC (meeting-design.md §4.1):
  the app or CLI writes one allowlisted, versioned request (`stop`, `pause`, `resume`, `marker`) for an exact
  session ID as `control/<UUID>.json`; the recorder applies it at most once and acknowledges it in `status.json`,
  which it rewrites as a heartbeat. SIGINT and SIGTERM stop gracefully.
- The recorder owns the archive's writer lock and hands the processing lease to post-processing; a child it starts
  can inherit the lease (`--lease-fd`). `InProcessLauncher` runs the same workflow inside the app, and still runs
  diarization in a child.

## Capture and recognition

- `PCMFrame` owns its samples and timing. Capture callbacks copy borrowed buffers before returning and only enqueue
  into bounded queues: no `await`, file I/O, resampling or model work in them.
- Queues are bounded with explicit overflow handling: dictation's capture fails on overflow
  (`CaptureOverflow.fail`); a meeting drops, counts, and records the gap as a discontinuity (`.dropAndCount`,
  `ChunkWriterPump`). Missing audio is never filled with fabricated samples.
- Recognition results are `TranscriptUpdate` values (a segment plus `isFinal`). `TranscriptReducer` replaces
  provisional segments over the same interval, never duplicates them, and refuses to replace finalized audio. Empty
  final results add no text.
- One task feeds a recognition session; `AppleSpeechSession` applies backpressure outside the audio callback.

## Persistence

- `SessionArchive` is the only mutable owner of an active archive. Writes go through `AtomicFile` (write, fsync,
  rename, folder fsync). The event journal has increasing sequence numbers; a failed append is truncated back, and a
  damaged line is skipped and counted. Details and lock rules: meeting-design.md §1.6, §1.7.
- Session files and the HolosStorage stores (speaker data, profiles, dictation history, word list) are encoded
  with `HolosJSON` and carry `schemaVersion`; readers refuse a version newer than they know (the edit journal
  skips such lines instead; meeting-design.md §1.6), and growable code sets are `OpenStringCode`s. Exceptions today: `corrections.json` (`CorrectionList`) uses a plain `JSONEncoder` and has
  no version; the reading pipeline and library (`ReadingManifest`, `library.json`) carry `schemaVersion` but use
  their own encoders; small values kept in `UserDefaults` (review maintenance entries, the meeting-source notice)
  are plain JSON without a version. New persisted files follow the `HolosJSON` rule.
- Speaker edits go to an append-only journal; `SpeakerProjection` applies it to a run. An edit that no longer
  applies is reported as stale, never applied blindly.

## Dictation and insertion

- `DictationController` runs one utterance at a time: `idle → preparing → listening → finalizing → result` (or
  `failed`). Listening has no duration limit; startup and finalization time out.
- `InsertionTarget` snapshots the focused app, element and selection at key-down; insertion rechecks it. A changed
  target gives `targetChanged`; text that cannot be inserted gives `needsCopy` and waits for the user's Copy. There
  is no second automatic paste, and nothing writes to the clipboard on its own.
- The language-model fix (`TranscriptFixer`) keeps a reply only when `AIFixGuard` accepts it as a small word-level
  edit; anything else keeps the chunk as recognized.

## Synthesis and documents

- Each render names one voice and exact text. A missing voice fails explicitly; nothing substitutes another.
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
- The rule for new code is that `CancellationError` passes through unchanged (meeting-design.md §1.4). Known
  exception: `ReadingPipeline` turns any failure while rendering or joining parts, cancellation included, into
  `HolosError.incomplete` after a best-effort save of its manifest, so a stopped reading reports "Reading stopped at part …".
- Transcription failure after a successful recording keeps and names the saved audio.
- CLIs put content and JSON on stdout and progress on stderr; exit codes are in meeting-design.md §1.4.
- Logs use `Logger(subsystem: "ca.orlenko.holos.app", …)`. Never log transcript text, names, vocabulary or
  embeddings; user paths only as `.private` (§1.5).
