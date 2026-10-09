# Voice is Local

Voice is Local is a local speech toolkit for Apple Silicon Macs, written in Swift. It has
a command-line interface for on-device transcription, meeting recording with
speaker labels, archive recovery, and native speech playback/export, plus a
locally built menu bar app for push-to-talk dictation and meeting recording.
Implemented inference runs locally with Apple's frameworks and, for speaker labels,
FluidAudio's Core ML models; a cloud inference backend is not implemented.

The repository is still called `holos`, Ukrainian for "voice": a reminder to add
Ukrainian once Apple's on-device speech supports it. Code modules keep the `Holos` prefix.

The software was built on macOS 27 with Apple Silicon and Swift 6.4. Live
microphone/system-audio capture, app permissions, cross-app insertion, and audible
playback still need manual validation on the target machine. See
[current status](docs/status.md) for the evidence and remaining gaps.

## Build

Requires macOS 27 and Swift 6.4. The build script builds the package and ad-hoc
signs the CLI executable with the embedded permission usage descriptions:

```sh
./scripts/build.sh
BIN_DIR=$(swift build --show-bin-path)
"$BIN_DIR/voiceislocal" --help
```

Run the test suite with `./scripts/test.sh`. Unless you set them yourself, it points
`HOLOS_DATA_DIR` (sessions) and `HOLOS_SUPPORT_DIR` (Application Support files) at a
temporary folder and removes it afterwards, so tests never touch your real data. Do
not use `swift run` for capture permission checks; the identity that owns macOS
permissions still needs validation.

To build the ad-hoc-signed accessory menu bar app locally, then launch it yourself:

```sh
./scripts/build-app.sh
open build/VoiceIsLocal.app
```

The build does not install or launch the app, add a login item, or enable dictation.

To build a signed, notarized DMG for download, run `./scripts/release-app.sh`; see [releasing](docs/release.md) for
the one-time Apple Developer setup. Without a Developer ID it makes an ad-hoc signed dry run in `build/release`.

To update the running app in one step, run `./scripts/restart-app.sh`. It compiles first while the app keeps
running, asks Voice is Local to quit (the first time, macOS asks whether your terminal may control it), rebuilds
the bundle, and opens it again. It never force-quits: while the app asks what to do with a meeting in progress or
finishes saving one, it waits (Ctrl-C stops waiting), and it refuses while a meeting recorder is still labelling
speakers. It quits the app running from any copy, since only one can run at a time.
Quit Voice is Local before running `build-app.sh` directly; the script refuses to replace a running copy, because
that invalidates its code signature (macOS re-prompts for permissions, and dictation
into a terminal has frozen the terminal). It also refuses while a meeting recorder or
its speaker labelling runs from the bundle. A running app that detects this pauses
dictation and asks to be reopened.

The app used to be built as `build/Holos.app` with a `holos` command. `build-app.sh`
refuses while that old copy runs, and `restart-app.sh` quits it first. The new build
keeps the same bundle ID, settings, sessions, corrections, and people, so they carry
over. Because the app's path changed, macOS may ask for its permissions again. Once
`build/VoiceIsLocal.app` works, delete `build/Holos.app`.
On first launch, dictation is disabled and the Setup Assistant opens (run it again
with **Run Setup Assistant…** in Settings, or click **Skip — Show All Settings** to go
straight to Settings in the main window). It goes one page at a time: pick the dictation
language (by default the supported language closest to your macOS preferred languages
and region, English (Canada) when none of them is supported; any language Apple's speech
transcriber supports, such as French (Canada)) and allow the Microphone; Apple's speech
model for that language, and the speaker models when meetings are set up, then download
in the background. Next it walks you through Accessibility in System Settings, which
takes effect at once. Screen & System Audio Recording, which takes effect only after
the app reopens, comes last: switch it on, choose **Later** when macOS offers to Quit &
Reopen, and the assistant's **Reopen Voice is Local** reopens the app once at the end
and shows what is set up. Dictation turns on as soon as the microphone, Accessibility
and the speech model allow it. Input Monitoring is not asked for: the hold-to-talk
key's event tap runs on Accessibility (still to be confirmed on a real Mac; see the
validation guide). Only if macOS refuses the tap anyway do Settings (and the
assistant) show an Input Monitoring row. An install that was already set up never sees
the assistant; later launches open the main window on Settings (**Settings…** ⌘, in the
menu) while dictation is off, and otherwise on the section it last showed (Meetings
while a meeting records) unless Settings › General › **Open the Voice is Local window
when it starts** is off. The default hold-to-talk choice
is Right Option; Control–Option–Space is available as an alternate. The menu bar
app shows a live preview, and releasing the shortcut finalizes one utterance.
See the [dictation validation guide](docs/dictation-validation.md) before relying
on insertion into other apps.

