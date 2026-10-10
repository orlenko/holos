# Meeting controls in the app

The menu bar's meeting controls, the start panel, the Meetings window, reattaching, automatic relabel and the
"Name Speakers" offer. §5.8 comes from the build plan and names the PR that built it; the code cites it for
behaviour.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 5.8 PR4: Menu bar meeting controls (wave 4)

**Goal.** Start, watch, pause, mark, and stop meetings from the menu bar; launch the
bundled recorder as a child (or in-process); reattach after an app crash and notice
terminal-started meetings; prompt about interrupted sessions and relabel them
automatically; confirm quit during a recording; keep dictation available while a meeting is
active; install speaker models from the app; list, open, save, and delete meetings; and
lead to naming speakers after a meeting.

**Files.**

- HolosMeeting, add: `MeetingReducer.swift` (pure), `MeetingController.swift`
  (`@MainActor`, no AppKit), `RecorderLauncher.swift` (`RecorderLauncher` protocol,
  `ChildProcessLauncher`, `InProcessLauncher`, `MaintenanceLauncher` for
  `holos session recover|diarize|delete` and `holos setup --speakers` children, and the
  shared `posix_spawn` helper), `AutoRelabelPolicy.swift` (pure).
- HolosApp, add: `HolosApp+Meeting.swift` (menu section, actions, concurrent dictation),
  `MeetingStartPanel.swift`, `MeetingsWindow.swift`, `LiveTranscriptWindow.swift`,
  `AboutCredits.swift`.
- HolosApp, change: `HolosApp.swift` (stored properties, launch hooks,
  `applicationShouldTerminate`, menu insertion points, independent dictation controls), `SetupWindow.swift` ("Speaker labels" row).
