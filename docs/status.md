# Implementation status

The CLI recording/playback milestone and a second, locally built menu bar dictation
milestone are implemented, not the full T01–T14 plan. The package builds with
Swift 6.4 on macOS 27 / Apple Silicon. Native speech inference is local.
Hardware-facing and cross-app acceptance remain pending.

Opt-in meeting screen context is implemented: one Settings checkbox (off for new
installs, on for users of the earlier window offer) and a per-meeting "Capture screen"
box; the whole main display without Voice is Local's own windows (no window picker,
no other displays); low-rate JPEGs of changes that hold still, at most 2560 pixels;
post-stop on-device Vision OCR, read-only timed text and vocabulary candidates in
Review, and bounded OCR context for existing word-list questions. Screen evidence is
removed with audio; no new live LLM step is added. `record start --screen display`
is the CLI form. Synthetic frame (including 5K)/lifecycle/storage/OCR tests, a 5K CPU
probe, and offscreen light/dark previews of the Settings row and the start panel row
cover the implementation. Real ScreenCaptureKit permission, own-window exclusion,
pause/restart, and end-to-end UI acceptance checks remain pending. "All displays", the
thumbnail timeline, and a larger local-model benchmark are follow-ups.

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
  meetings are unchanged. The filter runs only with speaker labels, so a call exported
  without the speaker models keeps the echo, and misheard echo shorter than 3 matching
  words stays. Nothing warns when a call plays on the laptop speakers: the `echoRisk`
  warning, its output-route check, and the start panel's orange line were removed with
  the one meeting mode (below); the menu ignores an `echoRisk` left in `status.json` by an
  older recorder.
- Meeting recording, one mode: the start panel has no In person / Online call choice, no
  app picker, and no "Others are in the room" option. Every meeting from the app records
  the system default input and everything the Mac plays, labels speakers on both tracks,
  and filters the microphone's echo of the computer's audio (meeting.json `call` with
  `othersInRoom: true`, `record start --source mic+system --others-in-room --microphone
  default`). "Me" comes from the remembered voice of the person marked This is me when
  there is one; otherwise you name the speakers in review. Setup's System audio row is an
  ordinary step (pending until granted, never marked as a problem). Without the
  permission when a meeting starts, the meeting records the microphone only (no prompt,
  no refusal) and the menu says "Recording the microphone only — allow System audio in
  Setup to include the computer's sound." (UserDefaults `meeting.sourceNotice` keeps it
  with the session ID, so a relaunched app following that meeting shows it again.)
  Setup's Advanced section, collapsed each time the window opens, has "Record
  the computer's audio (system sound) in meetings" (UserDefaults
  `meetingRecordSystemAudio`, on by default); off, meetings record the microphone only.
  A microphone-only meeting records the system default input, labels speakers on it, and
  is saved as `inPerson` (`--source mic --microphone default`). Sessions recorded as in
  person, call, or hybrid keep their meaning and are labelled, exported, and reviewed as
  before. `record start` keeps its defaults for scripts (`--source mic+system`, the
  microphone as "Me" without `--others-in-room`, and the built-in microphone for `--source
  mic`); `--microphone default|built-in` is new. With the lid closed, a microphone-and-system
  meeting whose microphone is the built-in one (the system default input, or `--microphone
  built-in`) records the computer's audio alone, warns "The built-in microphone is off while
  the lid is closed; recording the computer's audio only. Open the lid to include the
  microphone.", and journals `deviceChanged` (`builtInMicrophoneLidClosed`) on the
  microphone track; opening the lid (or unlocking the screen with it open) restarts capture
  with the microphone. Closing the lid mid-meeting on the built-in microphone restarts
  capture the same way (`deviceChanged` `lidClosed` on the microphone track), even when
  Core Audio keeps the device listed: a microphone-and-system meeting goes on with the
  computer's audio alone and that warning, and a microphone-only meeting waits with "The
  built-in microphone is off. Open the lid to continue recording." An external default
  input keeps recording.