The app also records meetings from the menu bar: **Start Meeting Recording…**, then
Pause, Add Marker, Show Live Transcript, and **Stop and Save…**. Every meeting records
the system default microphone and everything the Mac plays (the other side of a call, a
video), and labels speakers on both. There is no meeting type to choose. The System
audio row in Settings › Permissions grants the permission for the computer's audio;
without it a meeting records the microphone only and the menu says so. Settings ›
Meetings has "Record the computer's audio (system sound) in meetings" (on by default);
turned off, meetings record the microphone only. The recorder is the
bundled `voiceislocal` tool (`VoiceIsLocal.app/Contents/MacOS/voiceislocal`, which `build-app.sh` now
builds and signs) running as a child of the app: it keeps recording if the app quits
or crashes, and the app finds it again on relaunch, as it does a meeting started from
a terminal. The start panel's Language pop-up (the same languages as dictation) sets
the language the meeting is transcribed in; it starts as the dictation language and
remembers your last choice. When that language's speech model is not installed, the
panel says so and offers Install… (a download from Apple, only when you click it); a
meeting recorded without it saves its audio but no transcript. **Also detect** adds up
to two more languages for a meeting that mixes them (French and English in Montreal,
say): the live transcript stays in the first language; once the meeting is saved, Voice
is Local transcribes the audio again in each language and keeps, every few seconds, the
language that fits, before it labels the speakers (about 3 more minutes for a 3-hour
meeting in two languages). Their speech models are checked and offered for
Install… the same way; a language whose model is missing is left out and the finished
message says so. Dictation keeps its one language. The recorder's log is
`~/Library/Logs/Holos/recorder-<id>.log`;
`defaults write ca.orlenko.holos.app meetingRecorderMode inProcess` records inside
the app instead. Dictation remains available while a meeting records. If a permission prompt
is open when you choose Stop Recording, the recorder stops once the prompt is
answered. **Meetings** (⌘3 in the main window) lists recordings and can recover them,
label their speakers, open or save the transcript, delete the audio or the whole meeting,
and clean up leftover renders. Settings › Meetings has a "Speaker labels" row that
installs the speaker models (about 21 MB). Voice is Local relabels a meeting automatically
when its labelling was interrupted (at most twice per meeting, within 7 days). **People**
(⌘4) lists the people you have named and their remembered voices (below). When the Mac's speakers play a call,
labelling drops the microphone's echo of it (below); nothing warns about it.

Screen capture during meetings is optional and off by default. Turn on **Capture the
screen during meetings (slides, shared screens) to improve transcripts** in Settings ›
Meetings; the start panel's **Capture screen** box begins checked then and can be
unchecked for one meeting. Every display connected when the capture starts is captured,
without Voice is Local's own windows; one unplugged stops being captured. The displays
are chosen again whenever the capture restarts during the meeting (after a pause,
sleep, or an audio device change), so a display plugged in mid-meeting is captured
from then on, or from the next meeting. Notifications and anything else on the displays are included. Everything
stays on this Mac. Screen & System Audio Recording permission must already be granted;
without it the box is dimmed, and a capture failure never stops the audio.
`voiceislocal record start --screen display` does the same from the command line
(`--screen main` captures the main display only, chosen again when the capture restarts). Changed snapshots (a change counts
once it holds still, so a moving video is skipped) are saved locally at up to one sample
every two seconds per display, at most 2560 pixels wide. The displays share the storage
limits (1000 snapshots, 256 MiB); near them the busiest display stops first, so a
quieter one with slides keeps going. OCR runs on this Mac after recording stops; no
language-model correction runs during recording. Recorder/recovery OCR batches are
limited to eight frames and five seconds of waiting; unfinished frames stay saved.
**Screen Text…** in Review shows timestamped OCR (and which display, when there were
several) and unverified word-list candidates, and **Recognize Next Batch** continues unfinished OCR.
They are never added automatically. Nearby OCR can support an existing word-list
question, but is not proof that a term was spoken. Delete Audio removes both snapshots
and their OCR. A thumbnail timeline is not implemented yet.

**Review…** in Meetings (or double-clicking a labelled meeting, or the
**Name Speakers — <name>…** line the menu shows after a meeting) opens the review window:
speakers on the left (a name field that suggests known people, talk time, the start of
their longest turns, Play samples, This is me, Merge into…, and "Maybe Maria" suggestions to
confirm or reject, or Confirm All at once), turns on the right (a time button that plays
from there, a speaker pop-up that lists a voice match first as "Jim (suggested)", and the
text). Space plays and pauses, 1–9 give the selected turns to that speaker, ⌘' jumps to
the next uncertain turn, and ⌘Z undoes the window's changes one at a time; Split Turn,
search (⌘F), Find More Speakers (a relabel that asks for one more speaker and keeps the
names), and Export (Save As… Markdown, text, or JSON; Copy as Markdown) complete it.
Changes save as you make them and the transcript files follow a moment later; a change made from an outdated view (another window or a command)
is refused and the window shows the current labels. The footer box "Learn voices of people
I name in this meeting" decides whether naming a person also learns their voice; it starts
checked while Remember voices is on (on for new installs). Delete
Meeting can also forget the voice samples learned from that meeting. See the
[meeting validation guide](docs/meeting-validation.md) for the manual checks.

## The main window

**Open Voice is Local** (⌘0) in the menu bar menu opens one window with a sidebar:

| Section | Key | What it does |
| --- | --- | --- |
| History | ⌘1 | Dictations kept on this Mac, grouped by day, with search (⌘F). The selected one shows its text, the text as heard before fixes (changed words marked), where it went, its language, what was fixed, and its length. Copy (⌘C; for a partly written dictation, only the part that was not written, as Copy Result had it), Copy As Heard (⇧⌘C), Correct… (⌘E), Delete (⌫, asks first); its audio plays (▶, Space in the list) and Run Again (⌘R) recognizes it again with today's settings and compares; Clear History… in the footer. |
| Corrections | ⌘2 | Fix a dictation and learn the word swaps, and edit the learned list (was the Corrections window). **Correct Last Dictation…** in the menu opens it with the last dictation, History's Correct… with the chosen one. Below, the **Word list** (see below). |
| Meetings | ⌘3 | The saved meetings (was the Meetings window). Return opens Review, ⌫ is Delete Meeting…. |
| People | ⌘4 | People you have named and their voice samples (was the People window). |
| Reading | ⌘5 | Articles and documents made into one audio file each (see below). |
| Settings | ⌘, | General (open the window when the app starts; Appearance: System, Light, or Dark), Permissions, Dictation (on/off, shortcut, language, speech model, fillers, spoken paths and commands as code, Apple Intelligence fix, preview), Meetings (system audio, speaker labels), Reading (default voice, speed, output folder), Dictation history (how long, Clear History…, keep the audio and its disk use), and **Run Setup Assistant…** (was the Setup window). |

A card at the bottom of the sidebar shows the dictation status ("Dictation ready", or
"Dictation ready"). The window remembers its size and place;
↑↓ move in lists, Return opens, Tab reaches the sidebar, list and detail, and every
control is a standard one, so Full Keyboard Access and VoiceOver work. The Setup
Assistant, the meeting start panel, the live transcript, Review (Name Speakers), and the
dictation preview stay separate windows.

Closing the window never quits: Voice is Local stays in the menu bar, and dictation,
meeting recordings, and readings keep going; only **Quit** in its menu, or ⌘Q, quits.
While the window is open the app shows in the Dock and ⌘-Tab, and a click on its Dock
icon brings the window back. Settings › General › **Appearance** keeps every Voice is
Local window, the dictation preview included, light or dark whatever macOS uses, or
follows macOS (System, the default).

The menu bar menu is short: the status line, the dictation toggle, Copy Result / Copy
Original / Discard Result while a result is kept, Correct Last Dictation…, the meeting
lines, then Open Voice is Local, History, Meetings, Settings…, About, and Quit. The
dictation language and shortcut are chosen in Settings.

### Reading

**Reading** (⌘5) turns a web article or a document into one `.m4a` you can play here or
send to your phone, the same file `voiceislocal read` makes (AAC, mono, about 14 MB per
hour, title and author tags, a chapter at each heading). Paste an `https://` link into the
**New reading** field (⌘V also works with the list focused), or drop a PDF, Word, HTML,
Markdown, RTF, OpenDocument or text file anywhere on the section, or use **Choose File…**
(several files at once are all added). Pick a voice (Automatic is the best installed voice
for the text's language; Premium voices are marked), hear it with **▶ Preview** (press again
to stop), set **Speed** (0.8×–1.4×), and press **Make Audio** (Return).

Readings are made one at a time, in this process; the list shows each one's title and
source, then "Rendering part N of M" with a progress bar and **Stop**, or, once made, its
length, chapters, size and voice with **▶ Play** (Space; shows the position), **Share…**
(⇧⌘S: AirDrop, Messages, Mail…), **Show in Finder**, and **Delete…** (⌫, asks first; the
file goes to the Trash). A stopped or failed reading keeps what it rendered and offers
**Resume** or **Try Again**. The list survives relaunching (an index in Application
Support/Holos/ReadingLibrary); a file moved or deleted in Finder shows as such. Quitting
while a reading is made asks: **Keep Rendering** quits and continues it at the next launch,
**Stop** stops it (Resume later).

Files go to `~/Music/Voice is Local/Readings/<Title>.m4a` ("Title 2.m4a" when the name is
taken), a folder Settings › Reading can change, along with the default voice and speed.
It is not in Documents because iCloud Drive's "Desktop & Documents Folders" would upload
it; nothing is uploaded, and the only network access is fetching the page you paste. The
render cache stays in Application Support/Holos/Readings, as for `voiceislocal read`.

**History** keeps each finished dictation that produced text: the text as written (or as
offered for Copy), the text as heard, the app it was for, the language, what happened to
it, what was fixed, and its length. It lives only in
`~/Library/Application Support/Holos/History/dictations.jsonl` (readable only by you), for
30 days unless Settings › Dictation history says 7 days, Forever, or Off (Off stops
recording and offers to clear what is kept). Nothing is sent anywhere or logged, a
dictation refused in a password field is never recorded, and nothing reaches the clipboard
unless you choose Copy. `voiceislocal history list [--json] [--limit N]` and
`voiceislocal history clear --yes` do the same from Terminal.

