# Local reference comparison

Use `scripts/evaluate-references.swift` to compare Holos's native transcription
with private product exports. Run it from the repository root. It reads paired
media and text, invokes the existing `holos transcribe` CLI for each selected
backend, and writes raw transcripts plus numeric reports only into a new
0700-permission directory below the ignored `.local/evaluation/` tree. It never
uploads media or text, records audio, or plays sound. The CLI must already have
its speech assets installed for the selected locale and backend.

```sh
swift scripts/evaluate-references.swift --self-test
swift scripts/evaluate-references.swift \
  --input reference-data/wisprflow \
  --cli .build/out/Products/Debug/holos \
  --backend both --locale en-CA
```

The default `wispr` layout pairs `001.wav` with `001.txt`. For an Otter export,
each numbered subdirectory must contain one MP3 and one `*_transcript.txt`.
Select a short pair before running a long recording:

```sh
python3 scripts/import-otter-references.py          # validate ZIPs without extracting
python3 scripts/import-otter-references.py --extract
swift scripts/evaluate-references.swift \
  --input .local/evaluation/otter-inputs \
  --reference-format otter --pair 002 \
  --cli .build/out/Products/Debug/holos \
  --backend both --timeout-seconds 120
```

`--backend` also accepts `speech` or `dictation`. `--output` can name a new
directory under `.local/evaluation/`; existing run directories are never
overwritten. Each CLI call has a timeout (600 seconds by default), and the
script's dynamic-programming alignment uses memory proportional to the shorter
transcript. `summary.json` and `summary.md` contain per-pair and aggregate
duration, runtime, reference word count, substitutions, deletions, insertions,
numeric-token edits, and micro WER. Raw recognizer JSON stays beside them.

The TXT files are product exports, not verified verbatim truth. Wispr files were
copied directly from Wispr; whether its history incorporated the user's earlier
target-app corrections is unknown. Otter exports contain speaker/time headers
and an export footer; the harness removes those metadata lines before scoring.
The score therefore means normalized word disagreement with an exported product
output, not true recognition accuracy. Normalization applies Unicode
compatibility composition and lowercasing, then compares contiguous Unicode
letter/digit tokens. Punctuation is ignored; number spelling differences count.

## First comparison, 2026-09-22

Both backends used `en-CA` on this macOS 27 / Swift 6.4 Mac. These are
micro-averaged word-edit distances divided by the product export's normalized
word count; lower means closer to that export, not necessarily more correct.

| Reference set | Audio | Reference words | Speech | Dictation |
| --- | ---: | ---: | ---: | ---: |
| Five Wispr clips | 463.9 s | 790 | 10.4% | 13.0% |
| Shortest Otter recording | 411.8 s | 1,265 | 15.7% | 57.9% |

This is an exploratory baseline, not a held-out acceptance test. No correction
rules were trained from these examples. Playback, live finalization latency,
speaker attribution, and actual network-disconnected operation were not measured.

Across the five Wispr pairs, Speech's edit counts were balanced between
substitutions and extra words, while Dictation had more substitutions. Numeric
edits were a small subset. These counts alone cannot distinguish fillers or
restarts from changed wording, nor identify name or proper-noun errors; those
require a private, human review of the source and raw transcripts. On the shortest
Otter meeting, Dictation produced much less text than either the Otter export or
Speech, and reference-relative deletions dominated its score. An opt-in,
aggregate-only native-result probe on that recording counted 8 Dictation final
results containing 559 whitespace-delimited words; the collector accepted and
output all 8 and all 559 words. It dropped no final result and promoted no
volatile hypothesis. The same probe counted 146 Speech final results and 1,165
whitespace-delimited words, all accepted and output. These probe word counts use
whitespace splitting, unlike the normalized Unicode-token counts in the table.
Thus the sparse Dictation output on this recording was already present at the
native final-result boundary, not caused by collector overlap rejection. The
reason for the native backends' difference remains undetermined; this probe does
not establish that the collector's overlap policy is safe on every recording.
Keep Speech as the default for meeting files and treat Dictation as experimental
there. The two longer Otter recordings have not been benchmarked.

For a local aggregate-only check, set `HOLOS_SPEECH_PROBE=1` when running a file
transcription. On success, the CLI prints a JSON counter object to standard
error, without recognition text or audio paths. The probe is off by default.

## Cloud reference

`voiceislocal eval` compares a meeting's local transcript with a transcript
made by OpenAI from the same audio, shows the passages where they differ next
to the audio, and turns the decisions of a human reviewer into a reference
transcript and proposed corrections. It is a developer tool: CLI only, never
used by the app, and nothing it writes is read by the app or the exports.

