# HolosApp

The menu bar app (`VoiceIsLocal.app`, built by `scripts/build-app.sh`): AppKit views, windows, menus, and the
wiring between them and the library controllers (docs/design.md "Main window").

**Owns**
- `HolosApp.swift`: `HolosAppMain` (`@main`; `--check` prints a permission report) and `HolosAppDelegate`, the menu
  bar item and menu, plus 11 `HolosApp+<Area>.swift` extensions (Meeting, DeepTranscription, MeetingSummary,
  EchoCatchUp, MainWindow, History, People, WordList, Reading, SetupAssistant, MeetingLanguage) with their state
  holders (`MeetingAppState`, `DeepTranscriptionAppState`, …).
- `MainWindow/`: `MainWindowController` (sidebar window) and the panes (History, Meetings, People, Corrections,
  Reading, Settings, live meeting view).
- `Review/`: `ReviewWindow`, `TurnListView` (+WordEditing, +Splitting), `SpeakerSidebarView`, `ReviewPlayer`,
  `ScreenTextPanel`. The model is `HolosMeeting`'s `ReviewSession`.
- `Reading/`: `ReadingController`, voice preview. Dictation UI: `DictationOverlay`, `DictationFixing`. Setup:
  `SetupAssistantWindow`. Meeting start: `MeetingStartPanel`.

**Must not own:** business logic, session-file layout or locks, decoding `voiceislocal` output by hand. Put
controllers in `HolosMeeting`/`HolosDictation` and paths in `HolosStorage`. Today it still holds the dictation
session and three background-job schedulers (`+DeepTranscription`, `+MeetingSummary`, `+EchoCatchUp`, none with
tests), 13 files import `HolosStorage`, and it decodes `voiceislocal` output by hand (`doctor --json` and
maintenance output with `JSONSerialization` in `HolosApp+Meeting.swift`, its own `SummaryOutcome` and
`EchoOutcome`; the command-runner refactor removes this). Shrink these, do not copy them.

**Depends on:** HolosCore, HolosAudio, HolosSpeech, HolosDesktop, HolosDictation, HolosStorage, HolosSpeakers,
HolosMeeting, HolosSynthesis, HolosContent. Never HolosDiarization or HolosWhisper (they run in a `voiceislocal`
child). AppKit, AVFoundation, ApplicationServices.

**Invariants**
- One instance: a second launch with the same bundle identifier exits.
- The clipboard is written only by explicit Copy actions (the menu's Copy Result and Copy Original, History's Copy
  and Copy As Heard, Review's and Corrections' copy commands), never automatically after dictation.
- Closing the last window does not quit; dictation, recordings and readings keep running from the menu bar.

**Tests:** `Tests/HolosAppTests` (16 files, `@testable import HolosApp`, so a focused run builds the whole app).
Views are tested offscreen; nothing launches the app.
