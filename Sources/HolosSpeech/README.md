# HolosSpeech

The adapter over Apple's on-device speech recognition (`SpeechAnalyzer` with `SpeechTranscriber` or
`DictationTranscriber`).

**Owns**
- `AppleSpeechEngine`: locale capabilities, asset status, installing assets, transcribing a file
  (`transcribe(file:…)`, used by `voiceislocal transcribe`), and building a module for a locale and
  `SpeechBackend` (`.speech` or `.dictation`).
- `AppleSpeechSession` (actor): one recognition session. `make(locale:backend:contextualStrings:accurate:onUpdate:)`
  starts it; frames go in with backpressure (a bounded input), results come out as `TranscriptUpdate` values.

**Must not own:** recording lifetime, capture, files, focus or insertion, transcript editing. Callers
(`HolosDictation`, `HolosMeeting`, `HolosCLI`) decide when a session starts and ends.

**Depends on:** HolosCore. Speech, AVFoundation, CoreMedia.

**Invariants**
- A session only runs with installed assets; otherwise `make` throws `HolosError.unavailable` telling the user to
  run setup. The default test suite never installs assets.
- Vocabulary (`contextualStrings`) is best effort; corrections are applied to the text afterwards by the callers.
- Recognition with installed assets runs on the Mac and uses no network. `installAssets` (`voiceislocal setup`
  and the app's install actions) is the exception: it downloads Apple's speech assets through `AssetInventory`.

**Tests:** `Tests/HolosSpeechTests/AppleSpeechEngineTests.swift`. Tests that need installed assets are opt-in
(`HOLOS_SPEECH_TEST_*` environment variables).
