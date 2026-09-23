# Implementation and evaluation plan

This is the design and task backlog, not a completion checklist. See
[implementation status](status.md) for the current working milestone and validation
gaps. English first is confirmed; use configurable `en-CA` provisionally
and compare `en-US` if the user's recordings justify it.

## Delivery sequence

1. **Feasibility:** establish transcription behavior, permissions/app identity,
   usable native voices, and the cost/quality of any optional speaker model.
2. **Foundation:** freeze data contracts, durable audio storage, and shared adapters.
3. **Daily dictation:** working hotkey/insertion, explicit corrections, then optional
   learning and constrained language-model assistance.
4. **Meeting reliability:** dual-source recording, recoverable text, playback and
   edits; automatic speaker labels follow the diarization decision and evaluation.
5. **Reading workflow:** short speech can ship early; article playlists build on the
   proven renderer and extraction adapter independently of dictation/meetings.

Start with vertical demonstrations rather than implementing every library in full.
The basic file-to-text and text-to-file paths make later failures much easier to
localize. A native voice audition should happen early even if long-form reading
ships later. Do not advertise Otter replacement before automatic speakers are tested.

## Feasibility gates

Each gate produces a small reproducible probe, machine-readable results, and a short
decision note with OS/toolchain/asset versions. Do not build production abstractions
to conceal an unresolved platform question.

| ID | Question | Deliverable and exit condition |
| --- | --- | --- |
| F1 | Which recognizer works best for English dictation and meetings? | Run SpeechTranscriber and DictationTranscriber over identical files. Measure final text, word timing, finalization, latency, and contextual vocabulary behavior. Confirm asset installation and offline operation. Choose defaults from results. |
| F2 | What process/bundle structure gives reliable macOS permissions? | Minimal signed app and CLI exercise mic, system audio, hotkey down/up, and one AX insertion. Document the actual permission owner and behavior after rebuild/relaunch. Choose standalone recorder vs bundled worker, and XPC/socket control. |
| F3 | Which native voices meet the listening and export requirement? | Enumerate voices, render the same short passage to a file, and play it. Record unsupported export behavior. User auditions preferred candidates against AITTS. Select voice/settings and native format. |
| F4 | Can a local diarizer label the user's meetings acceptably? | Conditional on accepting a downloaded model. Pin candidate library/model revisions, review licenses, run offline on representative meetings, measure speaker errors/overlap and peak RAM. Choose adapter or keep manual labels as an explicit limitation. |
| F5 | How should web articles be extracted in Swift? | Compare a small set of static articles, navigation-heavy pages, code blocks, and failure cases. Validate the DOM/Readability approach and dependency/license requirements. Output clean text with provenance and coverage; settle the adapter before promising arbitrary URL support. |

F1 and F3 need representative input but can begin with small deliberately selected
samples. F4 benefits strongly from the upcoming Otter material. No production
dependency on FluidAudio is implied until the local-model choice is settled.

## Bounded implementation tasks

The task owner reads the design and contracts plus only the relevant task. A task
is a small PR with a demonstrable result. Split it further if it starts spanning
several unrelated external APIs. The coordinator owns shared contract changes.

### T01 — Package and data contracts

- **Depends on:** F1/F2 results sufficient to settle ownership and lifecycle.
- **Owns:** Package.swift, HolosCore, target skeletons, app packaging skeleton.
- **Output:** Codable/Sendable values, IDs/time arithmetic, error taxonomy, workflow
  interfaces, CLI command tree, schema-version fixtures. No fake working features.
- **Accept:** Swift 6 build passes; time/range encoding round-trips; invalid ranges
  fail; help clearly marks unimplemented commands. Freeze public signatures for
  subsequent tasks. Add private-fixture exclusions before accepting user data.

### T02 — Session archive and correction store

- **Depends on:** T01.
- **Owns:** HolosStorage and persistence fixtures.
- **Output:** Session writer, immutable chunks/snapshots, event/edit journals,
  processing checkpoints, recovery, correction SQLite migrations/CRUD.
- **Accept:** Inject interruption during chunk/manifest/journal updates; completed
  audio remains discoverable and readable, truncated records recover predictably,
  stale edits fail, repeated recovery is idempotent. State measured tail-loss bound.

### T03 — Native transcription adapter

- **Depends on:** T01, F1.
- **Owns:** HolosSpeech.
- **Output:** Capabilities/assets, file and streaming adapters, timed results,
  normalized replacement/finalization events, cancellation and draining.
- **Accept:** Recorded input produces one final transcript without duplicated
  hypotheses; timestamps map to input; missing assets and silence are handled;
  cancellation closes consumers. Same file works with networking unavailable after
  assets are installed. Expose the chosen alternate engine only if justified by F1.

