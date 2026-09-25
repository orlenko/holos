# Implementation status

The CLI recording/playback milestone and a second, locally built menu bar dictation
milestone are implemented, not the full T01–T14 plan. The package builds with
Swift 6.4 on macOS 27 / Apple Silicon. Native speech inference is local.
Hardware-facing and cross-app acceptance remain pending.

## Available now

- `doctor` reports local framework/model, voice, permission, and speech-asset
  readiness without requesting permissions. `setup` installs Apple's speech or
  dictation assets for `--locale`; without it, `setup`, `doctor`, `transcribe`,
  `record start`, and `session import` use the supported locale closest to the macOS
  preferred languages and region (`en-CA` when none is supported), and
  `session retranscribe` uses the locale the session was recorded with.
  `doctor --json` names the locale its asset statuses describe (`locale`).
- `transcribe` processes a local audio file using Apple's Speech framework. It can
  print finalized timestamped segments, emit JSON, or write JSON to a new file.
- `record start` captures microphone, system audio, or both into a `.holos` session
  archive while displaying finalized transcript phrases. `--record-only` saves
  audio without recognition. `status` and `stop` inspect/request graceful stop;
  Ctrl-C finalizes capture and saves audio before transcription drains.
  `pause`, `resume`, and `marker` control a running recording by session ID.
- `session inspect`, `recover`, and `retranscribe` validate/recover archived audio;
  `retranscribe` writes a new transcript to a separately named JSON file. Audio and
  existing archive revisions are retained.
- Session archives (meeting-recording wave 0): a failed journal append is truncated
  back instead of leaving a partial line; a corrupt journal line is skipped and
  counted, so `inspect` and `recover` still work; `transcripts/current.json` names
  the current transcript revision (older archives fall back to the newest one);
  `recover` takes a per-session processing lease and refuses while another Voice is Local
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
  a hint to install them. (Wave 4 added meeting recording and labelling to the app.)
- Import and evaluation (wave 2): `session import <audio-file>` turns any audio file
  macOS reads into a session (one in-person microphone track), transcribes it, and
  labels its speakers. The session is built in a hidden `.import-<UUID>` folder in
  the sessions folder and appears as a session only once it is complete, so an import
  that fails, is cancelled, or is killed is never taken for a recording; a failed or
  cancelled import removes that folder, and the next import removes one a killed
  import left (only a folder with that exact name and the `.holos-import` marker
  Voice is Local writes into it; nothing else in a `--directory` folder). Labelling runs under the lock the import took, and the session's path
  is printed once labelling ends. The hidden
  `session score --otter <transcript.txt>` compares a session's labels with Otter's
  and prints numbers only (hashed labels with `--json`).
  `scripts/evaluate-references.swift --speakers --calibrate` runs both over the private
  Otter recordings; see the results below.
- Recovery, session list, and deletion (wave 3): `session recover` finishes a session
  whose recorder died. Under one processing lease it indexes the saved audio, rebuilds
  the transcript from the phrases live transcription journaled (with their word
  times and IDs; older journals give untimed phrases), transcribes only the audio
  after the last saved phrase or after a point where live transcription fell behind,
  joining the two at word level, and labels the speakers. The rebuild is idempotent
  (a second `recover` changes nothing; `--force` rebuilds again); a failed or
  timed-out transcription publishes nothing and leaves the recovered archive, and
  `--no-transcribe` rebuilds from the saved phrases only. A session that was not
  interrupted keeps its transcript (one whose transcription did not finish keeps the
  transcript saved at stop, and is rebuilt only when it has none). `recover` exits 3 when speaker labelling failed
  or was skipped for a reason other than missing speaker models, and 1 when recovery
  or the rebuild failed or some saved audio could not be recovered. `session list`
  (also used by `record status`) shows each session's state (`recording`,
  `processing`, `interrupted` for a dead recorder, the saved status, or `damaged`
  for an unreadable manifest), saved audio, size, and speaker-label state. `session delete --yes` moves a session to
  the Trash and deletes its recorder log (a `damaged` folder too, even one left
  without a manifest); `--audio-only` deletes the audio, renders,
  and any voice data for good and writes `audio-deleted.json`, keeping the
  transcript, speaker labels, and exports (the session still inspects clean, and
  labelling it again says the audio was deleted). Deletes never follow a symbolic
  link out of the session. `inspect`, `recover`, and `session list` report skipped
  journal lines.