- Meeting languages: the start panel's Language pop-up (the dictation languages, the last
  choice remembered in `meetingLocales`) sets the language a meeting is transcribed in
  live (`record start --locale`); "Also detect" adds up to two more, for meetings that mix
  languages. Their speech models are checked in the panel and installed only on Install….
  With several, meeting.json records them (`languages`), and post-processing (stage
  `languages`, before the speakers) transcribes the saved audio again in each language
  (final results only; the live transcript stands in for its language only when that
  fails, which the finished message says and a later run retries), keeps each transcription as a transcript revision that is not current
  (`languagePass` in the journal), and merges them: words in 3 s passages, each passage in
  the language whose words score higher (mean word confidence plus the on-device language
  identifier's probability that the text is in that language), switching only when two
  passages in a row agree (in a call, a microphone passage that echoes the system track
  follows the system track's language, so the echo is still dropped). The merged transcript becomes current (`languagesDetected`),
  names each segment's language, and speakers are labelled on it. It is resumable (saved
  transcriptions are reused), does nothing on a second run, and fails soft: a language
  whose speech model is missing, or whose transcription fails, is left out and the result
  is partial with the reason (exit 3), the transcript staying as it was when fewer than
  two languages remain. `record start` and `session import` take `--languages fr-CA,en-CA`;
  `session languages <session> --languages …` detects the languages of a saved or
  imported session and labels its speakers again when the transcript changed (`--force`
  over edited labels; a run that leaves the transcript as it was keeps the labels). The
  Markdown export lists the languages in its header and the JSON export each turn's.
  Dictation stays in one language.
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
- `voices list` and `say` provide native voice discovery (with each voice's quality, and a
  hint to download Premium voices when none is installed), playback, and `.m4a`, `.wav`,
  or `.caf` export. Text comes from arguments or UTF-8 stdin. `--voice` takes a name as
  `say -v '?'` prints it ("Ava (Premium)") or an identifier.
- `read` turns a local .txt, .md, .html, .pdf, .rtf, .rtfd, .docx, .doc, or .odt file,
  stdin, or an `https://` web article (Mozilla Readability in an offscreen web view; the
  byline becomes the author) into one AAC `.m4a` (mono, 22.05 kHz, about 32 kbit/s, about 14 MB per hour) named
  after the document's title, with title/author metadata and a chapter at each heading.
  Markdown markup is dropped; code blocks and images are skipped. The default voice is the
  best installed voice for the text's language. `--output` takes a `.m4a` path or a
  directory; `--resume` continues an interrupted reading (a web page is loaded again, and a page
  whose text changed is refused); `--play` plays the file;
  `--print-text` shows what would be read. The sample output was checked with `afinfo` and
  `ffprobe`; playback on an iPhone of this command's output has not been tried yet (a
  `say`-made file with the same settings played there).
- `scripts/build-app.sh` builds and ad-hoc signs `build/VoiceIsLocal.app`, an accessory
  menu bar app. Dictation is disabled on first launch; the user explicitly grants
  Microphone and Accessibility, picks the dictation language (by default the supported one closest to
  the macOS preferred languages, `en-CA` when none is; any language Apple's
  SpeechTranscriber supports), installs that language's speech model, and enables the
  chosen hold-to-talk shortcut. Right Option is the default choice, with
  Control–Option–Space available instead. It previews speech and finalizes on
  release; Esc cancels even during finalization. Until the default language is
  known (the supported list loads just after launch), installing its speech model
  and enabling dictation wait for it, and the meeting start panel keeps Start off.
- Setup Assistant: the first launch opens a step-by-step assistant (language and
  microphone, then Accessibility, then the permissions that need a reopen, then a
  re-check) that downloads the speech and speaker models in the background, reopens the
  app once at the end when Screen & System Audio Recording was requested, and shows a
  one-page check after the reopen. **Run Setup Assistant…** in Settings runs it again;
  installs that were already set up never see it (docs/design.md "First-launch setup").
  Input Monitoring is no longer required: the hotkey's active event tap is gated on
  Accessibility only, and Settings shows an Input Monitoring row only when macOS refuses
  the tap with Accessibility granted. The decisions are unit-tested; the windows and
  the reopen have not been run on screen yet.
