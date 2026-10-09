# Deep transcription

The deep transcription pass after a meeting.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.16 Deep transcription after meetings

Added after wave 5, outside the PR plan. The user's request: "make the after-the-fact
transcription smarter": capture live, then after the meeting (minutes, hours, or overnight;
time does not matter) produce a correct transcript, fully local.

*Evidence (measured on the user's real meetings; numbers only).* On a 53-minute meeting's
system track, scored against a cloud transcription (gpt-transcribe) as the reference, Apple's
transcript had 20.9 % WER and 31 of 82 word-list terms right; Whisper large-v3-turbo run
locally with the word list as its prompt had 11–14 % WER and 56–66 of 82 terms. At places
the user had labelled it wrote the right names, and it never turned "cloud" (computing) into
"Claude". Through WhisperKit on an M4 Pro it took about 186 s per 53 minutes of audio, 1.2 GB
at peak. Failure modes seen: "Thank you." / "Thanks for watching" segments over silent
stretches (43 in a 107-minute meeting with a 9-minute capture gap), and with whisper.cpp
(not WhisperKit) a 7.5-minute loop repeating one sentence; WhisperKit's temperature
fallback avoided that loop on the same file, and the pass guards against both anyway.

**Engine.** `WhisperKit` 1.1.0 (argmaxinc/WhisperKit, MIT; Core ML on the Neural Engine) in
target `HolosWhisper`, which only the command-line tool links; the app runs the pass through
`voiceislocal`. Model `openai_whisper-large-v3-v20240930_turbo` from
`argmaxinc/whisperkit-coreml` (about 1.6 GB). `DeepTranscriber` (HolosCore) is the seam:
`engine` ("whisper:<model>"), `promptTokenCount`, `transcribe(samples, language, prompt)`;
tests use scripted fakes and never download or load a model. `WhisperKitTranscriber` decodes
with the meeting's language (Whisper's token: "en" for "en-CA", and Whisper's own spelling where
it differs, "no" for Bokmål "nb", "tl" for Filipino "fil", "jw" for Javanese "jv"; a language
Whisper does not know is detected instead, since WhisperKit would put the English token in its
place), the prompt's tokens on every
chunk, `chunkingStrategy .vad`, word timestamps, and WhisperKit's default temperature fallback
and compression-ratio, log-probability and no-speech thresholds; it loads from the install
folder only (`download: false`).

*Word times with a prompt* (`PromptAlignedSegmentSeeker`). WhisperKit 1.1.0 stores each decoder
position's alignment weights at its absolute index, and with a prompt the decoder input
starts with `<|startofprev|>` and the prompt's tokens, while `addWordTimestamps` reads the
rows from `<|startoftranscript|>`: every word was aligned with the weights of a token
`prompt + 1` places earlier. On invented speech after 4 s of silence, a short prompt put
the first seven words at the segment's start, in the silence, and the rest over a second early. The seeker
(given to WhisperKit as its `SegmentSeeking`) moves the weights up by those rows before
WhisperKit aligns the words, keeping Core ML's padded row stride (1504 for 1500 frames; a
first version that ignored it put every word 0.8 s late with that prompt and 8 s late with a
110-token one). After it, the word starts with a 39- and a 448-character prompt matched the
ones without a prompt within 0.05 s, except the first word with the long prompt (0.6 s
early); the opt-in model test checks this.

