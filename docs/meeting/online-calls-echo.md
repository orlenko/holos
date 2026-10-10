# Online calls and echo

Online-call refinements: the echo filter, the acoustic echo analysis and the headphone warning. §5.11 comes from the
build plan and names the PR that built it; the code cites it for behaviour.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 5.11 PR11: Online-call refinements (wave 5)

**Goal.** Cleaner call transcripts: drop microphone echo of system audio, hide
microphone clusters that are mostly echo, and warn when laptop speakers are the output.
("Mic = Me" is a track policy in PR5a/PR7b and condition-tagged samples ship in PR10;
resolution R13.)

**Files.**

- Add `Sources/HolosSpeakers/EchoFilter.swift`, `Sources/HolosAudio/OutputRoute.swift`.
- Change `Sources/HolosSpeakers/SpeakerRunBuilder.swift` (apply the filter when
  `parameters.echoWindowSeconds != nil`; a microphone cluster with at least 60 % of its
  words dropped as echo is not listed and its remaining turns become unknown speaker),
  `Sources/HolosMeeting/PostProcessing/SpeakerAnalysis.swift` (call sessions use
  `AlignmentParameters.v1` with `echoWindowSeconds = 1.0`),
  `Sources/HolosApp/MeetingStartPanel.swift` (warning line),
  `Sources/HolosMeeting/RecordingWorkflow.swift` (set `echoRisk` at start and after
  device changes in call mode), `Sources/HolosCLI/Record.swift` (stderr warning).
- Fill "Online calls (PR11)" in `docs/meeting-validation.md`, including the hybrid case
  of H16.
- Tests: `Tests/HolosSpeakersTests/EchoFilterTests.swift`, `Tests/HolosAudioTests/OutputRouteTests.swift`
  (pure classification only). PR11 owns `Fakes.swift` and `SessionFixtures.swift` edits
  in wave 5.

**API.**

```swift
public enum EchoFilter {
    /// Microphone spans to drop: runs of at least `echoMinRunWords` consecutive mic words whose normalized
    /// text (lowercased, letters and digits only) equals, in order, consecutive system words, each mic word
    /// within ±echoWindowSeconds of its system counterpart.
    public static func echoSpans(transcript: Transcript, parameters: AlignmentParameters) -> [WordSpan]
}
public struct OutputRoute: Sendable, Equatable {
    public var name: String
    public var isBuiltInSpeakers: Bool
    /// Default output device: transport built-in and data source 'ispk' → speakers; 'hdpn' → headphones.
    public static func current() -> OutputRoute?
    /// Pure classification used by `current()`, for tests.
    public static func classify(transportType: UInt32, dataSource: UInt32?) -> Bool
}
```

Dropped words go to `run.droppedWords` with reason `echo` and appear in no turn and no
export. Consecutive matches extend one run only while both tracks stay inside
`EchoFilter.echoRunGapSeconds` (2 s): matches further apart are separate utterances and
each starts a new run, so the same short word said on both tracks three times over a call
never adds up to the three-word minimum. A microphone cluster hidden as echo is also taken
out of the overlap metadata of the words that survive, so no turn is marked overlapped
with a cluster the run does not list as a speaker (which would also keep a real room
speaker's turn out of voice enrollment). Warning text (start panel, CLI, `echoRisk`): "The laptop speakers are playing
the call, so other people's voices also reach your microphone. Headphones give a
cleaner transcript."

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `threeWordEchoRunIsDropped` | system "we should vote now" at 10.0–11.2; mic same words at 10.3–11.5 | mic span of 4 words dropped |
| `singleMatchingWordIsKept` | mic "yes" matching system "yes" | kept |
| `outsideWindowIsKept` | same words 1.5 s later | kept |
| `droppedWordsExcludedFromTurnsAndExports` | run with echo | words absent from turns and Markdown; listed in `droppedWords` |
| `echoHeavyMicClusterIsHidden` | mic cluster with 70 % of its words dropped as echo | cluster not listed; its remaining turns unknown speaker |
| `inPersonSessionsDoNotFilter` | meeting mode inPerson | no spans |
| `builtInSpeakersClassification` | ('bltn', 'ispk'), ('bltn', 'hdpn'), (USB, nil) | true, false, false |

**Acoustic echo (added 2026-10).** The text filter only finds echo the recognizer heard as
the same words. On laptop speakers it also hears garbled copies, which became most of a
call's microphone turns (one 53-minute call: 571 of 883 turns were "Unknown" microphone
fragments). The acoustic analysis compares the audio instead: where the microphone and the
system audio say the same thing, only the system's words stay; microphone speech that is
genuinely local (the user, or people in the room) stays even while the call plays.

