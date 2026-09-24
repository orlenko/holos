# Meeting recording: manual validation

These are manual acceptance steps on the user's Mac, not checks the automated suite performs
(docs/meeting-design.md §7.2). Each check names its hardware-checklist ID. Record the date, the
Holos build, and the result under each check. Use short private test recordings first; recording
other people requires the notice or consent your situation calls for.

## Recording controls (PR4)

Build the app with `./scripts/build-app.sh` (it now bundles the `holos` tool as
`Holos.app/Contents/MacOS/holos`), then open `build/Holos.app`. The recorder runs as a child of the
app by default; `defaults write ca.orlenko.holos.app meetingRecorderMode inProcess` switches to the
in-process fallback, and `defaults delete ca.orlenko.holos.app meetingRecorderMode` switches back.
Recorder output goes to `~/Library/Logs/Holos/recorder-<SESSION-UUID>.log`.

### H1: Permissions and the start panel

1. Choose **Start Meeting Recording…**. The panel shows the name, In person or Online call, the
   microphone that will be recorded (in person: the built-in microphone; a call: the system
   default input), the disk estimate, the speaker-model state, and the consent reminder.
2. Start an in-person recording. Note which app macOS names in the microphone prompt (and, for an
   online call, the screen and system audio prompt). While a prompt is open, the menu must say
   "Waiting for permission…" after about 5 seconds.
3. After approving, the status item shows a red record symbol and the elapsed time; the menu shows
   the recording lines (time, disk used and free, microphone, transcription state).
4. Stop and save, rebuild the app, and repeat. Note whether the permission survives a rebuild.
5. If a prompt still appears (for example after a rebuild), choose **Stop Recording** while it is
   open. The menu says the recorder stops once the prompt is answered, and no "did not start within
   2 minutes" failure appears even after 2 minutes. Then answer the prompt.

Pass: the prompts name Holos; "Waiting for permission…" appears while a prompt is open; recording
works; a recording stopped at the prompt ends with "The recording was stopped before it started."

Result: Pending.

### H2: The app dies during a recording

1. Start a recording from the menu and let it run for a minute.
2. `kill -9` the Holos app (not the recorder): `pkill -9 -f build/Holos.app/Contents/MacOS/HolosApp`.
3. Wait 30 seconds; check that `status.json` in the session folder keeps changing (`sequence` grows).
4. Open Holos again.

Pass: the recorder keeps writing; the relaunched menu shows the meeting with the right elapsed
time; Stop and Save works; no audio gap.

Result: Pending.

### H3: The recorder dies during a recording

1. Start a recording from the menu; after a minute, `kill -9` the recorder process
   (`pkill -9 -f "build/Holos.app/Contents/MacOS/holos record start"`).
2. Within 10 seconds the menu must say the recorder stopped unexpectedly.
3. Open **Meetings…**: the session shows as Interrupted with its saved duration. Choose
   **Recover…**.

Pass: the menu reports the stop within 10 s; Meetings shows "Interrupted" with the saved duration;
Recover rebuilds the transcript; at most one 30 s chunk is lost.

Result: Pending.

### H12: Dictation is paused while recording

1. Enable dictation. Start a meeting recording.
2. Open the menu: the dictation items are replaced by one line, "Dictation paused during meeting
   recording".
3. In a text field of another app, hold Right Option.
4. Stop the recording; once the menu shows it saving, hold Right Option again.

Pass: no dictation during the meeting and the key reaches the app; the menu shows only the paused
line; dictation works again after the stop. (After a sleep during the meeting, dictation stays off
and the menu says to enable it.)

Result: Pending.

### H13: Quitting during a recording

With the child recorder (the default), quit Holos during a recording three times, choosing each
button of "A meeting is recording.":

- **Stop and Save**: Holos quits within about 10 seconds; the recording is saved and speaker
  labelling finishes on its own (check Meetings after reopening).
- **Keep Recording**: Holos quits at once; the recording continues; reopening Holos shows it.
- **Cancel**: nothing changes.

With `meetingRecorderMode` set to `inProcess`: **Stop and Save** shows "Saving the meeting’s
transcript…" and quits once the transcript is saved (speaker labelling continues in its own
process); **Cancel** changes nothing. A meeting started with `holos record start` in a terminal is
not recorded by Holos in either mode, so quitting during it offers all three buttons, as in child
mode.

Pass: each choice behaves as docs/meeting-design.md §5.8 says.

Result: Pending.

### H17: Consent reminder

1. Start a recording with "Don't show this again" checked; stop it.
2. Open the start panel again.

Pass: the reminder stays hidden on the next start.

Result: Pending.

### H19: Speaker models installed from the app

1. With no speaker models installed (move
   `~/Library/Application Support/Holos/Models/speaker-diarization-coreml@df2625ac79a7` aside),
   record a short meeting and stop it.
2. The finished message in the menu says "No speaker labels: speaker models are not installed".
3. Open **Setup…**: the Speaker labels row offers **Install (21 MB download)**; install and watch
   the progress.
4. In **Meetings…**, select the meeting and choose **Label Speakers**.

Pass: the message names the missing models; Setup installs them; Label Speakers then works and a
"Name Speakers — …" entry appears for later meetings.

Result: Pending.

### H22: Labelling interrupted by a shutdown

1. Record a meeting of a few minutes, stop it, and shut the Mac down at once, while the menu
   still says it is labelling speakers.
2. Start the Mac again and open Holos.

Pass: the meeting is labelled automatically within a minute or two (Meetings shows it Labelled).

Result: Pending.

## Review window (PR9)

Pending.

## Online calls (PR11)

Pending.
