# Manual testing: what has not been tried

One list of what no one has checked by hand yet, grouped by how it gets covered. The step-by-step checks
stay in the guides it points to; features that have no guide yet get their checks here.

The repo has no recorded result for any manual check: every guide below says "not run" or "Result:
Pending". Daily use since 2026-09-29 (dictation, real meetings, calls, Review) has covered parts of this
without being written down. When you see something work or fail, tick it here with the date and build
(`git log -1 --format=%h`), or tell the agent and it will. A failure goes to the agent as feedback first.

How each item gets covered:

- **Meetings** — an ordinary meeting exercises it; just notice the result afterwards.
- **Deliberate** — needs a few minutes of trying on purpose; it will not happen by itself.
- **Throwaway** — breaks or interrupts a recording; use a test recording, never a real meeting.

## 1. Covered by your meetings: what to notice

- [ ] **Live transcript in the main window.** The recording meeting is the first row of Meetings
  ("● Recording"); opening it shows the words as they are spoken, volatile words grey until final,
  following the newest words until you scroll up ("Jump to Live"). It was blank in the first real
  meeting (2026-10-06); the fix has not been seen in a real meeting since. After the stop: saving
  progress, then Open Review / Open Transcript.
- [ ] **Echo on calls through the laptop speakers.** Live: the far end's words are not shown twice.
  Afterwards in Review: no duplicate Unknown rows, and playback does not sound echoey (the microphone's
  echo is muted). A short echo can flash live for a moment; that is a known limit.
- [ ] **Live corrections.** While recording, select a finished phrase and fix its text or name its
  speaker; after the meeting the fix is in the transcript and the name is on that speaker.
- [ ] **Titles and summaries.** After the meeting, the Meetings row gets a title and a summary that match
  what was discussed; a name you gave the meeting is kept.
- [ ] **Meetings list.** One line per meeting under Today / Yesterday / This Week headers: Name with
  badges, When, Description, and the Open, View, Delete Audio and Copy Path buttons, each acting on its
  own row (View opens the Markdown transcript in your Markdown app; Copy Path pastes as the meeting's
  folder; Delete Audio asks, and "Don't ask again" sticks). A click on the selected meeting's name
  renames it, a double-click opens it; Rename… (⌘R) works; the search field filters by title, summary
  and people. Narrow the window beside a call: When hides and nothing overlaps.
- [ ] **Meeting word fixes.** Terms from the word list fixed in the transcript where they were misheard;
  in Review the fixed words are underlined and the menu on one reverts it. Never run on a real meeting.
- [ ] **Deep transcription (English meetings).** Download the model in Settings › Meetings (about
  1.6 GB) and turn on Deep transcription after meetings: the Meetings row shows the pass queued or
  running, it waits for AC power, and the right-click menu can run it now or cancel it. Note whether the
  result reads better than Apple's transcript.
- [ ] **Screen context** (if Capture screen is on). After the meeting, Review shows timed screen text and
  vocabulary candidates; names visible on screen come out spelled right more often. Both displays when
  two are connected; Voice is Local's own windows are left out.
- [ ] **Review on a real meeting.** Speaker pane, ⌘E word editing, Hide Speakers (⌥⌘S), short
  interjections folded into the speaker's row (View ▸ Show Short Interjections lists them again), joins
  with Backspace (keys typed while a join saves beep), click-to-play with the word highlighted, export.
  The guide: [meeting-validation.md](meeting-validation.md) "Review window", "Voices within one
  meeting", "Playback and following along".
- [ ] **Voices across meetings.** A person named in one meeting is suggested ("Jim (suggested)") in the
  next. [voice-profile-validation.md](voice-profile-validation.md) "H15".
- [ ] **Dictation during a meeting.** The hold-to-talk key still works while recording.
  [meeting-validation.md](meeting-validation.md) "H12".
- [ ] **A long meeting (3 h).** Speakers named in Review in under 10 minutes; nothing lost; memory and
  battery reasonable. [meeting-validation.md](meeting-validation.md) "H20",
  [hardware-validation.md](hardware-validation.md) "H9".
- [ ] **A French or bilingual meeting.** [meeting-validation.md](meeting-validation.md) "Meeting
  languages: French and English in one meeting".

## 2. Deliberate: try on purpose

### Dictation

- [ ] **Targets other than your usual apps** — the matrix in
  [dictation-validation.md](dictation-validation.md) "Manual acceptance matrix": a browser rich editor,
  iTerm2 with tabs and split panes, one of Ghostty/WezTerm/kitty/Alacritty/Warp/Rex, switching tab or pane
  while speaking (typing must stop), a password field (refused), Esc during finalizing, holding past
  three minutes.
