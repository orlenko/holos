# HolosSynthesis

Text-to-speech with the voices installed on the Mac: rendering to files, playback, and audiobook writing; and the
natural voices' catalog and pack install (their backend is in `HolosPocket`).

**Owns**
- `NativeSpeechRenderer`: renders text with an `AVSpeechSynthesizer` voice to an audio file (`VoiceDescriptor`,
  `RenderedAudio`, `SpeechRate`).
- `VoiceSelection` and `ReadingVoiceMenu` / `ReadingSpeed`: finding and ranking installed voices. Pure: callers pass
  the installed voices and the user's languages.
- `SpeechPlayback`: plays one file at a time under a per-user playback lock (`voiceislocal say`).
- `AudioBookWriter`: joins rendered parts into one AAC `.m4a` with metadata and chapters.
- `NaturalVoiceCatalog` (`NaturalVoices.swift`): the Pocket TTS voices and their recordings' licences; only voices
  whose licence allows commercial use are offered. `NaturalSpeechBackend` is the seam the renderer speaks through.
- `NaturalVoiceModels` and `NaturalVoicePackFiles`: a pack's folder (`<supportRoot>/Models/pocket-tts/<pack>`,
  `HOLOS_POCKET_MODELS_DIR`), its install (staging, checks, warm-up, the `installed.json` marker with the commit and
  file inventory), status and readiness. The download and check steps come from `HolosPocket`.
- `NaturalSpeechRenderer`: renders with a natural voice paragraph by paragraph (`NaturalSpeechPlan`), with a fixed
  seed, Speed as a time-stretch (`NaturalSpeechSpeed`, `TimeStretch`), and each paragraph heard back
  (`SpeechChunkCheck`, numbers written out in words on both sides with HolosCore's `SpelledNumbers`), rendered
  again or read by a system voice (`ParagraphFallback`) when it fails; one render at a time per renderer.
  `NaturalRenderSettings` are what a caller can keep across runs. `NaturalVoiceTemporaries` sweeps the folders a killed render
  leaves.
- `NaturalHelperRun`, `ProcessExitWatch`, `NaturalOutputLock`, `NaturalHelperScratch`
  (`NaturalVoiceHelperGuard.swift`): the app's `voiceislocal say` helper stops when the app ends, waits for an
  earlier helper writing the same output, and removes only the scratch folder the app made for it.
- `ExclusivePublisher`: moves a finished file into place without ever replacing an existing one; every file the
  renderer and the reading pipeline publish goes through `publish`.

**Must not own:** document loading or web fetching (`HolosContent`), meeting recording, FluidAudio (`HolosPocket`).

**Depends on:** HolosCore. AVFoundation / AVFAudio, AudioToolbox, CryptoKit.

**Invariants**
- Publishing never replaces an existing file. With an exclusive rename (`RENAME_EXCL`) the file appears whole;
  on volumes without one, `ExclusivePublisher` creates the destination with `O_EXCL` and copies into it, so the
  partly written file is visible until the copy ends. A failed copy is removed; if that removal cannot be
  confirmed, `CleanupFailed` names the file so the caller can finish later.
- A natural voice pack counts as installed only when its marker names `NaturalVoiceModels.revision` and every file
  it inventories is in place, read under the pack's shared lock; one process installs a pack at a time
  (`.<pack>.install.lock`).
- A render that names a voice fails (`HolosError.unavailable`) when that voice is missing; it never substitutes
  another. A render that names none uses an English system voice (`defaultVoiceIdentifier`: the current locale
  when it is English, else en-US).

**Tests:** `Tests/HolosSynthesisTests`. `NativeSpeechRendererTests` renders real speech to files and
`AudioBookWriterTests` joins generated tones (both `.serialized`); `NaturalVoiceInstallTests` installs fake packs in
temporary folders; `NaturalSpeechRenderingTests` uses a fake backend and checker. Nothing is played aloud.