- Finalized phrases are written into the focused field while the user speaks: through
  Accessibility (`AXSelectedText`) into writable native fields, and as typed keystrokes
  into terminals and web or other editors without a direct Accessibility write, only
  while the same field keeps focus. For a terminal, "the same field" means the terminal
  staying frontmost with the same focused window and focused element as reported to
  Accessibility at key-down, so switching tabs, panes or windows stops typing where the
  terminal reports a per-session element (expected for Terminal and iTerm2; not yet
  checked against live terminals). A terminal reporting only its window is tracked by
  window, so a pane switch inside that window goes undetected; one reporting neither is
  tracked by staying frontmost only. Key-down reads the terminal's focus until two
  consecutive reads agree (at most four reads); if they never agree, as when focus
  moves during the capture, that dictation is not typed and is kept for Copy Result.
  Secure fields and Secure Keyboard Entry are refused.
  It never synthesizes Return and never pastes. Text it could not write (target
  changed, safety check failed, unverified write, forced stop) is kept for Copy Result
  or Discard in the menu; it is never put on the clipboard automatically, since
  dictation can be sensitive. The kept result is replaced only by a later dictation that
  produces text; a press that is cancelled, released before listening, or recognizes
  nothing leaves it and its ten-minute expiry in place. See
  [dictation validation](dictation-validation.md).
  Dictation audio is not saved.
- Dictation text is cleaned before it is written: filler words are removed (English and
  French lists; off in Settings), then learned corrections are applied. **Correct Last
  Dictation…** learns word swaps from the user's edits, and the Corrections section adds,
  edits and removes them. An opt-in Settings option, off by default, fixes misheard words
  in each chunk with Apple's on-device Foundation Models before it is written; a guard
  keeps the original text when the reply changes more than a few words, undoes a
  learned correction, adds, drops, splits or joins a word, replaces a real word with
  anything but a listed homophone or a word the spell checker does not know with one
  that does not sound like it (unless a learned pair whose heard phrase was said there
  taught it), or changes punctuation other than commas and apostrophes (the
  last piece of a dictation may also change its closing `.`, `!`, `?` or `…`). **Copy Original** keeps
  the text as heard.
