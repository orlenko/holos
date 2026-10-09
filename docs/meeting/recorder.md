# Recorder

The recorder process: its protocol with the app, state machine, capture path, sleep and power, disk policy, stop
path, concurrent dictation, microphone selection and vocabulary (§4.1–§4.6, §4.12). §5.4 (long recordings) and
§5.6 (recovery, the session catalog, deletion) come from the build plan and name the PRs that built them; the code
cites them for behaviour.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.1 Recorder ↔ app protocol

Files, not sockets or XPC. The session folder is private (0700), which restricts access
to the user; every command is an allowlisted enum value with an exact session ID.

**Launch (child mode, PR4).** The app computes a session ID, writes the vocabulary file
(§4.12), then spawns:

```
Holos.app/Contents/MacOS/holos record start
    --session-id <UUID> --name <name> --source mic|mic+system [--app <bundle-id>]
    [--others-in-room] [--expected-speakers N] [--vocabulary-file <path>] [--screen display]
    --no-live-text --directory <HolosPaths.sessions>
```

- `posix_spawn` with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT` (§1.7 rule 4).
  fd 0 is `/dev/null`; fds 1 and 2 are `~/Library/Logs/Holos/recorder-<UUID>.log`
  (`O_WRONLY|O_APPEND|O_CREAT`, 0600). Never pipes: a pipe to a dead app would raise
  SIGPIPE in the recorder. With its own session the recorder gets no terminal SIGHUP
  and no signals sent to the app's process group.
- The recorder ignores SIGPIPE. SIGINT and SIGTERM stop gracefully (audio saved,
  post-processing runs). SIGHUP keeps today's default behaviour; changing it is open
  question Q6.
- The app reaps the child with `DispatchSource.makeProcessSource(identifier:eventMask: .exit)`
  plus `waitpid(pid, WNOHANG)`. After an app relaunch the recorder is no longer its
  child; liveness then comes from locks and `status.json` (below).
- Environment: inherited, plus `HOLOS_RECORDER_PARENT=app` (informational, logged).

**Files.**

| File | Writer | Reader | Rule |
|---|---|---|---|
| `meeting.json` | recorder at start | post-processor, app | written once, before capture starts |
| `vocabulary.json` | recorder at start (copy of `--vocabulary-file`, which it then deletes) | recorder, replay, rebuild, post-processing | written once |
| `status.json` | recorder `StatusWriter` actor | app, `holos record status` | atomic rewrite on every change and as a heartbeat every 1 s from launch until exit; `sequence` increments; kept after exit with `phase: exited` |
| `control/<UUID>.json` | app or CLI via `RecorderChannel.send` | recorder `ControlInbox` | published by rename from `control/.<UUID>.tmp`; polled every 100 ms while capture runs and every 1 s after it stops; applied at most once; `controlHandled` event; file deleted; `ControlAck` added to `status.json`; leftovers deleted at exit |
| `stop.request` | legacy `holos record stop` | recorder | still honoured as a stop request |
| `control.json` | — | — | no longer written (PR2a); `status.json` carries pid and start time |

`RecorderChannel` (PR2a, `Sources/HolosMeeting/RecorderChannel.swift`):

```swift
public enum RecorderLiveness: String, Sendable, Equatable {
    /// Writer lock held, and status.json absent or fresh with phase starting…transcribing.
    case capturing
    /// Processing lease held and status.json fresh with phase postprocessing (the recorder's own post-processing).
    case processing
    /// A lock is held by something else: recover, rebuild, `session diarize`, delete, or a stale status.
    case maintenance
    /// No lock held and status.json phase == exited.
    case exited
    /// No lock held and status.json missing or not exited: interrupted if the manifest says recording/processing.
    case dead
}

public enum RecorderChannel {
    /// Reads status.json; nil when absent. Throws on a newer schemaVersion.
    public static func readStatus(session: URL) throws -> RecorderStatus?
    /// Publishes one request atomically with `sentAtNanos` from mach_continuous_time; creates control/ (0700).
    /// Refuses (`unavailable`) when the session has no manifest yet (the recorder is still starting; stop it
    /// with SIGTERM instead), when status.json says exited, or when only a maintenance command holds the
    /// session (`maintenanceOnly`): no recorder would read or remove the request.
    @discardableResult
    public static func send(_ command: ControlCommand, label: String? = nil, session: URL,
                            sessionID: String, sender: String) throws -> ControlRequest
    /// Liveness is `maintenance` and status.json is missing or exited, or names a process that is gone. A live
    /// recorder with a stale status is not maintenance-only: it still answers `control/`.
    public static func maintenanceOnly(session: URL, now: Date = Date()) -> Bool
    /// Polls status.json every 50 ms for the request's ack.
    public static func waitForAck(_ request: ControlRequest, session: URL, timeout: Duration) async -> ControlAck?
    /// "Fresh" means updatedAt less than 10 s before `now` and kill(pid, 0) == 0.
    public static func liveness(session: URL, now: Date = Date()) -> RecorderLiveness
    /// For maintenance commands: when liveness is dead and status.json is not exited, rewrites it as exited
    /// (reason `interrupted`, archiveStatus from the manifest). Returns true if it rewrote.
    public static func markDeadRecorderExited(session: URL, now: Date = Date()) throws -> Bool
}
```

Senders wait for the previous state-changing request's ack before sending the next
(`waitForAck`, 3 s), unless the CLI was given `--no-wait`.

**Control inbox rules (recorder side, PR2a `ControlInbox`).** Consider only regular
files named `<UUID>.json` (no dot prefix, `lstat`, no symlinks), at most 4 KiB. Reject
(log `controlRejected`, delete) files that fail to decode, have `schemaVersion != 1`, a
different `sessionID`, or an unknown command. Truncate labels to 200 characters. Apply
in `(sentAtNanos ?? 0, id)` order, never by `createdAt`. Keep handled IDs in memory; a
repeated ID is acknowledged `ignored`.

| Command | recording | waiting | paused | sleeping | starting | after capture stopped |
|---|---|---|---|---|---|---|
| `stop` | applied → stopping | applied → stopping | applied → stopping | applied → stopping | applied (stops right after start) | ignored ("already stopping") |
| `pause` | applied → paused | applied → paused | ignored | rejected ("the computer is asleep") | rejected | ignored |
| `resume` | ignored | ignored ("already restarting audio") | applied → recording | rejected | rejected | ignored |
| `marker` | applied | applied | applied | applied | rejected | ignored |

**Reattach (PR4).** On launch, and every 3 s while idle, `MeetingController` looks for
a live meeting: it `stat`s `status.json` under `HolosPaths.sessions` and decodes only
files modified in the last 10 s. A session with a fresh status, liveness `capturing` or
`processing`, and phase `isMeetingActive` or `postprocessing` is the current meeting,
whoever started it (app or terminal). Only sessions under `HolosPaths.sessions` are
visible to the app.

**In-process fallback (decision 4).** `InProcessLauncher` (PR4) runs
`RecordingWorkflow.run` in a task inside the app with the same options: both launchers map
`MeetingStartSettings` with `RecordingOptions(settings:…)`, and `ChildProcessLauncher.arguments`
hands its values to the child. Settings without a language take the recorder's default, the
supported language closest to the user's (`AppleSpeechEngine.defaultLocale`, the default
dictation language Settings shows), in both; a recording without the microphone (`system`)
ignores a microphone choice in both, and the child gets no `--microphone`. Frames are
consumed off the main actor (§1.3), and the launcher holds
`ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled])`
while recording so App Nap and timer coalescing do not apply. The recorder code writes
the same `status.json` and reads the same `control/`, so `MeetingController` does not
know which launcher is used. Post-processing still runs in a child, keeping FluidAudio
out of the app: the in-process `PostProcessHook` (§4.6) hands the processing lease to a
child without ever releasing it. It spawns
`holos session diarize <path> --after-recording --json --lease-fd 3` with a
`posix_spawn_file_actions_adddup2` that places the lease's lock descriptor at fd 3 in the
child (dup2 clears close-on-exec on the copy; `flock` locks belong to the open file
description, so the child now co-owns the held lock). Only after `posix_spawn` succeeds does
the parent close its own descriptor; the lock stays held by the child until it exits. With
`--lease-fd`, the child adopts that descriptor as its `ProcessingLease` instead of acquiring
one, and refuses to run if fd 3 is not a lock on this session's lease file. If the spawn
fails, the parent still holds the lease and records the failure itself. There is therefore
no moment when neither the writer lock nor the lease is held, so `liveness` never reads a
fresh `postprocessing` session as `dead`, and recovery, deletion, or relabelling cannot slip
in. The hook mirrors the child's `postprocess.json` progress into `status.json` and returns
its final record. Test `inProcessLeaseHandoffHasNoGap` (PR4): a probe polling
`SessionLocks.isProcessing` throughout the handoff never sees `false`. The mode is `UserDefaults "meetingRecorderMode"` = `child` (default) or
`inProcess`; S2 decides the default.

### 4.2 Recorder state machine

Owned by PR2a as a pure reducer, `RecorderMachine`
(`Sources/HolosMeeting/RecorderMachine.swift`). PR2a defines every input and effect and
implements everything except the sleep, watchdog, and device rules, which PR2b fills in
(stacked on PR2a). The `@MainActor` recorder loop feeds it inputs and executes its
effects in order.

```swift
public enum CaptureEnd: Sendable, Equatable {
    case requested                   // the stream finished after stopCapture
    case configurationChanged        // AVAudioEngineConfigurationChange
    case failed(message: String)     // any other error, including ScreenCaptureKit stopping by itself
    case startFailed(message: String)
    case userStoppedSharing          // SCStreamError.Code.userStopped only
}