*Timestamp rules with a prompt* (`PromptTimestampRulesFilter`). WhisperKit's
`TimestampRulesFilter` finds where sampling begins by looking for `<|transcribe|>` among the
first three tokens, and for a multilingual model applies no rule when it is not there, which
is always the case after a prompt. The filter (WhisperKit's custom logits filter) finds the
task token wherever it is and applies the same rules from the token after `<|0.00|>`;
without a prompt it leaves the logits to WhisperKit's own.

*Chunks and the prompt* (`WhisperKitTranscriber`). The pass cuts each piece into WhisperKit's
voice-activity chunks itself (`VADAudioChunker`, at most 30 s each) and decodes them with
`transcribeWithOptions`, so a chunk whose decoding fails is seen and decoded again on its own
(WhisperKit's own `.vad` path drops it without a trace). A chunk that fails again fails the
pass (`incomplete`, naming where the audio starts): the transcript is kept and the record is
partial, rather than a "successful" transcript that silently leaves up to 30 s out (which
recovery would also count as holding all of the audio). Even with both fixes a prompt can
make the model stop early in a chunk: on ten minutes of a real call's system track, the words
of the recorded transcript with no Whisper word within 3 s were 30 of 1,820 without a prompt,
433 with a 10-term invented prompt, and 383 with the timestamp fix. So each chunk is decoded
without the prompt too, and keeps the prompted result only when it has at least 85 % of the
plain result's words: 0 of 1,820 left uncovered, 7 of 28 chunks kept without the prompt, at
about 2.8 times the time of a plain pass (70 s for the ten minutes on the test Mac).

*Empty chunks* (found by evaluating the first version against a cloud reference). Whole chunks
still came back with no words at random, in both decodes, and the dropped 20–30 s stretches
gave the system track 725 deletions (Apple's: 192; plain `whisperkit-cli` with the same prompt:
425). A decode that is empty is `<|startoftranscript|><|en|><|transcribe|><|0.00|><|endoftext|>`
at temperature 1.0: WhisperKit's first-token log-probability check (`firstTokenLogProbThreshold`,
−1.5 by default; Whisper itself has no such check) judged the first token unlikely, which a prompt
makes common, and sent the chunk through every fallback temperature to an end-of-text. On the
piece of the call at 572–1144 s, 12 of about 40 prompted chunks were empty with it, none of the
audible ones without it. So the check is off (the compression-ratio and log-probability
fallbacks stay). Chunks are also at most 20 s (a 110-token prompt leaves about 110 tokens of
WhisperKit's 224 for the words, which 30 s of fast speech can exceed), and a chunk that still
gives no words over audio above −50 dBFS is decoded again in two halves split at its quietest
100 ms (twice at most, down to 4 s halves). A decode's words count its text when it has no word
timings, so the plain-or-prompted choice never takes text for silence. A stretch above −50 dBFS
that is still empty after the halvings is reported (`DeepTranscribedSegment.unheard`), and the
pass fails (transcript kept, record partial) when the recorded transcript has at least 3 words
there: speech it would leave out. Empty stretches on a track at most 1 s apart (the halves of
a retry, the pieces of one stretch) are joined before their recorded words are counted, so
words spread over several of them still count together. Where the recorded transcript has fewer (music, noise, a
quiet room's hum), the empty stretch is accepted: the live recognizer's words are the speech
evidence, rather than an energy-based voice detector that cannot tell music from speech.

*Audio the chunking leaves out* (`WhisperKitTranscriber.plan`). WhisperKit's chunker only picks
where to cut (the middle of the longest silence in the second half of each 20 s window), so its
chunks follow one another, except that it stops when less than a second is left: that tail
is joined to the last chunk (any stretch under a second between chunks is joined to the chunk
before it). Each request also carries the starts of the recorded transcript's words in its
samples (`DeepTranscriptionRequest.recordedWords`, mapped from session time through the
render's time map), so audio a chunker leaves out where the recorded transcript has at least 3
words is decoded too (in pieces of at most 20 s, those with a recorded word), and a stretch with
recorded words that comes back empty is reported as unheard even when it is quieter than −50
dBFS, for the same lost-speech rule. A chunking that hears nothing of the recorded speech
therefore cannot make the pass publish without it.

**Model files** (`WhisperModels`). `<supportRoot>/Models/whisperkit/<model>/` (or
`$HOLOS_WHISPER_MODELS_DIR/<model>/`), as WhisperKit's Hugging Face download lays it out,
with the large-v3 tokenizer (`models/openai/whisper-large-v3/tokenizer.json`, fetched by the
first load) and `installed.json` written last. `voiceislocal setup --whisper [--force]`
downloads into `<model>.download/` (kept on failure, so the next run resumes: the downloader
continues partial files; `--force` deletes it first and downloads everything again), loads the model once there, writes the marker, and renames it into
place (swapping out an older install). Status from files only: `installed` (marker, Core ML
models, tokenizer), `downloading` (another process holds `.<model>.install.lock`), else
`notInstalled`; `voiceislocal doctor` prints it (`deepTranscriptionModel` in `--json`).

**Stage 1b′ `deepTranscription`** (`DeepTranscriptionStage`), after the languages stage and
before live text hints, only with `PostProcessingOptions.deepTranscribe`; `keepTranscript`
skips it.

1. *Which transcript.* The current transcript's unfixed base (`WordFixStage.unfixedID`). When
   that base is a deep transcript (`Transcript.engine` "whisper:…"), the recorded transcript
   it replaced is the one its `deepTranscribed` event names; otherwise the current transcript
   is the recorded one.
2. *Skips.* A meeting with several languages in meeting.json, or a current transcript merged from
   several (one made in a single language named with `session languages` has `languages` too
   and is transcribed again, in that transcript's language):
   `skipped`, "This meeting is in several languages; deep transcription handles meetings in
   one language for now, so the transcript was kept." (WhisperKit can detect a language per
   window but not limit detection to the meeting's languages, so v1 does not try.) A base this
   model made already: `succeeded`, "The meeting was already transcribed with Whisper
   large-v3 turbo.", unless `force` (checked first: a deep transcript in another language,
   made with `--any-language` or by an earlier version, is kept). A meeting in one language
   other than English (the language of the transcript of step 1, else meeting.json's first,
   else the recording's): `skipped`, "Deep transcription is tuned for English meetings; this
   meeting keeps Apple's transcript.", unless `PostProcessingOptions.deepAnyLanguage`
   (`session deep-transcribe --any-language`, to try it). `force` never lifts it, so the
   app's Make Final Transcript Now (which passes `--force`) is checked again when it runs, and
   the app never passes `--any-language`. On a real 3.7 h meeting in French and
   English, Whisper's French was worse than Apple's (status.md), so other languages wait for
   validation on real recordings; `DeepTranscriptionStage.languageProblem` holds both rules,
   and the command, the app's queue and Make Final Transcript Now ask it
   (`SessionDeepTranscribeCommand.languageProblem`). Edited speaker labels of the current transcript:
   `skipped` with "Speaker labels were edited, so the meeting was not transcribed again. …
   run voiceislocal session deep-transcribe with --force." (checked again under the
   publication's locks). Words changed in Review (an edit, or an automatic fix reverted:
   `TranscriptWordEdit.hasReviewEdits`) are kept the same way unless forced, here and in the
   languages stage. Deleted audio, no audio, the model not installed, an unreadable
   vocabulary.json or words.json: the transcript is kept and the record says why.
3. *Prompt* (`DeepTranscriptionPrompt`, pure). "<meeting name>. <term>, <term>, …." with the
   word list's terms and the names of the people the app knows; the ones this meeting's
   vocabulary.json holds come first (in its order), then the rest of the word list, then the
   other names; each spelling once. Capped at 110 tokens of the model's tokenizer:
   WhisperKit 1.1.0 keeps only the last 111 prompt tokens (its `Constants.maxTokenContext` is
   224, half of Whisper's 448, and a prompt gets half of that less one) and cuts the start of
   a longer one, which is where the meeting name and this meeting's terms are. Each candidate
   is counted as it sits in the list (" Term,"), added while the sum fits, skipped (and the
   next tried) when it does not; the whole prompt is counted once at the end and trimmed from
   its end if it still exceeds the budget. A meeting name that alone exceeds it is left out.
4. *Audio.* Each track, one at a time: `TrackRenderer` to `derived/deep-<track>-16k.caf`
   (16 kHz mono, gaps over 60 s shortened to 5 s, the disk check of stage 4), deleted once
   transcribed. Read in pieces of at most 600 s, each ending at the quietest 100 ms of its
   last 30 s, so a long meeting is never in memory whole and no word is cut. Segment and word
   times map back to session time through the render's time map (`RenderTimeMap.
   sessionTime`, linear inside a span). Output over the silence the render inserted for a
   shortened gap (outside every span) is discarded rather than snapped to a span edge, where it
   would stretch across the whole gap and escape the silence guard: a word there is dropped (by
   its middle), a segment with words in two spans becomes two, an untimed segment keeps its part
   in one span, and an empty stretch keeps its parts in spans.
5. *Guards* (`DeepTranscriptGuards`, pure). Per track: a segment whose audio is below
   −50 dBFS RMS and where the recorded transcript has no word within 0.5 s is dropped
   (`droppedSilent`); then each repeat past the first of 3 or more consecutive segments with
   the same text (lowercased, letters and digits), each starting within 5 s of the end of the
   one before, with no other track's speech (other text than theirs, so an echo does not count)
   starting between them, is dropped (`droppedRepeats`): the same short answer said again
   minutes later, or given to each of several questions from the other side, is not a loop. The
   threshold, measured on a 53-minute call (both tracks, the recorded transcript's word
   spans against one-second windows with no word near them): words' p1 −47 dBFS (mic) and
   −43 dBFS (system), p50 −22 and −21; wordless seconds' p50 −64 and −72. Below −50 dBFS
   lay 0.6 % and 0.4 % of the words but 75 % and 92 % of the wordless seconds, and a quiet
   word the live recognizer heard still keeps its segment by the second condition.
6. *Segments.* Words are joined as Whisper spaced them (punctuation it wrote as a word of its
   own joins the word before), each a `TimedWord` with its UTF-16 offset, start, end and
   probability as confidence; a segment without word timings keeps its text untimed. New
   segment IDs. Live hints reconcile by track, time and words, as for any new transcript.
   Nothing recognized while the recorded transcript has words keeps the transcript.
7. *Publication*, as the languages stage: under the writer and speaker locks, the
   edited-labels check again, `deepTranscribed {transcriptID, base, engine, language, tracks,
   seconds, segments, words, droppedSilent, droppedRepeats, promptTerms, promptTokens}`, then
   `saveTranscript` (the recorded transcript stays as a revision). Cancellation publishes
   nothing; a cancelled or killed pass starts over next time (it is cheap enough).
8. *Downstream.* Live text hints (1c), word fixes (1d, whose revisions keep `engine`),
   speakers (relabelled because the transcript changed; names carry over), recognition and
   exports run as after a recording. Microphone echo of a call is found by `EchoFilter` on
   the new words exactly as on Apple's. Recovery treats a deep transcript as standing for the
   recorded one (`TranscriptRebuilder.recordedTranscriptID`, followed back through language
   merges and deep transcripts in any order, never around a loop: rebuild R, `session
   languages` revision M, deep D stands for R, as does a revision M of a deep D of R) and
   as holding all of the saved audio (`mergeHoldsAllAudio`), as it does a merge. A cancellation
   after the publication leaves the new transcript current with the later stages maybe
   unfinished; the command says so (and to run `session diarize`) instead of claiming the
   transcript was kept.
9. *No transcript yet.* A session recorded with `--record-only` or imported with
   `--no-transcribe` has saved audio and no transcript; the pass makes its first one (stage 1
   is `skipped`, the languages stage does not run, and the meeting's language is meeting.json's
   or the manifest's). With no recorded words to look for, the silence guard drops every
   segment over near-silent audio (the level alone). Nothing recognized: no transcript is made
   and the record is `failed` ("No transcript was made. …", exit 1).

**Evaluation against a cloud reference** (the same call's system track, the user's scorer:
jiwer after normalization, terms of the word list; `eval local --backend whisper` with today's
vocabulary and word fixes): Apple 20.9 % WER (192 deletions), 31/82 terms; plain
`whisperkit-cli` turbo with the same prompt and VAD 13.7 % (425 deletions), 63/82; this pass
before the empty-chunk fix 19.5 % (725 deletions), 58/82; after it 14.6 % (521 substitutions,
339 deletions, 293 insertions), 63/82 (+3 extra). Recorded words with no word of the candidate
within 3 s on that track: 349 before, 56 after. The candidate took about 15 minutes for both
tracks (106 minutes of audio, with the test suite running alongside).

**Validation** (a copy of the user's 53-minute call, both tracks, release build on the M4
Pro; numbers only). The pass took 1,163 s for 6,348 s of audio (about 11 minutes per hour of
audio with each chunk decoded twice; an earlier version without the plain decode took 890 s),
772 MB at peak. It wrote 1,208 passages and 15,786 words (the recorded transcript: 17,193,
fillers and microphone echo included), left out 14 passages over silence and 2 repeats, and
the prompt held 26 terms (96 tokens). Against the recorded transcript's word times (aligned
by text in 5-minute windows): median |Δstart| 0.12–0.13 s, 94 % within 0.5 s, 98 % within 1 s
(before the stride fix: a constant +7.6 s). Recorded words with no deep word within 3 s:
about 65 s of speech per track (217 and 269 words), against about 500 s per track before the
timestamp rules and the plain-chunk check. Speakers were labelled again on it with names
carried over.

**App.** The app does not link WhisperKit; it runs `voiceislocal setup --whisper` and
`voiceislocal session deep-transcribe <session> --json` as maintenance commands
(`HolosApp+DeepTranscription.swift`). The passes are a kind of background job (`DeepTranscriptionJobs`) that
`BackgroundJobCoordinator` runs with the echo catch-up (online-calls-echo.md §5.11): it owns the lock probe, the holds, preemption, the
retries and the order between them (`BackgroundJobOrder`).

- *Settings › Meetings.* A "Final transcript" row with the model's state from `voiceislocal
  doctor --json` (`deepTranscriptionModel`) and Download (1.6 GB), showing `setup --whisper`'s
  progress; and the checkbox "Deep transcription after meetings", off by default and disabled
  until the model is installed (UserDefaults `deepTranscriptionAfterMeetings`; turning it on
  records when, `deepTranscriptionEnabledSince`). While it is off, automatic items are dropped
  from the queue (`dropAutomatic`), except the one the app's own pass is running on, which goes
  when it ends: at launch, on every 30 s tick, and after every pass however it ended (a busy
  exit, a preemption), so none is left behind to come back when it is turned on again. Run Now
  items stay. While another process downloads the model, the doctor check runs again every 30 s;
  while the model is not installed and the setting is on or Settings shows, every 60 s, so an
  install started in Terminal is noticed (and its meetings found, as on any change to
  installed). When doctor cannot run at all the row says the tool is missing.
- *Queue* (`DeepTranscriptionQueue`, `DeepTranscriptionSchedule`, pure, in HolosMeeting). When
  the recorder reports a meeting finished (its own post-processing ran in the recorder), the
  meeting is queued if the setting is on, the model installed, and neither meeting.json nor the
  current transcript names more than one language (read off the main actor; when the read ends,
  the meeting is queued only if the setting did not change meanwhile and the user did not act
  on it: not in the queue, not considered, so a Run Now asked for and cancelled meanwhile stays
  cancelled). The queue is saved in UserDefaults
  (`deepTranscriptionQueue`) on every change. Whenever the model becomes installed (doctor's
  first report at launch, or after it was missing or downloading) and whenever the setting is
  turned on, the meetings that finished while the app was closed (read off the main actor, and queued only if
  the setting is still on, with the same activation time, when the read ends) (a recorder saves and post-processes on its
  own after the app quits), started since the setting was turned on, finished (not recording,
  processing, or interrupted), in one language, with no `deepTranscribed` event and never queued
  before (`deepTranscriptionConsidered`, never capped: forgetting one could queue a meeting the
  user cancelled), are queued too; so are meetings that finished while the model was missing.
  The next pass runs when none is running, no meeting is starting, recording, or saving, the
  model is installed, and no other command or Review uses the meeting (`MeetingController.
  sessionsInUse`, `sessionsUnderReview`: open, opening, or still saving): a meeting asked for from its menu first, whatever the power source; else the
  oldest queued meeting when the setting is on and the Mac is on AC power (or has no battery),
  otherwise it waits ("Final transcript waits for power"). The power source (IOKit's providing
  power source) is read every 30 s, which also retries the queue; a command letting go of a
  meeting retries it too. A meeting picked whose folder is gone (deleted while queued) is taken
  off the queue and the next ready one is picked in the same call (`nextPresent`).
- *Running.* The pass holds the meeting (`beginUsing`, "Final transcript in progress…" in the
  State column, other actions on it refused) and is taken off the queue however it ends (done,
  partial, refused, or cancelled). A Make Final Transcript Now pass that does not finish (exit 1
  or 3, or killed) says why in an alert: the messages of the stages its `--json` record says
  failed (and of the deep transcription stage when skipped), else its last error line
  (`DeepTranscriptionSchedule.failureText`); one the user cancelled says nothing.
- *One pass at a time* (`DeepTranscriptionLock`). `session deep-transcribe` takes an exclusive
  `flock` on `<supportRoot>/deep-transcription.lock` for its whole life and writes `{pid,
  sessionID, force}` into it once it holds it; a second pass finds it held (it retries for 2 s,
  since a probe holds it for an instant) and exits 1 with "Another final transcript, meeting
  summary or echo analysis is running…". The kernel lets go of the lock when the process ends,
  however it ends. `session summarize` (titles-summaries.md §4.17, `kind` `summary`) and `session echo-analyze`
  (online-calls-echo.md §5.11, `kind` `echo`) hold the same lock.
- *The app manages only its own pass.* A lock held by any other process (a pass started in
  Terminal, or one the app started before it was quit, since maintenance commands are
  detached) only means "busy": the app starts nothing while it is held, checks again every
  30 s, and its queued meetings show "Waiting for another final transcript to finish". It never
  adopts such a pass, never holds its meeting, and never cancels, preempts, or signals it (it is
  the user's own run, or one that finishes on its own). The app's own child is signalled (Cancel,
  a meeting starting) by its spawn pid, which no other process can have until the app reaps it.
  The queue saves no process identity (keys an earlier version saved, `pid`, `pidStart`,
  `started`, `verifyOnly`, are ignored). A pass cut short by a quit or a crash, or still running
  from before a relaunch, stays queued and runs again once the lock is free, with the flags it
  was queued with: an automatic one without `--force`, so the command keeps a transcript the
  model already made (a no-op); a Run Now one with `--force`, so a Run Now whose pass did finish
  before the quit is transcribed a second time (a known cost, accepted for simplicity). Turning
  the setting off keeps the running pass's item until it ends. A command refused by the
  processing lease (another command on the meeting) stays queued and only its meeting waits a
  minute (`delayed`): the next ready meeting runs meanwhile. One refused by the lock (another
  pass started a moment before), or one that cannot be started at all, stays queued and
  everything waits a minute (`passEnded`).
- *Review waits.* Opening Review (from Meetings, or the menu bar's Name Speakers, all through
  `openReview`) for a meeting the app's pass works on (its `sessionsInUse` entry) says "Final
  transcript in progress" and that Review opens when it finishes, which it then does, and offers
  Cancel Final Transcript. For a meeting another process's pass works on (the lock's holder)
  it says so and opens nothing. The scheduler already leaves meetings open in Review alone.
- *Stale scans.* Every turn of the setting on or off counts an activation; the after-meeting
  language read and the launch check snapshot it and drop their result when it changed, so a
  scan begun before the setting was turned off never queues afterwards, even if it was turned on
  again. Launch-time results are also checked against the queue and the meetings considered
  right before each is queued.
- *Meetings first.* When a meeting starts (or one that failed may still be capturing or
  post-processing, by its recorder's liveness, or a recorder the app launched has not exited,
  even without a session folder: `MeetingController.recorderMayStillRun`, which a start checks
  too) while the app's pass runs, the pass is stopped (SIGTERM; it publishes nothing) and stays
  queued, so it runs again from the start once the meeting is saved, but only when the signal
  ended it (exit 143, 128 + SIGTERM, as the command's cancellation and a killed process both
  report it): a pass the signal reached after it had already ended (done, failed, or partial)
  ends as it did, with its alert for a Run Now. Another process's pass is left
  running. A pass cancelled after it already published its transcript says so in an alert (the
  labels and files may be behind: Label Speakers finishes them). Maintenance commands, like this one, keep running after the
  app quits.
- *Meetings list.* The State column shows "Final transcript queued", "… waits for power",
  "Waiting for another final transcript to finish", or "… in progress…". Right-clicking a finished meeting offers Make Final Transcript Now
  (relabels speakers): it runs next, also on battery, with `--force`, so a transcript the model
  made before is made again and edited speaker labels are replaced (names carry over, edits of
  single turns do not), as asking for it by name means; refused with an alert without the model,
  for a meeting that is not finished, or for one the pass does not transcribe (several
  languages, or one other than English: Make Final Transcript Now passes `--force`, so the app
  checks first, and the pass checks again when it runs). A meeting queued
  automatically offers it too (it upgrades the item, so it runs next whatever the power source).
  The request is reserved at once, before its languages are read off the main actor, and saved
  with the queue (`pending`; a quit meanwhile does not lose it: the languages are read again at
  the next launch): the meeting is not started meanwhile (a queued automatic item would run
  without `--force`), shows as queued, and is considered; a Cancel meanwhile ends the
  reservation, and a refusal (its language) leaves the meeting as it was. The automatic queue
  takes only meetings the pass transcribes (`transcribable`).
  While a meeting is queued or the app's own pass runs on it, Cancel Final Transcript (SIGTERM: the command cancels and says whether the new
  transcript was already published).
- *Tests.* `BackgroundJobCoordinatorTests` (with a fake runner and clock: Run Now, then the echo analysis, then an
  automatic pass; a Run Now still reading its languages; the first echo scan; a Summarize Again scan; summaries
  looked for before the next job; meetings busy, in use or under review; the lock held by another process; a pass
  or analysis stopped for a meeting and run again; Cancel; a meeting turned down (a minute for a pass, longer each
  time for an analysis); the lock refusing a pass; a failed start; a failure not tried again in the launch; a
  deleted meeting), `BackgroundJobTests` (the order), `DeepTranscriptionQueueTests` (order and run-now upgrade, saving and damaged data,
  one at a time, AC/battery/no battery, busy meetings, meetings in use or in Review, run-now on
  battery, the setting off, queuing only one-language meetings, the State column's texts,
  commands refused for another process, an earlier version's queue read without its process
  fields, a pass cut short running again with its flags, waiting for another process's pass,
  the failure text of Run Now, finished states, the launch check), `DeepTranscriptionLockTests`
  (held only while taken, the holder read while held, a second pass refused, a holder not
  written yet). The Settings row, the menu, the alerts, Review waiting, and the power switch
  are not exercised by tests and need a manual check.

**Contract additions.** `Transcript.engine: String?` (left out of the JSON when nil),
`PostProcessingStage.deepTranscription`, `MeetingEventKind.deepTranscribed`.

**CLI.** `voiceislocal session deep-transcribe <session> [--force] [--json]`
(`SessionDeepTranscribeCommand`): a precheck first (unfinished recording, deleted or missing
audio, several languages, model not installed or still downloading) exits 1 with nothing
changed (a session left `processing` by a recorder that died while saving counts as unfinished:
Recover first); a run with nothing to do (the transcript is this model's, no `--force`) needs
neither the model nor the audio (deleted since, it is not an error); then the post-processor with `deepTranscribe`: exit 0 done, 3 partial (exports
written, but the pass was skipped or failed, or speaker labelling was), 1 failed.
`voiceislocal eval local <session> --backend whisper [--language …]` makes a local candidate
in the current transcript's language (as the pass chooses it) with the same rendering, prompt (recorded in run.json as `prompt`, the candidates as
`vocabulary`, `engine` set) and guards, so `eval compare --local latest` scores it against a
cloud run. Its run.json records the transcript the guards compared with
(`referenceTranscriptID`, empty for a run begun without a transcript, which stays unguarded),
which a resumed run reads again, and is schema 2 with `backend` "whisper" (the meeting's own in
`meetingBackend`), which an older Voice is Local cannot read, so it never resumes the run with
Apple's recognizer. A run resumed with `--run` keeps the language it began with, whatever the
current transcript's is now. Without `--language`, a meeting whose meeting.json or current
transcript names several languages is refused, as the pass refuses it (`--language` evaluates
one of them). A current transcript that cannot be read is an error, never a run without a
reference. An explicit `--language` Whisper has no token for is refused. Each track's render
needs the same free space as the pass's (the render plus 1 GB), checked before it is written.

**Tests.** `DeepTranscriptionTests` (prompt order and cap; quietest cut; time mapping through
a shortened gap; word offsets and punctuation; the silence guard needing both conditions,
tracks, untracked reference segments; repeat runs per track; end to end with a scripted
transcriber: a new revision relabelled and exported with the recorded one kept, a second run
keeping it and `--force` redoing it against the recorded transcript, edited labels refused
then forced with names carried, labels edited while transcribing, word fixes and live
corrections on the new text, call echo still dropped, a failed or empty pass, cancellation,
the precheck's refusals, ordinary post-processing never running it, recovery bookkeeping, and
`eval local --backend whisper`), `WhisperModelsTests` (status, staged install with a fake
download and load check, resume after a failed load, removal, the prompt rows and the moved weights, the timestamp rules after a prompt, the plain-chunk rule). Opt-in:
`HOLOS_WHISPER_MODEL_TESTS=1 HOLOS_WHISPER_MODELS_DIR=<installed folder>` transcribes invented
speech (rendered by the system synthesizer to a file, never played) in a session end to end;
`HOLOS_DEEP_MEASURE_SESSION=<copy of a session>` prints the level measurements above, `HOLOS_DEEP_COMPARE_SESSION=<copy that deep-transcribe ran on>` the word-time agreement and uncovered stretches, and `HOLOS_DEEP_PROBE_SESSION=<copy>` (with `HOLOS_DEEP_PROBE_PROMPT`) the coverage of ten minutes of one track.

**Follow-ups.** Languages other than English, once validated on real recordings; meetings in several languages. A notification when a final transcript
is ready. Measuring the vocabulary terms the pass gets
right against a cloud reference on more meetings (`eval local --backend whisper`, then `eval
compare`), now that the prompt is checked chunk by chunk. Upstream reports for the three
WhisperKit prompt problems worked around here.