- Speaker editing (wave 3): `speakers list <session> [--turns] [--json]` shows the
  labels; `rename`, `merge`, `assign` (to a speaker, `unknown`, or `new[:NAME]`),
  `split` (`--at-word` or `--at`), `exclude`, and `undo` correct them. `<session>` is a
  `.holos` path or a session ID; speakers are chosen by ID, engine label, number, or
  name, and turns by ID or by a time inside them. Each edit is appended to the
  session's edit journal only if the labels it was made against are still current
  (otherwise it exits 1 with a reload message and writes nothing), and the exports
  are rewritten afterwards, keeping a hand-edited copy under a new name. A command
  that would change nothing says so and saves nothing. `undo` walks back one command
  at a time; there is no redo. `session export <session> --format md|json|txt
  [--output FILE]` renders the labelled transcript (`--output` creates a new 0600 file
  and never replaces one), and `--all` rewrites `exports/`.
- Menu bar meetings (wave 4): VoiceIsLocal.app records meetings from the menu bar (Start
  Meeting Recording…, then Pause, Add Marker, Show Live Transcript, and Stop and Save).
  The recorder is the bundled `voiceislocal` tool running as a child of the app; it keeps
  recording if the app quits or crashes, and the app finds it again on relaunch, as it
  does a meeting started from a terminal. Its log is
  `~/Library/Logs/Holos/recorder-<id>.log`; `defaults write ca.orlenko.holos.app
  meetingRecorderMode inProcess` records inside the app instead. A start that gets no
  recording status within 2 minutes is stopped; if a permission prompt is open when
  Stop Recording is chosen, the recorder stops once the prompt is answered. Dictation is
  paused while a meeting records. Meetings… lists recordings and can recover them,
  label their speakers, open or save the transcript, delete the audio or the whole
  meeting, and clean up leftover renders. Setup has a "Speaker labels" row that installs
  the speaker models (about 21 MB). Voice is Local relabels a meeting automatically when its
  labelling was interrupted, at most twice per meeting within 7 days; quitting during a
  recording asks what to do. `build-app.sh` bundles and signs the CLI and refuses to
  rebuild while a recorder runs from the bundle.