- [ ] **History** — [dictation-validation.md](dictation-validation.md) "Main window and history" steps
  4–8: the Fixed / Not inserted badges, Copy only on request, password fields not recorded, retention Off,
  Clear History.
- [ ] **Dictation audio and Run Again** — [dictation-validation.md](dictation-validation.md) "Dictation
  audio and Run Again": Play, Run Again after teaching a correction, turning audio off.
- [ ] **Word list** — [dictation-validation.md](dictation-validation.md) "Word list": terms added in the
  card and in Terminal, the "Often heard as" column, whether the terms are recognized more often.
- [ ] **Apple Intelligence fix** — [dictation-validation.md](dictation-validation.md) "Corrections":
  "The build runs Onobunto" becomes "…on Ubuntu"; ordinary sentences stay as said.

### Main window and Settings

- [ ] **Keys and accessibility** — [dictation-validation.md](dictation-validation.md) "Main window and
  history" steps 1–3 and 9–14: ⌘0, ⌘1–⌘5, ⌘,, ⌘F, Full Keyboard Access, VoiceOver, open at launch,
  closing never quits, the Dock icon, Appearance Light/Dark/System.
- [ ] **Settings search** — choosing a chapter under Settings in the sidebar scrolls to its card; the
  search field (⌘F) shows only matching settings, Return goes to the best match, Escape clears. Smooth
  scrolling, focus moves and VoiceOver are unverified.

### Reading

The whole section is in [dictation-validation.md](dictation-validation.md) "Reading section". Nothing in it
has been run. In order of value:

- [ ] **A link and a PDF** made into audio, played in the app, then shared to an iPhone and played there
  with its chapters (steps 3, 4, 7).
- [ ] **The voice picker** — search ("English premium"), the Language filter, ↑/↓, Return, Escape;
  Settings › Reading has the same picker (step 2).
- [ ] **Natural voices** — Download English in Settings › Reading (about 530 MB), Cancel and resume,
  then a reading with Alba; Preview with a natural voice; listen for garbled paragraphs. Try French
  (about 1.9 GB) with Estelle. Starting a second download while one runs is refused.
- [ ] **Speed** — 0.8× and 1.4× sound slower and faster without sounding broken (the mapping was never
  checked by ear).
- [ ] **Queue, Stop, Resume, quit while rendering** (steps 5, 10).
- [ ] **A book-length reading** (a long PDF): it finishes, and the file plays to the end.

### Setup and permissions

- [ ] **Setup Assistant** as a new user — [dictation-validation.md](dictation-validation.md) "Setup
  Assistant", including dictating with Input Monitoring off.
- [ ] **Meeting permissions** — [meeting-validation.md](meeting-validation.md) "H1", "H16b": which app
  macOS names in each prompt; the System audio setting off and its permission missing.
- [ ] **Speaker models from Settings** — [meeting-validation.md](meeting-validation.md) "H19".

## 3. Throwaway: test recordings only

- [ ] **Failures mid-meeting** — [meeting-validation.md](meeting-validation.md) "H2" (app killed), "H3"
  (recorder killed), "H13" (quitting while recording), "H22" (shutdown during labelling). At most one
  30 s chunk should be lost.
- [ ] **Sleep, lid, devices** — [hardware-validation.md](hardware-validation.md) "H4"–"H7", "H10",
  "H11", "H21": screen locked, lid closed on power and on battery, AirPods in and out, a small disk,
  paused then lid closed, a call on AirPods. [meeting-validation.md](meeting-validation.md) "H1b" for
  display sleep.
- [ ] **Screen capture edge cases** — plug or unplug a display while recording (expected: the display set
  changes only after a pause or restart; hot-plug is not implemented), pause and resume with Capture
  screen on, and deny Screen Recording: audio must keep recording.

## 4. Developer and CLI only (low priority)

- [ ] `voiceislocal read` / `say` output played on an iPhone.
- [ ] `voiceislocal eval cloud` on a real meeting (only a 16 s synthetic clip has been sent).
- [ ] Speaker error against a hand-labelled slice of a recording (today only agreement with Otter is
  measured; [speaker-evaluation.md](speaker-evaluation.md)).
- [ ] Recognition accuracy against human-reviewed reference audio
  ([reference-evaluation.md](reference-evaluation.md)).
