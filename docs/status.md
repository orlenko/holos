# Implementation status

The CLI recording/playback milestone and a second, locally built menu bar dictation
milestone are implemented, not the full T01–T14 plan. The package builds with
Swift 6.4 on macOS 27 / Apple Silicon. Native speech inference is local.
Hardware-facing and cross-app acceptance remain pending.

## Available now

- `doctor` reports local framework/model, voice, permission, and speech-asset
  readiness without requesting permissions. `setup` installs Apple's speech or
  dictation assets for `en-CA` by default; `en-US` is also selectable.
- `transcribe` processes a local audio file using Apple's Speech framework. It can
  print finalized timestamped segments, emit JSON, or write JSON to a new file.
- `record start` captures microphone, system audio, or both into a `.holos` session
  archive while displaying finalized transcript phrases. `--record-only` saves
  audio without recognition. `status` and `stop` inspect/request graceful stop;
  Ctrl-C finalizes capture and saves audio before transcription drains.
  `pause`, `resume`, and `marker` control a running recording by session ID.
- `session inspect`, `recover`, and `retranscribe` validate/recover archived audio
  and write a new transcript revision to a separately named JSON file. Audio and
  existing archive revisions are retained.
- Session archives (meeting-recording wave 0): a failed journal append is truncated
  back instead of leaving a partial line; a corrupt journal line is skipped and
  counted, so `inspect` and `recover` still work; `transcripts/current.json` names
  the current transcript revision (older archives fall back to the newest one);
  `recover` takes a per-session processing lease and refuses while another Holos
  process holds it. The value types and storage for meeting recording and speaker
  labels (runs, edit journal, opt-in voice data, locks) exist as internal APIs;
  no command writes speaker data yet.
- Meeting recording (wave 1): recording moved out of the CLI into the `HolosMeeting`
  library, which the menu bar app can also use. Capture, speech recognition, stop
  requests, and progress output are injectable, so the recording lifecycle is tested
  without a microphone. After saving, `record start` takes the session's processing
  lease before it releases the archive and runs post-processing under the lease;
  `--no-postprocess` skips it. Fallback and `session retranscribe` transcription share
  one replay of saved audio, which can start at a given session time and pass
  recognition vocabulary.
- Speaker labelling algorithms (wave 1): the `HolosSpeakers` library holds them as pure
  code with no file access: aligning transcript words to diarization output, building
  speaker turns, applying speaker edits and carrying names over to a new labelling,
  Markdown/text/JSON transcript exports, an Otter transcript parser, and diarization
  scoring (DER and agreement with Otter).
- Long recordings (wave 2): audio is saved as 16-bit chunks (about 0.35 GB/h per
  track; system audio is mono) through a 60 s write buffer, so a slow disk drops and
  marks audio instead of stopping capture; dictation's capture still fails on
  overflow. Capture restarts in a new epoch after a failure or a device change, and a
  recording ends only after 10 minutes without audio. Session time runs from the first
  captured frame on one clock across restarts. `status.json` (a 1 s heartbeat, kept with
  `phase: exited`) and `control/` requests replace `control.json`; `stop.request` is
  still honoured. New `record start` flags: `--session-id`, `--no-live-text`,
  `--others-in-room`, `--expected-speakers`, `--vocabulary-file`. The start check
  refuses or warns on low disk, and a recording stops below 500 MB free. Stopping has
  time limits on capture stop and speech finish, and only audio that live transcription
  missed is transcribed again. Exit code 3 means the audio was saved but the recording
  stopped by itself (`diskLow`, `sleepTimeout`, `pauseTimeout`) or post-processing was
  partial or failed.
- Sleep, devices, and microphones (wave 2): the Mac is kept from idle sleep while
  recording (not while paused). Before a system sleep, capture stops and chunks are
  closed; a wake within 15 minutes with the lid open resumes the same session with the
  gap marked, and a longer sleep ends the recording at the sleep point. A sleep while
  paused stays paused, up to the 6-hour pause limit. A track silent for 3 s is reported
  stalled, and a silent microphone is restarted after 10 s (backing off to 5 minutes).
  In person (`--source mic`) records the built-in microphone, pinned when AirPods
  connect, and refuses to start without it or with the lid closed. A call records the
  system default input, follows a change of it with an "audio restarted" gap, and
  records system audio alone when there is no input device.
