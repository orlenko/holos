# Meeting recording plan: long recordings, speaker diarization, speaker labels

Status: approved plan, not implemented. Produced by a planning agent on 2026-09-23 from the code on
`main` and web research. The user reviewed §8 on 2026-09-23: recommendations 1–5, 7, and 8 accepted;
6 and 9 changed (dictation is paused during meeting recording; built-in laptop mic only).

## 1. Summary

**Disk comes first.** This Mac has 24 GiB free (data volume 95% full). Holos writes Float32 audio
chunks (`Sources/HolosAudio/ChunkWriter.swift:62`), so a 3-hour mic+system recording takes about
6.2 GB. Disk handling is fixed before any speaker work.

**Speaker diarization.** Apple provides nothing for it: the macOS 27 SDK has no speaker,
diarization, or voiceprint API (greps in §9). Use **FluidAudio** (Swift/CoreML, Apache-2.0 code,
SPM product `FluidAudio`, v0.17.1):

- Run its `OfflineDiarizerManager` **after the recording stops**, one pass per track. It uses
  pyannote community-1 segmentation, WeSpeaker 256-d embeddings, and AHC+VBx clustering.
- Its benchmark reports about 10.6% DER on AMI single-mic at about 323× real time on an M5 Pro. For
  a 3-hour council meeting on one laptop mic with 5–10 speakers, expect **about 15–25% strict DER**
  (estimate), worse during cross-talk. That is usable only with a good review screen.
- Keep FluidAudio behind an adapter in its own target, so speaker, alignment, and voiceprint code
  never imports it.

**Recording.** A 3-hour recording runs in a **separate recorder process**: the existing `holos`
CLI, bundled inside Holos.app and started by the menu bar app. A crash in the app (event taps, AX,
typing) cannot end a meeting. The CLI already has chunked `.holos` storage, `stop.request` control,
`control.json`, recovery of unindexed chunks, and a writer lock that detects interrupted sessions.
The recording code moves out of `HolosCLI` into a shared library first.