**Privacy.** `voiceislocal eval cloud` uploads the meeting's audio to OpenAI:
the audio leaves this Mac. Use it only with the consent of everyone who was
recorded. It never uploads without an explicit yes: it prints what will be
sent and asks `Upload to OpenAI? [y/N]`; without a terminal it refuses unless
`--yes` is given. The API key is read from `OPENAI_API_KEY` and is never saved
or printed (error messages that quote a key are redacted). With `--vocabulary`,
your word list, people's names, and the words of your corrections are sent
too. Every other
`eval` command works offline.

### What the API supports (read 2026-09-29)

From OpenAI's speech-to-text guide, API reference, and pricing page:

| Model | Price | Timestamps | Hints |
| --- | ---: | --- | --- |
| `gpt-transcribe` (default) | $0.0045/min | none | `prompt`, `keywords[]`, `languages[]` |
| `gpt-4o-transcribe` | ≈$0.006/min | none | `prompt`, `language` |
| `gpt-4o-mini-transcribe` | ≈$0.003/min | none | `prompt`, `language` |
| `whisper-1` | $0.006/min | word and segment (`verbose_json`) | `prompt` (224 tokens), `language` |

`gpt-transcribe` answers `{"text": …, "languages": [{"code": "en"}], "usage":
{"type": "duration", "seconds": 17}}` (checked with one synthetic clip). Files
may be up to 25 MB (m4a accepted). OpenAI documents no duration limit for
`gpt-transcribe`; the older models refuse audio over 1,400–1,500 s and cut
their answers at about 2,000 output tokens (8–11 minutes of speech). The
`gpt-4o` models and `whisper-1` are deprecated and shut down on 2027-02-26.

### How a run works

```sh
voiceislocal eval cloud <session> [--model gpt-transcribe] [--tracks mic,system] [--vocabulary] [--timestamps] [--yes]
voiceislocal eval local <session> [--language xx-YY] [--no-vocabulary] [--run <local run>]
voiceislocal eval compare <session> [--run <id>] [--local current|latest|<local run>] [--raw]
voiceislocal eval review <session> [--run <id>] [--no-open]
voiceislocal eval apply <session> decisions.json [--add-corrections] [--add-vocabulary]
voiceislocal eval list <session>
voiceislocal eval delete <session> (<run> | --all)
```

1. **cloud** renders each track (16 kHz mono, pauses over 60 s shortened to
   5 s, as for speaker labelling) and cuts it into segments of at most 5
   minutes, each cut at the quietest 0.4 s within the 45 s before the limit.
   When that stretch is not silence, the next segment repeats the last second,
   and stitching drops the words the two segments share at the junction (at
   most what one second holds: 4 words, or 10 characters of an unspaced
   script; compared by letters and digits; only with the segment just before,
   so after an empty answer nothing is dropped). A segment that is silence throughout
   is not sent. Segments are AAC .m4a (32 kbit/s, about 1.2 MB per 5 minutes).
   The cost shown is the audio sent times the list price. Each segment's raw
   answer and parsed text are saved as soon as they arrive; failed requests are
   retried (network errors, 408, 409, 429 except an exhausted quota, 5xx) up to
   six attempts with 2–32 s waits or the server's `Retry-After`. Ctrl-C stops;
   running the same command again resumes the newest unfinished run with the
   same settings (or `--run <id>`) and sends only the missing segments. It
   refuses a session that is recording, whose audio was deleted, or whose audio
   changed since the run started: the chunk list must be the same, and every
   segment's samples in the new render must have the SHA-256 recorded when the
   run was planned (so a chunk replaced by other audio of the same length is
   caught before any saved answer is reused). It holds the session's processing lock
   while it works (every `eval` command that writes does). `--run` resumes
   only with the options the run was started with. The meeting's languages are always sent (`languages[]`, or
   `language` for older models when there is one).
   `--timestamps` also sends each segment to `whisper-1` for word times (off by
   default; doubles the uploads and roughly doubles the cost); compare then
   times the words only the cloud has from them.