- Word list (docs/design.md "Word list"): terms the recognizer should expect (names,
  products, jargon), in `words.json` (versioned, atomic 0600 writes, changes under a lock),
  edited in the Corrections section's Word list card and with `voiceislocal words
  list|add|remove|import`. Dictation and new meetings give the recognizer the list first,
  then correction words (meetings: people's names, then correction words), at most 100
  contextual strings; the app picks up a change from Terminal at the next dictation. A
  meeting's saved `vocabulary.json` stays what replays use; `session recover
  --current-vocabulary` opts into today's list. Apple Intelligence's fix counts the terms'
  words as real words and changes nothing else in its guard. On one real meeting the list
  took term hits from 30 of 82 to 32 of 82. A term may list real words it is often heard as
  ("cloud", "clot" for "Claude": `voiceislocal words add Claude --heard-as cloud,clot`,
  `words heard-as`, the card's "Often heard as" column); after dictation's fix, each place
  such a word was said is one question to the on-device model, which may put the term
  exactly there and nowhere else (on 5 invented sentences: right in all 5). Unit-tested with
  a stand-in model; the card's column is built and compiled only.
- Meeting word fixes (docs/design.md "Meeting word fixes"): post-processing stage 1d, after
  the languages and live text corrections but before the speakers, applies the learned
  corrections to every segment (as dictation does) and asks Apple's on-device model, place
  by place, whether a term was meant where its often-heard-as word was written (only with Apple Intelligence's fix on);
  a replaced phrase takes the time of the words it replaced. The result is a new transcript
  revision (`fixedFrom`, `wordsFixed`; the one before is kept), fixed words are marked and
  shown with a dotted underline and a "Heard as" tooltip in the review, and `voiceislocal
  session fix-words <session> [--force]` fixes an existing meeting again with today's
  corrections and terms, mapping the current speaker labels and their effective edits to
  the new word positions without diarizing (`--force` labels again). Review can revert one
  dotted-underlined fix from its contextual menu or VoiceOver action while keeping the
  other word fixes and speaker edits; automatic post-processing keeps that rejection until
  `session fix-words` is explicitly requested. Untimed segments use word order rather than
  their redistributed estimated times when labels are mapped. On invented
  sentences the model never put the term where it was not meant and found it in 3 of the 6
  places of an invented meeting where it was meant.
  The stage (versions, re-runs, the model off, edited labels, cancellation, the languages
  stage and recovery seeing through a fix), the timings, and the question are unit-tested
  with a scripted model; it has not run on a real meeting yet, and the review's underline
  and revert menu have not been seen on screen. `eval apply --add-vocabulary` proposes and adds
  often-heard-as words where reviewed passages replaced real words by a term. `eval local`
  applies the stage to its candidate by default (`--no-word-fixes` opts out).
- Deep transcription after meetings (docs/meeting-design.md §4.16): `voiceislocal
  setup --whisper` downloads Whisper large-v3 turbo for WhisperKit (about 1.6 GB, resumable,
  loaded once before it counts as installed; `doctor` reports it), and `voiceislocal session
  deep-transcribe <session> [--force]` transcribes a finished meeting's saved audio again on
  this Mac, prompted with the meeting's name, the word list and people's names, and publishes it
  as a new transcript revision (`engine` "whisper:…", `deepTranscribed`), followed by live
  corrections, word fixes, speaker labels and exports. Passages over near-silence where the
  recorded transcript has no words and repetition loops are left out. Three WhisperKit 1.1.0
  problems with prompts are worked around (word times read from the wrong decoder rows, timestamp
  rules switched off, speech left out of a chunk; each chunk is also decoded without the prompt
  and keeps the plain result when the prompted one lost words). `eval local --backend whisper`
  makes the same transcription as a candidate. In the app, Settings › Meetings downloads the model
  and turns on "Deep transcription after meetings", which queues each saved one-language meeting
  and runs the pass on AC power, one at a time, resuming the queue after a quit; the Meetings list
  shows the pass's state and a meeting's right-click menu runs it now or cancels it (the queue
  policy is unit-tested; the Settings row, the menu and the power switch have not been seen on
  screen yet). Unit-tested with a scripted transcriber; an opt-in
  test runs the real model on invented speech.
  Manual validation on a copy of a real 53-minute call (both tracks, release build, M4 Pro,
  numbers only): 1,163 s for the pass (6,348 s of audio over two tracks), 772 MB peak, 1,208
  passages and 15,786 words (the recorded transcript had 17,193), 14 passages over silence
  and 2 repeats left out; word starts agreed with the recorded transcript's within 0.13 s at
  the median (98 % within 1 s); recorded words with no deep word within 3 s fell from about
  500 s of speech per track before the prompt workarounds to about 65 s. Against a cloud
  reference (system track, `eval local --backend whisper`): 14.6 % WER (339 deletions) and 63 of
  82 word-list terms, against Apple's 20.9 % and 31 of 82, after WhisperKit's first-token check,
  which emptied whole chunks (725 deletions), was turned off.
- Meeting titles and summaries (docs/meeting-design.md §4.17): `voiceislocal session summarize
  <session> [--force] [--json]` has Apple's on-device model write a title (at most 8 words), a
  one- or two-sentence summary, key points and action items from the current transcript with
  speaker names, by map and reduce over parts that fit the model's context; they go to
  `summary.json` and into the Markdown and JSON transcript files. meeting.json records whether
  the user named the meeting (`nameSource`); older meetings count a "Meeting YYYY-MM-DD HH:MM"
  name as default, so a generated title never replaces a name the user gave. In the app, a
  meeting is summarized in the background once its transcript is final and again after a final
  transcript, one at a time, never while a meeting records or saves (Settings › Meetings, on by
  default; off without Apple Intelligence). Unit-tested with a scripted model. Manual validation
  on copies of three real meetings (52–80 min; numbers only): 6, 6 and 9 model calls, 32–53 s
  each, no failures; the titles and summaries named the meetings' topics and their facts were in
  the transcripts, with recognition errors in names and jargon carried over.
- Meetings list (docs/design.md "Meetings list"): rich rows grouped by Today, Yesterday, This
  Week and month, with the title, start, length, people, the summary, and badges instead of
  columns; a search field filters by title, summary and people; the row's menu has every action.
  Rendered offscreen with invented meetings in light and dark; not yet seen in the running app.
- Main window (docs/design.md "Main window"): **Open Voice is Local** (⌘0) opens one
  window with a sidebar: History (⌘1), Corrections (⌘2), Meetings (⌘3), People (⌘4),
  Reading (⌘5), and Settings (⌘,), with a
  dictation status card at the sidebar's bottom. Corrections, Meetings, and People are the
  former windows' contents hosted as sections; Settings replaces the Setup window
  (Permissions, Dictation, Meetings, Reading, History and privacy, Run Setup Assistant…), and every
  "Setup…" path opens it. The menu bar menu is slimmed to the dictation status and toggle,
  the kept result's Copy items, Correct Last Dictation…, the meeting block, and the window's
  items; the language and shortcut submenus moved to Settings. The Setup Assistant, the
  meeting start panel, Review, and the dictation preview stay separate windows. Built and
  compiled only: nothing of the main window has been seen on screen yet.
- Settings chapters and search (docs/design.md "Main window"): the sidebar lists Settings'
  cards as chapters under it; choosing one scrolls its card to the top, and the sidebar
  follows the card at the top while scrolling. A search field above the page (⌘F) shows only
  the settings whose title, caption, or keywords match (a fuzzy scorer, `SettingsSearch`,
  unit-tested with the chapter-at-offset mapping); Return goes to the outlined best match,
  Escape clears. Rendered offscreen (sidebar and page) in light and dark: the page, a query,
  no match, a chosen chapter, and Return; not yet seen in the running app (smooth scrolling,
  focus moves, and VoiceOver announcements are unverified).
- Live transcript in the main window (docs/design.md "Live transcript"): the meeting being
  recorded is the first row of Meetings ("● Recording"), and opening it (double-click,
  Return, Live Transcript, or the menu bar's Show Live Transcript…) shows its words in place
  of the list as they are spoken: volatile words in a secondary colour until final (the
  recorder writes them to `live.json` at most every 200 ms), the microphone's echo of the
  call hidden with post-processing's echo rule, following the newest words until the user
  scrolls up ("Jump to Live"). After the stop it shows the saving progress, then offers
  Open Review or Open Transcript. The separate Live Transcript window is gone. Unit-tested
  (volatile to final, echo hiding, following, what opens) and rendered offscreen in light
  and dark; not yet seen in a real meeting.
- Reading section (docs/design.md "Reading section"): the main window's Reading (⌘5) makes
  the `voiceislocal read` file in the app. A New reading card takes an `https://` link or a
  document (typed, pasted with ⌘V, dropped anywhere on the section, or chosen; several files
  at once are all added), a voice (Automatic, or the installed voices with the user's
  languages first, Premium first and marked) with Preview, and a speed (0.8×–1.4×, an
  estimated mapping onto the speech rate that has not been checked by ear). Readings are made
  one at a time in this process, each into `~/Music/Voice is Local/Readings/<Title>.m4a`
  (Settings › Reading changes the folder, default voice, and speed), and listed with their
  progress ("Rendering part N of M", Stop) or, once made, length, chapters, size, and voice,
  with Play (in the app, Space), Share… (⇧⌘S), Show in Finder, and Delete… (⌫; the file goes
  to the Trash, the render cache is removed). Failed and stopped readings offer Try Again or
  Resume, which reuse the rendered parts and the saved text. The list is an index in
  `Application Support/Holos/ReadingLibrary`, so it survives relaunching; a file moved away
  shows as missing. Quitting while a reading is made asks Keep Rendering (continues at the
  next launch) or Stop. The source parsing, the index store, the queue and its stop and quit
  logic, the voice order, the speed mapping, and the pipeline's new progress reports are
  unit-tested; the section itself is built and compiled only and has not been seen on screen
  yet (docs/dictation-validation.md "Reading section").