**Transcript and timing.** Live Apple transcription during the meeting stays as it is. After stop:
diarize each track (about 1–2 minutes for 3 hours if FluidAudio's speed claims hold on this M4 Pro),
align Apple's per-word timings (`TimedWord`) to diarization segments, match clusters against
enrolled voiceprints, and export. Target: a labelled transcript within about 5 minutes of stopping,
provided live transcription kept up. No live speaker labels in v1.

**Speaker names and voiceprints.** Every correction is an edit layered over an unchanged
diarization output. Voiceprints change only through user-confirmed labels, and remembering voices
is off by default. This reverses `docs/design.md` ("No inferred cross-meeting voiceprint database")
and T11 in `docs/implementation.md` ("No cross-session identity claim"); see decision 2.

## 2. Architecture

### Targets (`Package.swift`)

| Target | Status | Contents |
|---|---|---|
| `HolosCore` | changed | Pure value types: `SpeakerTurn`, `SessionSpeaker`, `SpeakerEdit`, `LabelProvenance`, `DiarizationSegment`, `VoiceprintSample`. No new dependency. |
| `HolosSpeakers` | new (the owner `docs/contracts.md` already names) | Depends on `HolosCore` only. Word→segment alignment, turn building, overlap marking, applying edits (`SpeakerProjection`), cosine matching and confidence tiers, exporters (md/json/srt/vtt/Otter-style txt). Unit-testable without CoreML. |
| `HolosDiarization` | new | Depends on `HolosCore` and `FluidAudio`, pinned `exact: "0.17.1"`. One adapter, `FluidDiarizer: SpeakerDiarizer` (protocol sketched in `docs/contracts.md`). Returns per-track segments and cluster centroids, plus per-segment embeddings if the API exposes them (spike S1). Owns model install and checksum verification. |
| `HolosStorage` | changed | Speaker files inside the session, a short-lived processing lock for post-`finish` work, the `derived/` cache, and a global `SpeakerProfileStore`. |
| `HolosAudio` | changed | `TrackRenderer` (joins a track's 30 s CAF chunks into one 16 kHz mono file, gaps filled with silence), device-change restart (today `AudioCapture` has no `AVAudioEngineConfigurationChange` handling), a watchdog for a track that stops delivering frames, Int16 chunk encoding, a power assertion while recording. |
| `HolosMeeting` | new (`docs/contracts.md` calls it "HolosWorkflows") | Moves in `RecordingWorkflow`, `LiveTrack`, `StopController`, and replay from `Sources/HolosCLI/RecordingWorkflow.swift`. Adds `MeetingPostProcessor` (transcribe if needed → diarize → align → recognize → export), a `status.json` writer, and a control-request reader. Depends on HolosAudio, HolosSpeech, HolosStorage, HolosSpeakers, HolosDiarization. |
| `HolosCLI` | changed | Thin layer over HolosMeeting. New: `record pause|resume|marker`, `record start --status-file --no-live-text`, `session diarize`, `session export --format md|json|srt|vtt|txt [--portable]`, `speakers list|rename|merge|assign|split`, `people list|rename|forget|export` (not "voices": `voices list` is the TTS command). |
| `HolosApp` | changed | `MeetingController` starts or reattaches to the recorder child, reads `status.json`, writes control requests. New AppKit windows: Meetings (session list), Transcript Review, People (voice profiles). |

### Data model (new value types in HolosCore)

- **DiarizationRun** (immutable): id; engine name and version; models (id, revision, sha256);
  config; createdAt. Per track, `segments: [DiarizationSegment(track, clusterID, start, end,
  overlapCount)]` and `clusters: [ClusterSummary(clusterID, track, speechSeconds, centroid)]`.
  Cluster IDs are session-local, e.g. `system:S2`.
- **SpeakerTurn**: id, track, start, end, clusterID?; words stored as a segment ID plus a word-index
  range into the existing Transcript (`TranscriptSegment`/`TimedWord` in
  `Sources/HolosCore/Models.swift`), so text and timing are never copied; `overlap`,
  `otherClusters`; `assignmentScore` (share of the turn's word time covered by the chosen cluster).
- **SessionSpeaker**: speakerID, displayName?, profileID?, provenance, confidence?. Provenance is one
  of `diarizer`, `channelAssumption` (mic track is "Me"), `recognized(distance, tier)`,
  `userConfirmed`, `userRenamed`.
- **SpeakerEdit** (append-only journal): id, baseRunID, at, expected (prior value; a mismatch marks
  the edit stale). Actions: `rename`, `linkProfile`, `rejectProfile` ("not Jim", this session only),
  `merge(from, into)`, `reassignTurn`, `reassignRange(track, start, end, to)`,
  `splitTurn(turnID, atWord)`, `newSpeakerFromTurns`, `excludeFromEnrollment`. Matches the
  `TranscriptEdit` contract in `docs/contracts.md`.
- **SpeakerProfile** (global): id, displayName, createdAt, `embeddingModel` (id and revision;
  comparing across models is refused), `samples: [VoiceprintSample(sessionID, speakerID,
  speechSeconds, embedding, condition room|call, addedAt)]`, derived centroid, `recognitionEnabled`.

### Session folder layout

Extends `SessionArchive.create` (`Sources/HolosStorage/SessionArchive.swift:99`):

```
<id>.holos/
  manifest.json              schema v1 unchanged (readManifest requires ==1)
  audio/{mic,system}/*.caf   Int16 from PR2 on; old Float32 archives still read
  events.jsonl               new kinds: paused, resumed, marker, systemWillSleep, didWake,
                             deviceChanged, diskLow
  status.json                live recorder status; removed at finish, like control.json
  control/<uuid>.json        requests from the app: stop, pause, resume, marker
  transcripts/<id>.json
  speakers/runs/<runID>.json immutable DiarizationRun
  speakers/edits.jsonl       SpeakerEdit journal; torn last line tolerated
  exports/transcript.{md,json,srt,vtt,txt}   regenerated views
  derived/                   deletable cache (16 kHz renders); excluded from integrity checks
```

New folders are created lazily, so older archives stay valid. New API:
`SessionArchive.withProcessingLock(at:)`, holding the flock for one write so the review window and
CLI edits can alternate.

### Global store

- `~/Library/Application Support/Holos/Speakers/profiles.json` (folder 0700, files 0600).
- Models under `Application Support/Holos/Models/<name>@<rev>/`, verified by sha256.

### How the CLI and app share work

Both call HolosMeeting and HolosStorage. The app launches `Holos.app/Contents/MacOS/holos record
start … --status-file --no-live-text`, sends commands as files in `control/` (the loop at
`RecordingWorkflow.swift:174` already polls `stop.request` every 100 ms), and reads `status.json`,
rewritten atomically every second (elapsed, bytes, free space, transcription lag, last phrase,
warnings, processing progress). XPC can come later.

## 3. Recording UX for long meetings

**Start.** Menu item "Start Meeting Recording…" opens a panel: name (default "Meeting YYYY-MM-DD
HH:MM"); mode "In person (microphone)" (`--source mic`) or "Online call (mic + system audio)" with an
optional meeting-app filter (`--app`); for calls, "others in the room with me" (diarize the mic
track too); disk estimate ("≈1.0 GB for 3 h · 24 GB free"); a dismissible
consent reminder. Toggle shortcut (default ⌃⌥⌘R) starts with the last settings; stopping by
shortcut needs a second press within 2 s.

**While recording.** Status item shows a red dot and elapsed time ("● 1:23:45"). The menu shows
name, elapsed, bytes used, free space, transcription state ("live" / "behind — will finish after
stop"), warnings, and Pause/Resume, Add Marker, Show Live Transcript, Stop and Save.

**Disk.**
- Before start: refuse below the 4 h estimate + 2 GB; warn below the 8 h estimate + 2 GB.
- During recording (checked at each chunk close): warn below 2 GB; below 500 MB stop gracefully,
  finalize, log `diskLow`.
- Int16 instead of Float32 (`ChunkWriter.swift:60–63`): mic mono ≈0.35 GB/h (was 0.69), system
  stereo ≈0.69 GB/h (was 1.38). A 3 h mic+system meeting drops from ≈6.2 GB to ≈3.1 GB.
- AAC compaction after review: later, optional (decision 3).

**Sleep, lock, lid.** Hold `kIOPMAssertionTypePreventUserIdleSystemSleep` while recording. Screen
lock: keep recording (ScreenCaptureKit behaviour under lock unverified, spike S2). Lid close or
forced sleep: finalize open chunks and log `systemWillSleep`; on wake after <15 min restart capture
in the same session (the gap is logged as `audioDiscontinuity`) and notify; after ≥15 min finalize at
the sleep point. The app's `suspendForSessionChange` only affects dictation, never the recorder.

**Device changes.** `AudioCapture` (`Sources/HolosAudio/AudioCapture.swift:51–77`) does not observe
`AVAudioEngineConfigurationChange`; connecting AirPods or unplugging a USB mic would stop the engine
while the loop keeps waiting (found by reading, not reproduced). Fix: restart on configuration
change, log `deviceChanged`, new format epoch; watchdog warns when a track delivers no frames for
more than 3 s.

**Crash recovery.** App crash: the recorder keeps running; on relaunch the app reattaches via
`control.json` + `SessionArchive.isActive`. Quitting during a recording asks Stop and save / Keep
recording / Cancel. Recorder crash or power loss: interrupted sessions are listed with saved
duration; Recover runs `SessionArchive.recover`, rebuilds the transcript from
`transcriptFinalized` events, retranscribes only uncovered audio, then diarizes and exports. Tail
loss is at most one open 30 s chunk.

**Dictation during a meeting.** Paused while a meeting recording is active (decision 6): the hotkey
does nothing and the menu says "Dictation paused during meeting recording". It resumes when the
recording stops. No dictation markers in the meeting transcript.

## 4. Transcription and diarization pipeline

**When each step runs.** Transcription stays live (today's `LiveTrack`); a lagging track is replayed
from disk after stop (`RecordingWorkflow.swift:91–98`). Diarization runs once per track after stop;
streaming diarization is much less accurate (LS-EEND ~20.7% DER on AMI; Sortformer 26–32%, ~41% with
5–9 speakers).

**Steps after stop (`MeetingPostProcessor`).**
1. Transcript from live final segments; replay any lagging track.
2. Render `derived/<track>-16k.caf` (≈346 MB Int16 for 3 h).
3. Diarize with `OfflineDiarizerManager.process(url)`; progress feeds `status.json`. Fallback if
   spike S1 shows peak memory >4 GB: 30 min blocks with 30 s overlap, clusters linked by centroid
   cosine.
4. Align (`HolosSpeakers.SpeakerAlignment`): each `TimedWord` goes to the cluster with the most time
   overlap on its track; a word in a gap goes to the nearest segment within 0.5 s, else "unknown";
   segments without word timing spread words evenly; runs of ≤2 words flipping A→B→A within 0.4 s
   go back to A; new turn on speaker change or pause >1.5 s. Apple segments split at word
   boundaries, keeping word timing.
5. Overlap: each word goes to its main speaker; the turn is marked `overlap` with `otherClusters`.
   Words are never duplicated.
6. Recognize against voice profiles (§5), write the run file, apply edits, export.

**Online calls.** Mic track = "Me" (`channelAssumption`), diarized only if "others in the room" was
checked. System track always diarized. Echo without headphones: warn at start when output is the
built-in speakers; PR11 drops mic words that match system words within ±1 s. Voiceprint samples are
tagged room or call (call codecs likely shift embeddings; unverified).

**Budgets for 3 h.** Recording memory flat (bounded queues); diarization ~1–2 min per track
(claimed, unmeasured here); alignment milliseconds for ~30k words. Proposed: peak RSS <4 GB during
diarization; RSS growth <100 MB/h while recording; labelled transcript ≤5 min after stop if live
transcription kept up.

## 5. Speaker-labeling feedback loop

**Transcript review window** (AppKit, opened from the Meetings window).
- Left sidebar, one row per speaker: editable name, talk time, "Play samples" (three 4 s clips from
  the longest non-overlapping turns), suggestion chip ("Jim? (likely)") with Confirm / "Not Jim",
  "Merge into…". Unknown speakers show as "Speaker N".
- Right pane, one row per turn: `[01:12:03]` timestamp (click plays from there), speaker chip with a
  reassign pop-up, turn text.
- Editing: multi-select → "Assign to…" / "New speaker from selection"; "Split turn here"; "Next
  uncertain turn" (low score, overlap, unknown); search; Export.
- CLI equivalents write to the same journal: `holos speakers list|rename|merge|assign|split`.

**Voiceprint updates** (only when "Remember voices" is on).
- Confirming "S2 is Jim" asks once whether to remember Jim's voice; if yes, S2's embedding becomes a
  sample, built from S2's turns excluding reassigned, overlapped, and <2 s turns. Under 20 s of
  speech the sample is "weak" and does not drive automatic labels.
- Reassigning turns after enrollment recomputes that session's sample. "Not Jim" is a
  session-only rejection. Linking a speaker to Jim in a later meeting adds a sample. Profile merges
  happen in the People window.

**Recognition in later meetings.** Score = best cosine similarity between a cluster centroid and a
profile's same-condition samples; one-to-one greedy assignment; two clusters matching one person
suggests a merge. Tiers, not percentages: *likely* (applied, marked "(auto)", one-click undo),
*possible* ("Jim?", needs Confirm), *none*. Start at FluidAudio's 0.65 cosine distance, then
calibrate on the user's own labelled meetings.

**Privacy.** Voiceprints are biometric identifiers of third parties: opt-in, stored only in
Application Support, never sent over the network. The People window lists each person's
contributing meetings with Forget this sample / Forget person / Forget all voices. `holos session
export --portable` strips centroids. Deleting a meeting's audio does not delete its voice samples,
and the UI says so.

## 6. Output formats

All exports are regenerated from transcript + diarization run + edits into `exports/`, replacing
the Markdown written in `saveTranscript` (`SessionArchive.swift:190–201`).

- **Markdown**: header (name, date, start time, duration, participants with talk time); each turn
  as "**Jim** · 00:12:03" and a paragraph; inline notes for gaps, pauses, markers, overlap;
  uncertain names as "Jim?".
- **JSON** (schemaVersion 1): speakers with provenance and confidence, turns with word references,
  gaps, markers, engine and model versions.
- **SRT/VTT**: one cue per turn, split at 7 s or 2 lines; VTT uses `<v Jim>`; timestamps past 1 h.
- **Otter-style TXT** ("Name  mm:ss" blocks): the format `scripts/evaluate-references.swift:83`
  already parses, so Holos output can be scored with the existing tool.
- **Minutes draft** (later, optional): local `SystemLanguageModel` only (8,192-token window, so
  chunked map-reduce for ~40k tokens); output is a draft with timestamp links; never a cloud model.

## 7. Phased implementation

- **S1 — Diarization feasibility spike** (no product code). Probe package under `.local/`, outside
  the main `Package.swift`. Run FluidAudio 0.17.1 offline on the three Otter recordings (7 min / 3
  labels, 20 min / 8 labels, 89 min / 11 labels) and a synthetic ~3 h concatenation. Record the
  model license text, whether a per-segment embedding API exists, and first-run CoreML compile
  time. Accept: `docs/speaker-evaluation.md` with runtime, peak RSS, speaker count vs Otter,
  approximate DER vs Otter turns, go/no-go.
- **S2 — Recorder process and platform spike.** Holos.app launches the bundled CLI. Check which
  process macOS credits mic and screen-recording permissions to; `kill -9` the app mid-recording;
  10 min screen lock; lid close on power and battery; AirPods connect/disconnect; built-in laptop
  mic capture quality in a real room. Accept: findings in
  `docs/hardware-validation.md` and the child-process vs in-process decision.
- **PR1 — Extract HolosMeeting.** Move the workflow out of HolosCLI; add a capture protocol at the
  `AudioCapture` boundary (like `DictationCapture`). No behaviour change. Tests: existing suite plus
  a fake-capture workflow test (start → frames → stop → saved; capture error → "incomplete").
- **PR2 — Long-recording robustness.** Int16 chunks; disk checks; power assertion; `status.json`;
  `control/` requests; device-change restart; watchdog; sleep/wake policy.
  Tests: Int16 CAF round trip; disk policy with injected free space; control parsing and
  idempotence; sleep-policy state machine; gap event on resume. Manual: 3 h soak with RSS per hour,
  bytes per hour, chunk continuity; lid close; AirPods switch.
- **PR3 — Recovery with the journal transcript.** Rebuild from `transcriptFinalized` events,
  retranscribe only uncovered audio, list interrupted sessions. Tests: torn journal tail, coverage
  gaps, idempotent recovery.
- **PR4 — Menu bar meeting controls.** Start panel, indicator, stop confirmation, toggle shortcut,
  child start/reattach, interrupted-session prompt, quit dialog, dictation paused while recording. Tests: a
  `MeetingController` reducer with a fake recorder. Manual: new `docs/meeting-validation.md`.
- **PR5 — HolosSpeakers values, alignment, exporters** (no ML dependency). Synthetic tests for
  boundary words, gap words, flicker smoothing, overlap, untimed segments, split turns, edit
  projection and stale edits, SRT/VTT past 1 h, Otter-style TXT parsing.
- **PR6 — Speaker storage in the session.** Runs, edits journal, processing lock, `derived/`
  excluded from integrity. Tests: torn edit line, second editor refused, old archives inspect clean.
- **PR7 — FluidAudio adapter and `session diarize`.** `HolosDiarization`, `TrackRenderer`,
  `holos setup --speakers` (pinned, sha256-verified model download), doctor model status,
  post-processing after stop. Tests: renderer gap filling and 48→16 kHz timing; opt-in fixture
  (`HOLOS_DIARIZATION_FIXTURE=1`) on a 3-voice conversation rendered with `NativeSpeechRenderer`
  (target DER <10%, 3 clusters). Extend `scripts/evaluate-references.swift --speakers` to report
  speaker count and DER against Otter, labelled "agreement with Otter".
- **PR8 — CLI speaker editing and re-export.** End-to-end CLI edit → journal → export test.
- **PR9 — Transcript review window.** Manual: label the 89 min Otter meeting from scratch; target
  under 10 minutes.
- **PR10 — Voice profiles.** Opt-in store, enrollment from confirmed labels, recognition tiers,
  People window, `holos people`. Synthetic-embedding tests for tiers, one-to-one assignment, merge
  suggestions, cross-model refusal, centroid recompute after forgetting, portable export stripping.
  Manual: enroll from meeting A, recognize in meeting B.
- **PR11 — Online-call refinements.** Mic = "Me", echo duplicate removal, headphone warning,
  condition-tagged samples.
- **PR12 (optional) — Local minutes draft** via `SystemLanguageModel`; exports still work when the
  model is unavailable.

**Acceptance set.** The user hand-reviews a 10–15 min slice of the 89 min Otter meeting (they know
the participants). Proposed bars: DER (0.25 s collar) ≤20% on that slice; speaker count within ±1
on all three Otter meetings; labelled transcript ≤5 min after stopping a 3 h meeting; no unreported
capture gaps in the 3 h soak.

## 8. Decisions and risks

Decisions (recommendation in brackets; the user's answer follows each):

1. **Downloaded third-party model?** FluidAudio code is Apache-2.0; the weights are CC-BY-4.0 per
   the Hugging Face card (conflicts with the README's MIT/Apache claim). [Accept; pin version and
   model revision with checksums; credit authors in About.] **Accepted.**
2. **Remember voices across meetings?** Reverses `docs/design.md` and T11. [Yes, opt-in, only from
   confirmed labels, with forget and export; update both docs.] **Accepted.**
3. **Audio format.** [Int16 PCM now; later an opt-in `session compact` to AAC after review.]
   **Accepted.**
4. **Where the recorder runs.** [Bundled CLI child process; in-process fallback if S2 shows
   permissions are not credited to Holos.app.] **Accepted.**
5. **Sleep policy.** [Resume after sleep under 15 min; otherwise finalize at the sleep point.]
   **Accepted.**
6. **Dictation during a meeting.** [Allow it and mark it in the transcript.] **Changed:** not
   needed; pause dictation while a meeting recording is active.
7. **Live speaker labels.** [Not in v1; revisit LS-EEND or Nemotron 3 later.] **Accepted.**
8. **Recording consent.** [User's responsibility; dismissible one-line reminder in the start
   panel.] **Accepted.**
9. **Room microphone.** [Test a USB omnidirectional boundary mic against the laptop mic in S2.]
   **Changed:** use the built-in laptop mic for now; no boundary-mic test, no input-device picker.

Risks and unknowns:

- Disk: 95% full (measured).
- FluidAudio is pre-1.0 (v0.17.1 released 2026-09-23); the adapter target limits API churn.
- Far-field DER of 15–25% (estimate) makes the review UI essential; overlapped words go to one
  speaker.
- Single-pass clustering memory for 3 h is unmeasured; block-wise diarization is the fallback.
- SpeechAnalyzer behaviour on timestamp jumps after a gap is untested
  (`AppleSpeechEngine.swift:173` allows gaps).
- A single 3 h SpeechAnalyzer session has not been soak-tested.
- Ad-hoc signing resets permissions on rebuild, and a bundled recorder ties its permissions to
  every app rebuild. (Rebuilding over a running copy also invalidated its signature and preceded
  two terminal freezes; `build-app.sh` now refuses to do that.)
- ScreenCaptureKit under screen lock is unknown.
- Room vs call voice embeddings likely differ; unmeasured.
- Live capture formats (mic channel count, sample rates) are unmeasured; no saved sessions exist
  yet.

## 9. Evidence

- **Files read**: `docs/design.md`, `docs/status.md`, `docs/contracts.md`,
  `docs/implementation.md`, `docs/reference-evaluation.md`, `docs/hardware-validation.md`,
  `README.md`; `Sources/HolosCore/Models.swift`, `Sources/HolosCore/Corrections.swift`,
  `Sources/HolosStorage/SessionArchive.swift`, `Sources/HolosAudio/ChunkWriter.swift`,
  `Sources/HolosAudio/AudioCapture.swift`, `Sources/HolosCLI/RecordingWorkflow.swift`,
  `Sources/HolosCLI/Record.swift`, `Sources/HolosCLI/Session.swift`,
  `Sources/HolosSpeech/AppleSpeechEngine.swift`, `Sources/HolosApp/HolosApp.swift`,
  `Sources/HolosApp/CorrectionsWindow.swift`, `Sources/HolosDictation/DictationController.swift`,
  `Package.swift`, `scripts/build-app.sh`, `Resources/*.plist`,
  `scripts/evaluate-references.swift`, `scripts/import-otter-references.py`.
- **SDK greps (MacOSX.sdk 27.0)**: `rg -il 'diariz|speakerident|speakerembed|voiceprint|speakerlabel|speakerID'`
  over Speech, SoundAnalysis, AVFoundation, AVFAudio, CoreML, ScreenCaptureKit, NaturalLanguage: 0
  files. `rg -i speaker` over Speech.framework: 0 hits. SoundAnalysis voice activity and speech
  emotion appear only as `.tbd` symbols. AVFAudio `setVoiceProcessingEnabled` is public.
- **Local data**: Otter ZIPs at `~/Downloads/for-otter-replacement/reference-data/otter/{001,002,003}.zip`
  (structure only read: 20:11 / 52 turns / 8 labels; 6:52 / 59 turns / 3 labels; 88:53 / 343 turns
  / 11 labels). Machine: M4 Pro, 48 GB RAM, 24 GiB free.
- **Web sources** (checked by the planning agent): FluidAudio repo (v0.17.1, Apache-2.0),
  `Documentation/Diarization/GettingStarted.md`, `SpeakerManager.md`, `Benchmarks.md`; Hugging Face
  `FluidInference/speaker-diarization-coreml` (CC-BY-4.0); pyannote community-1 (CC-BY-4.0, gated,
  19.9% DER AMI-SDM, 20.3% AliMeeting); NVIDIA streaming Sortformer v2.1 (41.4% DER with 5–9
  speakers); NVIDIA Nemotron-3-Diarization (≤8 speakers, no embeddings); sherpa-onnx v1.13.8
  (Apache-2.0, no published DER); Argmax SpeakerKit (MIT, no enrollment API); DiariZen (CC BY-NC
  weights); Picovoice Falcon (AccessKey required); SpeechBrain ECAPA (Apache-2.0).
- **Not verified**: CAM++/WeSpeaker EER figures (from memory); sherpa-onnx CoreML path in practice;
  the 15–25% DER expectation and 3 h clustering memory (estimates).