- People and voices (wave 4): `speakers link <session> <speaker> <person|new:NAME>` (and
  `speakers me`) links a speaker to a person and names it, so names carry across
  meetings with or without voiceprints; `speakers reject` says a speaker is not a person
  in that meeting. "Remember voices" is off by default (`people remember on|off|status
  [--forget]`, or the People window): with it on, `link --learn-voice` learns one voice
  sample per person and meeting from the confirmed speaker's clear turns only (2 s or
  longer, not overlapped, not reassigned, split, or excluded; an outlier pass drops
  turns far from the rest), extracted on demand by a fresh FluidAudio pass (the app runs
  the bundled `voiceislocal` for it). Post-processing never stores voice embeddings; after
  labelling it compares speakers with remembered voices and saves distances only, and
  `speakers list` shows "suggestion: Maybe Jim". Suggestions are never exported, and
  nothing is named automatically until thresholds are calibrated on the user's own
  confirmed meetings (hidden `people calibrate --apply`; the default suggestion
  threshold, 0.43 cosine distance, comes from the Otter calibration below). Samples live
  in `Application Support/Holos/Speakers` (0700, 0600 files, excluded from Time Machine)
  and follow later speaker edits in their meeting (a sample whose turns changed and that
  can no longer be recomputed is removed, with a note on stderr; one from an earlier
  labelling of the meeting is kept until new labels replace it). `people list [--json]`,
  `rename`, `merge`, `forget` (a person, one sample, a meeting's samples, or `--all`), and
  `export [--include-voiceprints]` manage them; People… in the menu does the same.
  Forgetting cleans the meetings in the sessions folder, not sessions kept elsewhere with
  `--directory`. A forget is journalled first and finished at the next app launch or
  `people`, `speakers`, or `session` command if Voice is Local stops midway. Known people's names
  are added to meeting recognition vocabulary.
- Online calls (wave 5): when a call's speakers are labelled, the microphone's echo of the
  call audio is left out: a run of 3 or more microphone words that repeats the call audio
  starting up to 1 s after it (or at most 0.25 s before, for timing jitter; earlier words
  are your own voice sent back by the far end and stay) is listed in the run's
  `droppedWords` with reason `echo`, is in no turn or export, and splits the microphone
  turn around it. With others in the room, a microphone speaker whose words are at least
  60 % echo is not listed and its remaining words become unknown speaker. In-person
  meetings are unchanged. The start panel, the menu (from `status.json`'s `echoRisk`
  warning), and `voiceislocal record start` (stderr) warn when a call plays on the laptop
  speakers, checked at start, after device changes and capture restarts, and every 2 s.
  The filter runs only with speaker labels, so a call exported without the speaker models
  keeps the echo, and misheard echo shorter than 3 matching words stays.
- Review window (wave 5): Review… in Meetings (or double-click, or the "Name Speakers —
  …" menu line after a meeting, which then goes away) opens a window to name a labelled
  meeting's speakers: a name field per speaker that links or creates a person (a known
  name links that person), talk time, the start of the speaker's two longest turns, Play
  samples (three clips from the longest turns without overlap), This is me, Merge into…,
  and "Maybe Maria" suggestions to confirm or reject one by one or all at once; a turn
  list with a play-from-here time button, a speaker pop-up (speakers, known people,
  Unknown, New Speaker…), and ⚠ for uncertain turns; Next Uncertain (⌘'), 1–9 to assign
  the selection, Split Turn, search, Find More Speakers (a relabel with a minimum of one
  more speaker than found; names carry over, turn-level changes do not), Label Speakers on
  My Microphone for calls, Label Again after the transcript changed, Undo (⌘Z, the
  window's own changes, newest first), and Export (Save As… Markdown, text, JSON; Copy as
  Markdown). Voice is Local has no main menu, so these live in the window's toolbar ("Speakers"
  pull-down) and the window handles its shortcuts. Every change shows at once and is saved
  in order in the background through the same compare-and-append as `voiceislocal speakers`; a
  change made on labels that changed elsewhere is refused and the window reloads them.
  The transcript files are rewritten 2 s after the last change and when the window closes
  (and before Voice is Local quits); a hand-edited export is moved aside and the footer says so.
  Playback uses the saved chunks at their session times (off after Delete Audio). The
  footer box "Learn voices of people I name in this meeting" decides whether naming learns
  a voice. Delete Meeting can also forget the voice samples learned from that meeting.
- `voices list` and `say` provide native voice discovery, playback, and `.m4a`,
  `.wav`, or `.caf` export. Text comes from arguments or UTF-8 stdin.
- `read` renders a local UTF-8 text/Markdown file or stdin as an ordered AAC
  playlist, with resume and optional playback. Markdown is read verbatim.
- `scripts/build-app.sh` builds and ad-hoc signs `build/VoiceIsLocal.app`, an accessory
  menu bar app. Its Speech dictation is disabled on first launch; the user
  explicitly grants permissions, picks the language (by default the supported one
  closest to the macOS preferred languages, `en-CA` when none is), installs speech
  assets, and enables the chosen
  hold-to-talk shortcut. Right Option is the default choice, with
  Control–Option–Space available instead. It previews speech and finalizes on
  release; Esc cancels even during finalization. Until the default language is
  known (the supported list loads just after launch), installing its speech model
  and enabling dictation wait for it, and the meeting start panel keeps Start off.
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
Headphones avoid remote speech leaking acoustically into the microphone track. When a
call's speakers are labelled, repeated call audio on the microphone (3 or more matching
words) is removed from the transcript; acoustic echo cancellation is not implemented, and
a call without speaker labels keeps the echo.

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
`session score`, speaker editing (stale views refused, batches, undo, concurrent
editors, selectors), recovery (journal rebuild, torn and corrupt journal lines,
coverage and word-level replay, idempotence, the one-lease recover → rebuild →
label chain), the session catalog's states and sizes, Delete Audio and Delete
Meeting (including symbolic links in place of session folders), the menu bar meeting
logic (the meeting reducer and controller, launchers and spawned children, the
automatic relabel policy, the vocabulary hand-off file), people and voice profiles
(recognition tiers and one-to-one assignment, enrollment rules, calibration, the
private locked store, linking with and without voice learning, samples kept in step
with edits and never overwritten by a stale refresh, forgetting and resuming a forget
after a crash, the extractors' speaker-slot selection, and that post-processing stores
distances but no vectors), online calls (the echo filter and hidden echo-only microphone
speakers, end to end on a call and a hybrid call; the laptop-speaker classification and
the `echoRisk` warning with a fake output route), the review window's model (changes
shown before they are saved, saved in order, refused and reloaded when the labels changed
elsewhere, including changes queued behind a refused one; undo of saved, saving, and
queued changes; turns made by a pending split; Confirm All as one undo; exports rewritten
after a delay and at close; search, next uncertain turn, sample clips, previews, and the
name field's link-or-create rule) and its playback composition (chunks at their session
times, overlapping chunks trimmed, missing chunks skipped), and the speaker algorithms
(alignment, edit projection, carry-over, exporters, scoring) on synthetic data; run them with
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
Voice is Local disagreed with Otter's speaker on 1.4–5.1 % of the time where both have a
speaker. Voice is Local had 2, 7, and 6 speakers with at least 30 s of speech; Otter had 2,
7, and 8 labels with at least 30 s of turns (counts, not matched people). Voice is Local
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
- Exercise capture failure/relaunch/recovery on hardware (`kill -9` a recorder, then
  `session recover`: the loss should be at most one 30 s chunk) and run multi-hour
  soak tests for memory growth, drift, interruptions, and audio continuity. The
  lid-close, sleep, screen-lock, AirPods, small-disk, and 3 h checks for long
  recordings are listed in the [live-recording checklist](hardware-validation.md)
  ("Long recordings") and have not been run.
