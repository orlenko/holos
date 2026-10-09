# HolosSynthesis

Text-to-speech with the voices installed on the Mac: rendering to files, playback, and audiobook writing.

**Owns**
- `NativeSpeechRenderer`: renders text with an `AVSpeechSynthesizer` voice to an audio file (`VoiceDescriptor`,
  `RenderedAudio`, `SpeechRate`).
- `VoiceSelection` and `ReadingVoiceMenu` / `ReadingSpeed`: finding and ranking installed voices. Pure: callers pass
  the installed voices and the user's languages.
- `SpeechPlayback`: plays one file at a time under a per-user playback lock (`voiceislocal say`).
- `AudioBookWriter`: joins rendered parts into one AAC `.m4a` with metadata and chapters.
- `ExclusivePublisher`: moves a finished file into place without ever replacing an existing one; every file the
  renderer and the reading pipeline publish goes through `publish`.

**Must not own:** document loading or web fetching (`HolosContent`), meeting recording.

**Depends on:** HolosCore. AVFoundation / AVFAudio, AudioToolbox.

**Invariants**
- A published file is complete: rendering writes elsewhere and publishes by an exclusive rename; no partly
  written file is ever at the final path.
- Voice lookup fails explicitly (`HolosError.unavailable`) when a voice is missing; nothing substitutes another.

**Tests:** `Tests/HolosSynthesisTests`. `NativeSpeechRendererTests` renders real speech to files and
`AudioBookWriterTests` joins generated tones (both `.serialized`); nothing is played aloud.
