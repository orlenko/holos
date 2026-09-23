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
