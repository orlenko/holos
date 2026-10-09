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
- `SpokenNumbers`: the numbers a text says, by value, from digits or English and French number words, for comparing
  a paragraph of numbers with what a recognizer heard.
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
temporary folders; `SpokenNumbersTests` is pure. Nothing is played aloud.