- Label speakers on a real in-person meeting and a real 3 h call; hand-label a slice
  of a recording to measure speaker error rather than agreement with Otter.
- Run the menu bar meeting checks in the [meeting validation guide](meeting-validation.md)
  (permission prompts and ownership, an app or recorder killed mid-meeting, dictation
  paused during a meeting, quitting while recording, installing speaker models from
  Setup, automatic relabel after a shutdown, a call on laptop speakers and a hybrid call,
  naming the speakers of the 89-minute Otter meeting and of a real 3 h meeting in the
  review window in under 10 minutes; the review window's layout, keys, and playback have
  not been seen on screen yet) and the
  [voice profile checks](voice-profile-validation.md) (a voice confirmed in one meeting is
  suggested in the next; forgetting removes it). None has been run yet.
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
  correction. No correction database workflow is present.
- Speaker names and edits: labels are "Speaker N" until named in the review window or
  with `voiceislocal speakers`. The review window has no redo, and its undo does not reach past
  a relabel (Find More Speakers keeps names, not turn-level changes). Find More Speakers is
  off for a call whose two tracks were both split into speakers, because a minimum speaker
  count cannot be asked of two tracks at once. Recognition thresholds come from a small
  calibration (two recordings of one team); suggestions for a person recorded in the
  other condition (room vs call) are less reliable. Speaker counts are approximate:
  quieter or briefer speakers can merge into others. Nothing deletes old meetings
  automatically.
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