History also keeps each dictation's **audio** (AAC, about 4 KB a second, in
`History/audio/<id>.m4a`, readable only by you) unless Settings › Dictation history ›
**Keep the audio of dictations (for Run Again)** is off; Settings shows the space it takes,
and it is deleted with its dictation (Delete, Clear History, and the 7- or 30-day sweep).
In History, ▶ (or Space in the list) plays it, and **Run Again** (⌘R) recognizes it again
with today's language, word list, corrections, filler removal, and Apple Intelligence fix, then shows
the text as heard and as written, then and now, with the changed words marked and which
step changed what. Nothing is typed or copied; **Copy New Result** copies it on request and
**Update History…** keeps it as the dictation's text. From Terminal,
`voiceislocal history rerun <id|latest> [--json] [--no-ai-fix] [--language en-US]` prints
the same comparison, and `voiceislocal history rerun --all [--since 7d] --json` reports,
for every dictation with audio, whether its text changes and which step changed it, to try a
new correction or the fix on your real dictations.

### Word list

Words the recognizer should expect: names, products, jargon. A correction needs a misheard
side; the word list does not: add "Keycloak" or "Urban Sky" as you write it, and dictation
and new meetings tell the recognizer to expect it. The Corrections section's **Word list**
card adds (Return; a paste of several lines adds one term per line), removes (Remove or ⌫),
searches and counts; from Terminal:

```sh
voiceislocal words add "Urban Sky" Keycloak   # quote a term of several words
voiceislocal words add Claude --heard-as cloud,clot,clod   # real words it is often heard as
voiceislocal words heard-as Claude --add clawed --remove clod
voiceislocal words heard-as                  # every term's often-heard-as words
voiceislocal words list
voiceislocal words remove Keycloak
voiceislocal words import terms.txt          # one term per line; - reads standard input
```

