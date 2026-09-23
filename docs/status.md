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
- `session inspect`, `recover`, and `retranscribe` validate/recover archived audio
  and write a new transcript revision to a separately named JSON file. Audio and
  existing archive revisions are retained.
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
state transitions, insertion policy, and dictation lifecycle races; run them with
`./scripts/test.sh`. The opt-in native fixture was exercised separately for both
recognizers. WAV, CAF, and M4A synthesis/export were exercised without audible
playback. These checks do not establish real-device capture, permission ownership,
cross-app insertion, speaker separation, playback quality, or representative
recognition accuracy.

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

Still requiring real-machine or user-data validation:

- Confirm microphone and system-audio permission prompts and ownership under the
  built, ad-hoc-signed CLI identity; smoke-test live capture and playback.
- Validate the menu bar app's permission/setup flow, live microphone dictation,
  hotkey behavior, focus guard, and direct insertion across target applications.
  Neither `--check` nor unit tests exercise those interactions.
- Exercise capture failure/relaunch/recovery on hardware and run multi-hour soak
  tests for memory growth, drift, interruptions, and audio continuity.
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
- Automatic speaker diarization, speaker rename/edit UI, or individual speaker
  attribution. Track labels alone do not separate participants.
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