- Change `Resources/App-Info.plist` (`NSMicrophoneUsageDescription`: "Holos uses your
  microphone for push-to-talk dictation and for meeting recordings you start.";
  `CFBundleVersion` 3), `scripts/build-app.sh` (bundle the CLI), `Package.swift`
  (§1.2 wave 4, identical to PR10's edit).
- Add `docs/meeting-validation.md` with sections "Recording controls (PR4)", "Review
  window (PR9)", "Online calls (PR11)"; the last two contain only `Pending.`
- Tests: `Tests/HolosMeetingTests/{MeetingReducerTests, MeetingControllerTests, LauncherTests, AutoRelabelPolicyTests}.swift`.
  PR4 owns `Fakes.swift` and `SessionFixtures.swift` edits in wave 4.

**API.**

```swift
public struct MeetingStartSettings: Codable, Sendable, Equatable {
    public var name: String
    /// .microphone ("In person") or .microphoneAndSystem ("Online call").
    public var source: AudioSource
    public var applicationBundleID: String?
    public var othersInRoom: Bool
    public var expectedSpeakers: Int?
    public init(name: String, source: AudioSource, applicationBundleID: String? = nil, othersInRoom: Bool = false,
                expectedSpeakers: Int? = nil)
    /// "Meeting 2026-09-23 14:00" in `timeZone`.
    public static func defaultName(now: Date, timeZone: TimeZone) -> String
}

public enum MeetingState: Sendable, Equatable {
    case idle
    case starting(sessionID: String, since: Date, pid: Int32?)
    /// Recorder phase starting…stopping (including waiting and unknown).
    case active(sessionID: String, status: RecorderStatus)
    /// Capture stopped; transcribing or post-processing.
    case finishing(sessionID: String, status: RecorderStatus?)
    case failed(sessionID: String?, message: String)
}

public enum MeetingEvent: Sendable, Equatable {
    case startRequested(MeetingStartSettings, sessionID: String, at: Date)
    case launched(pid: Int32?, at: Date)
    case launchFailed(message: String)
    case statusRead(RecorderStatus?, liveness: RecorderLiveness, at: Date)
    case childExited(code: Int32, logTail: String?, at: Date)
    case tick(at: Date)
    case stopConfirmed
    case pauseRequested
    case resumeRequested
    case markerRequested(label: String?)
    case reattached(sessionID: String, status: RecorderStatus)
    case reviewOpened(sessionID: String)
    case dismissFailure
}

public enum MeetingEffect: Sendable, Equatable {
    case launch(MeetingStartSettings, sessionID: String)
    case send(ControlCommand, label: String?, sessionID: String)
    /// SIGTERM to the child: a graceful stop while starting, or the 120 s start timeout.
    case terminateChild(sessionID: String)
    case announce(String)                // first menu line / status item tooltip
    case finished(sessionID: String, summary: String, speakersReady: Bool)
    /// "Name Speakers — <name>…" at the top of the menu and a dot on the status item, until reviewed.
    case offerNaming(sessionID: String, name: String)
    case clearNamingOffer(sessionID: String)
}

public struct MeetingReducer: Sendable, Equatable {
    public private(set) var state: MeetingState
    public init()
    public mutating func reduce(_ event: MeetingEvent) -> [MeetingEffect]
}

@MainActor public protocol RecorderLauncher: AnyObject {
    /// Starts a recorder for `sessionID`; returns the child pid (nil for in-process).
    func launch(_ settings: MeetingStartSettings, sessionID: String, root: URL, vocabularyFile: URL?) throws -> Int32?
    func terminate(sessionID: String)
    var onExit: ((Int32, String?) -> Void)? { get set }      // exit code, last log line
}

@MainActor public final class ChildProcessLauncher: RecorderLauncher {
    /// Default: Bundle.main.bundleURL/Contents/MacOS/holos.
    public init(executable: URL, logDirectory: URL)
    /// ["record", "start", "--session-id", id, "--name", name, "--source", src, ("--app", id)?,
    ///  ("--others-in-room")?, ("--expected-speakers", n)?, ("--vocabulary-file", path)?,
    ///  "--no-live-text", "--directory", root.path]
    public static func arguments(_ settings: MeetingStartSettings, sessionID: String, root: URL,
                                 vocabularyFile: URL?) -> [String]
}
@MainActor public final class InProcessLauncher: RecorderLauncher { public init() }
@MainActor public final class MaintenanceLauncher {
    public init(executable: URL)
    /// Runs `holos <arguments> --json` detached (POSIX_SPAWN_SETSID, CLOEXEC); returns the pid.
    public func run(_ arguments: [String], onExit: @escaping @MainActor (Int32) -> Void) throws -> Int32
}

public enum AutoRelabelPolicy {
    /// Sessions to relabel now, at most one: origin recorded, created in the last 7 days, speaker state
    /// interrupted or none (or notLabelled for a reason other than missing models), no speaker edits,
    /// liveness exited or dead, fewer than 2 attempts; only when models are installed and no meeting is active.
    public static func candidates(_ summaries: [SessionSummary], attempts: [String: Int], modelsInstalled: Bool,
                                  meetingActive: Bool, now: Date) -> [SessionSummary]
}

@MainActor public final class MeetingController {
    public private(set) var reducer: MeetingReducer
    public var state: MeetingState { get }
    public var status: RecorderStatus? { get }
    public init(root: URL = HolosPaths.sessions, launcher: any RecorderLauncher, maintenance: MaintenanceLauncher?,
                freeSpace: any FreeSpaceProvider, findInputDevices: @escaping @Sendable () -> InputDevices,
                vocabulary: @escaping @MainActor () -> [String], modelsInstalled: @escaping @MainActor () -> Bool,
                now: @escaping @MainActor () -> Date = Date.init,
                onChange: @escaping @MainActor (MeetingState) -> Void,
                onEffect: @escaping @MainActor (MeetingEffect) -> Void)
    /// Finds a live meeting (§4.1), then polls its status every second; while idle, rescans every 3 s and runs
    /// the automatic relabel every 30 s.
    public func attachOnLaunch()
    /// Disk and microphone checks, writes the vocabulary file (0600), then launches. Throws with the start
    /// panel's error text.
    public func start(_ settings: MeetingStartSettings) throws
    public func confirmStop()
    public func pause()
    public func resume()
    public func addMarker(label: String?)
    public func reviewOpened(sessionID: String)
    /// Interrupted sessions not yet prompted about (SessionCatalog).
    public func interruptedSessions(excluding prompted: Set<String>) -> [SessionSummary]
}
```

**Reducer rules.**

- `startRequested` (idle) → `starting`, effects `launch`. Not
  idle → `announce("A meeting is already recording.")`. `launched(pid)` records the pid.
  `launchFailed` → `failed(message)`.
- While `starting`, liveness comes from the child process, not the folder: a missing
  folder or status is normal. `tick` 5 s after the start without a `recording` status →
  `announce("Waiting for permission…")` once. `tick` 120 s after →
  `terminateChild`, `failed("The recorder did not start within 2 minutes. Details:
  ~/Library/Logs/Holos/recorder-<id>.log")`.
  `childExited` while starting → `failed(logTail ?? "The recorder stopped before
  recording started.")`; no "Recover" text, because nothing
  was saved. `stopConfirmed` while starting → `terminateChild` (SIGTERM is a graceful
  stop).
- A fresh `statusRead` for the launched or attached session with phase `isMeetingActive`
  → `active` from any state, including `failed`.
- `statusRead` phase `transcribing`/`postprocessing` → `finishing`.
- `statusRead` phase `exited` → `idle`, `finished(id, summary, speakersReady)`, and
  `offerNaming` when speakers are ready (post-processing `succeeded` or `partial`, then
  checked against the saved labels by `MeetingController`). Summary: "Saved Council meeting (2:58:12).
  Speakers labelled." or the exit's post-processing message ("… No speaker labels:
  speaker models are not installed.").
- `active` + (liveness `dead`, or `childExited` without an `exited` status) →
  `failed("The recorder stopped unexpectedly. Recover the saved audio from Meetings.")`.
- `finishing` + (liveness `dead`, or `childExited` without an `exited` status) → `idle`,
  `finished(summary: "Saved Council meeting. Speaker labelling stopped; Holos will retry
  it, or use Label Speakers in Meetings.", speakersReady: false)`.
- `stopConfirmed` in `active` → `send(.stop)` once; repeats while already stopping are
  ignored. `pause`/`resume`/`marker` → `send`.
- `reviewOpened` → `clearNamingOffer`. `dismissFailure` → `idle`.

**UI.**

Status item: idle shows the existing waveform icon (with a small dot while a naming
offer is pending). While active its title is `● 1:23:45` (red `record.circle.fill`
plus monospaced digits from `status.elapsedSeconds`), `⏸ 1:23:45` when paused,
`◌ 1:23:45` while waiting for audio, with `⚠` appended while a warning is present.
While finishing: `waveform` plus `…`.

Menu while recording (the normal dictation block remains available, §4.12):

```
● Recording — Council meeting                      (disabled)
  1:23:45 · 0.9 GB used · 22.8 GB free               (disabled)
  Microphone: Built-in Microphone                    (disabled)
  Transcription: live   |   behind — will finish after stop
  ⚠ <warning message>                                (one line per warning, disabled)
  Pause Recording            |   Resume Recording
  Add Marker…                                        (prompt for an optional label)
  Show Live Transcript…
  Stop and Save…
──────────────
Dictation ready (or off, according to the user's choice)            (disabled)
Enable / Disable Dictation
Cancel Dictation / Copy Result / Discard Result        (when applicable)
Correct Last Dictation…
──────────────
Meetings…
Setup…
About Holos
Quit Holos
```

"Stop and Save…" asks: "Stop and save “Council meeting”?" with the informative text
"Holos then labels speakers, which takes about 2 minutes for a 3-hour meeting. Keep the
lid open until it finishes." `[Stop and Save]` `[Keep Recording]`. The live transcript's
header and the meeting's menu in Meetings offer the same Pause / Resume and Stop and Save…
with the same rules and the same path (`MeetingRecordingControls`,
`HolosAppDelegate.performMeetingRecordingCommand`; docs/design.md "Live transcript"); from
the main window the question is a sheet on it.

Idle menu: `Name Speakers — Council meeting…` at the top while offered (PR4 opens the
Meetings window with that session selected; PR9 opens Review), then
`Start Meeting Recording…`, the dictation items as today, and `Meetings…` above
`Setup…`. While finishing: `Saving Council meeting — labelling speakers 42%` (from
`status.progress`).

Start panel (`NSPanel`, titled "New Meeting Recording", 460 × ~380, floating like Setup):

```
Name      [Meeting 2026-09-23 14:00                     ]
Type      (•) In person — microphone
          ( ) Online call — microphone and system audio
                App   [Any app                      ▾]   (running apps with a bundle ID)
                [ ] Others are in the room with me (label speakers on my microphone too)
Mic       Built-in Microphone   |   AirPods Pro (system default)    (static label; red if unavailable)
People    [   ] expected (optional)                    (shown only if PR7c found the hint helps)
Disk      ≈1.0 GB for 3 h · 24.1 GB free                (orange = warn, red = refuse)
Speakers  Speaker labels ready   |   Speaker models not installed [Install…]
ⓘ Tell everyone you are recording.  [ ] Don't show this again
                                             [Cancel]  [Start Recording]
```

Start is disabled when `DiskPolicy.startCheck` refuses or, in person, the built-in
microphone is missing. The last settings are saved in `UserDefaults` key
`meeting.lastSettings` (JSON of `MeetingStartSettings` without the name); the consent
reminder's dismissal in `meeting.consentReminderDismissed`. The "People expected" field
exists only if `docs/speaker-evaluation.md` (PR7c) shows that the speaker-count hint
lowers joint-speech confusion or recovers merged speakers; otherwise PR4 omits it and
`expectedSpeakers` stays nil.

Setup window: a "Speaker labels" row with the status from `holos doctor --json`
(`speakerModels`) and an `Install (21 MB download)` button that runs
`holos setup --speakers` through `MaintenanceLauncher` and shows its progress.

Meetings window (`NSWindow` 760 × 460, resizable): table with columns Name, Date,
Duration (`savedSeconds`), State, Speakers, Size; buttons under it: `Recover…`
(interrupted or damaged-but-readable), `Label Speakers` (speaker state none, notLabelled,
failed, interrupted; runs `holos session diarize <path>`), `Show in Finder`,
`Open Transcript` (Quick Look preview of `exports/transcript.md`),
`Save Transcript As…` (NSSavePanel: md or txt), `Delete Audio…`, `Delete Meeting…`, and
`Clean Up` when `derivedBytes > 0`. Footer: "Meetings use 12.4 GB · 21.3 GB free".
Double-click opens the Quick Look preview (PR9 changes it to Review). Refreshes every
2 s while visible. Button enablement is `MeetingActionPolicy.enabled`, the rules of the
commands behind the buttons: Recover when `SessionRecoveryCommand.rebuilds` would rebuild
(asked with the catalog's readable transcript, so a `transcriptionIncomplete` or `incomplete`
meeting whose transcript cannot be read qualifies) or the meeting is interrupted, never for a
damaged manifest or a transcript from a newer Holos; Label Speakers for speaker state none,
notLabelled, failed, or interrupted, or (any state but unreadable) while a missed language of
a meeting in several can be detected now (`LanguageWork.ready`, docs/meeting/languages.md §4.14 step 5), with a
readable transcript and audio, not interrupted. No
lease-taking action while the app uses the meeting or another process holds it (liveness
capturing, processing, maintenance).

Live transcript: no longer a window; it is part of the main window's Meetings section, with
volatile words from the recorder's `live.json` and microphone echo hidden (docs/design.md
"Live transcript").