- Dictation history (docs/design.md "Dictation history"): each finished dictation that
  produced text is kept in `Application Support/Holos/History/dictations.jsonl` (0600, one
  JSON line each) with its app, language, text as written and as heard, fixes, outcome,
  length, and word count, for 30 days by default (Settings: Off, 7 days, 30 days, Forever;
  swept at launch and daily). History lists them by day with search, shows the words the
  fixes changed, and offers Copy, Copy As Heard, Correct…, Delete, and Clear History….
  Refused (secure-field) and cancelled dictations are not recorded, the text is never
  logged, and only an explicit Copy writes to the clipboard. `voiceislocal history list
  [--json] [--limit N]` and `history clear --yes` script it. Reads stream the file line by
  line (Forever never becomes unreadable); a partly written dictation keeps the rest Copy
  Result offered, which History's Copy copies; quitting waits (bounded) for queued history
  writes. The store, the in-app history service (flush, reloads merged with changes made
  meanwhile), and the record rules are unit-tested; recording from live dictations has not
  been checked on screen.
- Dictation audio and Run Again (docs/design.md "Dictation audio and Run Again"): each
  recorded dictation's microphone audio, the frames the recognizer took, is kept as
  `History/audio/<id>.m4a` (AAC mono 16 kHz, ~32 kbit/s, 0600) and linked from its record,
  unless Settings › History and privacy › Keep the audio of dictations is off (it shows the
  disk use; turning it off offers to delete the audio kept). Cancelled, refused, and
  unrecorded dictations leave none; Delete, Clear History, and the retention sweep remove it
  with the text, and sweeps also remove audio without a record and stale partial files.
  History plays it (▶/⏸, Space) and Run Again (⌘R) recognizes it again with today's
  language, corrections, filler removal, and Apple Intelligence fix, then compares then and
  now word by word and names the steps that behaved differently; Copy New Result and Update
  History… act only on request. `voiceislocal history rerun <id|latest>` and `rerun --all
  [--since 7d] --json` do the same from Terminal. The writer (a synthesized tone through
  format changes), the store's audio lifecycle (append, Delete, Clear, sweep, orphans,
  partials, removing all audio), the service's handling of the setting and History Off, the
  frame tap, the text steps with a stand-in fix, the comparison, and the JSON shapes are
  unit-tested. The end-to-end test that renders a sentence with AVSpeechSynthesizer and
  recognizes it again skips when the test process has no en-US speech model (it skipped on
  the development Mac, where the test runner and the CLI report that model as supported, not
  installed).
  Nothing of it has been seen on screen or tried with real dictation yet.

