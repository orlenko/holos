# Holos

Holos is a local speech toolkit for Apple Silicon Macs, written in Swift. It has
a command-line interface for on-device transcription, meeting recording with
speaker labels, archive recovery, and native speech playback/export, plus a
locally built menu bar app for push-to-talk dictation. Implemented inference runs
locally with Apple's frameworks and, for speaker labels, FluidAudio's Core ML
models; a cloud inference backend is not implemented.

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
"$BIN_DIR/holos" --help
```

Run the test suite with `./scripts/test.sh`. Unless you set them yourself, it points
`HOLOS_DATA_DIR` (sessions) and `HOLOS_SUPPORT_DIR` (Application Support files) at a
temporary folder and removes it afterwards, so tests never touch your real data. Do
not use `swift run` for capture permission checks; the identity that owns macOS
permissions still needs validation.

To build the ad-hoc-signed accessory menu bar app locally, then launch it yourself:

```sh
./scripts/build-app.sh
open build/Holos.app
```

The build does not install or launch the app, add a login item, or enable dictation.
Quit Holos before rebuilding; the script refuses to replace a running copy, because
that invalidates its code signature (macOS re-prompts for permissions, and dictation
into a terminal has frozen the terminal). A running Holos that detects this pauses
dictation and asks to be reopened.
On first launch, dictation is disabled and the Holos Setup window opens (reopen it
with **Setup…** in the menu). It shows live status for each step: explicitly grant
Microphone, Accessibility, and Input Monitoring access, install Apple's `en-CA`
Speech assets, then enable your chosen hold-to-talk shortcut. The default choice
is Right Option; Control–Option–Space is available as an alternate. The menu bar
app shows a live preview, and releasing the shortcut finalizes one utterance.
See the [dictation validation guide](docs/dictation-validation.md) before relying
on insertion into other apps.

## Quick start

```sh
BIN_DIR=$(swift build --show-bin-path)
holos="$BIN_DIR/holos"

"$holos" doctor                         # inspect capabilities, no permission prompt
"$holos" setup --locale en-CA           # install speech assets; may download assets
"$holos" setup --speakers               # download the speaker models (about 21 MB)
"$holos" transcribe ./meeting.wav       # local file to finalized timed text
"$holos" transcribe ./meeting.wav --json

"$holos" record start --name Planning --source mic+system
# Press Ctrl-C to stop and save, or use `record stop <session-id>` from another shell.
"$holos" record status
"$holos" record pause <session-id>      # also resume, marker, stop

"$holos" session import ./meeting.m4a   # an audio file to a transcribed, labelled session
"$holos" session diarize /path/to/session.holos

"$holos" say "The build is ready."       # native speech playback
printf '%s\n' "Piped text" | "$holos" say
"$holos" say --output greeting.m4a "Hello."
"$holos" read ./article.md              # local UTF-8 text/Markdown to AAC playlist
```

Recording sources are `mic`, `system`, and `mic+system`. macOS may request
microphone and/or screen/system-audio access when capture starts. Recording is
explicitly started by the user. Use `--record-only` to save audio without running
recognition. While recording, the terminal displays finalized phrases as they
arrive, tagged with their source track (`mic` or `system`); those labels identify
audio tracks, not individual speakers. Ctrl-C stops capture and saves audio before
transcription finishes. A further Ctrl-C during post-recording transcription exits
that processing while keeping the saved archive.

`mic` is an in-person meeting: it records the built-in microphone, even when
AirPods are the default input, and refuses to start without it or with the lid
closed. `mic+system` is a call: it records the system default input (such as a
headset) and system audio, and records system audio alone when there is no input
device. `record pause`, `resume`, `marker [--label TEXT]`, and `stop` control a
running recording by session ID from another shell; a pause stops capture and marks
the gap. Recordings keep going through audio problems: capture restarts after a
failure or a device change, and the recording ends only after 10 minutes without
audio. A sleep shorter than 15 minutes resumes the same session once the lid is
open, with the gap marked; a longer one ends the recording where the Mac went to
sleep, and a paused meeting stays paused through any sleep. The start
check refuses or warns when disk space is low, and a recording stops by itself
below 500 MB free. `record start` exits 3 when the audio was saved but the recording
stopped by itself (low disk, a long sleep, a 6-hour pause) or speaker labelling was
skipped or failed.

After a recording is saved, Holos labels its speakers (`--no-postprocess` skips
this). In a call the microphone is "Me" unless `--others-in-room` is given; the
system audio is split into speakers. Speaker labels need the models from
`holos setup --speakers` (FluidAudio 0.17.1, run offline; `holos doctor` reports
them as verified, not installed, or damaged). Without them the recording is saved
with speaker-less transcript files and a hint to install them. The results are
read-only generated files in the session's `exports/`: `transcript.md`,
`transcript.txt` (Otter's layout), and `transcript.json`. A hand-edited copy is
moved aside to `exports/edited-<YYYYMMDD-HHMMSS>.<ext>` instead of being
overwritten. `holos session diarize <session>` labels a finished session again;
it keeps edited speaker labels unless `--force` is given, and names carry over.
It exits 0 when speakers were labelled, 3 when the exports were written but
labelling was skipped or failed, and 1 when nothing was done (including when the
speaker models are not installed).
`holos session import <audio-file>` creates a session from any audio file macOS
reads (its channels mixed into one in-person microphone track), transcribes it,
and labels its speakers; it prints the new session's path.

`say` accepts text arguments or UTF-8 stdin and can play speech or save `.m4a`,
`.wav`, or `.caf`. `read` accepts a local UTF-8 text/Markdown file or `-` for stdin;
Markdown is read verbatim. URL extraction and PDF/OCR are not implemented.

Sessions are portable `.holos` directories. Inspect, recover, and retranscribe an
inactive archive without replacing its saved audio or original transcript:

```sh
"$holos" session inspect /path/to/session.holos
"$holos" session recover /path/to/session.holos
"$holos" session retranscribe /path/to/session.holos --output ./revised.json
```

`session recover` refuses while another Holos process is working on the same
session, and a damaged line in a session's event journal is skipped rather than
blocking inspection. Each saved transcript revision is recorded as the current one in
`transcripts/current.json`.

`reference-data/` is reserved for private, user-provided reference recordings and
transcripts. It is gitignored; keep originals out of commits.

## Project notes

- [Implementation status and validation gaps](docs/status.md)
- [Design and feasibility](docs/design.md)
- [Component and data contracts](docs/contracts.md)
- [Implementation tasks and evaluation](docs/implementation.md)
- [Native speech validation](docs/speech-validation.md)
- [Private-reference comparison method and results](docs/reference-evaluation.md)
- [Manual live-recording checks](docs/hardware-validation.md)
- [Menu bar dictation setup and manual validation](docs/dictation-validation.md)
- [Meeting recording plan](docs/meeting-recording-plan.md) and
  [implementation design](docs/meeting-design.md) (in progress)
- [Speaker labelling evaluation](docs/speaker-evaluation.md) and
  [third-party notices](THIRD_PARTY_NOTICES.md)