- `Sources/HolosSpeakers/EchoAnalysis.swift` (pure; Accelerate), on 16 kHz session-time
  audio (`EchoAudioSource`; the post-processor reads the stage 4 renders through their time
  maps, `RenderedEchoAudio`):
  1. *Delay.* GCC-PHAT of 10 s windows every 30 s (every 10 s under 5 minutes) where the
     system plays (RMS > 1e-4; a window may end at the last sample, so a 30 s call has three),
     lags −0.3…1.5 s; a window is confident when its largest |correlation| (either sign: a
     microphone of inverted polarity records the echo upside down) is over 20× the median
     |correlation|. Two starts are refined by least squares three times on the windows within
     3 ms, and the one more windows agree with wins: a robust (Theil–Sen) line, so an outlying
     window cannot drag it away from the rest (its slopes from at most 512 windows spread
     evenly, about 4 hours' worth, so memory stays bounded), and a constant delay at the median, for few
     windows with an outlier at an end (the delay drifts a few ms per hour between the two
     tracks' clocks).
  2. *Gate.* Echo is present only when at least 3 windows, and at least 30 % of the windows
     where the system plays, are confident and on the line, and the delay stays between 1 ms
     and 1.5 s. Otherwise (headphones; no or silent system audio) nothing is masked. A zero
     lag is one signal recorded twice, not the room.
  3. *Model.* STFT, 1,024-sample Hann window, 256 hop (16 ms frames), bins 150–4,000 Hz. Per
     5 s block and bin, an 8-tap complex filter (one frame after the delayed system frame to
     six before, ≈ −16…+112 ms) predicts the microphone from the system spectrum: ridge
     (1e-3 × mean diagonal) least squares on the frames where the system plays (power over
     3× the block's 20th percentile), then two refits without frames whose residual keeps over
     a quarter of the microphone power. Blocks run in parallel.
  4. *Frames* (`AcousticEchoMask`). Floors: 15 s minimum of the 31-frame mean power. Silence:
     microphone < floor + 10 dB. Local: residual within the threshold of the microphone level
     and ≥ floor + 10 dB; the threshold is −8 dB, raised toward −3 dB per 30 s where the echo
     is poorly cancelled (90th percentile of the residual ratio of echo-dominated frames + 1
     dB); 5-frame (80 ms) majority smoothing. Echo: every other active frame.
  5. *Words* (`AcousticEchoMask.isEcho`). A microphone word is echo when under 30 % of its
     active frames are local frames the word rule trusts (`trustedWordFrames`, worked out once
     per mask, each local frame judged by a bounded window around it, never through runs or
     stretches that can grow): (a) its predicted echo is 20 dB or more below the microphone, or
     absent (`negligibleEchoDB`: smoothing can leave one local frame of a quiet sound); (b) at
     least 3 local frames within 18 frames (288 ms) of it have the predicted echo more than 6 dB
     below the microphone (`supportFrames`; support comes only from those frames, so it cannot
     chain along later runs); (c) in the 31 frames (496 ms) centred on it at least half are
     local and most local ones have the predicted echo below −1 dB (`sustainedWindowFrames`,
     `sustainedDensity`, `sustainedLevelDB`): speech in the room makes the microphone louder
     than the echo alone (−3 dB at equal loudness), syllables leave brief gaps, while poorly
     cancelled echo predicts 0 to +3.5 dB in runs of 3–5 frames; (d) in its utterance (local
     frames at most 3 frames apart: smoothing fills shorter gaps), at least 3 local frames lie
     within 15 frames (240 ms) of it and most of them are below −1 dB (`utteranceReachFrames`),
     however far from other speech; the reach bounds it, so echo running on after speech turns
     back within 240 ms. Any other local frame is
     the call cancelled poorly and counts as echo. Playback keeps #108's stretches only
     (2026-10-08; before,
     every local frame counted, and the scattered false-local frames of poorly cancelled echo
     made echo words microphone turns and
     "Unknown" rows). A word with no active frame is echo only when the predicted
     echo explains its energy (median echo − microphone ≥ −5 dB; a frame with no microphone
     sound or no predicted echo, such as a gap in the recording, explains nothing). A word past
     the last frame, without times, or with estimated times (a segment without word timing) is
     kept.
- *Storage.* `echo/mask.json` (`EchoMaskRecord`, schema 1: verdict, delay fit, frame counts,
  the SHA-256 of the frames, analysis seconds) and `echo/frames-<sha>.bin` (one class byte
  per frame, then one byte per frame of predicted echo level in 0.5 dB steps; about 450 KB
  per hour). One limit sets the longest call: `EchoMaskStore.maximumSeconds` (12 hours, so
  `maximumFrames` is 2.7 million); the reader takes frames files up to it, and a longer call is not analysed
  but saved with verdict `tooLong`, which hides nothing and counts as done. The record is
  keyed to the audio (`SessionManifest.audioFingerprint` of the mic and system chunk lists, which
  include each chunk's SHA-256) and to `EchoAnalysis.version`; any other key is out of date
  and analysed again, but one of a newer schema or a newer analysis version (checked before
  the record is decoded) is refused and left alone, never overwritten. It is in the
  meeting folder because `derived/` is deleted after every run; Delete Audio leaves it (it
  holds no speech). The summary counts in it are recomputed from the frames when read. The
  frames file is named by its content, so a new analysis writes its own file, then switches
  the record to it, then deletes the others: a failure in between leaves the old mask in use.
  A save takes the speaker lock, and an edit made on a view shown with another mask than the
  one saved now is refused like one made on another run (`SpeakerEditor`).
- *Where it applies: the view only.* Stored runs never hold acoustic echo: they keep the text
  filter's drops exactly as before, and nothing that writes runs or edits knows the mask.
  `SpeakerSessionSnapshot.load` reads the mask (`EchoMaskStore.usable`: none when it is
  missing, out of date, damaged or from a newer build) and `SpeakerProjection.make(acousticEcho:)`
  hides the microphone words it flags, after the edit journal is applied to the stored turns
  (docs/meeting/speaker-labels.md §4.9 step 6). Review, exports, summaries, search, live speaker hints and voice learning all
  read that projection; voice learning and voice matching leave out turns cut by echo
  (`ProjectedTurn.cutByEcho`), since a turn's voice data covers its echo. Not through it, on
  purpose: relabel decisions and name carry-over (`SpeakerAnalysis.headState`, matched against
  a new run that holds the echo too), forget clean-up (it must reach every word a person owns)
  and evaluation scoring (diarization quality).
- *Turns.* A turn keeps its ID and speaker and leaves out the words the mask flags; its start,
  end and timing quality are those of the words left, and its talk time (sidebar, exports) is
  the sum of its runs of shown words, without the echo between them. A turn that loses every word is not
  shown, and a speaker with no turn shown is not listed. Edits work as without echo: the words a
  split is chosen from are the words shown, each named by its place in its segment (`WordRef`),
  so the split lands at that word of the stored turn; assign and undo name the turn. The
  journal only ever names stored turns and words, so it does not depend on the mask shown.
  Short interjections (docs/meeting/review-window.md §5.10) are decided after the mask, on the words it leaves: a turn
  of an echo cluster shown as unknown, or one the mask cut down to "Yeah.", is a candidate
  like any other, and the exports leave hidden ones out as they leave out echo.
- *Out of date when the mask changes.* The transcript files record the mask they were written
  with (`.generated.json` `echoMask`: `EchoMaskStore.identity`, the SHA-256 of the frames and the
  word rule's version, "<sha256>+words2"; none without a mask), and
  `SessionExports.filesState` calls them out of date when it is not the one the labels show now,
  so the app offers Update Transcript Files. A new word rule (`AcousticEchoMask.wordRuleVersion`)
  is a new identity for the same frames: files written under an earlier rule (which recorded
  the SHA-256 alone) are out of date, and the echo catch-up (`needsAnalysis`, through
  `echoMaskIsCurrent`) runs `echo-analyze` on them, which keeps the saved analysis and rewrites
  the files and the voice samples the new view changed. A summary made under the earlier rule
  is out of date when the rule hides different words (`MeetingSummaryKey` hashes every
  rendered line), so with automatic summaries on it is made again, once, like after an edit. A meeting whose audio was deleted keeps its analysis (Review uses it): the catch-up
  looks at it too, and `echo-analyze` rewrites its transcript files from the saved analysis
  and removes a voice sample the new view changed (only a new analysis needs the audio; no
  sample can be computed again without it). Recover rewrites them whenever they are, whatever
  else it did (`echoMaskIsCurrent`; a rewrite left pending counts as out of date). The people
  cache and the summary schedule key on the echo files' stamps. The mask is saved under the
  speaker lock (lease, then speakers, then profiles), and a voice sample is published only if
  the echo files did not change while it was computed. A sample's freshness comes from the
  files: its input digest covers the turns the masked view lets it use, so
  `VoiceProfileService.refreshSamples` (as after an edit) recomputes or removes one whose turns
  the mask changed and leaves the rest alone. Every post-processing pass that ends with labels
  runs the echo check and this sync once (`MeetingPostProcessor.checkEcho`: in stage 4b before
  recognition, with the head the sample was learned from, or after labels that were kept or
  left as they were; no lock held), every entry point names its `VoiceSampleSource` (`.none`
  only where samples are left to a later pass), every Recover
  and every `echo-analyze` run it when they have a voice extractor, whether or not they saved a
  mask, so a sync that failed is retried by the next pass and nothing records it as done. A
  sample learned from an earlier run is kept when the new labels give none only while its own
  turns, in that run seen through the mask, still give its digest; otherwise (or when that run
  cannot be read) it is removed.
- *Recognition.* Post-processing compares voices only for clusters the view lists with the mask
  (`RecognizeStage.withoutEcho`): a microphone cluster that is echo sounds like the far end and
  must not take a person's match from the system speaker. The mask exists by then (stage 4b).
- *Echo clusters.* A diarized microphone cluster with at least `echoClusterShare` of the words
  of its machine turns flagged is echo itself: turns still given to its speaker show unknown
  speaker, and no turn names it among its overlaps, unless the user named or linked that
  speaker. (The text filter's own cluster rule still runs when the run is built.)
- *Analysis needed* is worked out from the files, never recorded as pending work: a call with
  microphone and system audio, its audio kept, and no saved analysis of that audio and this
  version (`EchoAnalysisStage.needed`); any saved verdict counts as done, and so does one a
  newer build saved. Post-processing makes it in stage 4b when needed (also for edited labels
  stage 3 keeps, and when no track is diarized); its `echo` stage outcome is for reading only.
  A failure saves nothing, so the next pass tries again. Recover makes a missing analysis once
  per run (unless its post-processing just tried). Transcript files are rewritten after a save
  by `echo-analyze` and Recover with the speaker lock, then `profiles.lock`, held while people's
  names are read (docs/conventions.md §1.7 order).
- *Existing meetings.* `voiceislocal session echo-analyze <id|path> [--force] [--json]`
  (`SessionEchoAnalyzeCommand`) saves the analysis and rewrites the transcript files through
  the projection. Nothing else changes: speaker labels, edits, the transcript and its word
  fixes stay as they are on disk. For its whole life it holds the background job lock (docs/meeting/deep-transcription.md §4.16,
  `kind` `echo`; `Request.jobLock`), so it runs alone with final transcripts and summaries, and a
  run that outlived the app that started it is seen as busy after a relaunch; another holder
  makes it exit 1 with the lock's busy message, nothing changed. Post-processing and Recover make
  the analysis in-process without the lock, as before (a final transcript's own post-processing
  runs under its pass's lock). Ctrl-C or SIGTERM cancels it (exit 143 for SIGTERM, "Stopped. Run
  the command again to finish…"): before it starts, and before or while the voice samples are
  recomputed (minutes on a long call); the analysis and the transcript rewrite, seconds, are not
  cut short. What it leaves is read as done or owed: the mask is saved in one step under the
  speaker lock, an interrupted export rewrite stays `pending` (`SessionExports.echoMaskIsCurrent`
  false), and the samples are saved together or not at all (`samplesOutOfStep` true), so the
  next run, or the app's next scan, finishes it.
- *Catching up in the app.* Calls recorded before the analysis existed (or whose analysis
  failed) get it without a command (`EchoCatchUpSchedule`, `EchoCatchUpJobs` run by `BackgroundJobCoordinator`
  with final transcripts, `HolosApp+EchoCatchUp.swift`; no
  setting: about 5 s per hour of audio). At launch and after each meeting is saved the app
  reads the sessions folder off the main actor and queues every finished meeting
  (`DeepTranscriptionSchedule.isFinished`) the command has work on
  (`EchoCatchUpSchedule.needsAnalysis`: the analysis is needed, `EchoAnalysisStage.needed`, or it
  is saved but the transcript files were not rewritten for it, `SessionExports.echoMaskIsCurrent`
  false, or a voice sample learned from the meeting was not brought in step with it,
  `VoiceProfileService.samplesOutOfStep`, read only), newest first. Nothing about it is saved: a run a quit cut short leaves the analysis
  missing, or the files out of step with it, so the next launch finds it again (run again, the
  command keeps a saved analysis and finishes the files and the voice samples). One meeting at a time, the app runs `voiceislocal session
  echo-analyze <path> --json` as a maintenance command (so the transcript files and the voice
  samples learned from the meeting follow, exactly as the command does them), after reading
  `needed` once more (a relabel, Recover or a run in Terminal may have made it since). It
  shares the one-job-at-a-time rule of final transcripts and summaries (docs/meeting/deep-transcription.md §4.16, docs/meeting/titles-summaries.md §4.17): nothing
  starts while a meeting starts, records or saves, while this app makes a final transcript or a
  summary, or while any process holds the background job lock; while it runs neither of them
  starts. The command holds that lock itself (`kind` `echo`), so a run the app started before it
  was quit (maintenance commands are detached and keep running) holds the relaunched app's queue
  back instead of running beside it, as does one started in Terminal; the Meetings list says
  "The call's echo is being removed from this meeting." for its meeting
  (`SessionCatalog.jobInProgress`), Rename waits for it, and it never counts as another final
  transcript (`isDeepPass`). A run refused by the lock (taken a moment after the app looked) is
  tried again later (`retryLater`), never a failure. Priority: a Make Final Transcript Now
  that is ready (or has its languages read) and a Summarize Again the summary scan going on may
  start go first; the echo analysis goes before automatic final transcripts and automatic
  summaries, which wait while a queued meeting is ready for it and while a scan goes on (the
  first of the launch, or one after a meeting was saved: the queue is not known yet); each scan's
  end looks for them again. When a meeting starts (records or saves) while this app's run goes
  on, the child is stopped by its spawn pid (SIGTERM) and stays queued (`RunEnd.stopped`, only
  when the signal ended it: exit 143), neither failed nor delayed, so it runs again once the
  meeting is saved and finishes what the stopped run left; a run another process started is left
  alone. Meetings in use or under
  Review (open, opening or saving) wait and are tried every 30 s. A run turned down because
  another process held the meeting or the lock (or it records again) is tried again after 1, 2, 4… minutes,
  at most 30; a meeting whose run ended (done, failed or partial) is not tried again until the
  next launch, and a run that finds nothing to do leaves an earlier result in the list. The Meetings list shows
  "Echo removal queued" on waiting meetings and "Removing echo…" (the meeting's use,
  `MeetingController.beginUsing`) on the one running; a failure shows "Echo not removed" and the
  selected meeting's status line says why in the command's words; exit 3 (saved, but the
  transcript files or a voice sample not brought in step) says so in the status line. A run
  holds the meeting as a maintenance command does (`ReviewMaintenance.Command.echoAnalysis`): a
  Review opened while it runs opens read-only and, when it ends, rereads the labels, so the
  window takes the new mask (`ReviewEchoMaskFollow`) and its microphone volume follows; one that
  finished opening after the run ended rereads the meeting too (`maintenanceEnded`).
- *Playback.* `AcousticEchoMask.localSpeechIntervals()` gives the microphone's own
  speech: runs of local frames, joined into stretches across gaps under 300 ms
  (`localStretches()`, `stretchGapSeconds`; the word rule has its own, wider trust, `trustedWordFrames`); a stretch is
  kept only when at least 3 of its local frames (`evidenceFrames`) have the predicted
  echo more than 6 dB below the microphone (`evidenceDB`); kept stretches are padded
  64 ms before and 200 ms after. The review window plays the microphone only there (docs/meeting/review-window.md §5.10,
  echo-free playback). The evidence rule (2026-10-08) answers echo heard in review on a call
  through laptop speakers: where the call's speech is cancelled poorly, the frame rule calls
  short runs of a few frames local all through it, their predicted echo at or above the
  microphone's level (or a steady 3–5 dB under it), and each one, padded and joined to the
  next, opened the microphone at full volume over seconds of echo. On the 8 echo masks on
  the developer's machine (5.6 hours of calls), local stretches are either without such a
  frame or have many: 73 % of 3–5-frame stretches have none, and 84 % of stretches of 20
  frames or more have 10 or more. Before, after: microphone on 3,811 s, 2,581 s; echo frames
  played 1,110 s, 372 s; microphone on where the echo dominates (echo frames at least three
  times the local ones within ±0.5 s) 1,308 s, 307 s; local frames with the predicted echo
  12 dB or more below the microphone kept 100 %, 99.8 %. Of the stretches of 20 frames or
  more, 102 of 1,045 are dropped; 70 of those have a median level at or above 0 dB, which
  speech in the room added to the call cannot give (it makes the microphone louder than the
  echo alone). The quieter double-talk frames (−12 to −3 dB) are kept 74 % (a stretch with
  louder frames keeps all of its own). Considered and not taken: a minimum stretch length
  (13 frames cut the echo further but dropped 7 % of the clearly local frames, short sounds
  over a quiet call) and a partial volume for doubtful stretches (it still plays the echo,
  only quieter).
- *Measuring the word rule.* `voiceislocal session echo-label-stats <session>… [--json]`
  (hidden; `SessionEchoLabelStats`, `EchoLabelStats`) compares, for each call given, the
  labels under the word rule before the evidence requirement
  (`AcousticEchoMask.countingEveryLocalFrame()`) and now, and prints one line per session (by
  session ID) and a total; counts only, never text, names, word times or paths. Example
  (synthetic numbers): `<ID>: mic words 1200, judged 1150; user's 420 -> 350 (local->echo 70
  [in echo 62, elsewhere 8], echo->local 0); in echo 95 -> 30; mic rows 140 -> 118, unknown
  41 -> 22; rows changed 35`.
  Judged words are those the mask judges as the labels do (not dropped by the text filter, not
  edited in Review, timed); "user's" are judged words not echo; "in echo" are those whose
  ±0.5 s surroundings hold at least three times as many echo frames as local ones (local->echo
  is split the same way: "elsewhere" are likelier the user's own words lost, and both are
  bucketed by the median predicted echo over the word's local frames, ≥0, −1..0, −3..−1,
  −6..−3, <−6 dB, and by its share of local frames, 30–50, 50–80, ≥80 %); rows are
  the microphone rows Review shows (short interjections applied, then consecutive turns of one
  speaker grouped into rows by `ReviewParagraphs.group`), "unknown" those without a speaker;
  "rows changed" the microphone rows (matched before and after through a shared turn) whose
  turns, words or speaker differ (a short
  interjection hidden under both rules is none). Each argument is resolved on its own: one that
  names no session (missing, a symbolic link, an unknown ID) is listed by its place ("#3: not
  measured (unreadable)") without its path or the reason. A session that is recording, has no
  usable mask, no transcript, or cannot be read is listed as not measured; it exits 1 only when
  none was measured. It only reads, takes no lock, and changes nothing: it is the one `session`
  command that does not first resume a pending forget of voices (`ForgetResumeScope`), which
  can delete and rewrite files.

Validation. Synthetic tests (`Tests/HolosSpeakersTests/AcousticEchoTests.swift`,
`Tests/HolosMeetingTests/AcousticEchoMeetingTests.swift`): the delay to within 1 ms (also an
inverted microphone, a 30 s call, outlying windows); echo-only frames echo, local bursts
local, local speech over the call at echo level kept, gaps in the recording kept;
headphones, missing or silent system audio, and one signal on both tracks are no-ops;
playback keeps sustained local speech with its lead and double-talk from its weak first run,
and leaves scattered local runs the call explains muted; the word rule makes words with
scattered false-local frames echo, keeps double-talk and quiet speech without predicted echo
the user's, counts only the frames it trusts for a word partly in them, and trusts more than
playback opens (a word can stay the user's while its audio stays muted); files written under the earlier word rule are out
of date and `echo-analyze` rewrites them; the stats count words, rows and unknown rows and
print no text; the projection hides echo words from turns that keep their IDs, a split chosen among the words
shown lands at that stored word (assign and undo too, through the review), hides echo
clusters, keeps a named speaker whose turns are all echo with its name and assignments, and
changes with the mask alone; a word fix across an echo boundary is judged once; stale,
damaged and newer masks are ignored; exports equal the view, go out of date when the mask
changes, and Recover rewrites them; recognition skips an echo cluster; post-processing, Recover and
`echo-analyze` change no stored speaker file. On three real calls (copies), against the
research reference: delay 46.1 / 46.3 / 46.4 ms (+5.1 / +4.3 / +4.3 ms/h); leftover
"Unknown" microphone words hidden 1,356/1,489, 1,352/1,468, 1,479/1,645 (91 / 92 / 90 %);
the user's own words hidden 11/638 and 11/441; words while the system was silent hidden
2/364, 0/294, 1/4; microphone turns shown 571 → 94, 585 → 103, 714 → 110 (all turns
883 → 406, 837 → 355, 996 → 392); all 8 edits of the edited meeting apply, and its stored
labels are byte-identical. The analysis took 1.8–2.1 s per hour of audio on the development
Mac, about 5 s per hour with both renders (release build).

**Does not touch.** `Sources/HolosApp/Review/*`, `ReviewSession.swift`, `MeetingsWindow.swift`,
`SpeakerProjection.swift`, `Package.swift`, README and `docs/status.md` (PR9 writes the
wave-5 docs from PR11's "Docs note").
