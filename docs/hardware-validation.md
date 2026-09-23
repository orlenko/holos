# First live-recording check

These are manual acceptance steps, not checks already performed by the automated
suite. Use a short private test before trusting Holos with a meeting. Recording
other people requires the appropriate notice/consent for your situation.

## Capture both sources

1. Build with `./scripts/build.sh` and use the resulting executable directly:

   ```sh
   BIN_DIR=$(swift build --show-bin-path)
   "$BIN_DIR/holos" doctor
   "$BIN_DIR/holos" record start --name "Capture check" \
     --source mic+system --duration 30 --record-only
   ```

2. Approve the requested microphone/system-audio permissions if desired. Note
   whether macOS attributes each permission to Holos or the launching terminal.
   A declined permission must fail clearly without claiming a successful recording.

3. Speak a short sentence, then play a known audio file in another application,
   such as QuickTime Player. Use headphones initially: remote audio remains in the
   system track without also leaking acoustically into the microphone. Holos does
   not yet implement cross-track echo cancellation or duplicate-speech removal.

4. After automatic stop, inspect the `.holos` path printed by the command:

   ```sh
   "$BIN_DIR/holos" session inspect /path/to/session.holos
   ```

   Expect a clean archive, with CAF files under `audio/mic/` and `audio/system/`
   when those sources supplied audio. Listen to each source separately in a local
   player. Check beginnings/endings, no unexpected gaps, and that the system track
   contains the played audio even while wearing headphones. Silence on a source
   is not evidence that source works.

5. Retry after relaunch and rebuild. Record the actual permission owner and whether
   permission survives. Ad-hoc signing is not proof of stable permission behavior.

## Growing transcript and safe stop

Install assets explicitly with `holos setup --locale en-CA`, then repeat without
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
and actual microphone/system timing measurements remain separate acceptance work.