- Speaker labels (wave 2): `HolosDiarization` runs FluidAudio 0.17.1's offline
  diarizer (pyannote Community-1 segmentation, WeSpeaker embeddings, VBx clustering),
  fully offline, one track at a time. `setup --speakers` downloads the pinned models
  (about 21 MB, every file checked by SHA-256, load-checked before use; `--force`
  reinstalls), and `doctor` reports them as verified, not installed, or damaged.
  After a recording, and with `session diarize <session>`, each labelled track is
  rendered to 16 kHz (gaps over 60 s shortened to 5 s), diarized, and aligned with
  the transcript words; the run is saved without voice embeddings. A call's microphone
  is "Me" unless `--others-in-room`. Exports are read-only generated files
  (`exports/transcript.{md,json,txt}`); a hand-edited copy is moved aside, never
  overwritten. `session diarize` keeps edited labels unless `--force`, and names carry
  over to a new labelling. Without the models, recordings keep speaker-less exports and
  a hint to install them. The app does not record meetings or label speakers yet.
- Import and evaluation (wave 2): `session import <audio-file>` turns any audio file
  macOS reads into a session (one in-person microphone track), transcribes it, and
  labels its speakers. The session is built in a hidden `.import-<UUID>` folder in
  the sessions folder and appears as a session only once it is complete, so an import
  that fails, is cancelled, or is killed is never taken for a recording; a failed or
  cancelled import removes that folder, and the next import removes one a killed
  import left (only a folder with that exact name and the `.holos-import` marker
  Holos writes into it; nothing else in a `--directory` folder). Labelling runs under the lock the import took, and the session's path
  is printed once labelling ends. The hidden
  `session score --otter <transcript.txt>` compares a session's labels with Otter's
  and prints numbers only (hashed labels with `--json`).
  `scripts/evaluate-references.swift --speakers --calibrate` runs both over the private
  Otter recordings; see the results below.
- `voices list` and `say` provide native voice discovery, playback, and `.m4a`,
  `.wav`, or `.caf` export. Text comes from arguments or UTF-8 stdin.
- `read` renders a local UTF-8 text/Markdown file or stdin as an ordered AAC
  playlist, with resume and optional playback. Markdown is read verbatim.
- `scripts/build-app.sh` builds and ad-hoc signs `build/Holos.app`, an accessory
  menu bar app. Its `en-CA` Speech dictation is disabled on first launch; the user
  explicitly grants permissions, installs speech assets, and enables the chosen
  hold-to-talk shortcut. Right Option is the default choice, with
  Control–Option–Space available instead. It previews speech and finalizes on
  release; Esc cancels even during finalization.
- The app attempts one direct `AXSelectedText` insertion only into a writable,
  non-secure text field whose focus, selection, and nearby text still match the
  key-down snapshot. Unsupported or changed targets retain the result for explicit
  Copy/Discard; it never synthesizes Return or pastes through the clipboard.
  Dictation audio is not saved.

The CLI bundle embeds microphone and speech-recognition permission usage strings.
`scripts/build.sh` ad-hoc signs the built executable to give macOS a stable CLI
identity across launches. This packaging detail is implemented; which process
identity macOS actually assigns each capture permission, and the complete live
permission flow, remain to be confirmed on the target machine.
Use the [manual live-recording checklist](hardware-validation.md) for that check.

For `record`, on-screen source labels identify microphone/system tracks, not
speaker IDs or people. Transcription displays finalized phrases, not a continuously
changing provisional hypothesis. With `--record-only`, no transcript is generated;
this remains a useful audio-only fallback if recognition is unavailable. After
Ctrl-C saves audio, another Ctrl-C can terminate ongoing transcription while
preserving the archive.
Headphones avoid remote speech leaking acoustically into the microphone track;
cross-track echo cancellation and duplicate-speech removal are not implemented.

## Validation completed and pending

`docs/speech-validation.md` records a local fixture run for both native recognizer
backends, plus the scope of that check. The test suites cover software-level
transcription events, archive recovery, synthesis, content processing, hotkey
state transitions, insertion policy, and dictation lifecycle races, plus the
meeting-recording storage foundations (atomic writes, failed and torn appends,
locks and the processing lease, close-on-exec descriptors, the transcript pointer,
speaker storage, and JSON round trips of the shared file formats), the recording
lifecycle with fake capture and speech (audio-only and transcribed recordings, capture
and start failures, stop by duration, `stop.request`, or task cancellation, fallback
replay, vocabulary, and the processing-lease hand-off), the long-recording logic
with fakes (the recorder state machine with restarts, waiting, sleep, dark wake, and
the pause limit; disk policy; control-request order; the status heartbeat; epochs and
frame continuity; the capture write buffer; stop-path time limits; replay of only
what live speech missed; the stall watchdog; microphone selection), speaker labelling
end to end with a fake diarizer on generated audio (rendering and gap compression,
the post-processing stages, protected exports, the disk-space skip, the inherited
lease), speaker-model verification on fake files, `session import` and
`session score`, and the speaker algorithms (alignment, edit projection, carry-over,
exporters, scoring) on synthetic data; run them with
`./scripts/test.sh`, which keeps `HOLOS_DATA_DIR` and `HOLOS_SUPPORT_DIR` in a
temporary folder. The opt-in native fixture was exercised separately for both
recognizers. WAV, CAF, and M4A synthesis/export were exercised without audible
playback. These checks do not establish real-device capture, permission ownership,
cross-app insertion, playback quality, or representative recognition accuracy.

