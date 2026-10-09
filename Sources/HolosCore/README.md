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
  `WordList`, `TranscriptEditLearning`, `DictationTextPipeline` (in `DictationRerun.swift`).

**Must not own:** file I/O, locks, UI, speech or model engines. Exceptions to shrink, not copy: `Lexicon`
(AppKit `NSSpellChecker`), `Corrections.swift` (reads and writes `corrections.json`, a `FolderWatcher`, its own
flock), and app-only flows (`SetupAssistantFlow`, `SettingsSearch`, `PermissionButtons`, `MainWindowLaunch`,
`AppearanceChoice`, `LicenseNotice`, `ResultRetention`, `DeclinedCorrectionQueue`).

**Depends on:** no Holos target. Foundation, NaturalLanguage (`DictationSeams`), AppKit (`Lexicon` only).

**Invariants**
- The persisted meeting and speaker types carry `schemaVersion`; within a version fields are only added, never
  renamed or removed (docs/meeting-design.md §1.6). `CorrectionList` (`corrections.json`) is an exception: plain
  `JSONEncoder`, no version (docs/contracts.md "Persistence").
- Do not add `HolosError` cases; machine-readable reasons travel in data (`StopReason`, `ControlResult`, …),
  docs/meeting-design.md §1.4.
- `HolosPaths.sessions` honours `HOLOS_DATA_DIR` and `HolosPaths.supportRoot` honours `HOLOS_SUPPORT_DIR`; build
  every Application Support path from `supportRoot`.

**Tests:** `Tests/HolosCoreTests` (`ContractCodingTests` covers JSON round trips of the shared models).