### T04 — Audio capture and timeline

- **Depends on:** T01/T02, F2.
- **Owns:** HolosAudio.
- **Output:** Microphone and ScreenCaptureKit adapters, source separation, bounded
  queues, native-format chunks, resampling and mapping to one monotonic timeline.
- **Accept:** Known timed signals on both sources preserve order/alignment; callback
  work stays bounded; artificial analyzer delays do not lose recorded audio. Device
  changes, denied permissions, overflow, and disconnects produce explicit events.

### T05 — File transcription and foreground meeting workflow

- **Depends on:** T02/T03/T04.
- **Owns:** Meeting/file orchestration and record/transcribe CLI handlers.
- **Output:** `transcribe`, `record start/status/stop`, Ctrl-C finalization, disk
  backlog replay, crash recovery, basic transcript export and timed audio playback.
- **Accept:** A multi-hour soak has bounded memory; stop leaves usable audio/text;
  forced termination can resume transcription; no silent omissions at chunk
  boundaries. Recording survives recognizer failure and reports disk exhaustion.

### T06 — Hotkey app shell

- **Depends on:** T01, F2.
- **Owns:** HolosApp packaging, hotkey adapter, state overlay, local control,
  permission/setup presentation, optional login item.
- **Output:** Stable installed app identity with hotkey press/release/cancel,
  non-activating status, focus snapshot, clear ready/disabled/error states.
- **Accept:** Repeated press/release, lost key-up, modifier changes, wake, app
  switching, and permission denial do not leave recording stuck on. UI does not
  steal focus. The app remains controllable without enabling login startup.

### T07 — Text insertion adapters

- **Depends on:** T01/T06.
- **Owns:** App-side AX insertion, paste fallback, receipts.
- **Output:** Insert at current selection with pre-write focus validation,
  clipboard preservation, explicit copy recovery, secure-field handling.
- **Accept:** Manually verify the app matrix; replacement/undo work where supported;
  focus switching never inserts into a newly focused field; no duplicate paste or
  automatic Return; Unicode/rich clipboard contents survive supported fallbacks.

### T08 — End-to-end push-to-talk

- **Depends on:** T03/T04/T06/T07.
- **Owns:** Dictation workflow and its integration tests.
- **Output:** Press -> capture -> preview -> release -> final insertion; bounded
  recent-result retention; deterministic cancellation/fallback.
- **Accept:** Measure warm/cold time to ready and release-to-insert p50/p95 across
  short/long utterances. No clipped beginnings, missing endings, or mixed concurrent
  utterances. Test while a meeting is recording; preserve the meeting on conflicts.

### T09 — Explicit correction memory

- **Depends on:** T02/T08.
- **Owns:** Rule matcher, correction CLI, app's correct-last action.
- **Output:** Reviewable before/after diff, scoped confirmed rules, undo/remove,
  deterministic precedence, retrieval of relevant vocabulary where supported.
- **Accept:** Repeated proper names improve without changing unrelated phrases;
  substring collisions, punctuation/case, inflections, app scope, and overlapping
  rules have meaningful fixtures. Never create a rule from unrelated typing.

### T10 — Local contextual correction and optional edit observation

- **Depends on:** T09 and held-out reference cases.
- **Owns:** Foundation Models adapter and separately opt-in insertion-span observer.
- **Output:** Candidate-or-unchanged structured decision with validation and timeout;
  bounded observation proposes corrections for review. Query availability/context
  budget and explicitly select the local system model.
- **Accept:** Unavailable/refusing model and malformed output preserve the usable
  transcript. No unrelated numeric/name/negation changes on held-out cases; measure
  correction precision, false substitutions, and added latency. Observer does not
  promote ambiguous diffs. Split the model adapter and observer into separate PRs.

### T11 — Speaker editing and optional diarization adapter

- **Depends on:** T02/T05; F4 for automatic labeling.
- **Owns:** HolosSpeakers, speaker/session CLI handlers and alignment.
- **Output:** Manual speaker turns and names first; optional offline diarizer;
  timestamp alignment, overlap/unknown handling, rename/split/merge/reassignment.
- **Accept:** Renaming does not rerun inference; timing survives word/turn splits;
  a new diarization revision does not silently discard human edits; reference
  meetings meet the agreed speaker-attribution bar. No cross-session identity claim.

### T12 — Native speech renderer and short-speech CLI

- **Depends on:** T01, F3.
- **Owns:** HolosSynthesis, voices/say commands.
- **Output:** Voice selection, supported prosody options, playback/file output,
  cancellation, native encoding, per-user playback queue and stale-message timeout.
- **Accept:** Files play to completion; buffer completion is handled once; concurrent
  callers do not overlap playback; canceled output is marked incomplete; unavailable
  voices give a clear error. Compare listening quality with the selected baseline.