The app's `--check` path reports its bundle identity and read-only permission
status without launching a UI, prompting, recording, installing an event tap,
accessing Accessibility text, or touching the clipboard. It is a packaging check,
not a live dictation test. Use the [manual dictation matrix](dictation-validation.md)
before relying on it.

Both recognizers have now processed the five private Wispr clips and the shortest
Otter recording locally. This is a comparison against product-exported text, not
human-verified accuracy: the Wispr exports may incorporate subsequent corrections.
Speech remains the default. Dictation omitted substantially more reference words
on the Otter sample and remains experimental for meeting transcription. An
aggregate-only probe found the sparse output already in the native Dictation final
results, rather than lost by the collector; why the native backends differed on
that recording remains undetermined.
See the [reference comparison](reference-evaluation.md) for scoring rules and results.

Speaker labels were run end to end (`session import`, `session diarize`,
`session score`) on the three private Otter recordings (7, 20, and 89 minutes).
Holos disagreed with Otter's speaker on 1.4–5.1 % of the time where both have a
speaker. Holos had 2, 7, and 6 speakers with at least 30 s of speech; Otter had 2,
7, and 8 labels with at least 30 s of turns (counts, not matched people). Holos
labelled the 89-minute recording in about 17 s at about 780 MB peak RSS (about
1.05 GB peak memory footprint). This is agreement
with Otter, not accuracy. Keeping overlapping speech (`exclusiveSegments` false) did
not raise disagreement, and a speaker-count hint did not recover merged speakers.
See the [speaker evaluation](speaker-evaluation.md).

Still requiring real-machine or user-data validation:

- Confirm microphone and system-audio permission prompts and ownership under the
  built, ad-hoc-signed CLI identity; smoke-test live capture and playback.
- Validate the menu bar app's permission/setup flow, live microphone dictation,
  hotkey behavior, focus guard, and direct insertion across target applications.
  Neither `--check` nor unit tests exercise those interactions.
- Exercise capture failure/relaunch/recovery on hardware and run multi-hour soak
  tests for memory growth, drift, interruptions, and audio continuity. The
  lid-close, sleep, screen-lock, AirPods, small-disk, and 3 h checks for long
  recordings are listed in the [live-recording checklist](hardware-validation.md)
  ("Long recordings") and have not been run.
- Label speakers on a real in-person meeting and a real 3 h call; hand-label a slice
  of a recording to measure speaker error rather than agreement with Otter.
- Measure recognition accuracy against private, human-reviewed reference audio.
  No general accuracy claim is established by the small fixture.
- Audition native voices against the user's preferred baseline and validate export
  behavior on the target machine.

## Limits and work not yet implemented

- Broad target-app insertion support is not established: direct Accessibility
  selected-text replacement depends on each app's writable text-field support.
  The app is neither auto-installed nor a login item. Right Option is reserved
  while the user enables that shortcut; unrelated typing cancels dictation and
  may be consumed until the key is released. Copy overwrites the clipboard only
  when explicitly chosen from the menu.
- Correction memory, correction management, or Foundation Models-assisted
  correction. No correction or speaker database workflow is present.
- Speaker names and edits: labels are "Speaker N" until they can be renamed, merged,
  or reassigned (`holos speakers …` and the review window are later waves), and voices
  are not remembered across meetings. Speaker counts are approximate: quieter or
  briefer speakers can merge into others. The menu bar app has no meeting controls
  yet.
- URL/article extraction, PDF text extraction, and OCR. `read` supports local
  UTF-8 text/Markdown and stdin only.
- Broader install/update/uninstall packaging and the T14 acceptance run.

`reference-data/` is for private, user-provided evaluation material and is excluded
by `.gitignore`. Raw recognizer outputs and comparison reports stay under ignored
`.local/evaluation/`. Human-reviewed accuracy and correction evaluation still need
a reviewed, held-out set; the exported product text is not assumed to be ground truth.

For the planned task definitions and acceptance criteria, see
[implementation.md](implementation.md); this status page records milestone evidence
and gaps and does not mark every planned task complete.