A term keeps its case; one that differs only in case from a listed term is the same term.
The list is `Application Support/Holos/words.json`; the app picks up a change from Terminal at
the next dictation. The recognizer gets the word list first, then the words of learned
corrections (and for a meeting, people's names after the list), 100 strings at most. Apple
Intelligence's fix counts the terms' words as real words, so a non-word said like one may
become it ("keycloack" → "keycloak"); it still never joins or splits words or changes a name,
which is what a correction is for. A meeting keeps the vocabulary it was recorded with
(`vocabulary.json`); `voiceislocal session recover --force --current-vocabulary` transcribes
its missed audio again with today's list instead.

Some terms come out as real words: "Claude" as "cloud", "clot" or "clod". A correction
would be wrong there, since "cloud" is often meant. List those words as the term's **often
heard as** words (`--heard-as`, or double-click the card's "Often heard as" column). With
"Fix misheard words with Apple Intelligence" on, dictation's fix and a meeting's word fixes
(below) may replace such a word by the term where the context says it was meant ("I asked
cloud to refactor the parser"), and only there; nothing replaces it on its own.

### Meeting word fixes

After a recording, before speakers are labelled, a meeting's transcript gets your learned
corrections (applied as dictation applies them: whole words and phrases, any case, a
sentence's capital carried over), then Apple's on-device model is asked, for each place
where a term's often-heard-as word was written, whether the term was meant there (the
passage around it and the meeting's title; one short question per place, and only the
term itself replaces that place). A replaced phrase takes the time of the words it
replaced. The result is a new version of the transcript; the one before is kept, and the
review marks each fixed word with a dotted underline whose tooltip says what was heard.
Running it again after you add corrections or terms fixes the meeting again from the
transcript before any fix:

```sh
voiceislocal session fix-words <session>          # today's corrections and word list
voiceislocal session fix-words <session> --force  # also when speaker labels were edited
```

It exits 0 when done (also without speaker models), 3 when the words could not be fixed
(edited speaker labels without `--force`, an unreadable list) or speaker labelling was
skipped, and 1 when nothing could be done. Speakers are labelled again on the new text
(names carry over); running it again with the same corrections and terms changes nothing.

### Deep transcription after meetings

Once a meeting is over, nothing waits for its final transcript, so the saved audio can be
transcribed again by a larger model on this Mac: Whisper large-v3 turbo through WhisperKit,
prompted with the meeting's name, your word list and the names of the people you know. On a
real 53-minute call it halved the word error rate of the live transcript (20.9 % to 11–14 %
against a cloud reference; 14.6 % as built) and got about twice as many word-list terms right
(63 of 82 against 31); it takes about 8–11 minutes per hour of audio on an M4 Pro. Nothing leaves the Mac; the model itself is a
one-time download of about 1.6 GB.

It is for English meetings only, for now. On a real 3.7-hour board meeting in French and
English, Whisper did worse than Apple's speech recognition (48.8 % word error rate against
37.3 % for the merge of Apple's French and English transcriptions, and 49.1 % against 46.4 %
in French alone), so a meeting in another language keeps Apple's transcript, and meetings in
several languages are not transcribed again. `--any-language` tries a meeting in another
language anyway, as an experiment:

```sh
voiceislocal setup --whisper                       # download and check the model (resumes if interrupted)
voiceislocal session deep-transcribe <session>     # transcribe a finished meeting again
voiceislocal session deep-transcribe <session> --force   # again, or over edited speaker labels
voiceislocal session deep-transcribe <session> --any-language   # a meeting in another language (experimental)
voiceislocal eval local <session> --backend whisper      # the same, as a candidate for eval compare
```

Passages written over silence where the live transcript has no words ("Thank you." in a
gap) and runs of three or more identical passages are left out. The result is a new
version of the transcript (the one before is kept); live corrections, word fixes, speaker
labels (names carry over) and the transcript files follow as after a recording. It exits 0
when done, 3 when the files were written but the meeting was not transcribed again (edited
speaker labels without `--force`, a failure) or speaker labelling was skipped, and 1 when
nothing could be done (no model, deleted audio, a meeting in another language without
`--any-language`, or one in several languages, which is not supported).

In the app, Settings › Meetings downloads the model and turns on "Deep transcription after
meetings": each saved English meeting is then transcribed again on AC power, one at a time (on
battery it waits for the power adapter); a meeting in another language keeps Apple's
transcript. The Meetings list shows "Final transcript queued" or
"… in progress…"; right-click a meeting for Make Final Transcript Now (which also labels
speakers again; names carry over; for an English meeting only, checked again when it runs) or
Cancel Final Transcript. Meetings saved while the app is closed are queued the next time it
opens.

### Meeting titles and summaries

Apple Intelligence's on-device model writes a short title, a one- or two-sentence summary,
key points and action items for each meeting from its transcript (with speaker names), part
by part, on this Mac. The Meetings list shows the title unless you named the meeting
yourself, with the date, length, people and summary; the Markdown and JSON transcript files
get the summary, key points and action items.

```sh
voiceislocal session summarize <session>           # title and summary of the current transcript
voiceislocal session summarize <session> --force   # again, even when it is up to date
voiceislocal session summarize <session> --json    # with the status and how many model calls it took
```

It exits 0 when the summary was written or is up to date, 3 when it was written but the
transcript files could not be rewritten, and 1 otherwise (Apple Intelligence off or not
supported, no transcript, another command working on the meeting). In the app, Settings ›
Meetings › "Title and summarize meetings with Apple Intelligence" (on by default) summarizes
each meeting in the background once its transcript is final, and again after a final
transcript; right-click a meeting for Summarize Again.

A name you give a meeting is kept: rename it in the Meetings list (right-click › Rename…, ⌘R,
or double-click its title; Return saves, Escape cancels, an empty name or Use Generated Title
gives back the generated title), or from Terminal:

```sh
voiceislocal session rename <session> "Weekly sync"    # your name; no generated title replaces it
voiceislocal session rename <session> --generated      # show the title Apple Intelligence wrote again
voiceislocal session rename <session> "Weekly sync" --json
```

A name is one line of at most 60 characters (a longer one is cut, at a space when it can be).
The transcript files are rewritten so the Markdown heading follows; nothing is summarized again.
It exits 0 when renamed (or the meeting already had that name), 3 when renamed but the
transcript files could not be rewritten (run the same rename again to rewrite them), and 1
otherwise, with nothing changed: the meeting is
recording or being saved, another command or a final transcript or summary of it is working on
it, it was interrupted or not finished properly (recover it first), or its transcript cannot be
read (damaged, from a newer version, or unreadable for now).

## Quick start

```sh
BIN_DIR=$(swift build --show-bin-path)
voiceislocal="$BIN_DIR/voiceislocal"

"$voiceislocal" doctor                         # inspect capabilities, no permission prompt
"$voiceislocal" setup --locale en-CA           # install speech assets; may download assets
# Without --locale, commands use the supported locale closest to your macOS preferred
# languages (en-CA when none is supported); session retranscribe uses the session's own.
# Scripts that need the same locale on every Mac pass --locale.
"$voiceislocal" setup --speakers               # download the speaker models (about 21 MB)
"$voiceislocal" setup --whisper                # download the deep transcription model (about 1.6 GB)
"$voiceislocal" transcribe ./meeting.wav       # local file to finalized timed text
"$voiceislocal" transcribe ./meeting.wav --json

"$voiceislocal" record start --name Planning --source mic+system
# Press Ctrl-C to stop and save, or use `record stop <session-id>` from another shell.
"$voiceislocal" record start --name Board --languages fr-CA,en-CA   # French live; English detected after
"$voiceislocal" record status
"$voiceislocal" record pause <session-id>      # also resume, marker, stop

"$voiceislocal" session import ./meeting.m4a   # an audio file to a transcribed, labelled session
"$voiceislocal" session diarize /path/to/session.holos
"$voiceislocal" session languages <session> --languages fr-CA,en-CA   # mixed French and English
"$voiceislocal" session fix-words <session>    # fix misheard words with today's corrections and terms
"$voiceislocal" session deep-transcribe <session>   # transcribe again with the local Whisper model
"$voiceislocal" session summarize <session>    # title, summary, key points and action items, on this Mac
"$voiceislocal" session rename <session> "Weekly sync"   # your name for it; --generated for the title again
"$voiceislocal" session list                   # sessions, newest first, with state and size
"$voiceislocal" speakers list <session>        # a session's speakers; also rename, merge, assign, ...
"$voiceislocal" speakers rename <session> S2 "Maria"
"$voiceislocal" speakers link <session> S3 new:Jim   # a person whose name carries across meetings
"$voiceislocal" people list                    # people, their voice samples, and Remember voices
"$voiceislocal" session export <session> --format md

"$voiceislocal" say "The build is ready."      # native speech playback
printf '%s\n' "Piped text" | "$voiceislocal" say
"$voiceislocal" say --output greeting.m4a "Hello."
"$voiceislocal" read ./article.md              # one .m4a named after the title, to send to a phone
"$voiceislocal" read ./paper.pdf -o ~/Desktop --voice "Ava (Premium)"
"$voiceislocal" voices list --language en      # installed voices and their quality
```

Recording sources are `mic`, `system`, and `mic+system`. macOS may request
microphone and/or screen/system-audio access when capture starts. Recording is
explicitly started by the user. Use `--record-only` to save audio without running
recognition. While recording, the terminal displays finalized phrases as they
arrive, tagged with their source track (`mic` or `system`); those labels identify
audio tracks, not individual speakers. Ctrl-C stops capture and saves audio before
transcription finishes. A further Ctrl-C during post-recording transcription exits
that processing while keeping the saved archive.

`mic` records the built-in microphone, even when AirPods are the default input, and
refuses to start without it or with the lid closed; `--microphone default` records the
system default input instead. `mic+system` records the system default input (such as a
headset) and system audio, and records system audio alone when there is no input
device. The CLI's defaults are unchanged for scripts; a meeting from the app runs
`record start --source mic+system --others-in-room --microphone default` (or
`--source mic --microphone default` when the computer's audio is off or not allowed). `record pause`, `resume`, `marker [--label TEXT]`, and `stop` control a
running recording by session ID from another shell; a pause stops capture and marks
the gap. Recordings keep going through audio problems: capture restarts after a
failure or a device change, and the recording ends only after 10 minutes without
audio. A sleep shorter than 15 minutes resumes the same session once the lid is
open, with the gap marked; a longer one ends the recording where the Mac went to
sleep, and a paused meeting stays paused through any sleep. The start
check refuses or warns when disk space is low, and a recording stops by itself
below 500 MB free. `record start` exits 3 when the audio was saved but the recording
stopped by itself (low disk, a long sleep, a 6-hour pause) or speaker labelling
failed or was skipped for a reason other than missing speaker models.

After a recording is saved, Voice is Local labels its speakers (`--no-postprocess` skips
this). With `mic+system` the system audio is split into speakers, and the microphone is
"Me" unless `--others-in-room` is given, which splits it too (meetings from the app always
do; "Me" then comes from your remembered voice, or you name the speakers in review). With
`mic+system`, labelling also drops the microphone's echo of the system audio (a run of 3
or more words that repeats it up to 1 s later; the words are listed in the run's
`droppedWords`, reason `echo`, and appear in no export; with no speech in the system audio
nothing is dropped), and with others in the room a microphone speaker who is at least
60 % echo is hidden. Speaker
labels need the models from
`voiceislocal setup --speakers` (FluidAudio 0.17.1, run offline; `voiceislocal doctor` reports
them as verified, not installed, or damaged). Without them the recording is saved
with speaker-less transcript files and a hint to install them. The results are
read-only generated files in the session's `exports/`: `transcript.md`,
`transcript.txt` (Otter's layout), and `transcript.json`. A hand-edited copy is
moved aside to `exports/edited-<YYYYMMDD-HHMMSS>.<ext>` instead of being
overwritten. `voiceislocal session diarize <session>` labels a finished session again;
it keeps edited speaker labels unless `--force` is given, and names carry over.
It exits 0 when speakers were labelled, 3 when the exports were written but
labelling was skipped or failed, and 1 when nothing was done (including when the
speaker models are not installed, unless a language missed in a meeting in several
languages can now be detected: that runs without them and leaves the speakers
unlabelled). `--keep-transcript` labels the speakers without detecting the meeting's
languages again.
`voiceislocal session import <audio-file>` creates a session from any audio file macOS
reads (its channels mixed into one in-person microphone track), transcribes it,
and labels its speakers; it prints the new session's path once labelling ends. The
session appears in the sessions folder only once the import is complete. It exits 0
when the session was imported (and labelled, or the speaker models are not
installed), 3 when labelling failed, was skipped for another reason, or was
cancelled, and 1 when nothing was imported.

A meeting in several languages: `record start` and `session import` take
`--languages fr-CA,en-CA` (at most 3, each a different language; instead of `--locale`).
The first is transcribed live (or by the import); after the recording, post-processing
transcribes the saved audio again in each language (final results only, which are more
accurate than the live ones), groups the words into 3-second passages, keeps each
passage in the language whose transcription scores higher (the
recognizer's word confidence plus how much its text reads as that language, with a switch
only when two passages in a row agree), makes that the session's transcript, and then
labels the speakers on it. Each language's transcription is kept in the session and
reused. `voiceislocal session languages <session> --languages fr-CA,en-CA` does the same
for a saved or imported session (and relabels its speakers; `--force` when their labels
were edited, names carry over); with one language the transcript becomes that
language's alone. It exits 0 when done (also without speaker models), 3 when a language
could not be transcribed (its speech model is not installed, say: `voiceislocal setup
--locale <language>`) or speaker labelling was skipped, and 1 when nothing could be done.
The Markdown export then lists the languages in its header, the JSON export names each
turn's languages, and the text carries no language marks.

`voiceislocal speakers list <session>` shows a session's speakers (`--turns` adds every
turn); `rename`, `merge`, `assign`, `split`, `exclude`, and `undo` correct them.
`<session>` is the path to a `.holos` folder or a session ID. Each change is
checked against the labels it was worked out on: if they changed meanwhile, the
command refuses and exits 1 (list again and retry). Changes are saved in the
session's edit journal, never in the labels themselves, and rewrite `exports/`.
`voiceislocal session export <session> --format md|json|txt` writes the labelled
transcript to stdout or, with `--output`, to a new file; `--all` rewrites
`exports/`. Markdown and JSON include the meeting's summary, key points and action items
once `session summarize` made them. No export contains voice data.

People and voices: `voiceislocal speakers link <session> <speaker> <person|new:NAME>` links a
speaker to a person (`voiceislocal speakers me` to you), which also names the speaker, so the
name carries across meetings; `voiceislocal speakers reject` says a speaker is not someone in
that meeting. Names never need a voiceprint. Remembering voices is on for new
installs; an existing setting is kept (`voiceislocal people remember on|off|status`, or the People window): with it on,
`link --learn-voice` learns the person's voice from that speaker's clear turns (only do
this for people who agreed; voiceprints are biometric data), and later meetings suggest
them as "Maybe Jim" in `voiceislocal speakers list` and the review window. Suggestions are never
exported, and no name is applied automatically unless you calibrate on your own confirmed
meetings (hidden `voiceislocal people calibrate --apply`). Voice samples stay in
`~/Library/Application Support/Holos/Speakers` (private, not in Time Machine backups);
post-processing never stores voice embeddings. `voiceislocal people list`, `rename`, `merge`,
`forget <person> [--sample ID] | --session <session> | --all` (with `--yes`), and
`export [--output FILE] [--include-voiceprints]` manage them; a person's sample from a
meeting follows later speaker edits in that meeting.

`voiceislocal session list` shows every session, newest first: its state (`interrupted`
when the recorder stopped unexpectedly, `damaged` when its manifest cannot be
read), saved audio, size on disk, and speaker labels; `--interrupted` lists only
the sessions to recover, `--json` prints everything. `voiceislocal record status` uses the
same states. `voiceislocal session delete <session> --yes` moves a session to the Trash
(a damaged one too) and deletes its recorder log; with `--audio-only` it deletes only the audio (for
good), keeping the transcript, speaker labels, and exports. Both refuse while the
session is recording or another Voice is Local command is working on it.

`say` accepts text arguments or UTF-8 stdin and can play speech or save `.m4a`,
`.wav`, or `.caf`. `read` turns a local .txt, .md, .html, .pdf, .rtf, .rtfd, .docx,
.doc, or .odt file, `-` for stdin, or an `https://` web address into one AAC `.m4a`
(mono, about 14 MB per hour) named after the document's title, with a chapter at each
heading. A web page is loaded in an offscreen web view that keeps no cookies or history,
and Mozilla Readability picks out the article: title, byline (the file's author), headings,
paragraphs, and list items (code blocks, tables, figures, and reference sections are
skipped). Pages behind a sign-in or paywall fail; save their text to a file instead. The
file plays on iPhone, Android, Windows, and in browsers; send it with AirDrop, Messages, or
Mail. MP3 is not offered: macOS has no MP3 encoder. Without `--output` the file goes in
Application Support/Holos/Readings/<UUID>/; `--output` takes a `.m4a` path or a directory.
The voice is the best installed one for the text's language (Premium, then Enhanced);
`--voice` takes a name as `say -v '?'` or `voices list` prints it, such as "Ava (Premium)".
If no Premium voice is installed, download one in System Settings › Accessibility › Spoken
Content › System Voice › Manage Voices. `--print-text` prints the title, voice, output file,
chapters, and text that would be read, without rendering or creating anything. Ctrl-C stops a reading (or the page load)
and keeps its rendered parts; it continues with the same command plus `--resume` (a web
page is loaded again, and a page that changed since is refused). While a reading runs, a
hidden `.holos-output-<hash>.lock` beside `--output` reserves the file, so a second reading of
it is refused; a reservation a killed reading left is taken over once that process is gone, and
one made on another computer (or one this user cannot remove) is refused with its path, to be
deleted by hand when no reading of that file is running. OCR is not supported yet.

```sh
"$voiceislocal" read https://en.wikipedia.org/wiki/Speech_synthesis --print-text
"$voiceislocal" read https://en.wikipedia.org/wiki/Speech_synthesis -o ~/Desktop --play
```

Sessions are portable `.holos` directories. Inspect, recover, and retranscribe an
inactive archive without replacing its saved audio or original transcript:

```sh
"$voiceislocal" session inspect /path/to/session.holos
"$voiceislocal" session recover /path/to/session.holos
"$voiceislocal" session retranscribe /path/to/session.holos --output ./revised.json
```

`session recover` finishes a session whose recorder stopped unexpectedly (a crash,
`kill -9`, power loss): it indexes the saved audio, rebuilds the transcript from the
phrases live transcription had already saved, transcribes only the audio those do
not cover, and labels the speakers, all under one lock so no other Voice is Local process can
start in between. It prints what it did, for example `Recovered 212 chunks
(1:46:10). Transcript rebuilt from 1812 saved phrases; transcribed 0:31 of uncovered
audio. Speaker labels: 9 speakers.` `--no-transcribe` keeps only the saved phrases,
`--no-postprocess` skips speaker labels, and `--force` rebuilds a transcript that
was already rebuilt or a session that was not interrupted (a session whose
transcription did not finish otherwise keeps the transcript saved when it stopped).
Running it again changes nothing. It exits 0 when done, 3 when speaker labelling failed or was skipped for a
reason other than missing speaker models, and 1 when recovery or the rebuild failed
or some saved audio could not be recovered. It refuses while another Voice is Local process
is working on the same session. A damaged line in a session's event journal is
skipped, and `inspect`, `recover`, and `session list` say how many were skipped.
Each saved transcript revision is recorded as the current one in
`transcripts/current.json`.

`voiceislocal eval` is a developer tool that compares a session's transcript with a
cloud model's (OpenAI `gpt-transcribe` by default). **`eval cloud` uploads the
meeting's audio to OpenAI: the audio leaves this Mac.** Use it only when everyone
recorded agreed. It shows the minutes, number of requests, and estimated cost, and asks
before sending (`--yes` skips the question; without a terminal it refuses unless given);
the key comes from `OPENAI_API_KEY` and is never saved. Everything else works offline,
and the results stay in the session's `eval/` folder, which the app and the exports never
read:

```sh
export OPENAI_API_KEY=…                          # your key; never saved
"$voiceislocal" eval cloud <session> --vocabulary # asks first; Ctrl-C, then rerun to resume
"$voiceislocal" eval compare <session>            # WER both ways, differing passages by kind
"$voiceislocal" eval review <session>             # opens a page: listen, choose, export decisions.json
"$voiceislocal" eval apply <session> ~/Downloads/decisions.json   # gold transcript + proposals
"$voiceislocal" eval list <session>               # runs; eval delete <session> <run>|--all
```

`--vocabulary` sends what the recognizer gets for a meeting, in its order: your word list,
people's names, then correction words. `eval apply` adds nothing unless given
`--add-corrections` (the heard → meant pairs, to your corrections) or `--add-vocabulary`
(the terms you marked, to your word list); a running Voice is Local picks the additions
up and never saves over them. Where a reviewed passage replaced local real words by a term
of your word list or a marked one (local "cloud", cloud "Claude"), the pair is proposed as
an often-heard-as word of that term instead of a correction, and `--add-vocabulary` adds it
there; a pair with a word that is not a real word stays a correction. See
[Cloud reference](docs/reference-evaluation.md#cloud-reference).

`reference-data/` is reserved for private, user-provided reference recordings and
transcripts. It is gitignored; keep originals out of commits.

## Project notes

- [Working on the code: module map and rules for contributors and agents](AGENTS.md)
- [Future mobile apps (notes, not started)](docs/mobile-apps.md)
- [Implementation status and validation gaps](docs/status.md)
- [Design and feasibility](docs/design.md)
- [Component and data contracts](docs/contracts.md)
- [Implementation tasks and evaluation](docs/implementation.md)
- [Native speech validation](docs/speech-validation.md)
- [Private-reference comparison method and results](docs/reference-evaluation.md)
- [Manual live-recording checks](docs/hardware-validation.md)
- [Menu bar dictation setup and manual validation](docs/dictation-validation.md)
- [Menu bar meeting recording checks](docs/meeting-validation.md) and
  [people and voice profile checks](docs/voice-profile-validation.md)
- [Meeting recording plan](docs/meeting-recording-plan.md) and
  [implementation design](docs/meeting-design.md) (in progress)
- [Speaker labelling evaluation](docs/speaker-evaluation.md) and
  [third-party notices](THIRD_PARTY_NOTICES.md)

## License

Voice is Local is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. It is distributed in the hope that it will be
useful, but without any warranty; see [LICENSE](LICENSE) for the full terms. Copyright © 2026
Vlad Orlenko.

The name and the app icon are not covered by the license: Bjola Software Inc. owns the Voice is
Local trademark and the icon copyright, and builds you make and give to others ship under their own
name and icon. See [TRADEMARKS.md](TRADEMARKS.md) for what Bjola Software Inc. permits. Third-party components keep
their own licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