### T13 — Documents and playlists

- **Depends on:** T12; F5 before URL extraction.
- **Owns:** HolosContent, reading workflow, read command.
- **Output:** Text/stdin/Markdown adapter first, then URL adapter; semantic chunks,
  source capture, ordered M3U8, manifest, resume, explicit partial-result status.
- **Accept:** Reconstruct source coverage from chunk references; no dropped/repeated
  paragraphs; missing chunks remain visible and resume successfully; playback order
  is deterministic; changed voice/settings invalidate prior rendered parts. PDF/OCR
  is a separate later task, not hidden in this one.

### T14 — Installation and acceptance run

- **Depends on:** The tasks for the chosen first release; not every deferred feature.
- **Owns:** Install/update/uninstall instructions, doctor/setup integration, CI,
  compatibility/status documentation, reproducible acceptance report.
- **Output:** Usable app/CLI installation with stable identities and preserved data;
  no hardcoded developer paths. Local signing for personal use first; public
  distribution/notarization is a separate release decision.
- **Accept:** Fresh setup, asset download, permission denial/recovery, offline use,
  relaunch/update, and one daily workflow in each included tool. Report incomplete
  features plainly. Removing the app must not silently delete recordings.

## Parallel work after interfaces settle

The purpose is future delegation, not a requirement to spawn agents during design.

- After T01, storage, transcription, synthesis, and the app shell have distinct
  ownership. T04 begins once the storage interface is frozen.
- T07 can proceed with fake recognition events while the real speech adapter is
  developed. T05 and T08 integrate their corresponding proven components.
- T09/T10, T11, and T13 form independent feature tracks after their dependencies.
- Reserve OS integration, timebase/concurrency review, correction-policy decisions,
  and final acceptance for the coordinator or a stronger model. Delegate bounded
  adapters, serialization, CLI wiring, and deterministic transformations to simpler
  models once their interfaces and fixtures are settled.

Each assignment must include: exact inputs/outputs; owned paths; dependency versions;
failure/cancellation semantics; the acceptance cases; and explicit exclusions.
Require a short result with changed files, checks performed, and unresolved facts.
A worker must not invent a native API or silently expand a shared contract to finish
its task. Contract changes return to the coordinator for review.

Example assignment: "Implement T12 against SpeechRenderer in HolosSynthesis only.
Use the voice/format selected in F3. Support cancellation and atomic file completion.
Verify export, unavailable voice, and two queued playback calls. Do not fetch URLs,
change document chunking, add a cloud provider, or alter the protocol."

## How to use the Otter/Wispr reference material

Keep originals outside Git and index them with a private manifest: source tool,
locale, audio paths/channels, original transcript, human-corrected target, timestamps
when available, app/task context, and known issues. Do not assume the commercial
tool's transcript is ground truth. Identify a small human-reviewed subset.

Separate development examples from held-out evaluation by meeting/topic/time so a
correction learned from one recording is not credited for "generalizing" to that
same recording. Include names, acronyms, code words, spoken punctuation, hesitations,
negation, numbers, interruptions, long silences, and overlapping speakers. Use actual
target-app edits to distinguish transcription correction from deliberate rewriting.

| Area | Measure | Release interpretation |
| --- | --- | --- |
| Recognition | WER/CER with documented normalization; names/numbers separately | Compare both native engines and the current tool on identical audio; do not hide critical name errors in an average. |
| Dictation | Time to ready, first partial, release-to-insert p50/p95 | Initial proposed target: warm release-to-insert p95 under 1 second for ordinary short utterances; revise against actual hardware/quality, not as an API promise. |
| Corrections | Precision of changes, recall on repeated errors, false replacements | A correction pass must improve held-out text without new protected-token errors in the acceptance set. Track false corrections even when WER improves. |
| Speakers | DER with stated collar/overlap policy, speaker-attributed WER, name/edit stability | Compare offline labels with human-reviewed turns; numeric acceptance threshold comes from the reference set and intended use. |
| Recording | Missing/duplicate samples, drift, RAM trend, crash-tail loss | No unreported capture gaps; completed chunks recover; memory does not grow with meeting length. |
| Synthesis | Listening preference, pauses/pronunciation, source coverage, resume | User selects an acceptable voice; every source block is accounted for; interrupted books resume without omissions. |

Suggested meaningful tests are concentrated on interval replacement, Unicode
offsets, crash recovery, correction scope, focus validation, queue overflow, and
source coverage. Permission prompts, hotkeys, voice quality, and cross-app insertion
also require real-machine checks. Do not substitute a large mock-only suite for
those checks or require an LLM for ordinary unit tests.