2. **compare** takes the current transcript revision and, per track, compares
   each cloud segment with the local words that start inside it (from where
   the segment's own audio begins to where the next one's does), then aligns
   the alignment around each cut again as one stretch: at least 6 steps on
   each side, matched words included, and on until 3 matched words in a row
   (or the track's edge, at most 500 steps a side) bound it; stretches that
   touch are aligned as one. So a word, or a whole run of words that coarse
   local timing put on the other side of the cut, is not counted twice. Both transcripts are cut into words the
   same way, from their full text: at whitespace, and each character of a
   script written without spaces (Han, kana, Thai, Lao, Khmer, Myanmar,
   Tibetan) is a word of its own, so "你好世界" compares as four words however
   the recognizer grouped its timed words; each local word takes the time and
   echo mark of the recognizer words it overlaps, and passages, context and the
   gold keep the text's own spacing. Words are compared by their lowercased
   letters and digits, plus the marks that change a number (a separator,
   colon, slash or dash between digits, a leading decimal separator (".5",
   not after a letter), a minus sign before one or in an exponent ("1e-5"),
   a percent
   sign after one, a currency sign beside one, a minus before an amount; a
   run of lone signs and currency signs joins the amount after it, so "$ 50"
   is one word, as "$50" is, and "- 5" keeps its sign): "1.5" and "15", "-5"
   and "5", "- 5" and "5", "5%" and "5",
   "$50" and "€50", or "-$50" and "$50" are a word difference in the
   numbers group, never case or punctuation only ("1,000" and "1000" are
   shown too). The alignment
   is minimum-edit. Microphone words that are
   echo of the system track in a call (the exports' echo filter) are left out,
   and so are cloud-only words between two echo words or up to 3 of them next
   to one (with `--timestamps`, only those said within 1 s of an echo word
   beside them; a timed cloud word aligned with an echo word but said more
   than 1 s from it is a cloud-only word, not echo, kept in the order the
   cloud said it). Segments without a track count for the first track only. WER is
   given against both sides, since neither is the truth yet. The report leads
   with the normalized WER (see "Fair comparison" below) and gives the raw
   WER beside it; `--raw` makes the raw comparison the whole report (every
   passage to review, no normalized scores).
   Differing passages are grouped as numbers, names and terms (a capital not
   at a sentence start, an acronym, letters mixed with digits), dropped or
   added words, other word changes, formatting only (the same words under the
   normalized comparison), and case or punctuation only. A segment
   where the cloud has less than half the local words is flagged (the model may
   have cut its answer), and so is a track with more echo words left out than
   words kept ("unreliable: mostly echo": what is left of the microphone is
   mostly what the echo filter missed, so its WER says little). The **Terms**
   section counts, for each word-list term and each correction's meant phrase,
   how often the cloud text has it (echo left out) and how often the local
   transcript has the same words at the aligned position, as one unbroken
   run (only fillers or echo between them), sorted by misses, with each
   track's share (the microphone's count depends on the echo left out, which
   differs between local transcripts): the number to follow from one
   vocabulary to the next. `--local` compares a
   local candidate (`eval local`) instead of the current transcript. Output:
   `eval/compare/<run>/report.md` and `report.json` (a candidate's in
   `eval/compare/<run>/<local run>/`); the report says which local transcript
   and which vocabulary it compared.
3. **review** writes `eval/review/<run>/review.html` with
   `review-audio/<track>.m4a` beside it and opens it. The page is
   self-contained and loads nothing from the network (its
   Content-Security-Policy blocks connections). Each word passage shows its
   time with ▶ (plays from 1.5 s before to 1.5 s after), the local and cloud
   text with context, and a "Correct" field that starts as the cloud text;
   Local / Cloud / Edited choose. Keys: `j`/`k` next/previous, `1` local, `2`
   cloud, `e` edit (`Esc` leaves the field), space play/pause, `t` add the
   selected text to Terms. Decisions and terms are kept in the browser's
   localStorage per run and transcript, each passage and term under a key of
   its own, so two tabs never save over each other's decisions; **Export
   decisions** downloads `decisions.json`. The page's own decisions are what
   counts: when the
   browser cannot store them (storage full or blocked) they stay in the page,
   are applied again on top of whatever another tab stores, and a warning
   says to export before closing (closing asks first). Case- and punctuation-only passages are left to
   report.md; formatting-only passages are hidden unless **Show
   formatting-only differences** is ticked (hidden cards are skipped by
   `j`/`k` and left out of the count). Review compares again first when the
   comparison of the current transcript predates the normalized comparison.
   Delete Audio removes the page's audio copy. The page's audio is
   written only when the track still renders to the samples the run sent
   (the same segment digests), so it never plays other audio than the cloud
   heard.
4. **apply** checks that the decisions belong to this session, run, and
   transcript revision (a comparison of a local candidate is refused), ignores
   decisions on formatting-only passages (it says how many), then writes
   `eval/gold/<run>.json`: each track's local
   words (echo left out) with every decided passage replaced by its final text,
   as timed pieces, with the transcript's spacing (where a decided text meets
   other script, or around an insertion or deletion, a space unless both
   sides are unspaced script). It prints heard → meant pairs (word substitutions of at
   most 3 words a side, from the passage and its context, a lone dictionary
   word kept with a neighbour as the Corrections pane learns them) and the
   terms you marked (whitespace collapsed, once each in any case).
   `--add-corrections` adds the pairs to the app's `corrections.json`;
   `--add-vocabulary` adds the marked terms to the word list (`words.json`,
   as `voiceislocal words add` does, each entry marked as coming from a
   review; a term already listed in any case stays as it is, and one over 100
   characters or past the list's 1,000 terms is reported and makes the command
   exit 1 after the rest are added). Each file's read, change, and save hold
   its lock (`flock` on `corrections.json.lock` or `words.json.lock`), which
   the app takes for its own changes too, so neither two applies nor an apply
   and the app lose an entry: the app makes each change to the list as saved
   at that moment, and reads both files again when they change on disk (a
   watch on their folder; the word list is also checked at each dictation), so
   a running Voice is Local uses the additions from its next dictation,
   meeting or Run Again and never saves over them. A dictation keeps the
   corrections, word list and vocabulary it started with until it ends, so
   text it already wrote never changes under it. Nothing is added without a
   flag.

