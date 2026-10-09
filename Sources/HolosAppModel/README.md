# HolosAppModel

The app's own decisions, free of AppKit and of any controller, in a library so their tests build without the app
executable.

**Owns**
- Settings: `SettingsSearch` (the fuzzy search at the top of Settings) with `SettingsChapterTracking` and
  `SettingsScrollGeneration`; `AppearanceChoice` (Settings › General › Appearance).
- Launch and setup: `MainWindowLaunch` (whether the main window opens at launch, and on which section),
  `SetupAssistantFlow` and its `SetupAssistantFacts`, `SetupAssistantItem` and `SetupAssistantLaunch` (the Setup
  Assistant's pages and whether it opens), `PermissionButtons` (the buttons of a permission row).
- Dictation results: `ResultRetention` and `DictationResult` (what Copy Result and Copy Original offer),
  `DeclinedCorrectionQueue` (swaps learning declined, kept until the user adds or skips each one).
- `LicenseNotice` (the About panel's license notice and source links).

**Must not own:** AppKit views or windows (`HolosApp`), controllers (`HolosMeeting`, `HolosDictation`), anything
another library or `voiceislocal` needs (that goes in `HolosCore` or the library that owns it), file I/O.

**Depends on:** HolosCore. Foundation.

**Invariants**
- Only `HolosApp` and `HolosAppModelTests` depend on this target.

**Tests:** `Tests/HolosAppModelTests` (one `<Source>Tests.swift` per file here), run with
`./scripts/test-target.sh HolosAppModelTests`.
