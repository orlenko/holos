# HolosDictation

Dictation without the UI: one microphone utterance at a time, and Run Again over a saved dictation.

**Owns**
- `DictationController` (`@MainActor`, no AppKit): capture → recognition → result for one utterance, reported as
  `DictationStatus` (`DictationPhase`: idle, preparing, listening, finalizing, result, failed). Capture and speech
  are injected (`DictationDependencies`), so tests run without a microphone or speech assets.
- `DictationSessionPolicy`: whether dictation is suspended, independent of meetings.
- `DictationRerun` (docs/design.md "Dictation audio and Run Again"): recognizes saved dictation audio as live
  dictation would, runs the current text steps, and compares with what History kept. `DictationPreferences` reads
  the app's saved dictation settings. `OnDeviceFix`: Apple Intelligence's fix of misheard words
  (FoundationModels), used by dictation and Run Again.

**Must not own:** inserting text or the hotkey (`HolosDesktop`), the overlay and menus (`HolosApp`), history files
(`HolosStorage`). The text steps themselves (`DictationTextPipeline`, `TranscriptFixer`, `DictationSeams`) are in
`HolosCore`.

**Depends on:** HolosCore, HolosAudio, HolosSpeech. FoundationModels.

**Invariants**
- Listening has no duration cutoff; only startup and post-release finalization time out.
- Settings read at the start of an utterance (locale, vocabulary, seam terms) do not change an utterance in
  progress.
- Run Again writes nothing into any app and copies nothing.

**Known split:** `HolosCore/DictationRerun.swift` (pure text pipeline) and `HolosDictation/DictationRerun.swift`
(I/O and settings) share a file name but hold different types. The dictation session that drives this controller
still lives in `HolosApp/HolosApp.swift`.

**Tests:** `Tests/HolosDictationTests` (`DictationControllerTests`, `DictationRerunTests`,
`DictationSessionPolicyTests`).