With `--vocabulary`, the request carries what the recognizer's own meeting
vocabulary holds, in its order: your word list, then people's names, then the
words of your corrections' meant phrases for the meeting's languages, each
once in any case or spacing. `keywords[]` (gpt-transcribe only) gets at most
100 of them, the recognizer's limit (OpenAI documents no count limit; it
rejects a form of about 1,000 parts), leaving out any over 100 characters or
containing a line break, `<` or `>` (OpenAI rejects the whole request for
one). The `prompt` lists them in the same order up to 800 characters
(whisper-1 reads 224 tokens), stopping at the first that does not fit: `A
meeting in English and French. Terms: Keycloak, Urban Sky. People: Maria Chen,
Jim. Other words: Kubernetes.` A words.json or corrections.json that cannot
be read stops the run before anything is sent. A resumed run keeps the
request it was planned with.

### Fair comparison

Many differences between the two transcripts are not recognition errors: a
number written in digits on one side and in words on the other, a filler one
side keeps and the other drops, a compound written as one word or as several.
The normalized comparison (the default of `compare`) does not count them. It is
used for the scores, the Terms section and the formatting-only mark only:
passages, the review page and the gold keep the words as written.

- **Numbers.** A run of up to 5 words that spells a number is the same as that
  number in digits, in English or French: cardinals ("three"/"3",
  "twenty one"/"twenty-one"/"21", "a hundred"/"one hundred"/"100", "one
  hundred and five", "fifteen hundred", "two thousand twenty six", years said
  in halves such as "nineteen eighty four"; "vingt et un", "soixante-dix-sept",
  "quatre-vingt-dix", "deux cents", "deux mille vingt-six"), ordinals
  ("first"/"1st", "twenty first"/"21st"; "premier"/"1er", "deuxième"/"2e"), decimals
  ("three point five"/"3.5"; "trois virgule cinq"/"3,5"), "plus" ("plus
  30"/"+30") and percent ("thirty percent"/"30%", "pour cent"). Digits may
  carry group commas ("1,000"/"1000"); a minus, a currency, a time or a range
  is compared as written. A spelled number is only the same as digits, never
  as another spelled number, so "one" and "un", or "first" and "premier",
  remain different words, and so do different numbers, a cardinal and an
  ordinal ("first"/"1"), or a sign ("+30"/"30").
- **Fillers.** um, uh, er, erm, hmm, mm, ah (English) and euh, heu, bah, hein
  (French), in any case, with punctuation, and drawn out ("ummm"), are left
  out on both sides: they count neither as words nor as errors, and the report
  counts them per side. A filler is never paired with a word the other side has.
  "ben", "err", "uh-huh" and "mhm" are words.
- **Compounds.** Two or three words whose letters and digits, joined, are the
  one word on the other side ("test flight"/"TestFlight", "chat GPT"/"ChatGPT",
  "follow up"/"follow-up", "A P I"/"API"), also with each run of spelled
  numbers in digits ("V one"/"v1", "V twenty one"/"V21", never "V201"), are
  the same. The joined words must hold a letter ("1 5" and "15" differ). Up to
  two fillers inside a joined number or compound ("twenty um one"/"21") are
  left out as fillers.
- **Case and punctuation** never count (as in the raw comparison).

Each word passage of the raw alignment (a run of edits between matched
words) is aligned again this way: a minimum-edit alignment where a filler
costs nothing to leave out and a number or compound run matches its other
spelling at no cost. Its remaining edits make the normalized WER, so every
normalized error is in a passage the review page shows; a passage with none
is formatting only. Matched fillers are left out of the word counts too.

### Local candidates

`voiceislocal eval local <session>` transcribes all of a session's saved audio
again, track by track, with Apple's speech recognition as the post-processing
languages stage does (final results only, `TrackReplayer` with the stop path's
time limits), so a vocabulary change can be measured on the same meeting:
`session recover --current-vocabulary` only transcribes the audio its saved
live phrases do not cover. Nothing leaves the Mac.

- **Languages:** meeting.json's languages, else the recording's locale, or
  `--language` alone. With several, each track is transcribed in each language
  and the transcriptions are merged as the languages stage merges them
  (`LanguageMerge`, microphone echo of a call found in each). A language whose
  speech model is not installed is refused before anything is saved.
- **Vocabulary:** today's, as a meeting starting now would get it
  (`RecognizerVocabulary.meeting`): the word list, then people's names, then
  the words of your corrections for those languages, each once, at most 100
  strings; `--no-vocabulary` gives it none. The exact strings are saved in
  `run.json`.
- **Text steps:** none. A meeting applies no text step after recognition
  today (corrections, filler removal and spoken-code formatting are dictation
  steps), so a candidate is what the recognizer returned.
- **Output:** `eval/local/<local run>/run.json` (settings, vocabulary, each
  track's audio fingerprint and the SHA-256 of its chunk files' bytes), `parts/<language>-<track>.json` (each track's
  timed words, saved as soon as it is done) and `transcript.json` once all
  are in. The meeting's transcript, speaker labels, exports and
  vocabulary.json are never changed.
- **Resuming:** Ctrl-C stops; the same command resumes the newest unfinished
  run with the same languages, vocabulary and audio, the chunk files' bytes
  hashed again (or `--run`, which keeps the vocabulary that run started with
  and refuses audio that changed) and transcribes only the tracks not
  saved yet. It refuses a session that is recording or whose audio was
  deleted.

Then `voiceislocal eval compare <session> --local latest` compares it with the
cloud run; its Terms section against the current transcript's is the before
and after of the vocabulary. `eval list` shows local runs; `eval delete
<session> <local run>` removes one and its comparisons. Review and apply work
on the comparison of the current transcript only.

Files, all in the session folder (`eval/` is removed with the session; Delete
Audio removes `review-audio/`; temporary audio lives in `derived/eval-cloud/`
and is removed when a command ends):

```
eval/cloud/<run>/run.json            plan, request fields (no key), progress
eval/cloud/<run>/segments/<track>-<n>.json, raw/<track>-<n>.json
eval/cloud/<run>/timestamps/…, raw-timestamps/…   with --timestamps
eval/cloud/<run>/<track>.json        stitched track
eval/local/<local run>/run.json, parts/<language>-<track>.json, transcript.json
eval/compare/<run>/report.md, report.json
eval/compare/<run>/<local run>/report.md, report.json
eval/review/<run>/review.html, review-audio/<track>.m4a
eval/gold/<run>.json
```

Run IDs are `<model>-<UTC yyyyMMddTHHmmssZ>`; local run IDs are
`local-<UTC yyyyMMddTHHmmssZ>`.

### First check, 2026-09-29

A 16 s synthetic clip (AVSpeechSynthesizer, en-US voice, generic sentences
with "Kubernetes", "Grafana", "Priya", "three thirty") imported into a scratch
session and transcribed locally in en-CA, then sent once with `--vocabulary
--timestamps` and a stand-in correction list. Local: 43 words, cloud: 42; WER
18.6 % against local, 19.0 % against cloud; 4 passages: "cuber needs" /
"Kubernetes", "Griffana dash boards" / "Grafana dashboards", "pool" / "pull",
"330" / "three thirty". The cloud text matched the script word for word (one comma aside); whisper-1
wrote "pool request" and "3.30". The review page played the passage audio,
kept decisions across a reload, and exported decisions.json; apply proposed
`cuber needs → Kubernetes`, `Griffana dash boards → Grafana dashboards`,
`pool request → pull request`, `before 330 → before three thirty`.
