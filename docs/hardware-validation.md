# First live-recording check

These are manual acceptance steps, not checks already performed by the automated
suite. Use a short private test before trusting Voice is Local with a meeting. Recording
other people requires the appropriate notice/consent for your situation.

## Capture both sources

1. Build with `./scripts/build.sh` and use the resulting executable directly:

   ```sh
   BIN_DIR=$(swift build --show-bin-path)
   "$BIN_DIR/voiceislocal" doctor
   "$BIN_DIR/voiceislocal" record start --name "Capture check" \
     --source mic+system --duration 30 --record-only
   ```

2. Approve the requested microphone/system-audio permissions if desired. Note
   whether macOS attributes each permission to Voice is Local or the launching terminal.
   A declined permission must fail clearly without claiming a successful recording.

3. Speak a short sentence, then play a known audio file in another application,
   such as QuickTime Player. Use headphones initially: remote audio remains in the
   system track without also leaking acoustically into the microphone. Voice is Local does
   not yet implement cross-track echo cancellation or duplicate-speech removal.

4. After automatic stop, inspect the `.holos` path printed by the command:

   ```sh
   "$BIN_DIR/voiceislocal" session inspect /path/to/session.holos
   ```

   Expect a clean archive, with CAF files under `audio/mic/` and `audio/system/`
   when those sources supplied audio. Listen to each source separately in a local
   player. Check beginnings/endings, no unexpected gaps, and that the system track
   contains the played audio even while wearing headphones. Silence on a source
   is not evidence that source works.

5. Retry after relaunch and rebuild. Record the actual permission owner and whether
   permission survives. Ad-hoc signing is not proof of stable permission behavior.

## Growing transcript and safe stop

Install assets explicitly with `voiceislocal setup --locale en-CA`, then repeat without
`--record-only`. Finalized phrases should appear during the recording with source
labels. These are microphone/system labels, not individual speaker recognition.
Speak several sentences with pauses to allow the model to finalize phrases.

Stop once with Ctrl-C. Confirm audio is saved before final transcription drains,
and inspect the transcript JSON under `transcripts/`. If processing is slow, a
further Ctrl-C exits it; inspect/recover/retranscribe the saved archive afterward.
Also test `record status` and `record stop <session-id>` from another terminal.

Only use a disposable test session for forced termination. Confirm completed
chunks remain readable and `session recover` reports any unrecovered tail rather
than silently losing it. A multi-hour soak, sleep/device changes, disk exhaustion,
and actual microphone/system timing measurements remain separate acceptance work;
the checklist below covers them.

## Long recordings

These are the hardware checks of [meeting-design.md §7.2](meeting-design.md) for the
long-recording work (PR2a: recorder loop, Int16 and mono system audio, capture pump,
restarts and the `waiting` phase, disk policy, `status.json`, `control/`, the stop path;
PR2b: sleep and power, device changes, the stall watchdog, microphone selection). The
automated suite covers the same rules with fakes; only a real Mac shows what macOS does.
Record the date, macOS build, Mac model, and the outcome of each item here.

Tools used below, all from a second terminal while `voiceislocal record start` runs:

```sh
BIN_DIR=$(swift build --show-bin-path)
"$BIN_DIR/voiceislocal" record status            # phase=… elapsed=… for the live session
"$BIN_DIR/voiceislocal" record status --json
S=/path/to/<SESSION-UUID>.holos
cat "$S/status.json"                      # phase, warnings, tracks, backlogSeconds, freeBytes
grep -o '"kind":"[A-Za-z]*"' "$S/events.jsonl" | sort | uniq -c
ps -o rss= -p <recorder pid>              # the pid is in status.json
```

`status.json` is rewritten every second (`sequence` grows) until it says `exited`, and
then keeps the outcome (`exit.reason`, `exit.archiveStatus`, `exit.postprocessing`).

### Control from another process (PR2a)

1. Start `voiceislocal record start --name "Control check" --source mic --record-only`.
2. `voiceislocal record pause <id>` prints `Paused Control check.`; the microphone indicator
   goes off; `record status` shows `phase=paused`, and `elapsed` keeps counting.