public enum RecorderInput: Sendable, Equatable {
    /// The first frame of `epoch` arrived at session time `at`.
    case captureRunning(epoch: Int, at: Double)
    /// Ends from any epoch other than the current one are ignored (logged).
    case captureEnded(epoch: Int, CaptureEnd, at: Double)
    case control(ControlRequest, at: Double)
    case signal(at: Double)
    case durationElapsed(at: Double)
    case willSleep(at: Double)
    case didWake(at: Double, lidOpen: Bool)
    /// Lid opened, screen unlocked (`com.apple.screenIsUnlocked`), or the CoreAudio device list changed.
    case retryNow(reason: String, at: Double)
    /// Every 1 s. `lastFrameAt`: per track, the session time at which the consumer last received a frame.
    case tick(at: Double, lidOpen: Bool, freeBytes: Int64?, lastFrameAt: [String: Double])
}

public enum RecorderEffect: Sendable, Equatable {
    /// Stop capture (≤ 5 s), drain, close every open chunk with `reason` pending, send a boundary to each LiveTrack.
    case stopCapture(reason: GapReason)
    /// Start epoch `epoch` at timelineOffset max(clock.now(), lastFrameEnd + 0.01) (§2.3).
    case startCapture(epoch: Int)
    case recordEvent(kind: String, details: [String: String])
    case acknowledge(ControlAck)
    case warn(RecorderWarning)
    case clearWarning(RecorderWarningCode)
    /// IOAllowPowerChange for the pending willSleep, after chunks are closed.
    case allowSleep
    /// Take or release the idle-sleep assertion (released while paused).
    case holdPowerAssertion(Bool)
    /// Leave the loop; the stop path (§4.6) runs next.
    case finish(StopReason)
}

public struct RecorderMachine: Sendable, Equatable {
    public private(set) var phase: RecorderPhase       // starting, recording, paused, waiting, sleeping, stopping
    public private(set) var epoch: Int
    public private(set) var markers: Int
    public init()
    public mutating func handle(_ input: RecorderInput) -> [RecorderEffect]
}
```

```
            captureRunning(0)                       resume
 starting ─────────────────▶ recording ◀──────────────────────── paused ◀─┐
    │ capture ends before       │  ▲ │ pause                          ▲      │ pause
    ▼ its first frame           │  │ └────────────────────────────────┘      │
 finish(startFailed)            │  │ retry succeeds                         │
                 capture fails, │  │ (tick ≥ retryAt, or retryNow)          │
                 restart fails  ▼  │                                        │
                              waiting ─────────────────────────────────────┘
                                 │ unavailable ≥ 600 s → finish(captureFailed)
 recording / waiting / paused ── willSleep ──▶ sleeping ── didWake/tick ──▶ recording, paused, or finish(sleepTimeout)
 stop / signal / duration / diskLow < 500 MB / pause ≥ 6 h ──▶ finish(reason) → stopping → transcribing
                                                                 → (archive.finish) → postprocessing → exited
```

Rules the reducer encodes:

- **Epochs.** Every restart is `stopCapture(reason)` followed by `startCapture(epoch+1)`.
  No path starts a capture without first stopping the previous one, so each restart
  closes chunks with its reason and gives `LiveTrack` a boundary. Each epoch creates a
  fresh `MeetingCapture` (streams are single-use).
- **Start.** `starting` + `captureRunning(0)` → `recording`. A capture end for epoch 0
  before its first frame → `recordEvent(startFailed)`, `finish(startFailed)`. A stop
  request while starting is applied and finishes right after capture starts.
- **Restarts and `waiting`** (resolution for review finding C1):
  - `configurationChanged` while recording → `recordEvent(deviceChanged)`,
    `warn(deviceChanged)`, `stopCapture(.deviceChanged)`, `startCapture(epoch+1)`.
  - `failed` or `startFailed` for the current epoch → `recordEvent(captureFailed {epoch,
    error})`. If `attempt == 0`: `stopCapture(.captureRestarted)` and `startCapture(epoch+1)`
    at once (`attempt = 1`). Otherwise: `stopCapture(.audioUnavailable)` (chunks are
    already closed; this sets the gap's reason) → `waiting`,
    `retryAt = at + min(30, 0.5 × 2^(attempt−1))` (0.5, 1, 2, 4, … 30 s),
    `recordEvent(captureWaiting {at, reason, attempt, retryInSeconds})`,
    `warn(audioUnavailable)`. `unavailableSince` is set on the first failure and kept
    across attempts.
  - `waiting` + (`tick` with `at ≥ retryAt`, or `retryNow`) → `startCapture(epoch+1)`,
    `attempt += 1`, phase `recording`. The phase is `recording` while a start is in
    flight; a start failure comes back as `startFailed`.
  - An epoch that has delivered frames for 10 s resets `attempt` to 0, clears
    `unavailableSince`, and emits `clearWarning(audioUnavailable)`. This stops a
    fail-fast loop (start works, fails 10 ms later) from retrying at full speed.
  - `tick` with `at − unavailableSince ≥ 600` → `finish(captureFailed)`. Audio before
    the outage is saved.
  - `userStoppedSharing` → `finish(requested)`. Only `SCStreamError.Code.userStopped`
    maps to it; every other ScreenCaptureKit error is `failed`, so ScreenCaptureKit
    stopping under screen lock waits and retries (and `retryNow` fires on unlock).
- **Pause.** `pause` while recording or waiting → `stopCapture(.paused)` (recording
  only), `recordEvent(paused {at})`, `holdPowerAssertion(false)`, ack applied → `paused`
  (`pausedSince = at`; retries stop). `resume` → `recordEvent(resumed {at, epoch})`,
  `holdPowerAssertion(true)`, `startCapture(epoch+1)` → `recording`. A pause (including
  sleep while paused) lasting 6 h → `finish(pauseTimeout)`.
- **Disk** (§4.5) and **watchdog** (below) are evaluated on every 1 s `tick` while
  starting or recording (the watchdog once the epoch's capture has started), so an
  epoch 0 that never delivers its first frame is flagged and restarted like any other
  stall. The disk is also checked while waiting.
- **Watchdog** (`TrackWatchdog`, held in the machine; PR2b). A track's stall timer starts
  at the epoch's start time and is reset by every `lastFrameAt` update. No frame for
  3 s → `recordEvent(trackStalled {track, silentSeconds})`, `warn(trackStalled)`.
  Frames again → `recordEvent(trackResumed)`, `clearWarning` when no track is stalled.
  A **microphone** track stalled for 10 s → `stopCapture(.captureRestarted)`,
  `startCapture(epoch+1)`; if the stalled epoch delivered no frame on any track, audio
  counts as unavailable from then (`unavailableSince`), so the 600 s limit ends a
  recording whose restarts never bring audio back. The system track is never restarted for a stall
  (ScreenCaptureKit may deliver nothing during silence, open question Q4). Arrival times
  come from the session clock, which starts at epoch 0's origin, so a slow startup or a
  permission prompt never looks like a stall.
- **Sleep** (PR2b): §4.4.
- After `finish`, the loop exits and every later input is ignored; the stop path (§4.6)
  is sequential code in `RecordingWorkflow.run`.

Loop rules (PR2a): every 100 ms drain power events (`pendingEvents()`, §4.4), poll
`ControlInbox`, check the stop source and legacy `stop.request`, and check the
duration; every 1 s build `tick` and then `StatusWriter.update`. Execute effects in
order. `startCapture` in call mode with no input device at all (PR2b) starts
ScreenCaptureKit with `captureMicrophone = false`, warns `microphoneUnavailable`
("Microphone unavailable; recording call audio only"), and retries with the microphone
on the next `retryNow` for a device-list change.

**Independent system-audio recovery (2026-10 revision).** Live mic+system meetings
use `IndependentMeetingCapture`: an AVAudioEngine microphone and a separate,
system-only ScreenCaptureKit stream. System failure (including unavailable/locked
displays) never stops, restarts, or rebases the microphone. A failed initial system
start also leaves microphone recording active. Only that stream retries with
0.5–30 s backoff and bounded startup/recorder-stop awaits. Timeout retries retain
their attempt count. A hung native start is not multiplied: its late result and
any in-flight cleanup settle before another attempt. The background recovery
worker may keep waiting for cleanup while the microphone and recorder remain
responsive; failed cleanup retries stopping the same retained handle with backoff,
never spawning another potentially concurrent stream. Silence alone is not a failure.

Both captures share the microphone's host origin, including retry setup time.
The first accepted recovered system frame carries an ordered track-local
`captureRestarted` boundary through format conversion, the chunk writer, and live
speech; the mic gets no boundary. The bounded merged queue retains a boundary and
drop mark when that frame is dropped. `unavailableTracks` supplies a visible
`systemAudioUnavailable` warning and stalled system-track status until audio
actually arrives. The recording phase stays active while the microphone runs.
The first system frame also carries a leading `audioUnavailable` boundary when
initial setup succeeds after a delay; this does not show a retry warning for a
healthy silent stream. A still-unavailable source's tail is journaled in writer
queue order when capture stops for pause, sleep, restart, or final Stop. If audio
later resumes, its boundary starts after the tail already saved, avoiding duplicate
gap intervals while preserving the actual sample-end continuity anchor.
Known system unavailability is carried into a new capture epoch and its warning
clears only on an accepted system frame, not merely on successful microphone startup.
The first system frame of a resumed epoch preserves the recorder's pause/sleep/restart
boundary reason; only the initial epoch uses the generic leading-unavailable reason.
An epoch that never heard a system frame saves that unwritten tail too, using a
separate tail-availability accessor so normal silence does not show an outage warning.
During a confirmed system outage, the generic "nothing may be playing" stall warning
is suppressed or narrowed to a genuinely stalled microphone; watchdog journal events
remain available for diagnostics.
Pause, sleep, and stop release both captures; deliberate Stop Sharing retains the
existing requested-stop behavior. Microphone failures retain recorder-wide
recovery, and a system-only recording retains the existing waiting/backoff policy.
Optional screen-image capture already fails independently of audio.

### 4.3 Capture → disk path

Disk latency never reaches the capture path (PR2a):

```
AudioCapture callback ─yield─▶ frames stream (4,096 buffers; overflow drops the buffer and counts it, never fails)
        │  consumer task (detached; never awaits disk or speech; stamps lastFrameAt)
        ├──▶ ChunkWriterPump.push   ≤ 60 s queued per track ─▶ writer task ─▶ AudioChunkWriter ─▶ SessionArchive
        └──▶ LiveTrack.push         ≤ 30 s queued per track ─▶ speech task ─▶ LiveSpeechSession