- Cloud reference (developer tool, CLI only; [details](reference-evaluation.md#cloud-reference)):
  `voiceislocal eval cloud` sends a session's audio to OpenAI (`gpt-transcribe` by
  default) after showing the minutes, requests, and estimated cost and getting a yes; the
  audio leaves the Mac, so it needs the consent of everyone recorded. Segments of at most
  5 minutes are cut at pauses, each answer is saved as it arrives, failures are retried,
  and a stopped run resumes. `eval compare` gives WER against both transcripts and the
  differing passages by kind (echo filtered as in the exports); `eval review` writes an
  offline HTML page with the audio to decide each passage and mark terms; `eval apply`
  makes a reference transcript and proposes heard → meant corrections, added only with
  `--add-corrections`, and the marked terms, added to the word list only with
  `--add-vocabulary`, each under its file's lock (the app takes it too and reads the
  file again when it changes). `--vocabulary` sends the word list, people's names, and
  correction words, in the recognizer's order. Results
  stay in the session's `eval/` folder; Delete Audio removes the page's audio copy. The
  segmenting, stitching, cost, consent gate, HTTP layer (faked: request shape, retries,
  resume), alignment, WER, grouping, review page, decisions, and apply are unit-tested;
  one 16 s synthetic clip was sent to the real API. It has not been run on a real meeting.

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
When a meeting's speakers are labelled, the computer's audio heard again by the
microphone (3 or more matching words) is removed from the transcript; acoustic echo
cancellation is not implemented, and a meeting without speaker labels keeps the echo.

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
speakers, end to end on a call and a hybrid call), the one meeting mode (the start
settings with the computer's audio on, off, or not allowed; the launcher arguments; the
microphone-only start check; meeting.json of a recording; the track plans of in-person,
call, and hybrid sessions), meeting languages (the passage-by-passage choice and its
smoothing on synthetic transcriptions; the language stage with scripted speech: the merge
made current, transcriptions reused and never redone, a missing speech model or a failed
transcription keeping the transcript, edited labels needing `--force`, cancellation, and
languages recorded by a recording and an import), the review window's model (changes
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

