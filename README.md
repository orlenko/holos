# Holos

Holos is a local speech toolkit for Apple Silicon Macs, written in Swift. It has
a command-line interface for on-device transcription, foreground audio recording,
archive recovery, and native speech playback/export, plus a locally built menu bar
app for push-to-talk dictation. Implemented inference runs locally with Apple's
frameworks; a cloud inference backend is not implemented.

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

Run the test suite with `./scripts/test.sh`. Do not use `swift run` for capture
permission checks; the identity that owns macOS permissions still needs validation.

To build the ad-hoc-signed accessory menu bar app locally, then launch it yourself:

```sh
./scripts/build-app.sh
open build/Holos.app
```

The build does not install or launch the app, add a login item, or enable dictation.
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
"$holos" transcribe ./meeting.wav       # local file to finalized timed text
"$holos" transcribe ./meeting.wav --json

"$holos" record start --name Planning --source mic+system
# Press Ctrl-C to stop and save, or use `record stop <session-id>` from another shell.
"$holos" record status

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
