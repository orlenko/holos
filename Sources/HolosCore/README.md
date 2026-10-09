# HolosCore

The values every other target shares, and text processing that needs no engine.

**Owns**
- Value types: `Models.swift` (`Transcript`, `TranscriptSegment`, `TimedWord`, `PCMFrame`, `HolosError`,
  `HolosPaths`), `MeetingModels.swift` (recorder status, control requests, post-processing records),
  `SpeakerModels.swift` (diarization runs, turns, edits, `SpeakerDiarizer`), `VoiceProfiles.swift`,
  `DeepTranscription.swift` (`DeepTranscriber`), `DictationHistory.swift`.
- `HolosJSON` (the encoder and decoder for session files and the HolosStorage stores) and `OpenStringCode`.
- Text processing: `TranscriptFixer` (language-model fix of misheard words, with an injected model and the
  `AIFixGuard` check), `SpokenCode`, `DictationSeams`, `FillerWords`,
  `WordList`, `TranscriptEditLearning`, `DictationTextPipeline` (with Run Again's report types), `SpelledNumbers` (the
  numbers of a text written out in English or French words with Foundation's `NumberFormatter`).

- `SpellChecking` and `SystemSpelling` (`Lexicon.swift`): the spell checker `Lexicon` and `DictationSeams` ask,
  installed by each executable (HolosSpelling's `SystemSpellChecker`); until one is installed every word is known.

**Must not own:** file I/O, locks, UI, speech or model engines. `corrections.json`'s location, reading, writing and
lock are in HolosStorage (`CorrectionsFile.swift`); the system spell checker is in HolosSpelling; app-only models
go in `HolosAppModel`.

**Depends on:** no Holos target. Foundation, NaturalLanguage (`DictationSeams`).

**Invariants**
- The top-level persisted types here carry `schemaVersion` (`Transcript`, `MeetingInfo`, `RecorderStatus`,
  `PostProcessingRecord`, `DiarizationRun`, `SpeakerHead`, `SpeakerEdit`, `SpeakerProfileDatabase`,
  `DictationRecord`, `WordList`, …); within a version fields are only added, never renamed or removed
  (`docs/meeting-design.md §1.6`). `CorrectionList` (`corrections.json`) is the exception: plain `JSONEncoder`, no
  version. How each reader treats a newer version: docs/contracts.md "Persistence".
- Do not add `HolosError` cases; machine-readable reasons travel in data (`StopReason`, `ControlResult`, …),
  `docs/meeting-design.md §1.4`.
- `HolosPaths.sessions` honours `HOLOS_DATA_DIR` and `HolosPaths.supportRoot` honours `HOLOS_SUPPORT_DIR`; build
  every Application Support path from `supportRoot`.

**Tests:** `Tests/HolosCoreTests` (`ContractCodingTests` covers JSON round trips of the shared models). Tests that
judge words with the real spell checker carry the `.systemSpelling` trait (`SystemSpellingTrait.swift`), which
installs it.
