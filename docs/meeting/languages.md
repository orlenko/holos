# Meeting languages

One language per meeting, and several languages detected after the recording.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.14 Multi-language meetings (LANG1, LANG2)

Added after wave 5, outside the PR plan. The user's request: "we should be able to specify
(in phase 1) a single language for the dictation and meetings; and in phase 2, a list of
languages that are detected automatically, so that mixed meetings (e.g. montreal
English+French mix or other multilingual environments) can be transcribed correctly,
through post-processing. It's ok if post-processing takes a while, we don't care about
instantaneous meeting feedback. The dictation stays monolingual."

**Phase 1 (LANG1, PR #43).** The start panel's Language pop-up (the dictation languages,
`DictationLanguage.groups`) sets the meeting language; UserDefaults `meetingLocales` keeps
a list, the first used; `MeetingStartSettings.locales`; the recorder gets
`--locale=<first>`; the manifest records one `locale`. Settings without a language (never
from the start panel, which keeps Start off until it has one) record in the recorder's
default, `AppleSpeechEngine.defaultLocale`, in process and as a child alike (§4.1).

**Phase 2 (LANG2).** A meeting may name up to three languages (`DictationLanguage.
maximumMeetingLanguages`), each a different language (`sameLanguage`: language and script;
"fr-CA" and "fr-FR" are one language, "zh-CN" and "zh-TW" two). The first is transcribed
live, exactly as before; after the recording, post-processing transcribes the saved audio
again in each language, merges the transcriptions passage by passage, and makes the merge
the current transcript before speakers are labelled, so speaker labels, exports, and the
review window use it.

*Evidence (spike on the user's private 3 h 43 min bilingual board meeting against Otter,
numbers only).* Both SpeechTranscribers ran over the same audio at about 100× real time
each; every word has a time and a confidence (`transcriptionConfidence`). Choosing the
language per fixed 3 s window with the sum rule below, and switching only after 2 windows
agree, gave 37.5 % WER against 46.5 % for French alone; 19.8 % on turns that mix languages
against 34.9 %; an English-only control meeting stayed at 10.9 % with no window chosen
French. Choosing per turn gave 41.8 %; splitting at pauses did not help.

**Contract additions** (§3.0 allows new optional fields and open-code constants):

- `MeetingInfo.languages: [String]?` (meeting.json), the recording's own locale first,
  written only when there are several; nil in older sessions and for one language.