```

- `AudioCapture` no longer fails when its stream is full: it drops the buffer and
  increments `droppedBuffers`. The consumer sees the counter advance and calls
  `pump.noteGap(track:reason: .overflow)`.
- `ChunkWriterPump` (HolosAudio) queues frames per track, bounded by duration (60 s).
  `push` never blocks; when a track's queue is full it drops the frame, remembers the
  dropped interval, and the writer closes the chunk with pending reason `overflow`
  (event `audioDiscontinuity {reason: overflow}`); the loop warns `audioDropped`.
  `backlogSeconds` per track goes to `status.json`.
- Chunk registration stays as it is (hash, fsync, manifest rewrite every 30 s); it runs
  on the writer task, so a slow fsync only grows the backlog.
- `SessionArchive` journal group commit (PR6): the recorder calls
  `archive.setJournalSync(.interval(seconds: 1))`. Events are written with `write(2)`
  at once and fsync'd by the actor at most once per second, at `finish`, and at once
  for `captureStopped`, `archiveRecovered`, and `transcriptRebuilt`. A crash loses at
  most about 1 s of events; recovery already tolerates a torn tail. Other callers keep
  today's per-event fsync.
- `AudioChunkWriter` additions (PR2a): `bytesWritten()`, `lastFrameEnd`,
  `closeAll(expectingGap:)`, and `noteGap(track:reason:)`, which sets the reason of the
  track's next `audioDiscontinuity`. It applies `FrameContinuity` (§2.3).
- The `audioDiscontinuity.reason` strings are exactly the `GapReason` raw values
  (`paused`, `sleep`, `deviceChanged`, `captureRestarted`, `audioUnavailable`,
  `overflow`) plus the writer's own `timestampGap` and `formatChanged`. There is no
  second spelling.

### 4.4 Sleep and power (PR2b)

- `PowerAssertion` (`kIOPMAssertionTypePreventUserIdleSystemSleep`, named "Holos meeting
  recording") is held from `starting` through post-processing, except while paused
  (`holdPowerAssertion(false)`), so a meeting left paused lets the Mac idle-sleep. Lid
  close and forced sleep still happen.
- A separate recording-only `kIOPMAssertionTypePreventUserIdleDisplaySleep` assertion
  prevents idle display sleep from disrupting ScreenCaptureKit. It is released before
  pause/sleep/stop cleanup, is not held during post-processing, and is reacquired on
  capture resume. [Apple documents](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep)
  that lid close and machine sleep can still turn the display off.
- `SystemPowerMonitor` (HolosAudio): `IORegisterForSystemPower` on a dispatch queue. It
  buffers events in a `Mutex` and the loop drains them with `pendingEvents()` every
  100 ms. `canSleep` is allowed immediately by the monitor. `willSleep` is queued for
  the loop only while a loop is attached (`attach()` at loop start, `detach()` at loop
  exit); otherwise the monitor calls `IOAllowPowerChange` itself, so transcription and
  post-processing never delay a lid close. From the recorder's start until the loop
  attaches (`observe()`: permission prompts, speech setup, capture start), `willSleep`
  and `didWake` are still queued with their arrival times, and `willSleep` is allowed at
  once; the loop drains them first, after `captureStarted(epoch 0)`, so a sleep during
  the start stops epoch 0 and resumes in epoch 1, or ends the recording
  (`sleepTimeout`) after 15 minutes. Such events have negative session times (before
  epoch 0's origin); they are not clamped to 0, which would erase the sleep's length.
  Device-list and screen-unlock events (§4.2) are buffered from the moment the
  dependencies are made, so they have no such gap; the lid is polled, not observed.
- On `willSleep` the loop executes `stopCapture(.sleep)` as: ask capture to stop (wait at
  most 5 s), close every open chunk, then `allowSleep`, even if the platform stop has
  not returned. Budget under 7 s; macOS allows 30 s.
- Rules in the machine:
  - `willSleep` from `recording`, `waiting`, or `paused`: `recordEvent(systemWillSleep
    {at, phaseBeforeSleep})`, `stopCapture(.sleep)` if recording, → `sleeping`,
    `allowSleep`. `sleepStart` and `phaseBeforeSleep` are set **only** on this
    transition.
  - `willSleep` while already `sleeping` (a dark wake going back to sleep):
    `allowSleep` only. `sleepStart` and `phaseBeforeSleep` stay, so dark wakes neither
    restart the 15-minute count nor forget that the meeting was paused.
  - `didWake(at, lidOpen)`, `slept = at − sleepStart` on the continuous clock:
    - `phaseBeforeSleep == paused` → `paused` for any sleep length (the 6 h pause limit
      still applies); event `didWake {action: wait}`. The menu shows "Paused — Resume
      or Stop". (Refinement of decision 5; Q1.)
    - `slept ≥ 900` → `finish(sleepTimeout)`; event `didWake {action: finalize}`. The
      recording ends at the sleep point.
    - `slept < 900`, lid open → `startCapture(epoch+1)`, `warn(resumedAfterSleep)`
      ("Resumed after 4 min of sleep; the gap is marked"), event `didWake {action:
      resume}`; `unavailableSince` restarts.
    - `slept < 900`, lid closed (dark wake, or clamshell) → stay `sleeping`, event
      `didWake {action: wait}`. Each tick re-checks: lid open before 900 s → resume; 900 s
      reached → `finish(sleepTimeout)`.
- `lidOpen` is `AppleClamshellState == false` from `IOPMrootDomain` (absent counts as
  open). The lid opening while `waiting` sends `retryNow`.
- No system notifications in v1 (they would add a permission prompt; resolution R14).
  The app's `suspendForSessionChange` keeps affecting dictation only (§4.12).

### 4.5 Disk policy (PR2a)

Pure functions in `DiskPolicy` (`Sources/HolosMeeting/DiskPolicy.swift`); free space from
`FreeSpaceProvider` (PR6, HolosStorage; `VolumeFreeSpace` = `statfs` `f_bavail × f_bsize`
on the sessions volume). All sizes are decimal (1 GB = 10⁹ bytes), matching the UI.

```swift
public enum DiskVerdict: Sendable, Equatable { case ok, warn(String), refuse(String), stop(String) }

