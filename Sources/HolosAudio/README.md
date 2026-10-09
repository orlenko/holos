# HolosAudio

Getting audio (and screen images) off the hardware and onto disk: capture, chunk writing, rendering a track, and
staying awake while recording.

**Owns**
- `AudioCapture` (`@MainActor`): microphone (`AVAudioEngine`) and system audio (ScreenCaptureKit) as a bounded
  `AsyncThrowingStream<CapturedAudio>`; `CaptureOverflow` (`.fail` for dictation, `.dropAndCount` for meetings),
  `PCMConversion`, `RecordingFormatConverter`, `FrameContinuity`, `BuiltInMicrophone` / `InputDevices`,
  `AudioEnvironmentEvents`.
- Writing: `AudioChunkWriter` (actor; 16-bit chunks through HolosStorage), `ChunkWriterPump` (bounded hand-off that
  records an overflow as a discontinuity), `DictationAudioWriter`.
- `TrackRenderer`: one track's chunks joined into a mono 16 kHz CAF on the session timeline, for post-stop analysis (diarization, echo analysis, deep transcription).
- `MeetingScreenCapture` (`@MainActor`): optional display capture for screen context (docs/meeting-design.md
  §4.15), with the pure `ScreenCapturePlan`, `ScreenFrameDifference`, `ScreenStoragePolicy`.
- Power: `SystemPowerMonitor` (`SystemPowerEvents`), `PowerAssertion`.

**Must not own:** transcripts, speaker names, recorder policy (when to restart or stop is `HolosMeeting`'s), UI.

**Depends on:** HolosCore, HolosStorage. AVFoundation, CoreAudio, AudioToolbox, ScreenCaptureKit, CoreImage, IOKit.

**Invariants** (docs/meeting-design.md §1.3, §2.3, §4.3)
- Real-time callbacks only copy samples into bounded queues: no `await`, file I/O, or blocking locks in them.
- A gap is recorded as a discontinuity event, never filled with fabricated audio; audio is never written twice.
- In a meeting recording, frames are consumed off the main actor, so a main-thread stall cannot overflow capture.
  Dictation is the exception: `DictationController` reads its frames in a `@MainActor` task, and its capture
  ends with an error on overflow (`CaptureOverflow.fail`) instead of dropping audio.

**Tests:** `Tests/HolosAudioTests` (synthetic frames, generated chunk files, fake displays).
`MeetingScreenCaptureTests` has opt-in benchmarks (`HOLOS_SCREEN_BENCHMARK`).
