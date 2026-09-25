# Meeting recording: manual validation

These are manual acceptance steps on the user's Mac, not checks the automated suite performs
(docs/meeting-design.md §7.2). Each check names its hardware-checklist ID. Record the date, the
Voice is Local build, and the result under each check. Use short private test recordings first; recording
other people requires the notice or consent your situation calls for.

## Recording controls (PR4)

Build the app with `./scripts/build-app.sh` (it now bundles the `voiceislocal` tool as
`VoiceIsLocal.app/Contents/MacOS/voiceislocal`), then open `build/VoiceIsLocal.app`. The recorder runs as a child of the
app by default; `defaults write ca.orlenko.holos.app meetingRecorderMode inProcess` switches to the
in-process fallback, and `defaults delete ca.orlenko.holos.app meetingRecorderMode` switches back.
Recorder output goes to `~/Library/Logs/Holos/recorder-<SESSION-UUID>.log`.

### H1: Permissions and the start panel

1. Choose **Start Meeting Recording…**. The panel shows the name, In person or Online call, the
   microphone that will be recorded (in person: the built-in microphone; a call: the system
   default input), the disk estimate, the speaker-model state, the language (a pop-up with the
   same languages as dictation, starting at the dictation language or the last meeting's), its
   speech-model state, and the consent reminder.
2. Start an in-person recording. Note which app macOS names in the microphone prompt (and, for an
   online call, the screen and system audio prompt). While a prompt is open, the menu must say
   "Waiting for permission…" after about 5 seconds.
3. After approving, the status item shows a red record symbol and the elapsed time; the menu shows
   the recording lines (time, disk used and free, microphone, transcription state).
4. Stop and save, rebuild the app, and repeat. Note whether the permission survives a rebuild.
5. If a prompt still appears (for example after a rebuild), choose **Stop Recording** while it is
   open. The menu says the recorder stops once the prompt is answered, and no "did not start within
   2 minutes" failure appears even after 2 minutes. Then answer the prompt.

Pass: the prompts name Voice is Local; "Waiting for permission…" appears while a prompt is open; recording
works; a recording stopped at the prompt ends with "The recording was stopped before it started."

Result: Pending.

### H2: The app dies during a recording

1. Start a recording from the menu and let it run for a minute.
2. `kill -9` the Voice is Local app (not the recorder): `pkill -9 -f build/VoiceIsLocal.app/Contents/MacOS/HolosApp`.
3. Wait 30 seconds; check that `status.json` in the session folder keeps changing (`sequence` grows).
4. Open Voice is Local again.

Pass: the recorder keeps writing; the relaunched menu shows the meeting with the right elapsed
time; Stop and Save works; no audio gap.

Result: Pending.

### H3: The recorder dies during a recording

1. Start a recording from the menu; after a minute, `kill -9` the recorder process
   (`pkill -9 -f "build/VoiceIsLocal.app/Contents/MacOS/voiceislocal record start"`).
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

With the child recorder (the default), quit Voice is Local during a recording three times, choosing each
button of "A meeting is recording.":

- **Stop and Save**: Voice is Local quits within about 10 seconds; the recording is saved and speaker
  labelling finishes on its own (check Meetings after reopening).
- **Keep Recording**: Voice is Local quits at once; the recording continues; reopening Voice is Local shows it.
- **Cancel**: nothing changes.

With `meetingRecorderMode` set to `inProcess`: **Stop and Save** shows "Saving the meeting’s
transcript…" and quits once the transcript is saved (speaker labelling continues in its own
process); **Cancel** changes nothing. A meeting started with `voiceislocal record start` in a terminal is
not recorded by Voice is Local in either mode, so quitting during it offers all three buttons, as in child
mode.

Pass: each choice behaves as docs/meeting-design.md §5.8 says.

Result: Pending.

### H17: Consent reminder

1. Start a recording with "Don't show this again" checked; stop it.
2. Open the start panel again.

Pass: the reminder stays hidden on the next start.

Result: Pending.

### Meeting language

1. With no meeting language chosen yet (`defaults delete ca.orlenko.holos.app meetingLocales`),
   open the start panel: the Language pop-up shows the dictation language. Right after launch,
   before the supported languages load, the line reads "Finding the meeting language…" and
   Start stays off until the pop-up fills in.