Interrupted prompt: after `attachOnLaunch`, for each interrupted session not in
`UserDefaults "meeting.promptedInterrupted"`: alert "Holos found an interrupted
recording: Council meeting (1:12:40 saved)." `[Recover]` `[Later]`. Recover runs
`holos session recover <path>` via `MaintenanceLauncher`.

Automatic relabel: on launch and every 30 s while idle, `AutoRelabelPolicy.candidates`
picks at most one session and `MaintenanceLauncher` runs `holos session diarize <path>
--json`; attempts are counted in `UserDefaults "meeting.relabelAttempts"`. This covers a
Mac shut down or put to sleep while labelling.

Naming offer: derived from saved state, never emitted per path
(`MeetingController.refreshNamingOffer`, rule `NamingOfferPolicy.offer`). Among recorded
meetings with liveness exited or dead whose labels are ready and were made in the last 7 days
(`SessionSummary.labelsReadyAt`, the head run's `createdAt`), the one labelled last is offered,
unless its speakers were edited or the user opened the offer for that run (UserDefaults
`meeting.namingOffersDismissed`, session ID → run ID; another run of the meeting is offered
again). `createdAt` is saved to the whole second, so meetings labelled in the same second are
all the latest: the first of them by ID that is neither edited nor dismissed is offered. It is derived on launch, when a followed recording finishes, and whenever the app's use
of a meeting ends (`endUsing`: a Meetings command, the interrupted prompt's Recover, Clean Up,
Save Transcript As…, the automatic relabel), so a meeting labelled after Holos quit, by a
command in a terminal, or by any of those paths is offered, also after a relaunch. Each change
is reported once, as `offerNaming` or `clearNamingOffer`; `reviewOpened` dismisses it.

Meetings in use: `MeetingController.sessionsInUse` (session ID → what the app is doing) is the
one set of meetings the app works on. Every operation of the app that takes a meeting's
processing lease, or reads it for the user, holds an entry while it runs (`beginUsing` refuses a
second one): Recover, Label Speakers, Delete Audio, Delete Meeting, the interrupted prompt's
Recover, Clean Up, Save Transcript As…, and the automatic relabel. The relabel skips these
meetings, every Meetings action refuses them, and the State column shows what is running.

Labels are ready (a finished meeting's `speakersReady`, the naming offer, the Label Speakers
result) only when `SavedSpeakerState` finds them usable, the validation the catalog, recovery,
and the exports share (`MeetingController.speakerLabelsReady`, run off the main actor);
`speakers/head.json` alone is not enough.

Launched recorders: the pid and start time of each recorder child are kept in
`UserDefaults "meeting.launchedRecorders"` until its exit is seen. A start timed out while a
permission prompt is open leaves a child with no session folder; after a quit or crash the
relaunched app refuses a new start ("The last recording is still stopping…") while that pid
still names a process with the saved start time.

Quit (`applicationShouldTerminate`) while `active`: alert "A meeting is recording."
Child mode: `[Stop and Save]` (send stop; `.terminateLater`; reply once the status phase
is `transcribing` or later, at most 10 s; the recorder finishes labelling on its own),
`[Keep Recording]` (quit the app only), `[Cancel]`. In-process mode: `[Stop and Save]`
shows progress and replies once the recording in the app has ended, at most 10 minutes;
`[Cancel]`. Labelling continues in its child: once the recording's post-process hook has
handed the lease over, the quit calls `InProcessLauncher.leaveLabellingToItsChild()`,
which cancels the recording task; the hook stops mirroring the child and returns a
`running` record, and the recording writes `exited` (post-processing `running`) before it
ends. Replying at phase `postprocessing` alone would kill the app while the recording
still waits for the child, leaving `status.json` stuck in `postprocessing`. The readiness
rule is `QuitReadiness.ready`; any quit while a recording still runs in the app waits.
Test `quitLeavesLabellingToTheChildAndEndsTheRecording`. An in-process
recording whose exited status could not be written yet (`ExitRetry` still retrying it and
holding the locks) has not ended: `InProcessLauncher` keeps it running, reports its exit
only once `status.json` says exited (or the retry stops because the folder is gone, as a
failure), and a quit waits for it the same way (`isRecording` stays true, `isWritingExit`).
Test `inProcessRecordingEndsOnlyOnceItsExitedStatusIsWritten`.

About Holos: `NSApp.orderFrontStandardAboutPanel(options: [.credits: …])` with the
credits text of §4.8 embedded as a string constant (the app has no resource bundle).

**Concurrent dictation.** §4.12. Meeting effects do not alter dictation state.

**Vocabulary.** The app passes `vocabulary: { corrections.vocabulary }` (the list
dictation uses). PR10 extends this closure with known people's names.

**build-app.sh.** Build both products (`swift build --product HolosApp` and
`--product holos`), copy `holos` to `Holos.app/Contents/MacOS/holos`, sign it with
`codesign --force --sign - --identifier ca.orlenko.holos.cli`, then sign the bundle as
today. Refuse to rebuild while a recorder runs from the bundle
(`pgrep -f "$PWD/build/Holos.app/Contents/MacOS/holos"`), with the same message style as
the existing app check: replacing the binary would invalidate the running recorder's
signature in the middle of a meeting.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `startLaunchesWithoutChangingDictation` | `startRequested` | `starting`; effects `launch` |
| `recordingStatusMakesActive` | status phase `recording` | `active` |
| `missingFolderWhileStartingIsNotFailure` | liveness `dead`, no status, 3 s after start | still `starting` |
| `waitingForPermissionHint` | `tick` 6 s after start, no status | `announce("Waiting for permission…")` once |
| `startTimesOutAfterTwoMinutes` | `tick` 121 s after start | `terminateChild`; `failed` with the log path |
| `childExitBeforeRecordingShowsLogTail` | `childExited(1, "The built-in microphone is unavailable…")` | `failed` with that text; no "Recover" |
| `freshStatusRecoversFromFailed` | `failed(id)`, then a fresh `recording` status for `id` | `active` |
| `stopWhileStartingTerminatesChild` | `stopConfirmed` in `starting` | `terminateChild` |
| `captureStopDoesNotChangeDictation` | status phase `transcribing` | `finishing` |
| `exitedStatusFinishesAndOffersNaming` | phase `exited`, exit `complete`, post-processing succeeded | `idle`; `finished` with the name; `offerNaming` |
| `finishingDeadGoesIdle` | `finishing`; liveness `dead` | `idle`; `finished` with "Speaker labelling stopped…" |
| `deadRecorderFails` | `active`; liveness `dead` | `failed` with "Recover" text |
| `stopConfirmedSendsOnce` | `stopConfirmed` twice | one `send(.stop)` |
| `reviewOpenedClearsOffer` | offer pending; `reviewOpened` | `clearNamingOffer` |
| `launcherArguments` | mic+system, app `us.zoom.xos`, othersInRoom, expected 8, vocabulary file | exact argument array above |
| `spawnedChildInheritsNoLocks` | hold the speaker lock; spawn `/bin/sleep 2` with the launcher's spawn helper; release | a second descriptor acquires the lock at once |
| `controllerReattachesToLiveSession` | temp root with a fresh status and the writer lock held by the test | `attachOnLaunch` → `active` |
| `controllerFindsTerminalMeetingAfterLaunch` | idle; a new session's fresh status appears | `active` within one rescan |
| `controllerWritesControlFiles` | active; `pause()` | a valid `control/<id>.json` with command `pause` and `sentAtNanos` |
| `startRefusedOnLowDisk` | free 2 GB; mic | `start` throws; no launch |
| `inPersonStartRefusedWithoutBuiltInMic` | `builtIn == nil`; in person | throws; no launch |
| `callStartAllowedWithoutBuiltInMic` | `builtIn == nil`, default AirPods; call | launches |
| `vocabularyFileIsPrivate` | start with vocabulary ["Maria Chen"] | temp file 0600 with that list; path in the arguments |
| `autoRelabelPicksInterruptedRecentUnedited` | interrupted (recent, no edits), labelled, interrupted with edits, interrupted 10 days old, notLabelled (models missing) | only the first |
| `autoRelabelWaitsForModelsAndIdle` | models missing; or a meeting active; or 2 attempts | none |

**Manual checks.** H1–H3, H12, H13, H17, H19, H22 in §7, written into
`docs/meeting-validation.md`.

**Does not touch.** HolosSpeakers, profile store, `PeopleWindow*`, `RecordingWorkflow.swift`
internals (public API only), HolosDiarization, `MeetingPostProcessor.swift`,
`SpeakerEditor.swift`, CLI sources, README and `docs/status.md` (PR10 writes the wave-4
docs from PR4's "Docs note").