- `PostProcessingStage.languages`.
- `MeetingEventKind.languagePass` (`transcriptID, language, tracks, seconds`) and
  `MeetingEventKind.languagesDetected` (`transcriptID, base, languages, requested,
  source.<language>, windows, windows.<language>, switches`, and `fallback`: the language
  the recorded transcript stood in for, when it did). It can be journaled again for the same
  transcript with another `requested` (step 2); the last one naming a transcript counts. One
  whose `base` is empty names a transcript that is not merged (the recording's own) and
  only records the languages named for it.

Outside the frozen files: `Transcript.languages: [String]?` and `TranscriptSegment.language:
String?` in `Models.swift` (optional, left out of the JSON when nil, so older transcripts
and single-language ones encode byte for byte as before); `SessionArchive.
saveTranscriptRevision(_:)` (HolosStorage), which saves an immutable revision without
making it current and, in an archive from before `transcripts/current.json`, writes the
pointer first so the new revision never becomes current by being the newest;
`AppleSpeechSession.make(…, accurate:)` (final results only, no `fastResults`).

**Session folder.** Each language's transcription is a revision `transcripts/<UUID>.json`
(`locale` its language, `languages` nil) that is never current, journaled as
`languagePass`. The merge is a revision with `languages` set and each segment's
`language`, journaled as `languagesDetected` before it is saved as current.

**Stage 1b `languages`** (`Sources/HolosMeeting/PostProcessing/LanguageStage.swift`), after
stage 1 and before the speaker stages, in every caller of `MeetingPostProcessor` (the
recorder, `session diarize`, `recover`, `import`, the app's relabels):

1. *Which languages.* `PostProcessingOptions.languages` when given (`session languages`);
   else meeting.json's `languages` (two or more) while the current transcript is not
   merged, or when it was merged automatically from them (`requested` of its
   `languagesDetected`) but missed one (a speech model installed since) or had the
   recorded transcript stand in for one (`fallback`). A transcript
   merged from languages named on the command line, or kept for them (step 2), is never
   replaced automatically: its last `languagesDetected` names other languages than
   meeting.json's. `PostProcessingOptions.keepTranscript` (`session diarize
   --keep-transcript`, which every relabel from the review window passes) skips the stage,
   so a speaker action there never transcribes the meeting again under the open review. A
   meeting in one language records no stage at all, so its `postprocess.json` is unchanged.
   A session with saved audio and no transcript (`record start --record-only`, `session
   import --no-transcribe`) gets its first transcript from languages named on the command
   line (stage 1 is `skipped`, "This meeting has no transcript yet; it is made from the
   saved audio."); a failure then says "No transcript was made. …" and the record is
   `failed`. Without languages named, such a session still has nothing to label.
2. *Done already.* A current transcript merged from exactly these languages, with none
   stood in for (or, for one language, the recording's own when it is complete, as step 4
   defines), is kept: `succeeded`, "The transcript was already made from …". When the
   languages were named on the command line and the transcript's last `languagesDetected`
   names others (a merge made automatically from meeting.json's three languages that missed
   one, then `session languages` with the two it has), `languagesDetected` is journaled
   again for the same transcript with `requested` set to them, its other details kept (for
   the recording's own transcript: its `languages` and an empty `base`), under the writer
   lock; so is a merge that stands for them (step 5). A narrower request is thereby durable,
   and a later run without languages named keeps the transcript. A failure to journal it
   keeps the transcript and makes the record `partial` with why.
3. *Edited labels.* When the head run was built from the current transcript and has
   applied edits (names carried over by a relabel count), the stage is `skipped` unless
   languages were named with `force` (`session languages --force`) ("Speaker labels were
   edited, so the languages were not detected again. To detect them and label speakers again
   (names carry over), run voiceislocal session languages with --force."), checked again
   when the merge is published, under the speaker lock the publication holds (step 6).
   `force` alone (`session diarize --force`, Find More Speakers) relabels the speakers but
   never detects the languages over edited labels.
4. *Transcriptions.* For each language: the last `languagePass` after the last
   `archiveRecovered` whose revision reads (resumable); else a new one, one language after
   another, every track through `TrackReplayer` (the session vocabulary, the stop path's
   time limits, progress "Transcribing the meeting in French (Canada)…" reported at most
   once per whole percent, as rendering does) with
   `AppleSpeechSession.make(accurate: true)`, saved with `saveTranscriptRevision` and
   `languagePass` under the writer lock (held only for the save). A transcription whose
   save fails still goes into this merge (logged; a later run cannot reuse it). A
   transcription with no words at all, while the current transcript has some, counts as
   failed ("… was not transcribed: no words were recognized."): it is neither saved nor
   reused. Languages are compared as `DictationLanguage.identifier` spells them (hyphens and
   BCP 47 case), so an older recording's "en_CA" and a given "en-ca" are both "en-CA". The
   session vocabulary is read as the rebuild reads it: missing or damaged is none, but one
   written by a newer Holos is refused (`failed`, "Kept the transcript as it was.
   vocabulary.json was written by a newer version…"), never read as none; likewise
   meeting.json, which gives the echo parameters. The recorded transcript
   (the base: the current one, or the one a merge's event names) stands in for its own
   language only when that language cannot be transcribed again, and never when it is
   incomplete: the manifest says `transcriptionIncomplete`, or a rebuild saved it without
   transcribing while saved audio runs past its phrases (`transcribed: false` and a track's
   audio beyond its `coverageEnd`, `TranscriptRebuilder.leftAudioUntranscribed`: `recover
   --no-transcribe`, whose status is `recovered`); the stage message and the record's message
   then say so ("… The recorded transcript stands in for it."), `languagesDetected`
   records it as `fallback`, and a later run tries that language again. Speech models are
   checked first (`assetStatus`, each check within `speechFinishBase`; only `installed`
   transcribes) and nothing is transcribed when the
   languages that could be had would not make a merge.
5. *Fail soft.* A language that cannot be had (its model not installed, "downloading", or
   unsupported; a model check, speech error, or time-out; deleted audio) is left out with
   the reason. The
   merge needs the first language and, when several were asked for, two. Otherwise the
   current transcript stays (`failed`, "Kept the transcript as it was. English (Canada) was
   not transcribed: its speech model is not installed. Install it from the meeting start
   panel or with voiceislocal setup --locale en-CA, then choose Label Speakers in Meetings
   to detect the languages again."). Label Speakers runs this stage first, so it picks the
   language up once its model is installed (nothing does so on its own). Meetings offers
   it for labelled speakers too while that is so: the catalog lists the languages missed
   or stood in for (`SessionSummary.languageWork`, `LanguageStage.pendingLanguages`, files
   only), the window checks their speech models off the main actor
   (`SessionCatalog.checkingLanguageModels`, `LanguageWork.ready` from
   `LanguageStage.hasPendingWork`), and `MeetingActionPolicy.labels` enables Label Speakers
   when it is ready. The status line keeps the reason: the record's message while the
   model is missing, "Spanish (Spain) is missing from the transcript. Choose Label
   Speakers to detect the languages again." once it can be detected, and, with edited
   labels (which Label Speakers keeps), that `session languages --force` detects it.
   `session diarize` without speaker models runs when there is such work (`hasPendingWork`,
   not with `--keep-transcript`): the languages are detected and the speakers stay
   unlabelled, as after a recording without speaker models; otherwise it still refuses. A
   missing language makes the post-processing `partial` (exit 3) with that reason first in
   the message; speakers are still labelled. When nothing new can be added (the same
   languages as the current merge, the same one stood in for), the current merge stands.
6. *Merge and publish.* `LanguageMerge.merge` (pure); a merge that kept no words never
   replaces a transcript that has some (`failed`, "Kept the transcript as it was: no words
   were recognized in …"). Then, under the writer lock and the speaker lock (in that order,
   as deletion takes them), the edited-labels check of step 3 once more, and
   `languagesDetected` and `saveTranscript(merged)`, so a speaker edit is either seen by the
   check or waits until the merged transcript is current. The stage message: "Kept French
   (Canada) in 61 % of the passages and English (Canada) in 39 %, with 171 switches."; the
   record's message (and so the app's finished message) starts "Transcribed in French
   (Canada) and English (Canada)." Speaker
   labelling then sees a new transcript and relabels (names carry over, §4.9). A
   cancellation publishes nothing; saved transcriptions stay for the next run. Taking a lock
   can wait without seeing a cancellation (the speaker lock polls for up to 2 s), so
   cancellation is checked again with the locks held, before a pass is saved and before
   the journal and save of the merge (the rebuild's save too).
7. *Recovery.* `session recover` keeps a rebuild whose transcript was merged since (the
   merge's `base` names it, `TranscriptRebuilder.recordedTranscriptID`). A merge whose
   sources are all transcriptions of the saved audio after the last recovery (or the base
   standing in, which it does only when it leaves no audio out) holds all of the audio
   (`TranscriptRebuilder.mergeHoldsAllAudio`), so a rebuild made with `--no-transcribe`
   (`transcribed: false`) counts as transcribed for it: Recover reuses the rebuild instead of
   rebuilding over the merge. Recover does not call the labels up to date while this stage
   would do work now (`LanguageStage.hasPendingWork`, as the stage decides: a language
   stood in for or missed that can be had now, such as its speech model installed since,
   and speaker labels that were not edited), so Recover after installing a missing speech
   model detects it; while it cannot be had, or with edited labels, Recover changes nothing
   (a `partial` record whose speaker stages went as they would again, the languages stage
   having made it partial, counts as up to date: `SessionRecoveryCommand.
   speakerStagesSettled`), rather than labelling the speakers again on every run.

The stage runs inside the recorder's post-processing, so the app's next meeting can start
only once it ends (`.finishing`, `stillSaving`): about 3 more minutes for a 3-hour meeting
in two languages. The stop alert says "about 2 minutes for a 3-hour meeting, or about 5
when it also detects languages" and that the next meeting can start once it has.

**The merge** (`LanguageMerge`, `Sources/HolosMeeting/PostProcessing/LanguageMerge.swift`,
pure; `NaturalLanguageScorer` in `LanguageIdentification.swift` is the live scorer):

1. Per track, words go into fixed 3 s windows of session time from 0 by their middle
   ((start + end) / 2); a segment without timed words moves as one unit that weighs its
   whitespace-separated words (for echo, rule 5, its echoed words among them).
2. A window where one language has words takes it. Where several do, each scores its
   words' mean confidence (0 without any) plus the probability that its text there is in
   its own language, from `NLLanguageRecognizer` with `languageConstraints` set to the
   candidates' languages and the hypotheses normalized over them; the highest wins, a tie
   the language listed first.
3. Over the windows with words, the language changes only where 2 consecutive windows
   choose the same new one, at the first of them; the track starts in the language of the
   first such run (so a lone first window does not set it); windows without words keep the
   previous choice and do not break a run.
4. A window keeps its language's words only. A segment whose words are all kept is kept
   whole; a run of kept words from part of a segment becomes a segment `<id>/<first word>`
   cut from the text at the recognizer's UTF-16 offsets (the words' own texts joined with
   spaces when the offsets do not fit). IDs stay unique (`<id>/<language>` on a collision).
   Where two languages meet, a word can be kept twice or not at all; the measured error
   includes that.
5. *Echo in calls* (added in review). Each track is merged on its own, so a lone echoed
   window on the microphone could be smoothed into the other language, keep another
   recognizer's words than the system track's, and escape the speaker stages' echo filter
   (§5.11). So in a call the stage runs `EchoFilter.echoSpans` on each language's own
   transcription (`Candidate.echo`), and a microphone window where at least half of a
   language's words are echo takes that language (the system track's choice there, or the
   one before, when several hear echo; else the most echo words), outside the smoothing.

**Surfaces.**

- *Start panel (PR4's panel).* Under Language, "Also detect": a pull-down of the same
  languages with a checkmark on each chosen one ("None" by default; the meeting language's
  other regions and a fourth language disabled; "None" clears). The speech-model line names
  the first chosen language whose model is not ready ("Speech model for English (Canada) not
  installed: English (Canada) will not be detected." with Install…); installing is only
  ever on Install…. `meetingLocales` keeps the whole list. `MeetingStartSettings.
  normalized()` keeps three different languages. The menu's saving line reads "detecting
  languages". Dictation keeps its one language.
- *Recorder.* `ChildProcessLauncher` passes `--languages=<a>,<b>` for several (else
  `--locale=`); `RecordingOptions.languages` (validated: a meeting's languages, first equal
  to `locale`) goes to meeting.json. Live transcription is unchanged.
- *CLI.* `record start` and `session import` take `--languages fr-CA,en-CA` instead of
  `--locale`; `session languages <session> --languages … [--force] [--json]`
  (`SessionLanguagesCommand`) runs the post-processor with those languages (one language
  makes the transcript that language's alone): exit 0 done (also without speaker models),
  3 partial, 1 failed. When the stage leaves the transcript as it was (already made, or
  kept after a failure) and the head run was built from it, the speaker stages are
  skipped ("The transcript did not change, so the speaker labels were kept."), so a
  second run changes no labels and edited labels need no `--force`; `--force` matters only
  for replacing the transcript. `session diarize` takes `--keep-transcript` (label the
  speakers of the current transcript as it is; the review window passes it) and runs
  without speaker models when a missed language can be detected now (step 5).
- *Meetings window.* Label Speakers and the status line follow step 5.
- *Exports.* Markdown adds "- Languages: French (Canada), English (Canada)" (English names)
  to the header of a transcript merged from several; the text carries no language marks,
  because the language changes every few seconds, often inside a sentence, and marks would
  break the text up. JSON adds top-level `languages` and each turn's `languages` (those of
  its words in order), only for a transcript merged from several (not one made one
  language's alone). Text is unchanged.
- *Review window.* It shows the merged transcript (the head run's). Changing a turn's
  language there is a follow-up: it would need a per-turn override stored beside the
  transcriptions and a new merge, then a relabel.

**Tests.** `LanguageMergeTests` (pure French kept whole; the English control never
switches, with made-up French words at the start and in a pause; alternating passages;
a switch needs two windows; a lone window smoothed away; windows without words carry and
do not break a run; a window heard only in one language takes it; a lone window heard only
in the other keeps nothing; ties; tracks apart; three languages; one candidate; word
middles; cuts at recognizer offsets and the fallback; untimed segments; unique IDs;
determinism; smoothing cases; echo windows follow the system track, need half the
window's words (counted in words for an untimed segment), and take no part in smoothing;
the NaturalLanguage scorer),
`LanguageStageTests` (merged,
kept, and labelled end to end with scripted speech, progress once per percent; one
language records nothing; a second
run and a resumed run transcribe nothing again; a pass from before a recovery is made
again; a missing model or a failed transcription
keeps the transcript and says why; nothing new while a language is still missing; the
recorded transcript stands in (said, journaled, and replaced once it can be), but never an
incomplete one; a language added once its model is installed; labels edited while
transcribing are kept; passes without words never replace the transcript, and the recorded
transcript stands in for one; an edit saved just before publication keeps the labels; the
publication holds the speaker lock; a cancellation while the locks are taken publishes
nothing; newer vocabulary.json and meeting.json are refused; an "en_CA" recording and
locales in any case count as their language; an audio-only session gets its first
transcript from `session languages`; Recover retries a language stood in for, then changes
nothing, and a rebuild that left audio untranscribed never stands in; Recover settles
while a missed language's model is missing or the labels were edited; Recover keeps a
`session languages` merge of a `--no-transcribe` rebuild; cut pieces labelled and exported; a call's echo
still dropped; cancellation; `session
languages` with order, one language, and invalid lists; edited labels and `--force` with
names carried, then the same languages again keeping edited labels without `--force`;
a narrower request, and one language for the recording's own transcript, recorded and
kept by later relabels; `session diarize --force` and `--keep-transcript` never detect
languages over edited labels; the catalog's `languageWork` and Label Speakers once the
model is installed, not with edited labels; `session diarize` without speaker models
detecting a missed language; `session import --languages`), `MeetingActionPolicyTests`
(Label Speakers for `LanguageWork.ready`, its messages), `MeetingLanguageTests` (meeting.json from a
recording, refused lists, launcher arguments, start settings), `MeetingLanguagesTests`
(HolosCore lists and optional fields), `TranscriptRevisionTests`, `LanguageExportTests`.

**Validation on the user's data** (private recordings in `.local/bilingual-probe/`,
imported into a temporary sessions folder, WER per Otter turn as the spike computed it;
Otter is another recognizer, not ground truth):

| Transcript | All | French turns | English turns | Mixed turns |
|---|---|---|---|---|
| Live preset, French alone (the import) | 49.7 | 38.9 | 69.4 | 37.9 |
| Accurate, French alone | 46.5 | 37.1 | 63.6 | 35.1 |
| Accurate, English alone | 77.0 | 90.9 | 48.5 | 59.9 |
| Merge of live-preset French and English passes | 39.9 | 38.1 | 40.1 | 20.8 |
| Merge of the live French transcript and an accurate English pass | 38.3 | 36.5 | 39.6 | 20.0 |
| Merge of accurate passes (shipped) | 37.4 | 35.2 | 39.5 | 19.7 |
| Spike, 3 s windows with the 2-window switch | 37.5 | – | – | 19.8 |

The live transcriber's `fastResults` cost about 3 points per language, which is why every
language is transcribed again with final results only, one more pass than reusing the live
transcript would take: the stage took 245 s for both passes and the merge of the 3 h 43 min
meeting. The final run was the one the product does: `session import --locale fr-CA`, then
`session languages --languages fr-CA,en-CA`; running it again transcribed nothing. The
English-only control (20 minutes), imported with `--languages fr-CA,en-CA` (French live,
English detected): 10.9 % (the spike's 10.9 %; French alone 64.5 %), no passage kept in
French (0 of 399), no switch.

**Deviations from the validated spike, and why.** Every language is transcribed again,
including the live one (above). The smoothing starts a track in the first agreeing run's
language instead of the first window's, so a lone first window cannot set it either (it
affects at most one window per track). `Models.swift` gained two optional fields: the
language of each segment has to live in the transcript that exports and speaker runs
read.

**Follow-ups.** A per-turn language override in the review window; the live transcript in
several languages; a Markdown option to mark language switches; detecting a missed
language on its own once its model is installed, and an app action that detects languages
over edited labels (today only `session languages --force` does).