Meeting languages were run end to end (`session import`, then `session languages
--languages fr-CA,en-CA`) on the user's private 3 h 43 min bilingual (French and English)
recording, in a temporary sessions folder: 37.4 % word error rate against Otter, against
46.5 % for French alone and 77.0 % for English alone (the spike that chose the method
measured 37.5 %), and 19.7 % on turns that mix the two languages (French alone: 35.1 %). The
stage took about 4 minutes. On an English-only 20-minute control, recorded as French with
English detected, it kept no passage in French and matched English alone (10.9 %). Otter is
another recognizer, not ground truth; see docs/meeting-design.md §4.14.

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
- Run the [Setup Assistant checks](dictation-validation.md#setup-assistant), including
  dictating with Input Monitoring switched off for Voice is Local (expected to work with
  Accessibility alone; not yet confirmed on the target Mac).
- Run the [main window and history checks](dictation-validation.md#main-window-and-history):
  the window's layout in light and dark mode, ⌘0, ⌘1–⌘5, ⌘, and ⌘F, Full Keyboard Access
  and VoiceOver, a dictation recorded in History with its app, language, and text as
  heard, Copy only on request, retention Off, and Clear History. None has been run yet.
- Run the [dictation audio and Run Again checks](dictation-validation.md#dictation-audio-and-run-again):
  audio kept and played, Run Again after changing a correction, Off stops keeping audio,
  Clear History removes it. Not run yet.
- Run the [word list checks](dictation-validation.md#word-list): terms added in the app
  and in Terminal reach the next dictation, the card's paste, search, ⌫ and count, and
  whether the listed terms are recognized more often. Not run yet.
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
  Settings, automatic relabel after a shutdown, a meeting on the laptop speakers with people
  in the room and on a call, the system audio setting and a missing System audio permission,
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
  may be consumed until the key is released. The clipboard is written only when the
  user chooses Copy Result or Copy Original.
- Meeting languages: the review window shows the merged transcript but cannot change a
  turn's language; `session languages` redoes the whole meeting. The live transcript stays
  in the first language. Where two passages in different languages meet, a word can appear
  twice or not at all.
- Meeting word fixes: Review can revert one fix at a time, and `session fix-words` maps the
  current speaker labels and effective edits to the changed word positions without
  relabelling. A Review revert is kept by automatic processing until `session fix-words` is
  explicitly requested. `--force` labels speakers again (names carry over, turn-level changes do
  not). `eval local` applies the same fixes to its candidate by default; `--no-word-fixes`
  keeps the recognizer's words for comparison. The model is asked one place at a time (at
  most 500 per run).
- Deep transcription: meetings in several languages are not transcribed again yet; accuracy was
  measured on one meeting; the app's queue, Settings row and menu have not been seen on screen.
- Live transcript: selecting a finalized phrase while recording can correct its text or name
  its speaker. The app saves a timed hint, carries text into the final/replayed transcript,
  learns safe correction pairs, keeps a shared pair until the last confirming live edit is
  undone, and applies speaker names after diarization before export.
  The first one or two volatile words of a microphone echo can show briefly (the echo rule
  needs a run of three words), and an echo heard before the system track's words arrive
  shows until they do.
- Speaker names and edits: labels are "Speaker N" until named in the review window or
  with `voiceislocal speakers`. The review window has no redo, and its undo does not reach past
  a relabel (Find More Speakers keeps names, not turn-level changes). Find More Speakers is
  off for a call whose two tracks were both split into speakers, because a minimum speaker
  count cannot be asked of two tracks at once. Recognition thresholds come from a small
  calibration (two recordings of one team); suggestions for a person recorded in the
  other condition (room vs call) are less reliable. Speaker counts are approximate:
  quieter or briefer speakers can merge into others. Nothing deletes old meetings
  automatically.
- OCR. `read` supports local files, stdin, and `https://` web articles; a scanned PDF
  without a text layer is refused. PDF paragraphs and Word/RTF headings are guessed from
  line lengths and fonts. Web pages behind a sign-in or paywall fail with a hint to save
  their text to a file; `http://` is refused; code blocks, tables, and figures are not
  read; some bylines and "min read" lines leak into the spoken text.
- Broader install/update/uninstall packaging and the T14 acceptance run.

`reference-data/` is for private, user-provided evaluation material and is excluded
by `.gitignore`. Raw recognizer outputs and comparison reports stay under ignored
`.local/evaluation/`. Human-reviewed accuracy and correction evaluation still need
a reviewed, held-out set; the exported product text is not assumed to be ground truth.

For the planned task definitions and acceptance criteria, see
[implementation.md](implementation.md); this status page records milestone evidence
and gaps and does not mark every planned task complete.