3. `voiceislocal record pause <id>` again prints `Ignored: already paused.` (exit 0).
4. `voiceislocal record marker <id> --label Vote` prints `Marker added at hh:mm:ss.`
5. `voiceislocal record resume <id>`, speak, then `voiceislocal record stop <id>`.
6. Expect two chunks with an `audioDiscontinuity` of reason `paused` between them, and
   `paused`, `resumed`, `marker`, and `controlHandled` events. `control/` is empty after
   exit and `status.json` says `exited`.

Pass: every command answers within 3 s; no request file is left behind.

### H4: screen locked for 10 minutes (S2, PR2)

Record `--source mic` and then `--source mic+system` (audio playing), lock the screen
for 10 minutes, unlock.

Pass: recording continues; or, if system audio stops, `status.json` shows phase
`waiting` with warning `audioUnavailable`, capture comes back by itself (retries back off
to every 30 s; PR2b retries at once on unlock), and the gap is an `audioDiscontinuity`
with reason `audioUnavailable` or `captureRestarted`. Note which happened: it answers
open question Q3.

### H5: lid closed on power for 2 minutes (PR2b)

Pass: capture resumes in the same session; the warning `resumedAfterSleep` is shown;
the gap has reason `sleep` and the Markdown export has a "computer was asleep" line.

### H6: lid closed on battery for 20 minutes (PR2b)

Pass: the recording ends at the sleep point (`exit.reason` `sleepTimeout`, `voiceislocal`
exits 3); after wake the transcript and labels exist.

### H7: AirPods connected and disconnected (PR2b)

In person (`--source mic`): stays on the built-in microphone (listen to the chunks), no
stall over 3 s. In a call (`--source mic+system`): follows the new default input with an
`audioDiscontinuity` of reason `deviceChanged`.

### H8: a real in-person meeting (S2, PR7)

At least 3 people, at least 20 minutes, laptop microphone. Pass: audio intelligible;
speaker count within ±1 of the people who spoke.

### H9: 3-hour soak (PR2, PR7)

`--source mic+system` with audio playing for 3 hours. Sample the recorder's RSS every
hour.

Pass: RSS grows less than 100 MB per hour; about 0.69 GB per hour written
(`bytesWritten`; each chunk is 16-bit, and a 30 s mono chunk is about 2.9 MB); the
system chunks are one channel and sound like a proper mono mix (Q5); no
`audioDiscontinuity` without a reason you caused; `backlogSeconds` stays near 0; the
labelled transcript exists within 5 minutes of stop; diarization peak RSS under 4 GB.

### H10: small disk (PR2)

```sh
hdiutil create -size 2g -fs APFS -volname HolosSmall /tmp/holos-small.dmg
hdiutil attach /tmp/holos-small.dmg
HOLOS_DATA_DIR=/Volumes/HolosSmall/Sessions "$BIN_DIR/voiceislocal" record start --source mic
```

Pass: start is refused below 4 hours of budget plus 2 GB, or warns below 8 hours; with
space to start (use a larger image, then fill it with `mkfile` while recording), the
warning `diskLow` appears below 2 GB, and the recording stops by itself below 500 MB with
its audio saved (`exit.reason` `diskLow`, exit code 3); speaker labelling is skipped
with the disk message. Detach and delete the image afterwards.

### H11: paused, then lid closed for 20 minutes (PR2b)

Pass: the meeting is still paused after wake; `voiceislocal record resume <id>` continues it in
the same session.

### H21: a call with AirPods (PR2b)

Pass: the microphone track is the headset microphone (listen); room sounds are not on
it.

### Speech timing fixture (opt-in, no microphone)

After `voiceislocal setup --locale en-CA` has installed the configured speech assets:

```sh
HOLOS_SPEECH_FIXTURE=1 ./scripts/test.sh --filter speechFixtureTimesAreAbsolute
```

It renders a phrase with the system voice, feeds it as an epoch an hour into a meeting
and again after a 5 s gap, and checks that word times land within ±0.3 s of where the
speech is. It prints counts and times only. `HOLOS_SPEECH_TEST_LOCALE` picks another
locale.
