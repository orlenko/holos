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
On first launch, dictation is disabled and the Voice is Local Setup window opens (reopen it
with **Setup…** in the menu). It shows live status for each step: explicitly grant
Microphone, Accessibility, and Input Monitoring access, pick the dictation language
(by default the supported language closest to your macOS preferred languages and
region, English (Canada) when none of them is supported; any language Apple's speech
transcriber supports, such as French (Canada)), install Apple's speech model for it, then enable your chosen
hold-to-talk shortcut. The default choice
is Right Option; Control–Option–Space is available as an alternate. The menu bar
app shows a live preview, and releasing the shortcut finalizes one utterance.
See the [dictation validation guide](docs/dictation-validation.md) before relying
on insertion into other apps.

The app also records meetings from the menu bar: **Start Meeting Recording…**, then
Pause, Add Marker, Show Live Transcript, and **Stop and Save…**. Every meeting records
the system default microphone and everything the Mac plays (the other side of a call, a
video), and labels speakers on both. There is no meeting type to choose. Setup's System
audio row grants the permission for the computer's audio; without it a meeting records
the microphone only and the menu says so. Setup's collapsed **Advanced** section has
"Record the computer's audio (system sound) in meetings" (on by default); turned off,
meetings record the microphone only. The recorder is the
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
the app instead. Dictation is paused while a meeting records. If a permission prompt
is open when you choose Stop Recording, the recorder stops once the prompt is
answered. **Meetings…** lists recordings and can recover them, label their speakers,
open or save the transcript, delete the audio or the whole meeting, and clean up
leftover renders. Setup has a "Speaker labels" row that installs the speaker models
(about 21 MB). Voice is Local relabels a meeting automatically when its labelling was
interrupted (at most twice per meeting, within 7 days). **People…** lists the people
you have named and their remembered voices (below). When the Mac's speakers play a call,
labelling drops the microphone's echo of it (below); nothing warns about it.

**Review…** in Meetings (or double-clicking a labelled meeting, or the
**Name Speakers — <name>…** line the menu shows after a meeting) opens the review window:
speakers on the left (a name field that suggests known people, talk time, the start of
their longest turns, Play samples, This is me, Merge into…, and "Maybe Maria" suggestions to
confirm or reject, or Confirm All at once), turns on the right (a time button that plays
from there, a speaker pop-up, and ⚠ for uncertain turns). Space plays and pauses, 1–9 give
the selected turns to that speaker, ⌘' jumps to the next uncertain turn, and ⌘Z undoes the
window's changes one at a time; Split Turn, search (⌘F), Find More Speakers (a relabel that
asks for one more speaker and keeps the names), and Export (Save As… Markdown, text, or
JSON; Copy as Markdown) complete it. Changes save as you make them and the transcript files
follow a moment later; a change made from an outdated view (another window or a command)
is refused and the window shows the current labels. The footer box "Learn voices of people
I name in this meeting" decides whether naming a person also learns their voice. Delete
Meeting can also forget the voice samples learned from that meeting. See the
[meeting validation guide](docs/meeting-validation.md) for the manual checks.

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
"$voiceislocal" session list                   # sessions, newest first, with state and size
"$voiceislocal" speakers list <session>        # a session's speakers; also rename, merge, assign, ...
"$voiceislocal" speakers rename <session> S2 "Maria"
"$voiceislocal" speakers link <session> S3 new:Jim   # a person whose name carries across meetings
"$voiceislocal" people list                    # people, their voice samples, and Remember voices
"$voiceislocal" session export <session> --format md

"$voiceislocal" say "The build is ready."      # native speech playback
printf '%s\n' "Piped text" | "$voiceislocal" say
"$voiceislocal" say --output greeting.m4a "Hello."
"$voiceislocal" read ./article.md              # local UTF-8 text/Markdown to AAC playlist
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
`exports/`. No export contains voice data.

People and voices: `voiceislocal speakers link <session> <speaker> <person|new:NAME>` links a
speaker to a person (`voiceislocal speakers me` to you), which also names the speaker, so the
name carries across meetings; `voiceislocal speakers reject` says a speaker is not someone in
that meeting. Names never need a voiceprint. Remembering voices is opt-in and off by
default (`voiceislocal people remember on|off|status`, or the People window): with it on,
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
`.wav`, or `.caf`. `read` accepts a local UTF-8 text/Markdown file or `-` for stdin;
Markdown is read verbatim. URL extraction and PDF/OCR are not implemented.

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

`reference-data/` is reserved for private, user-provided reference recordings and
transcripts. It is gitignored; keep originals out of commits.

## Project notes

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