2. Choose French (Canada) (or another language whose speech model is not installed). The panel
   says the speech model is not installed and offers **Install…**; nothing downloads until you
   click it. Click it: the line says it is installing, then "Speech model ready".
3. Record a short in-person meeting speaking French; stop and save.
4. Open the start panel again: French (Canada) is still chosen.
5. Check the session: `manifest.json` has `"locale": "fr-CA"` and the transcript is French; while
   it recorded, `pgrep -lf "voiceislocal record start"` showed `--locale=fr-CA`. Repeat once in the
   in-process mode.

Pass: the pop-up starts at the dictation language, then at the last meeting's; the model is
installed only on Install…; the recording is transcribed in the chosen language in both modes.

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
2. Start the Mac again and open Voice is Local.

Pass: the meeting is labelled automatically within a minute or two (Meetings shows it Labelled).

Result: Pending.

## Review window (PR9)

The review window names the speakers of a labelled meeting. Open it from **Meetings…** (select
a meeting whose Speakers column says Labelled, then **Review…**, or double-click it) or from
the **Name Speakers — <name>…** line at the top of the menu after a meeting. The left side
lists the speakers (name field, talk time, the start of their two longest turns, **▶ Play
samples**, **This is me**, **Merge into…**, and "Maybe Maria" suggestions with **Confirm** /
**Not Maria**); the right side lists the turns (time button that plays from there, speaker
pop-up, ⚠ for uncertain turns, text). Keys: Space plays or pauses, ↑/↓ move, 1–9 give the
selected turns to that speaker number, ⌘' goes to the next uncertain turn and plays it, ⌘Z
undoes, ⌘F searches, ⌘E opens Export. The **Speakers** pull-down holds Confirm All
Suggestions, Find More Speakers…, Label Speakers on My Microphone… (calls recorded without
"others in the room"), and Undo.

Every change shows at once and is saved in the background to the meeting's edit journal (there
is no Save button); the transcript files in `exports/` follow about 2 seconds after the last
change and when the window closes. Undo takes back this window's changes, newest first, and
never a change made elsewhere; Find More Speakers and relabelling end the undo history. Naming
a speaker creates or links a person, whatever the "Remember voices" setting; the footer box
"Learn voices of people I name in this meeting" decides whether a voice is learned (it starts
as the Remember voices setting and is off while that is off).

Use an imported recording (`voiceislocal session import <audio-file>`) for the first run: naming and
merging change the meeting's labels (Undo takes them back). The Otter references are private: note
times and counts only, never transcript text or names, in this file.

### H14: Label the 89-minute Otter meeting from scratch

1. Import the 89-minute reference recording:
   `voiceislocal session import <path to the recording>` (it prints the new session's path once
   speakers are labelled). Do not commit anything from `reference-data/`.
