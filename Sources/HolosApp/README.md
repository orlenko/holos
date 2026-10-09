# HolosApp

The menu bar app (`VoiceIsLocal.app`, built by `scripts/build-app.sh`): AppKit views, windows, menus, and the
wiring between them and the library controllers (docs/design.md "Main window").

**Owns**
- `HolosApp.swift`: `HolosAppMain` (`@main`; `--check` prints a permission report) and `HolosAppDelegate`, the menu
  bar item and menu, plus 12 `HolosApp+<Area>.swift` extensions (Meeting, DeepTranscription, MeetingSummary,
  EchoCatchUp, BackgroundJobs, MainWindow, History, People, WordList, Reading, SetupAssistant, MeetingLanguage) with
  their state holders (`MeetingAppState`, `DeepTranscriptionAppState`, …). `+BackgroundJobs` wires `HolosMeeting`'s
  `BackgroundJobCoordinator`, which runs final transcripts, echo analyses and summaries.
- `MainWindow/`: `MainWindowController` (sidebar window) and the panes (History, Meetings, People, Corrections,
  Reading, Settings, live meeting view).
- `Review/`: `ReviewWindow` (+Layout, +Joining; its close types in `ReviewClosing`), `TurnListView` (+WordEditing,
  +Splitting, +Joining) with its `TurnTableView`, `TurnTextView`, `TurnScrollView` and `AssignMenu`,
  `SpeakerSidebarView`, `ReviewPlayer`, `ScreenTextPanel`. The model is `HolosMeeting`'s `ReviewSession`.
- `Reading/`: `ReadingController`, voice preview, natural voices (`HelperNaturalRenderer` runs each natural part
  in `voiceislocal say`; `NaturalVoiceDownload` is Settings › Reading's pack rows). Dictation UI:
  `DictationOverlay`, `DictationFixing`. Setup: `SetupAssistantWindow`. Meeting start: `MeetingStartPanel`.

**Must not own:** business logic, session-file layout or locks, decoding `voiceislocal` output by hand. Put
controllers in `HolosMeeting`/`HolosDictation` and paths in `HolosStorage`. Commands whose output the app reads go
through `HolosMeeting`'s `CommandRunner` and decode into the library's types (`DoctorReport`,
`PostProcessingRecord`, `SessionSummarizeCommand.Outcome`, `SessionEchoAnalyzeCommand.Outcome`,
`SessionRenameCommand.Outcome`). Today it still holds the dictation session, 13 files import
`HolosStorage`, and `CommandPrinted` (`HolosApp+Meeting.swift`) reads the result line of `session recover`,
`diarize`, `delete` and `rename` output as untyped JSON. Shrink these, do not copy them.

**Depends on:** HolosCore, HolosAppModel (the app's decisions without AppKit, tested without the executable),
HolosAudio, HolosSpeech, HolosDesktop, HolosDictation, HolosStorage, HolosSpeakers,
HolosMeeting, HolosSynthesis, HolosContent, HolosSpelling (installed in `HolosAppMain.main`). Never HolosDiarization, HolosWhisper or HolosPocket (they run in a
`voiceislocal` child), nor HolosEvaluation. AppKit, AVFoundation, ApplicationServices.

**Invariants**
- One instance: a second launch with the same bundle identifier exits.
- The clipboard is written only by explicit Copy actions (the menu's Copy Result and Copy Original, History's Copy
  and Copy As Heard, Review's and Corrections' copy commands), never automatically after dictation.
- Closing the last window does not quit (`applicationShouldTerminateAfterLastWindowClosed` returns false), so
  dictation, recordings and readings keep running from the menu bar.
- One natural-voice helper runs at a time (`NaturalVoiceHelperGate`); each gets the app's pid, so it stops if the
  app ends, and a scratch folder marked as the app's (`NaturalHelperScratch`), the only folder it removes.

**Tests:** `Tests/HolosAppTests` (`@testable import HolosApp`, so even a focused run builds the whole app). Tests
build views and windows inside the test process; none launches the app bundle.
