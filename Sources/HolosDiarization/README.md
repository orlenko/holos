# HolosDiarization

Speaker diarization with FluidAudio's offline Core ML models (`docs/meeting-design.md §4.8`). Only `HolosCLI` links
it; the app runs diarization in a `voiceislocal` process.

**Owns**
- `FluidDiarizer` (actor): the `SpeakerDiarizer` implementation (protocol in HolosCore) over FluidAudio, with
  `FluidDiarizerConfiguration`.
- `FluidModels`: where the speaker models live (`<supportRoot>/Models/speaker-diarization-coreml@<revision>`), their
  install status, installing them (`voiceislocal setup --speakers`), and verifying them against `PinnedModels`
  (every file's size and SHA-256 at the pinned revision; `ModelTreeDigest`).
- `Int16CAFSampleSource`: feeds a rendered 16 kHz track to FluidAudio. `HolosPaths.models`.

**Must not own:** speaker turns, alignment, names or exports (`HolosSpeakers`, `HolosMeeting`), session files.

**Depends on:** HolosCore. FluidAudio (pinned at 0.17.1 in `Package.swift`), CryptoKit, Accelerate.

**Invariants**
- FluidAudio is imported only in `FluidDiarizer.swift`, `FluidModels.swift` and `Int16CAFSampleSource.swift`.
  This target never imports HolosSpeakers: FluidAudio's `WordTiming` and `AudioSource` clash with Holos types, so
  write `HolosCore.AudioSource` where both are visible (`docs/meeting-design.md §1.1`).
- Models that are missing or fail verification make `diarize` throw; nothing downloads during a diarization.
- FluidAudio's `OfflineDiarizerManager` is not `Sendable`: create, use and drop it inside one function; cache only
  the models (`docs/meeting-design.md §1.3`).

**Tests:** `Tests/HolosDiarizationTests` (`ModelVerificationTests`, `SampleSourceTests`). Real-model tests are
opt-in: `HOLOS_DIARIZATION_FIXTURE=1` (`FluidDiarizerFixtureTests`).