2. Open Voice is Local, then **Meetings…**, select the imported meeting, and choose **Review…**.
3. Start a timer. Name every speaker: play their samples, read their previews, type a name and
   press Return (or pick a known person). Use **Next Uncertain** (⌘') to check doubtful turns,
   1–9 or the turn pop-up to move turns, **Merge into…** for a person split over two speakers,
   **Split Turn** for a turn that holds two people, and **Find More Speakers…** if two people
   share one speaker.
4. Stop the timer when every speaker with more than a minute of talk has a name and the
   uncertain turns you checked are right. Close the window.
5. In Meetings, choose **Open Transcript**: the names appear in the Markdown, with the changes
   you made.

Pass: done in under 10 minutes. Record the time, the number of speakers named, and how many
merges, splits, reassigned turns, and Find More Speakers runs were needed.

Result: Pending.

### H20: A real 3-hour council meeting

1. Record a real council meeting of about 3 hours (tell the room first) and stop it; wait for
   "Name Speakers — <name>…" in the menu.
2. Choose it: the review window opens and the menu's naming line and dot go away.
3. Name all speakers as in H14, timing only your own working time. While names save, keep
   typing and moving turns: the window must not freeze, and every change must still be there
   after closing and reopening the window.
4. Play from several timestamps across the meeting, including after a pause or a sleep: the
   audio must match the turn's text.

Pass: all speakers named in 10 minutes or less of your time. Record how many Find More
Speakers, split, and merge actions were needed, and anything that felt slow.

Result: Pending.

### Other review checks

1. **Changes made elsewhere.** With the window open, rename a speaker in Terminal
   (`voiceislocal speakers rename <session> S2 "Someone"`), then rename the same speaker in the window.
   Pass: the window says the labels changed outside it, saves nothing, and then shows
   "Someone"; a rename made after that is saved.
2. **Undo.** Name three speakers, confirm all suggestions (if any), move a turn, then press ⌘Z
   repeatedly. Pass: the changes come back out newest first, Confirm All as one step, and ⌘Z
   stops once the window's own changes are undone.
3. **Edited transcript kept.** In the meeting folder, make `exports/transcript.md` writable
   (`chmod u+w`), change a word, then rename a speaker in the window and wait 3 seconds. Pass:
   the footer says "Your edited transcript.md was kept as edited-<date>.md", that file holds
   your change, and `transcript.md` is regenerated.
4. **Transcript changed.** On an imported recording whose speakers you named, run
   `voiceislocal session recover <session> --force --no-postprocess` (a new transcript, not
   labelled), then open its review. Pass: the footer says "The transcript changed after speakers
   were labelled." with **Label Again**, which relabels it with the names carried over.
5. **Delete Audio.** With the window open, choose **Delete Audio…** in Meetings. Pass: playback
   stops, the footer says "Audio deleted; playback is off.", and naming still works.
6. **Delete Meeting forgets voices on request.** With Remember voices on, name a person in a
   meeting with voice learning on (People shows a sample from it). Choose **Delete Meeting…**
   with "Also forget voice samples learned from this meeting" checked. Pass: the review window
   closes first, the meeting goes to the Trash, and People no longer lists that sample; without
   the box checked the sample stays.

Result: Pending.

## Online calls (PR11)

In a call, Voice is Local records the system default input and the call audio. When the laptop speakers
play the call, the microphone hears the other people too: the start panel, the menu, and
`voiceislocal record start` warn about it, and speaker labelling leaves the microphone's copy of their
words (echo) out of the transcript. Only runs of 3 or more consecutive words that repeat the call
audio up to 1 second later are removed, so a short "yes" said over someone stays. Words the
microphone heard more than a quarter second before the call audio stay: that is your own voice
coming back from the other end, not echo. The removed words are
listed in `speakers/runs/<RUN-UUID>.json` under `droppedWords` with reason `echo`. For a call
with others in the room, a microphone speaker whose words are at least 60 % echo is not a person
in the room: it is not listed, and its remaining words show as "Unknown speaker".

For a remote participant, use a second device in a call, or play a talk or podcast in a browser
tab as "the call" and speak between its sentences. Install the speaker models first (Setup), since
echo is removed when speakers are labelled.

### H16: A call on the laptop speakers, then a hybrid call

1. Unplug headphones and disconnect AirPods so the laptop speakers are the output. Open **Start
   Meeting Recording…** and choose Online call. Under the microphone line, the panel shows in
   orange: "The laptop speakers are playing the call, so other people's voices also reach your
   microphone. Headphones give a cleaner transcript." Choose In person: the line goes. Choose
   Online call again, then plug in headphones (or connect AirPods): within 2 seconds the line goes.
2. Unplug the headphones. Start the call recording on the laptop speakers, with the call audio
   playing, and say a few sentences of your own between the other side's sentences. The menu shows
   "⚠ The laptop speakers are playing the call…" and the status item shows ⚠.
3. During the recording, plug in headphones: the warning leaves the menu within a few seconds. Unplug
   them: it comes back. (In a terminal, `voiceislocal record start --source mic+system --duration 60`
   prints the same warning on stderr once each time it appears.)
4. Stop and save. After labelling, open the transcript (Meetings → Open Transcript). The other
   side's sentences appear once, under their system-audio speakers, not again under "Me"; your own
   sentences are under "Me". Note any leftover single words under "Me" that came from the call
   audio (misheard echo shorter than 3 matching words).
5. Hybrid: two people in the room, "Others are in the room with me" checked, laptop speakers
   playing the call. Everyone in the room speaks, and the call audio plays between them. Stop and
   save; after labelling, check the transcript.
6. Optional: relabel the same meeting with `voiceislocal session diarize <path to the .holos folder>
   --force --no-others-in-room`, then with `--others-in-room`, and compare.

Pass: the warning shows with the laptop speakers and not with headphones, in the panel, the menu,
and the terminal; echoed phrases are absent from the microphone's turns; the room speakers are
labelled on the microphone track; no speaker consists only of echo (no microphone speaker whose
text repeats the call audio).

Result: Pending.
