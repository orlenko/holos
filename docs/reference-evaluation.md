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
people's names and the words of your corrections are sent too. Every other
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
voiceislocal eval compare <session> [--run <id>]
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
   most 4, what one second holds, compared by letters and digits). A segment that is silence throughout
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
   the 6 alignment steps on each side of each cut again together (matched
   words included; stretches that touch are aligned as one), so a word said
   across a cut is not counted twice. Both transcripts are cut into words the
   same way, from their full text: at whitespace, and each character of a
   script written without spaces (Han, kana, Thai, Lao, Khmer, Myanmar,
   Tibetan) is a word of its own, so "你好世界" compares as four words however
   the recognizer grouped its timed words; each local word takes the time and
   echo mark of the recognizer words it overlaps, and passages, context and the
   gold keep the text's own spacing. Words are compared by their lowercased
   letters and digits, plus the marks that change a number (a separator,
   colon, slash or dash between digits, a minus sign before one): "1.5" and
   "15", or "-5" and "5", are a word difference in the numbers group, never
   case or punctuation only ("1,000" and "1000" are shown too). The alignment
   is minimum-edit. Microphone words that are
   echo of the system track in a call (the exports' echo filter) are left out,
   and so are cloud-only words between two echo words or up to 3 of them next
   to one. Segments without a track count for the first track only. WER is
   given against both sides, since neither is the truth yet.
   Differing passages are grouped as numbers, names and terms (a capital not
   at a sentence start, an acronym, letters mixed with digits), dropped or
   added words, other word changes, and case or punctuation only. A segment
   where the cloud has less than half the local words is flagged (the model may
   have cut its answer). Output: `eval/compare/<run>/report.md` and
   `report.json`.
3. **review** writes `eval/review/<run>/review.html` with
   `review-audio/<track>.m4a` beside it and opens it. The page is
   self-contained and loads nothing from the network (its
   Content-Security-Policy blocks connections). Each word passage shows its
   time with ▶ (plays from 1.5 s before to 1.5 s after), the local and cloud
   text with context, and a "Correct" field that starts as the cloud text;
   Local / Cloud / Edited choose. Keys: `j`/`k` next/previous, `1` local, `2`
   cloud, `e` edit (`Esc` leaves the field), space play/pause, `t` add the
   selected text to Terms. Decisions and terms are kept in the browser's
   localStorage per run and transcript; **Export decisions** downloads
   `decisions.json`. The page's own decisions are what counts: when the
   browser cannot store them (storage full or blocked) they stay in the page,
   are applied again on top of whatever another tab stores, and a warning
   says to export before closing (closing asks first). Case- and punctuation-only passages are left to
   report.md. Delete Audio removes the page's audio copy.
4. **apply** checks that the decisions belong to this session, run, and
   transcript revision, then writes `eval/gold/<run>.json`: each track's local
   words (echo left out) with every decided passage replaced by its final text,
   as timed pieces. It prints heard → meant pairs (word substitutions of at
   most 3 words a side, from the passage and its context, a lone dictionary
   word kept with a neighbour as the Corrections pane learns them) and, for
   each marked term, what the local recognizer wrote in its place (learned the
   same way, up to 6 words).
   `--add-corrections` adds the pairs and `--add-vocabulary` the term pairs to
   the app's `corrections.json` (the correction list holds heard → meant pairs
   only, so a term with no soundalike in the review is listed, not added).
   The read, change, and save hold the list's lock (`flock` on
   `corrections.json.lock`), which the app takes for its own changes too, so
   neither two applies nor an apply and the app lose an entry: the app makes
   each change to the list as saved at that moment, and loads the file again
   when it changes on disk (a watch on its folder), so a running Voice is Local
   uses the additions at once and never saves over them. Nothing is added
   without a flag.

With `--vocabulary`, the request carries `keywords[]` (gpt-transcribe only):
people's names, then the words of your corrections' meant phrases for the
meeting's languages (the recognizer's own meeting vocabulary), at most 100,
without terms containing a line break, `<` or `>`; and a `prompt` of at most
800 characters: `A meeting in English and French. People: Maria Chen, Jim.
Terms: Kubernetes, Grafana.`

Files, all in the session folder (`eval/` is removed with the session; Delete
Audio removes `review-audio/`; temporary audio lives in `derived/eval-cloud/`
and is removed when a command ends):

```
eval/cloud/<run>/run.json            plan, request fields (no key), progress
eval/cloud/<run>/segments/<track>-<n>.json, raw/<track>-<n>.json
eval/cloud/<run>/timestamps/…, raw-timestamps/…   with --timestamps
eval/cloud/<run>/<track>.json        stitched track
eval/compare/<run>/report.md, report.json
eval/review/<run>/review.html, review-audio/<track>.m4a
eval/gold/<run>.json
```

Run IDs are `<model>-<UTC yyyyMMddTHHmmssZ>`.

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
