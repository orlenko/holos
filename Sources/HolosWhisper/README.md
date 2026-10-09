# HolosWhisper

Deep transcription after a meeting with WhisperKit's Core ML Whisper models (`docs/meeting-design.md §4.16`). Only
`HolosCLI` links it; the app runs the pass through `voiceislocal session deep-transcribe`.

**Owns**
- `WhisperKitTranscriber`: the `DeepTranscriber` implementation (protocol and values in HolosCore
  `DeepTranscription.swift`): the meeting's language, the vocabulary prompt on every chunk, voice-activity chunking,
  word timestamps. One transcription at a time.
- `WhisperModels`: the install folder (`<supportRoot>/Models/whisperkit`), install status, resumable downloads for
  `voiceislocal setup --whisper`, and the `installed.json` marker written last.
- WhisperKit decoding helpers: `PromptTimestampRulesFilter`, `PromptAlignedSegmentSeeker`.

**Must not own:** where words go in the transcript (the `DeepTranscriptionStage` in `HolosMeeting` merges and
publishes them), session files, scheduling (the app's deep-transcription queue).

**Depends on:** HolosCore. WhisperKit (pinned at 1.1.0 in `Package.swift`), CoreML.

**Invariants**
- The transcriber loads only from the install folder and never downloads; a model counts as installed only once
  `installed.json` exists.
- One process installs or checks a model at a time (`.<model>.install.lock`).

**Tests:** `Tests/HolosWhisperTests` (`WhisperModelsTests`). Real-model tests and probes are opt-in
(`HOLOS_WHISPER_MODEL_TESTS`, `HOLOS_DEEP_PROBE_*`, `HOLOS_DEEP_PIECE_*`).