public enum DiskPolicy {
    /// Nominal Int16 capture: mic 48 kHz mono 345.6 MB/h; system 48 kHz mono 345.6 MB/h
    /// (ScreenCaptureKit channelCount = 1).
    public static func captureBytesPerHour(_ source: AudioSource) -> Int64
    /// 16 kHz mono Int16 render per diarized track: 115.2 MB/h (deleted after diarization).
    public static let renderBytesPerHour: Int64 = 115_200_000
    /// capture + render for every track, per hour.
    public static func budgetBytesPerHour(_ source: AudioSource) -> Int64
    /// refuse if free < 4 h budget + 2 GB; warn if free < 8 h budget + 2 GB.
    public static func startCheck(freeBytes: Int64, source: AudioSource) -> DiskVerdict
    /// stop if free < 500 MB; warn once below 2 GB; re-arm the warning after free > 2.5 GB.
    public static func runtimeCheck(freeBytes: Int64, warned: Bool) -> (verdict: DiskVerdict, warned: Bool)
    /// Post-processing: render allowed only if free ≥ renderBytes + 1 GB.
    public static func renderCheck(freeBytes: Int64, renderSeconds: Double, tracks: Int) -> Bool
    /// "≈1.0 GB for 3 h · 24.1 GB free" (capture only, one decimal).
    public static func estimateText(source: AudioSource, hours: Double, freeBytes: Int64) -> String
}
```

The budget holds whatever the microphone delivers: AVAudioEngine keeps the input device's
format (a stereo or 96 kHz interface), so the recorder's frame consumer converts every
track to 48 kHz mono (`RecordingFormatConverter` in HolosAudio: channels averaged, one
resampler per track and epoch) before the pump and the live tracks.

Worked values: mic 4 h budget = 4 × 460.8 MB + 2 GB = 3.84 GB, 8 h = 5.69 GB;
mic+system 4 h = 4 × (691.2 + 230.4) MB + 2 GB = 5.69 GB, 8 h = 9.37 GB. A 3 h
in-person meeting is about 1.04 GB, a 3 h call about 2.07 GB (it was 3.1 GB with stereo
system audio).

The runtime check runs on every 1 s tick (`statfs` is cheap). `stop` →
`recordEvent(diskLow {freeBytes, action: stop})` and `finish(diskLow)`; audio already on
disk is finalized normally, and post-processing skips rendering (§4.7 stage 4).

### 4.6 Stop path, transcript coverage, timeouts, hand-off (PR2a)

After `finish(reason)` the loop exits and `RecordingWorkflow.run` does, in order:

1. **Stop capture** with a 5 s timeout. On timeout, abandon the stream, log, and record
   `captureFailed {epoch, error: "Capture did not stop within 5 s"}`. Drain the consumer,
   let the pump drain into the writer, then `writer.closeAll`. When the epoch's stream had
   already ended by itself (the user stopped sharing, or capture failed), the stop is only
   cleanup: an error from it (ScreenCaptureKit refuses to stop a stopped stream) is logged,
   never reported as a capture failure.
2. Phase `stopping` → `transcribing`. **Finish live speech** per track with a timeout of
   30 s + 0.05 × the seconds fed to its current speech session. On timeout, cancel that
   session; segments it already finalized are kept. The same deadline also ends the finishes of
   earlier sessions (an epoch or gap that ended just before the stop) that are still running.
3. **Coverage.** For each track, `TranscriptCoverage.coverageEnd` (below). A track whose
   live transcription never fell behind keeps its live segments. Otherwise
   `TrackReplayer.replay(from: max(0, coverageEnd − 2))` transcribes only the rest, and
   `TranscriptCoverage.merge` joins the two at word level. Hours of live words are never
   thrown away because of one dropped frame. A replay that times out or fails after partial
   progress keeps the segments of its finished sessions and the finals the failed session
   reported; the track is recorded as a transcription error. `--record-only`: no transcript.
4. `archive.saveTranscript(transcript, writeLegacyExports: false)` (updates
   `transcripts/current.json`).
5. If a post-process hook is set, **acquire the processing lease** (retry 1 s) while
   still holding the writer lock. On failure, skip post-processing with the message
   "Another Holos process is labelling this meeting." The hook does not run, but the
   outcome and `RecorderExit` still carry a `.failed` post-processing record ("Speaker
   labelling was skipped: … Run holos session diarize on this session later."), so
   `Record.Start` exits 3 and the app shows it; only a `nil` hook gives no record.
6. `archive.finish(status)` releases the writer lock when the lease is held. There is no
   moment in which the session holds neither lock, so liveness never reads `dead` between
   capture and post-processing. Without the lease (no hook, or it could not be taken),
   and on every failure or cancellation path, `archive.finish(status, keepingLock: true)`
   keeps the writer lock until `phase: exited` is written (step 8).
7. Phase `postprocessing`; call the hook with the lease. Progress goes into one
   `AsyncStream` read by one task that updates `status.json` in order; after the hook
   returns, finish the stream and await that task.
8. Write `phase: exited` with `RecorderExit` (archive status, stop reason,
   post-processing state and message), then release the last lock (the writer lock or the
   lease), so liveness goes to `exited` without reading `dead` on the way. `StatusWriter`
   then stops its heartbeat and ignores later updates. A failed final write is retried
   (3 attempts, 100 ms × attempt apart); only a write that lands finishes the writer. If
   none does, the error is logged, the heartbeat resumes with the last phase, and the
   recorder keeps its last lock until the process exits, so the session reads busy, not
   dead, while it shuts down; after exit, recovery handles it like any unfinished status.
9. Release the power assertion; delete leftover `control/*.json`; return the outcome.

While steps 1–9 run, `ControlInbox` keeps polling once a second and acknowledges every
request `ignored` ("The recorder is already stopping."). A stop during post-processing
does not cancel it.

Requests are closed before the last poll. Right before step 8 the recorder creates
`control/.closed`, polls one last time (answering `ignored`), writes `exited`, and only
once `exited` is written deletes leftover requests and removes the marker.
`RecorderChannel.send` refuses when the marker exists; after publishing, it checks the
marker and then `status.json`. Either one makes it withdraw its request: a request it
removes is refused; one the recorder already took is answered by the last poll (or,
if `status.json` already says exited without its answer, was a deleted leftover and is
refused). The request file belongs to whoever unlinks it, so the inbox never handles a
request its sender withdrew.

**`StatusWriter` heartbeat.** The actor starts a 1 s timer at launch (phase `starting`)
and rewrites `status.json` every second until `exited`, independent of the loop, so
status stays fresh through transcription and post-processing.

**`LiveTrack`** (PR2a):
- Input is `enum LiveInput { case frame(PCMFrame), boundary }` on a queue bounded by
  duration (30 s of audio, not a buffer count).
- Overflow: record `transcriptionBehind {track, from}` (session time of the first
  dropped frame), set transcription `behind`, stop feeding live speech for the rest of
  the recording, and keep every segment already finalized.
- `boundary`: finish the current speech session (with the timeout above) and keep its
  segments. The next epoch's speech session is created while the previous epoch stops,
  before `startCapture`, so new frames never wait behind `AppleSpeechSession.make`. A
  failed creation records `transcriptionBehind {track, from: epoch start}`.
- Every `transcriptFinalized` event adds `segmentID` and `words` (compact `HolosJSON`
  array of `TimedWord`). The journal queue holds 4,096 segments; if it is full, the
  earliest dropped segment's start is remembered and recorded as `transcriptionBehind
  {track, from}` once the queue drains, so recovery knows where the journal has a hole.
- Speech sessions are rebased to 0 and created with the meeting vocabulary (§2.3,
  §4.12).

**`TranscriptCoverage`** (PR2a, `Sources/HolosMeeting/TranscriptCoverage.swift`, pure;
PR3 reuses it):

```swift
public enum TranscriptCoverage {
    /// End of the last live segment, capped at `behindFrom` (the earliest transcriptionBehind.from for
    /// the track). 0 when there are no live segments.
    public static func coverageEnd(live: [TranscriptSegment], behindFrom: Double?) -> Double
    /// Keeps live words that start before `coverageEnd` and replayed words that start at or after it.
    /// A segment cut at a word boundary keeps its ID for the first part and gets a new UUID for the second;
    /// text is cut at the kept words' UTF-16 offsets. Untimed segments are kept or dropped whole by midpoint.
    public static func merge(live: [TranscriptSegment], replayed: [TranscriptSegment],
                             coverageEnd: Double) -> [TranscriptSegment]
}
```

**Lifecycle hook** (type defined by PR1, status handling by PR2a):

```swift
/// Runs post-processing for a finished session under `lease`. Never throws: failures come back as a
/// `.failed` record with a message.
public typealias PostProcessHook = @Sendable (_ session: URL, _ lease: ProcessingLease,
    _ progress: @escaping @Sendable (PostProcessingProgress) -> Void) async -> PostProcessingRecord
```

`RecordingDependencies.postProcess: PostProcessHook?`. The CLI passes a hook that runs
`makeMeetingPostProcessor(options:).run(session:lease:progress:)`; the in-process app
passes the child-process hook of §4.1; `nil` (`--no-postprocess`, `--record-only`)
skips steps 5 and 7. `Record.Start` only maps the outcome to exit codes (§1.4), so the
CLI and the in-process app run the same lifecycle.

### 4.12 Concurrent dictation, microphone selection, vocabulary

**Concurrent dictation (decision 6, revised).** A meeting never cancels, disables,
re-enables, or restores dictation. Its hotkey, enable toggle, shortcut settings,
Copy/Discard and corrections remain available throughout the meeting lifecycle,
including when following a recorder started elsewhere. No dictation markers are
written. Sleep/session changes still cancel the utterance and disable the hotkey
monitor without changing the saved enable preference. Meeting resume/save does
not enable dictation: the user must explicitly enable it after suspension.
Deferred Setup Assistant download completions also respect this suspension;
only a successful explicit enable (including an explicit setup enable choice)
clears the independent `DictationSessionPolicy`.

The capture code uses separate input units without requesting exclusive device
ownership or voice processing. Apple's [SpeechAnalyzer documentation](https://developer.apple.com/documentation/speech/speechanalyzer/setmodules%28_%3A%29)
states no current backing-engine instance limit on macOS. This is source/documentation
evidence, not a hardware guarantee: simultaneous microphone capture and speech
analysis must pass H12 on the target machine and its selected input device.

**Microphone selection (decision 9, PR2b).** `MicrophoneSelection { systemDefault,
builtIn }`:

- In-person (`--source mic`) records the built-in microphone. `BuiltInMicrophone.find()`
  (HolosAudio) returns the CoreAudio device whose transport type is
  `kAudioDeviceTransportTypeBuiltIn` and that has input streams. AVAudioEngine capture
  sets `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit` before
  reading the input format, and re-pins on every restart, so connecting AirPods does
  not move the recording.
- Online call (`--source mic+system`) records the **system default input**, the same
  device the call app uses (a headset records "Me" close up; the laptop microphone
  would pick up the room). ScreenCaptureKit captures it with `captureMicrophone = true`
  and no `microphoneCaptureDeviceID`, as `AudioCapture` does today. A default-device
  change is a configuration change: restart on the new default with a `deviceChanged`
  gap. With no input device at all, the call is recorded without the microphone (§4.2).
- The start panel shows the device as a static label: "Microphone: Built-in Microphone"
  (in person; red and Start disabled when missing: "The built-in microphone is
  unavailable. Open the lid and try again.") or "Microphone: AirPods Pro (system
  default)" (call). No device picker anywhere. `status.json` carries `microphoneName` and
  `microphoneIsSystemDefault`; the menu adds "(system default)" only when the latter is true.
- The closed-lid rule follows the device, not the choice: a microphone-only recording
  whose system default input is the built-in microphone refuses or waits with the lid
  closed, exactly as `--microphone built-in` does.
- In person, if the built-in microphone disappears mid-recording (lid closed with an
  external display), the recorder enters `waiting` with "The built-in microphone is off.
  Open the lid to continue recording." and resumes on lid open. The loop does not rely on
  the device disappearing: when a tick sees the lid close while the epoch records the
  built-in microphone (explicitly or as the default input), it sends `retryNow(lidClosed)`
  and the machine restarts once, so a call continues with system audio alone and a
  microphone-only recording waits.
- Dictation keeps the system default input (unchanged).
- Test seam: `findInputDevices: @Sendable () -> InputDevices` (`builtIn` and
  `systemDefault`, each `Device?`) in `RecordingDependencies` and
  `MeetingController.init`.

**Vocabulary (PR1 seam, PR2a recorder, PR4 app).** Meeting transcription gets the same
contextual strings dictation uses, so council members' names and strata terms are
recognized. `LiveSpeechFactory` takes `contextualStrings`; `RecordingOptions.vocabulary`
carries them; `TrackReplayer.replay`, `TranscriptRebuilder.rebuild`, and
`SessionImporter.importAudio` take them too. The app builds the list with
`RecognizerVocabulary.meeting`: the user's word list (design.md "Word list"), then known
people's names (PR10), then `CorrectionList.vocabulary` (PR4), each once ignoring case,
at most 100 strings (the hand-off file, the recorder and import keep what
`MeetingVocabulary.cleaned` keeps: each string trimmed, empty ones and ones over 100
characters dropped, the first 1,000 in order, duplicates included), writes it 0600 to
`$TMPDIR/holos-vocabulary-<id>.json`, and passes `--vocabulary-file`. The recorder copies
it to `vocabulary.json` before its first `status.json` write and deletes the temporary file;
replay, rebuild, and import read `vocabulary.json` (only `session recover
--current-vocabulary` passes today's list instead, for that run, leaving the file as
recorded). Because the temporary file holds private
names and correction terms, the app side owns cleanup too: `MeetingController` deletes it
on `launchFailed`, when the child exits for any reason, and as soon as the first
`status.json` for that session appears (the recorder has copied it by then). On launch the
app also removes any `$TMPDIR/holos-vocabulary-*.json` older than one hour. A hand-off
file is removed by moving it into a new 0700 folder `.holos-remove-<device>.<inode>.<UUID>`
beside it and unlinking it there (`AtomicFile.readAndRemove`, `removeRegularFile`), so a
file renamed onto its name meanwhile is never deleted. If the process ends, or the unlink
fails, after the move, the same launch sweep finishes it: in each such folder older than
five minutes that is a real folder owned by this user with mode 0700, it removes `file`
only if it is the regular file the folder's name records (same device and inode), then the
folder if empty; anything else stays. Tests (PR4):
`vocabularyFileRemovedOnLaunchFailure` (spawn fails), `vocabularyFileRemovedOnEarlyExit`
(child exits before any status), `staleVocabularyFilesSwept`,
`strandedRemovalFolderIsFinishedBySweep`, `strandedRemovalSweepRemovesOnlyTheRecordedFile`.

### 5.4 PR2a and PR2b: Long-recording robustness (wave 2, stacked)

**Goal.** A 3 h recording survives, and its audio, transcript, and timeline stay correct.
PR2a: the recorder loop and its files (Int16 and mono system audio, the capture pump,
frame continuity, the session clock, `RecorderMachine` with control, restarts and the
`waiting` phase, disk policy, `status.json` with heartbeat, `control/`, the stop path
with coverage-based replay, timeouts, and the lifecycle around the post-process hook).
PR2b, stacked on PR2a: sleep and power, device changes, the stall watchdog, microphone
selection, and the environment events that retry a waiting recorder.

#### PR2a

**Files.**

- HolosAudio, add: `ChunkWriterPump.swift`, `FrameContinuity.swift`.
- HolosAudio, change: `ChunkWriter.swift` (Int16; `FrameContinuity`; `bytesWritten`,
  `lastFrameEnd`, `closeAll`, `noteGap`), `AudioCapture.swift` (timeline offset;
  overflow drops and counts instead of failing; ScreenCaptureKit `channelCount = 1`;
  only `SCStreamError.Code.userStopped` maps to `CaptureInterruption.userStoppedSharing`;
  declares `MicrophoneSelection`, used by PR2b).
- HolosMeeting, add: `SessionClock.swift`, `RecorderMachine.swift` (§4.2),
  `DiskPolicy.swift` (§4.5), `ControlInbox.swift`, `RecorderChannel.swift` (§4.1),
  `StatusWriter.swift`, `TranscriptCoverage.swift` (§4.6), `Timeouts.swift` (internal).
- HolosMeeting, change: `RecordingWorkflow.swift` (the loop runs `RecorderMachine`;
  epochs; off-main consumer; `meeting.json`, `vocabulary.json`, `status.json`; the stop
  path of §4.6), `LiveTrack.swift` (§4.6), `TrackReplayer.swift` (new speech session at
  each gap over 1 s; rebased sessions), `MeetingCapture.swift` (offset, microphone
  selection, `droppedBuffers`), `StopSources.swift` (ignore SIGPIPE).
- HolosCLI: change `Record.swift` (new flags; `stop` via control; `status` shows phase;
  exit codes); add `RecordControl.swift` (`pause`, `resume`, `marker`, registered in
  `Record`'s `subcommands:`).
- Docs: append a "Long recordings" section to `docs/hardware-validation.md` (H4–H10
  procedures from §7.2).
- Tests: `Tests/HolosAudioTests/{Int16ChunkTests, FrameContinuityTests, ChunkWriterPumpTests}.swift`;
  `Tests/HolosMeetingTests/{RecorderMachineTests, DiskPolicyTests, ControlInboxTests, RecorderChannelTests, StatusWriterTests, RecorderEpochTests, LiveTrackTests, TranscriptCoverageTests, StopPathTests, SpeechFixtureTests}.swift`,
  helpers in `RecorderTestSupport.swift` (`fileprivate` or prefixed `recorder…`, §1.8).

**API (additions).**

```swift
// HolosAudio
public enum MicrophoneSelection: Sendable, Equatable { case systemDefault, builtIn }
public enum CaptureInterruption: Error, Equatable, Sendable {
    case configurationChanged        // AVAudioEngineConfigurationChange (reported from PR2b)
    case userStoppedSharing          // SCStreamError.Code.userStopped only
}
extension AudioCapture {
    /// Existing callers (dictation) keep `start(source:applicationBundleID:)`, which calls this with
    /// offset 0 and `.systemDefault`.
    public func start(source: AudioSource, applicationBundleID: String?, timelineOffset: Double,
                      microphone: MicrophoneSelection) async throws
    /// Buffers dropped because the frame stream was full.
    public var droppedBuffers: Int { get }
}
public enum FrameContinuity {
    public enum Decision: Sendable, Equatable {
        case contiguous(driftSeconds: Double)
        case gap(seconds: Double)
        case overlap(dropFrames: Int)     // leading frames to drop; ≥ frameCount means drop the whole frame
    }
    /// §2.3 rules with the 0.05 s tolerance. `expected` nil means the first frame of the track.
    public static func classify(frameStart: Double, frameCount: Int, sampleRate: Double,
                                expected: Double?) -> Decision
}
public final class ChunkWriterPump: Sendable {
    public init(writer: AudioChunkWriter, capacitySeconds: Double = 60)
    /// Never blocks. Returns false when the frame was dropped because the track's queue is full.
    public func push(_ audio: CapturedAudio) -> Bool
    public func noteGap(track: String, reason: GapReason)
    public func backlogSeconds() -> [String: Double]
    /// Writes queued frames in order until `finish()` is called and the queue is empty.
    public func run() async throws
    public func finish()
}
extension AudioChunkWriter {
    /// Bytes of finalized chunks plus frames × channels × 2 of open chunks.
    public func bytesWritten() -> Int64
    public var lastFrameEnd: Double { get }
    /// Closes every open chunk; the next discontinuity event on each track carries `reason`.
    public func closeAll(expectingGap reason: GapReason) async throws
    public func noteGap(track: String, reason: GapReason)
}

// HolosMeeting
public protocol SessionClock: Sendable { func now() -> Double }
public struct ContinuousSessionClock: SessionClock { public init(hostTimeOrigin: Double) }   // §2.3
public final class ManualSessionClock: SessionClock { public init(_ start: Double = 0); public func advance(by: Double) }

public actor StatusWriter {
    /// Writes `initial` and starts the heartbeat (rewrite every `heartbeat` until `finish`).
    public init(session: URL, initial: RecorderStatus, heartbeat: Duration = .seconds(1)) throws
    /// Bumps sequence, sets updatedAt, writes atomically. Does nothing after `finish`.
    public func update(_ change: @Sendable (inout RecorderStatus) -> Void) throws
    /// Writes phase exited with `exit` and stops the heartbeat.
    public func finish(exit: RecorderExit) throws
    public func current() -> RecorderStatus
}

public struct ControlInbox: Sendable {
    public init(session: URL, sessionID: String)
    public enum Item: Sendable, Equatable { case request(ControlRequest), rejected(file: String, reason: String) }
    /// Reads and removes valid or invalid request files (rules in §4.1); returns them in (sentAtNanos, id) order.
    public mutating func poll() -> [Item]
}

public struct StopTimeouts: Sendable, Equatable {
    public var captureStop: Duration                    // 5 s
    public var speechFinishBase: Duration               // 30 s
    public var speechFinishPerAudioSecond: Double       // 0.05
    public static let standard: StopTimeouts
}
```

`RecordingOptions` gains `sessionID: String?` (validated UUID, passed to
`SessionArchive.create(id:)`), `othersInRoom: Bool`, `expectedSpeakers: Int?`,
`liveText: Bool`, and `microphone: MicrophoneSelection` (from PR2b: `.builtIn` for
`mic`, `.systemDefault` for `mic+system`). `CaptureRequest` gains `microphone`
(default `.systemDefault`). `RecordingDependencies` gains, with inert defaults (§5.2):
`makeClock: @Sendable (Double) -> any SessionClock`, `freeSpace: any FreeSpaceProvider`
(`FixedFreeSpace(.max)`), and `timeouts: StopTimeouts` (`.standard`); `.live(...)` sets
`ContinuousSessionClock` and `VolumeFreeSpace`.

**Behaviour.**

- Int16: `AudioChunkWriter` writes CAF with `AVFormatIDKey: kAudioFormatLinearPCM`,
  `AVLinearPCMBitDepthKey: 16`, `AVLinearPCMIsFloatKey: false`,
  `AVLinearPCMIsBigEndianKey: false`, interleaved, processing format Float32 (the file
  converts on write). Reading is unchanged (AVAudioFile's processing format), so old
  Float32 chunks still replay and recover. System audio is captured mono.
- Start sequence: validate `--session-id`; `DiskPolicy.startCheck` (refuse → throw
  `HolosError.unavailable` with the message, before creating the session); create the
  archive with the ID; write `meeting.json` and `vocabulary.json` (copy
  `--vocabulary-file`, then delete it); create `StatusWriter` (phase `starting`,
  heartbeat running); `archive.setJournalSync(.interval(seconds: 1))`; create live
  speech sessions; start capture epoch 0; create the session clock from its
  `hostTimeOrigin`; start the frame consumer off the main actor and the pump's writer
  task.
- Loop, effects, capture path, stop path, `LiveTrack`, and coverage: §4.2, §4.3, §4.6.
- `control.json` is no longer written. `stop.request` is still honoured.

**CLI.**

```
holos record start [--name N] [--source mic|system|mic+system] [--app BUNDLE] [--duration S]
                   [--record-only] [--no-postprocess] [--directory D] [--locale L] [--backend B]
                   [--session-id UUID] [--no-live-text] [--others-in-room] [--expected-speakers N]
                   [--vocabulary-file FILE] [--screen display|main|off]
holos record status [--directory D] [--json]
holos record stop <session-id> [--directory D] [--no-wait]
holos record pause <session-id> [--directory D] [--no-wait]
holos record resume <session-id> [--directory D] [--no-wait]
holos record marker <session-id> [--label TEXT] [--directory D] [--no-wait]
```

- `--others-in-room` is valid only with `mic+system`. `--session-id` must be a UUID with
  no existing folder. `--expected-speakers` is 1…20.
- Control commands publish a request, then wait up to 3 s for its `ControlAck` in
  `status.json` unless `--no-wait`. Output: `Paused Council meeting.` /
  `Marker added at 01:02:03.` / `Recorder did not respond within 3 s; the request stays
  queued.` (exit 1) / `Ignored: already paused.` (exit 0).
- `record status` keeps its tab-separated lines and appends `phase=<phase>
  elapsed=<h:mm:ss>` for live sessions; `--json` prints
  `[{id, status, name, chunks, phase?, elapsedSeconds?}]`.
- Exit codes per §1.4: 1 for transcription incomplete and capture failure (as today);
  3 for `diskLow`, `sleepTimeout`, `pauseTimeout`, and post-processing
  `partial`/`failed`.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `int16ChunkRoundTripWithinOneStep` | frames [0.5, −0.25, 0.999, −1.0, 0] mono 48 kHz | file `fileFormat.commonFormat == .pcmFormatInt16`; read-back error ≤ 1/32768 + 1e−6 |
| `int16HalvesChunkBytes` | 30 s mono | data size = 30 × 48,000 × 2 bytes (± header) |
| `float32ChunksStillReplay` | archive with a Float32 CAF written as in `SessionArchiveTests` | `TrackReplayer` with FakeSpeech reads all frames |
| `smallJitterIsContiguous` | frames 0–0.1 s, then 0.13–0.23 s | one chunk; no discontinuity event |
| `gapClosesChunk` | 0–0.1 s, then 0.2–0.3 s | two chunks; `audioDiscontinuity {reason: timestampGap}` |
| `overlapIsTrimmedAndRecorded` | 0–1.0 s, then 0.8–1.3 s | the second frame's first 0.2 s dropped; `timestampOverlap {droppedSeconds: 0.2}`; no chunk starts before the previous one ends |
| `pumpAbsorbsSlowWriter` | writer stalls 10 s while 20 s of frames are pushed | nothing dropped; backlog peaks ≥ 9 s; all audio written after the stall |
| `pumpDropsBeyondCapacityAndMarksOverflow` | writer stalls 70 s (capacity 60 s) | pushes return false after 60 s; one `audioDiscontinuity {reason: overflow}` per track; capture never ends; warning `audioDropped` |
| `captureOverflowDoesNotFail` | capture receiver with capacity 2, 5 yields (internal hook) | stream still open; `droppedBuffers == 3` |
| `startCheckRefusesWarnsAndAllows` | mic; free 3.0 / 5.0 / 10.0 GB | refuse / warn / ok |
| `runtimeWarnsOnceAndRearms` | free 1.9 GB twice, then 2.6 GB, then 1.9 GB | warn, ok, ok, warn |
| `runtimeStopsBelow500MB` | free 0.4 GB | `stop` |
| `renderCheckNeedsOneGigabyteHeadroom` | 1 h, 1 track; free 1.1 GB, then 1.2 GB | false, true |
| `pauseResumeTransitions` | recording + pause, pause again, resume | `stopCapture(.paused)`, event `paused`, `holdPowerAssertion(false)`, ack applied; then ack ignored; then `recordEvent(resumed)`, `holdPowerAssertion(true)`, `startCapture(epoch: 1)` |
| `stopIsIdempotent` | two stop requests | first applied + `finish(requested)`; second ignored |
| `markerWhilePausedIsApplied` | paused + marker "Vote" at 12.5 | event `marker {at: 12.5, label: Vote}`; markers 1 |
| `configurationChangeStopsThenRestarts` | recording + `captureEnded(0, .configurationChanged)` | `deviceChanged` event and warning; `stopCapture(.deviceChanged)` before `startCapture(epoch: 1)` |
| `staleEpochEndIsIgnored` | epoch 2 running; `captureEnded(1, .failed)` | no effects |
| `failuresBackOffIntoWaiting` | a failure, then four start failures | first restart immediate; then `waiting` with retries 0.5, 1, 2, 4 s later; `captureWaiting` events; no `finish` |
| `failFiveTimesThenRecover` | FakeCapture epochs 1–5 fail to start, epoch 6 delivers | recording resumes in epoch 6; one gap with reason `audioUnavailable`; no finish |
| `waitingTimesOutAfterTenMinutes` | audio unavailable from 100 s; ticks at 699 and 700 | still waiting at 699; `finish(captureFailed)` at 700 |
| `retryNowStartsImmediately` | waiting with a retry due 4 s later; `retryNow` after 1 s | `startCapture` at once |
| `attemptsResetAfterTenSecondsOfAudio` | fail, recover, run 10 s, fail again | the second restart is immediate again |
| `userStoppedSharingStops` | `captureEnded(.userStoppedSharing)` | `finish(requested)` |
| `pauseTimesOutAfterSixHours` | paused at 100; ticks at 21,699 and 21,700 | `finish(pauseTimeout)` at 21,700 |
| `inboxRejectsForeignSessionUnknownCommandSymlinkAndOversize` | four bad files + one good | good returned as `.request`; four `.rejected`; all five files removed |
| `inboxOrdersBySentAtNotCreatedAt` | pause and resume with the same `createdAt` second, resume's UUID sorting first, `sentAtNanos` pause < resume | pause applied, then resume |
| `inboxIgnoresTemporaryFiles` | `.X.tmp` and one request | tmp untouched; request returned |
| `commandsAfterStopAreIgnored` | pause request during the stop path | ack `ignored` "already stopping"; file deleted; no leftover files at exit |
| `channelSendRefusesWithoutManifest` | session folder without a manifest | throws `unavailable`; no `control/` created |
| `livenessDistinguishesMaintenance` | (a) writer held by the test, fresh status `recording`; (b) writer held, stale `exited` status; (c) no locks, stale `recording` | capturing; maintenance; dead |
| `deadRecorderStatusIsMarkedExited` | case (c) | status rewritten `exited`, reason `interrupted`, archiveStatus from the manifest |
| `heartbeatKeepsStatusFresh` | writer created, no updates for 2.5 s (heartbeat 1 s) | sequence ≥ 3; `updatedAt` advanced |
| `updatesAfterExitAreIgnored` | `finish(exit:)`, then `update` | file still `exited`; sequence unchanged |
| `progressIsMirroredInOrder` | hook sends 200 progress values quickly, then returns | the last status before `exited` shows the last value; `postprocessing` never follows `exited` |
| `epochsRecordDiscontinuityWithReason` | FakeCapture epoch 0 frames 0–1 s; pause; resume at 5 s | two chunks; `audioDiscontinuity {reason: paused}`; events `paused`, `resumed` |
| `discontinuityReasonsUseGapReasonStrings` | pause, device change, restart, overflow | event reasons exactly `paused`, `deviceChanged`, `captureRestarted`, `overflow` |
| `epochOffsetNeverOverlaps` | epoch 0's audio clock runs 0.3 s ahead of the session clock; restart | epoch 1 offset = `lastFrameEnd + 0.01`; its first chunk starts after epoch 0's last chunk ends |
| `sessionTimeStartsAtFirstCapture` | 5 s between workflow start and capture start; a marker when the session clock reads 2.0 | first chunk starts at 0; marker event `at: 2.0` |
| `liveTrackRestartsSpeechAtBoundary` | two epochs, FakeSpeech per session returning one segment each | transcript has both segments; two speech sessions created |
| `speechSessionsAreRebased` | epoch 1 at 3,605 s; FakeSpeech returns a word at 1.0–1.4 relative | transcript word at 3,606.0–3,606.4; FakeSpeech saw a first frame time of 0 |
| `nextSpeechSessionIsReadyBeforeCaptureRestarts` | resume with a FakeSpeech factory that takes 0.5 s | the factory call finishes before the new epoch's `start` is called |
| `liveOverflowKeepsLiveWordsAndReplaysOnlyTheRest` | live queue 1 s; speech blocked 3 s at 40 s of a 60 s recording | `transcriptionBehind {from ≈ 40}`; live words before 40 kept; `replay(from: ≈38)`; merged at word level with no duplicates |
| `coverageMergeSplitsStraddlingSegment` | coverage 55.2; replayed segment 54.0–57.0 with words at 54.1, 55.0, 55.3, 56.0 | replayed words 55.3 and 56.0 kept in a cut segment; live words intact |
| `finalizedEventCarriesWords` | FakeSpeech segment with 2 TimedWords | event details `segmentID`, `words` decode to the same TimedWords |
| `journalDropRecordsBehind` | journal queue capacity 2 (internal), 5 finals while the archive stalls | `transcriptionBehind {from: start of the first dropped segment}` after the queue drains |
| `hungCaptureStopTimesOut` | FakeCapture `stop()` hangs; `captureStop` 0.2 s | stop path continues; `captureFailed` event; archive finished |
| `hungSpeechFinishTimesOut` | FakeSpeech `finish()` hangs | session cancelled after the timeout; its finalized segments kept; the rest replayed |
| `leaseTakenBeforeFinish` | hook set; a poller reads liveness every 5 ms during the hand-off | the lease is held before the writer lock is released; liveness never reads `dead` |
| `statusEndsExitedAfterFakePostProcessor` | hook returns a `partial` record | `status.json` phase `exited`, `exit.postprocessing == partial`, message copied |
| `speechFixtureTimesAreAbsolute` (opt-in `HOLOS_SPEECH_FIXTURE=1`) | a phrase rendered with `NativeSpeechRenderer`, fed through `AppleSpeechSession` as epoch at 3,600 s and again after a 5 s gap | word starts within ±0.3 s of the true times in both |

**Acceptance.** All tests pass; `holos record --help` lists the new subcommands and
flags; `holos record status --json` decodes on a sessions folder containing a fixture
`status.json`; the PR description reports the opt-in speech fixture result (run by the
implementer; no microphone). Agents do not run a live recording.

**Does not touch.** `MeetingPostProcessor.swift`, `Sources/HolosCLI/PostProcessing.swift`,
`Session.swift`, `Doctor.swift`, `Package.swift`, `HolosStorage` (uses PR6's API only),
`HolosSpeakers`, contract files (except additions allowed by §3.0), `HolosDictation`,
`HolosApp`, `Fakes.swift`.

#### PR2b (stacked on PR2a)

**Files.**

- HolosAudio, add: `PowerAssertion.swift`, `SystemPowerMonitor.swift`,
  `BuiltInMicrophone.swift`, `AudioEnvironmentEvents.swift` (CoreAudio
  `kAudioHardwarePropertyDevices` listener and the `com.apple.screenIsUnlocked`
  distributed notification, buffered in a `Mutex`).
- HolosAudio, change: `AudioCapture.swift` (report `configurationChanged`; pin the
  built-in microphone for `.builtIn`; start ScreenCaptureKit without the microphone when
  asked).
- HolosMeeting, add: `TrackWatchdog.swift`. Change: `RecorderMachine.swift` (sleep,
  watchdog, device rules of §4.2 and §4.4), `RecordingWorkflow.swift` (power assertion,
  power events, lid state, environment events, input-device lookup, call without
  microphone).
- HolosCLI: change `Record.swift` (in person refuses a missing built-in microphone).
- Tests: `Tests/HolosMeetingTests/{SleepPolicyTests, WatchdogTests, MicrophoneSelectionTests}.swift`,
  `Tests/HolosAudioTests/BuiltInMicrophoneTests.swift` (pure classification only).

**API (additions).**

```swift
// HolosAudio
public struct InputDevice: Sendable, Equatable { public let id: UInt32; public let uid: String; public let name: String }
public struct InputDevices: Sendable, Equatable {
    public var builtIn: InputDevice?        // nil when absent (e.g. lid closed in clamshell mode)
    public var systemDefault: InputDevice?  // nil when the Mac has no input device
}
public enum BuiltInMicrophone {
    public static func devices() -> InputDevices
    /// Pure classification used by `devices()`, for tests.
    public static func isBuiltInInput(transportType: UInt32, inputStreamCount: Int) -> Bool
}
public final class PowerAssertion: Sendable {
    /// kIOPMAssertionTypePreventUserIdleSystemSleep named `reason`. Released by `release()` or deinit.
    public init(reason: String) throws
    public func release()
}
public enum PowerEvent: Sendable, Equatable {
    case willSleep(token: Int)     // the loop calls allowPowerChange(token:) after closing chunks
    case didWake
}
public protocol SystemPowerEvents: Sendable {
    /// Events buffered since the last call.
    func pendingEvents() -> [PowerEvent]
    func allowPowerChange(token: Int)
    /// AppleClamshellState from IOPMrootDomain; true when the property is absent.
    func isLidOpen() -> Bool
    /// While detached, the monitor acknowledges willSleep itself.
    func attach()
    func detach()
}
public final class SystemPowerMonitor: SystemPowerEvents { public init() throws; public func stop() }
public final class AudioEnvironmentEvents: Sendable {
    public init()
    /// "audioDevicesChanged" or "screenUnlocked", buffered since the last call.
    public func pendingReasons() -> [String]
    public func stop()
}

// HolosMeeting
public struct TrackWatchdog: Sendable, Equatable {
    public init(stallSeconds: Double = 3, restartSeconds: Double = 10)
    public mutating func startEpoch(at: Double, tracks: [String])
    /// Tracks that became stalled, tracks that recovered, and microphone tracks due for a restart.
    public mutating func evaluate(lastFrameAt: [String: Double], now: Double)
        -> (stalled: [String], resumed: [String], restart: [String])
}
```

`RecordingDependencies` gains, with inert defaults: `power: (any SystemPowerEvents)?`
(nil), `makePowerAssertion: @Sendable (String) -> PowerAssertion?` (returns nil),
`findInputDevices: @Sendable () -> InputDevices` (a fake built-in and default device),
and `environmentEvents: AudioEnvironmentEvents?` (nil). `.live(...)` installs the real
ones.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `sleepUnderFifteenMinutesResumes` | willSleep at 100; didWake at 700, lid open | `stopCapture(.sleep)`, `systemWillSleep`, `allowSleep`; then `startCapture(epoch: 1)`, `warn(resumedAfterSleep)`, `didWake {action: resume}` |
| `sleepOverFifteenMinutesFinalizes` | willSleep at 100; didWake at 1001 | `finish(sleepTimeout)`; no `startCapture` |
| `wakeWithLidClosedWaitsThenFinalizes` | didWake at 160, lid closed; tick at 999, then 1000 | stays sleeping; then `finish(sleepTimeout)` |
| `darkWakeKeepsSleepStart` | recording; willSleep 0; didWake 600 lid closed; willSleep 601; didWake 1,200 lid open | `finish(sleepTimeout)` |
| `pausedStaysPausedThroughDarkWake` | paused; willSleep; didWake lid closed; willSleep; didWake 300 s later lid open | phase `paused`; no `startCapture` |
| `pausedSleepOverFifteenMinutesStaysPaused` | paused; willSleep 100; didWake 2,000 | phase `paused`; no `finish` |
| `sleepWhileWaitingRetriesOnWake` | waiting; willSleep; didWake 60 s later, lid open | `startCapture` |
| `wakeThenStartFailureRetries` | didWake with the lid open; the new epoch fails to start twice | first retry at once, then `waiting` with backoff; no `finish` |
| `monitorAcknowledgesWhenDetached` | detached; willSleep | acknowledged by the monitor itself |
| `loopAcknowledgesAfterClosingChunks` | attached; willSleep; FakeCapture `stop()` hangs | chunks closed, then `allowPowerChange` within the capture-stop timeout |
| `watchdogFlagsAfterThreeSecondsAndClears` | mic last frame at 10.0; now 13.1, then a frame at 13.5 | stalled [mic]; then resumed [mic] |
| `stalledMicRestartsInNewEpoch` | mic last frame at 10.0; ticks to 20.1 | `trackStalled` at 13; `stopCapture(.captureRestarted)` then `startCapture(epoch+1)` at 20 |
| `systemTrackIsNeverRestartedForStall` | system silent 30 s | stalled warning only |
| `slowStartIsNotAStall` | 5 s startup delay before epoch 0; first frame at session 0.2 | no stall |
| `retryOnScreenUnlockAndDeviceChange` | waiting; environment reason `screenUnlocked` | `retryNow` → `startCapture` |
| `inPersonPinsBuiltInMicrophone` | devices: built-in + AirPods as default; source mic | capture request `.builtIn`; status `microphoneName` is the built-in name |
| `callUsesSystemDefault` | source mic+system | capture request `.systemDefault`; `microphoneName` is AirPods |
| `inPersonRefusesWithoutBuiltIn` | `builtIn == nil` | start throws "The built-in microphone is unavailable. Open the lid and try again."; no session folder |
| `callWithoutAnyInputRecordsSystemOnly` | `systemDefault == nil` on restart | capture starts without the microphone; `warn(microphoneUnavailable)`; after `audioDevicesChanged` with a device back, restarts with it |
| `builtInClassification` | (built-in, 1 input stream), (USB, 1), (built-in, 0) | true, false, false |

**Manual checks.** H4–H7, H9–H11, and H21 in §7.2, recorded in `docs/hardware-validation.md`.

**Does not touch.** Same list as PR2a.

### 5.6 PR3: Recovery, session catalog, deletion (wave 3)

**Goal.** After a recorder crash or power loss, rebuild the transcript from
`transcriptFinalized` events, transcribe only audio that was not covered, list sessions
with their state, post-process the result, and delete audio or whole meetings.

**Files.**

- Add `Sources/HolosMeeting/TranscriptRebuilder.swift`, `Sources/HolosMeeting/SessionCatalog.swift`,
  `Sources/HolosStorage/SessionDeletion.swift`, `Sources/HolosCLI/SessionList.swift`,
  `Sources/HolosCLI/SessionDelete.swift`.
- Change `Sources/HolosCLI/Session.swift` (Recover flow; add `List.self`, `Delete.self`),
  `Sources/HolosCLI/Record.swift` (`status` uses `SessionCatalog`).
- Tests: `Tests/HolosMeetingTests/{TranscriptRebuilderTests, SessionCatalogTests}.swift`,
  `Tests/HolosStorageTests/SessionDeletionTests.swift`.
- Docs: PR3 merges last in wave 3 and writes the wave-3 `README.md` and
  `docs/status.md` notes for PR3 and PR8.

**API.**

```swift
public struct RebuildReport: Sendable, Equatable {
    public var transcriptID: String
    public var journalSegments: Int
    /// Per track: session time up to which journal words are kept.
    public var coverageEnd: [String: Double]
    /// Per track: seconds of audio transcribed again.
    public var replayedSeconds: [String: Double]
    /// True when an earlier rebuild was reused (idempotent path).
    public var reused: Bool
}

public enum TranscriptRebuilder {
    /// Requires an inactive archive and the caller's lease. Replays without the writer lock; takes it only for
    /// the final save through `SessionArchive.openForMaintenance(at:lease:)`. `vocabulary` nil reads vocabulary.json.
    public static func rebuild(session: URL, lease: ProcessingLease, force: Bool = false, transcribe: Bool = true,
                               vocabulary: [String]? = nil, makeSpeech: LiveSpeechFactory? = nil,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> RebuildReport
}

public enum SessionState: String, Codable, Sendable {
    case recording, processing, interrupted, complete, audioOnly, transcriptionIncomplete,
         incomplete, failed, recovered, damaged
}
public enum SpeakerLabelState: String, Codable, Sendable {
    /// No postprocess.json.
    case none
    case running
    case labelled
    /// Post-processing finished without a run (e.g. speaker models not installed); see `labelMessage`.
    case notLabelled
    case failed
    case interrupted
    /// postprocess.json or speakers/head.json cannot be read (damaged, newer Holos, I/O); see `labelMessage`.
    case unreadable
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var directory: URL
    public var name: String
    public var createdAt: Date
    public var source: AudioSource
    public var origin: MeetingOrigin
    public var state: SessionState
    public var manifestStatus: String
    /// Longest track's total chunk duration.
    public var savedSeconds: Double
    public var chunkCount: Int
    /// Set once the current revision was read and holds this ID.
    public var transcriptID: String?
    /// Why the current transcript cannot be read (missing, damaged, other ID, newer Holos).
    public var transcriptProblem: String?
    public var speakerState: SpeakerLabelState
    public var labelMessage: String?
    public var runID: String?
    public var hasSpeakerEdits: Bool
    public var phase: RecorderPhase?
    public var pid: Int32?
    public var liveness: RecorderLiveness
    public var bytes: Int64
    public var derivedBytes: Int64
    public var audioDeleted: Bool
    /// LANG2 (§4.14 step 5): languages of a meeting in several that the transcript misses.
    public var languageWork: LanguageWork?
}

public enum SessionCatalog {
    /// Newest first. A folder whose manifest cannot be read is `damaged` (named by its folder).
    public static func list(root: URL = HolosPaths.sessions, now: Date = Date()) -> [SessionSummary]
    public static func summary(session: URL, now: Date = Date()) -> SessionSummary
    /// LANG2: sets `languageWork.ready` where a missed language can be detected now (speech model check).
    public static func checkingLanguageModels(_ summaries: [SessionSummary],
                                              dependencies: LanguageDetectionDependencies = .live) async
        -> [SessionSummary]
}

public enum SessionDeletion {
    /// §4.13. Requires the lease and no writer.
    public static func deleteAudio(session: URL, lease: ProcessingLease) throws
    /// §4.13. `trash` defaults to FileManager.trashItem; `logDirectory` to ~/Library/Logs/Holos (tests inject both).
    public static func moveToTrash(session: URL, lease: ProcessingLease,
                                   logDirectory: URL = SessionDeletion.defaultLogDirectory,
                                   trash: (URL) throws -> Void = SessionDeletion.systemTrash) throws
}
```

**Rebuild algorithm.**

1. The caller holds the lease. Refuse if `isActive`. `RecorderChannel.markDeadRecorderExited`.
2. Read events with `SessionArchive.readEvents` (tolerant of a torn last line and corrupt
   lines). Collect `transcriptFinalized` per track. Events with `words` rebuild
   `TimedWord`s and keep `segmentID`; older events give segments without words. Drop
   exact duplicates `(track, start, end, text)`.
3. `coverageEnd[track] = TranscriptCoverage.coverageEnd(live: journal segments,
   behindFrom: earliest transcriptionBehind.from for the track)`. Live transcription is
   sequential, so everything before the last final was processed, unless a
   `transcriptionBehind` event marks a hole (live overflow or a dropped journal write),
   in which case coverage stops at the hole (resolution R20).
4. If `transcribe`: `TrackReplayer.replay(from: max(0, coverageEnd − 2))` with the
   session vocabulary; `TranscriptCoverage.merge` keeps journal words before coverage and
   replayed words from it on, cutting segments at word boundaries.
5. Sort by `(start, track)`; `openForMaintenance(at:lease:)`; append
   `transcriptRebuilding` with the details `transcriptRebuilt` will have (so a transcript
   a rebuild made current is never taken for one the recorder saved at stop);
   `saveTranscript(_:writeLegacyExports: false)` (pointer updated); set status
   `recovered`; append `transcriptRebuilt {transcriptID, journalSegments,
   replayedSeconds}`; `finish`. A failure after the save is reported, not thrown; the next
   rebuild (and recover, even for a session that keeps its saved transcript) finds the
   `transcriptRebuilding` naming the current transcript and finishes writing the missing
   status and event instead of rebuilding again.
6. Idempotence by sequence numbers, not dates: if a `transcriptRebuilt` event exists with
   a higher `sequence` than the last `archiveRecovered` event, its `transcriptID` is the
   current pointer, that revision decodes and holds its own ID, and `!force`, return it
   with `reused: true` and change nothing. A truncated, damaged, or mislabelled current
   revision is rebuilt. A current pointer or revision, or a `vocabulary.json` the replay
   would use, written by a newer Holos is refused (`unavailable`), even with `force`.

**State mapping (`SessionCatalog`).** Unreadable manifest → `damaged`. Manifest
`recording`/`processing`: liveness `capturing` → `recording`; `processing` or
`maintenance` → `processing`; else `interrupted`. Otherwise the manifest status maps 1:1.
Speaker state: `postprocess.json` `running` with liveness `processing` or `maintenance`
→ `running`; `running` otherwise → `interrupted`; `failed` → `failed`; a finished record
with a run → `labelled`; a finished record without a run → `notLabelled` with the record's
message; no record → `none`. A head counts as labels only when
`SpeakerSessionSnapshot.load` (the loader the exports and speaker commands use) loads its
run: the run and the transcript revision it was built from exist and decode, and every
span fits that transcript. A postprocess.json, speakers/head.json, head run, or run
transcript that exists but cannot be read (damaged, of another session, written by a
newer Holos, I/O), a head whose run or run transcript is missing, a span outside that
transcript, or a record that names a run while the head is missing → `unreadable` with
why, never the state of a session without it. `recover` validates the same files the same
way (one shared reader, `SavedSpeakerState`, which delegates to the snapshot loader)
before it decides to post-process, and refuses (`unavailable`) when one was written by a
newer Holos.

**Saved files are read, never only found.** Every versioned file recover, the catalog,
delete, relabel, and the exports read (meeting.json, vocabulary.json, postprocess.json,
`transcripts/current.json` and revisions, `speakers/head.json`, runs, recognition results,
`audio-deleted.json`, `exports/.generated.json`) is decoded with its version checked
first: newer → `unavailable`; a version below 1 or data that does not decode → damage,
never present-and-authoritative. A record that names a session (meeting.json,
postprocess.json, runs, voice data, and `audio-deleted.json` when it names one) is
checked against the manifest's ID; another session's is damage.
`manifest.json` stays strictly version 1 (schema rule 4).

**CLI.**

```
holos session list [--directory D] [--interrupted] [--json]
holos session recover <path> [--no-transcribe] [--no-postprocess] [--force]
holos session delete <path> [--audio-only] --yes
```

`session list` prints `ID  STATE  SAVED  SIZE  SPEAKERS  NAME` (SAVED as `h:mm:ss`).
`recover` takes the lease once and keeps it for `SessionArchive.recover(at:lease:)`,
`TranscriptRebuilder.rebuild(lease:)`, and `MeetingPostProcessor.run(lease:)`, so no
other process can start labelling in between. It prints, for example, `Recovered 212
chunks (1:46:10). Transcript rebuilt from 1812 saved phrases; transcribed 0:31 of
uncovered audio. Speaker labels: 9 speakers.` `delete` without `--yes` refuses with a
hint. Session arguments are paths, as today.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `rebuildUsesJournalWordsAndSegmentIDs` | events with 3 `transcriptFinalized` (words present) | 3 segments; words and IDs equal the event payloads |
| `legacyEventsProduceUntimedSegments` | events without `words` | segments with empty `words` |
| `tornJournalTailIsTolerated` | journal whose last line is cut | rebuild succeeds after `recover`; torn line ignored |
| `corruptMiddleLineIsTolerated` | a garbage line between finals | rebuild succeeds; the other finals kept |
| `coverageIsLastFinalizedEnd` | mic finals ending 40.0 and 55.2; system none | coverage mic 55.2, system 0 |
| `coverageStopsAtBehindEvent` | finals to 55.2; `transcriptionBehind {mic, from: 30}` | coverage mic 30 |
| `uncoveredTailIsReplayedAtWordLevel` | coverage 55.2; replayed segment 53.5–58.0 with words at 53.6, 54.8, 55.4, 57.0 | only 55.4 and 57.0 added; no duplicated words |
| `recoverRebuildAndPostProcessUnderOneLease` | recover → rebuild → post-process in one process; another descriptor tries the lease after each step | every attempt refused; the chain succeeds; lease released at the end |
| `rebuildSavesWhileHoldingItsOwnLease` | rebuild with a lease | succeeds; the writer lock is free afterwards |
| `recoveryIsIdempotent` | rebuild twice within one second | second returns `reused: true`; one `transcriptRebuilt` event; one new transcript file |
| `rebuildRefusesActiveRecording` | writer lock held with a fresh `recording` status | throws `unavailable` |
| `catalogMarksDeadRecorderInterrupted` | manifest `recording`, no locks, stale status.json | `interrupted` |
| `catalogShowsMaintenanceAsProcessing` | manifest `processing`, writer lock held, no status.json newer than 10 s | `processing`, not `recording` |
| `catalogReportsSavedDurationSizeAndSpeakerState` | chunks mic 0–30, 30–60; system 0–30; head present | savedSeconds 60; `labelled`; bytes > 0 |
| `catalogReportsNotLabelledWithMessage` | postprocess.json succeeded, diarize skipped (models) | `notLabelled`; message has the setup hint |
| `deleteAudioKeepsTranscript` | session with audio, run, voice data, derived | `audio/`, `derived/`, `speakers/voice/` gone; transcript, run, exports kept; `audio-deleted.json`; inspect clean; catalog `audioDeleted` |
| `deleteRefusedWhileRecording` | writer lock held | throws; nothing removed |
| `moveToTrashRemovesRecorderLog` | fake trash and temp log directory | folder handed to the fake trash; log file deleted |

**Does not touch.** `HolosSpeakers`, `SessionSpeakerStore`, `SpeakerEditor`,
`Speakers.swift`, `SessionExport.swift`, exporters, `MeetingPostProcessor.swift`,
`SessionArchive.swift`, `Package.swift`, `Fakes.swift` and `SessionFixtures.swift` (PR8
owns them in wave 3).
