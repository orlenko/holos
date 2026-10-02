# Local transcript correction model research

Research handoff for the Holos agent on Volodobook, recorded on 2 October 2026.
The problem is context-dependent speech errors: replacing a valid word with
another valid word globally can fix one passage and damage another. This spike
tests whether an offline model can judge a supplied alternative using earlier
spoken context, without rewriting the whole transcript.

Both pinned Qwen3.5 4-bit models completed synthetic inference on Koza, an Apple
M5 Mac with 16 GiB RAM. The 9B model is feasible for this bounded workload once
the initial conservative stop conditions are relaxed. It did not improve on
the 4B in these tiny invented examples. **Recommendation:** keep 4B as the
leading evaluation candidate, not as an approved automatic correction engine.

No production implementation, app rebuild, app launch, microphone or screen
capture, permission prompt, clipboard write, private meeting transfer, or new
OpenRouter request was performed for this local spike. Weights, virtual
environments, caches, and compiled binaries are not in this branch.

## Results on Koza

The same 24 homophone prompts and expected labels were checked byte-for-byte
through their recorded hashes across the two models. Each model also completed
six smoke decisions about the coding assistant versus remote storage. All 30
responses per model passed the strict keep/replace JSON parser.

| Measurement | Qwen3.5 4B 4-bit | Qwen3.5 9B 4-bit |
| --- | ---: | ---: |
| Peak MLX allocation in the homophone run | 3.005 GB | 5.609 GB |
| Median short decision | 2.99 s | 3.96 s |
| Median decision with spoken context | 6.39 s | 7.93 s |
| Median decision with spoken context and adversarial OCR | 5.77 s | 8.08 s |
| Correct contextual choices without OCR | 8/8 | 7/8 |
| Correct contextual choices with adversarial OCR | 8/8 | 4/8 |
| Conservative keeps on ambiguous short requests | 6/8 | 6/8 |
| Smoke choices matching the intended labels | 6/6 | 4/6 |

GB in the MLX allocation rows is decimal. These are **invented labels, not a
real-meeting accuracy score or a general model ranking**. Both models guessed
site for sight without context. That identical short prompt was requested
twice, once for each intended longer context, so the two failures are not
independent observations. In the 9B OCR condition, all four required replacements
were missed; the four keep cases remained correct.

The test supplies the alternative term in advance. It does not measure discovery
of unknown errors, full transcript rewrites, speaker attribution, or actual
meeting-level safety. Wider inputs contain about 650 words of unusually explicit
context and repeated neutral padding, yielding roughly 867–900 prompt tokens.
They do not test the maximum model window or long-meeting context retention.

## Memory safety and the expanded retry

The first watchdog stopped after 512 MiB of additional global swap. That was a
conservative experimental policy, not a hardware usability threshold. The
initial 4B attempt stopped with about 513 MB growth; its isolated retry finished.
The initial 9B attempt stopped during loading after about 2,632 MB growth.
Neither aborted attempt produced a decision. Their raw logs are retained.

The user subsequently authorized pushing the existing 9B test farther. The
expanded envelope allowed 4,096 MiB additional swap, a 10 GiB sampled RSS ceiling,
and sampling every two seconds. It stopped on critical kernel pressure,
warning pressure sustained for 120 seconds, two system probe batches exceeding
two seconds each, or combined swap-in/out above 128 MiB/s sustained for 15 seconds
after a 60-second startup grace. A first expanded attempt with a shorter
20-second warning cutoff also stopped before loading completed. These are
chosen safeguards, not universal boundaries between usable and unusable Macs.

The successful 9B smoke run loaded in 35.10 seconds and completed in 105.38
seconds including imports and pauses. Global swap rose by about 1,065 MiB by
exit, with short bursts of swapping rather than sustained thrashing. The
subsequent 24-decision run loaded in 39.39 seconds and completed in 267.65
seconds. During that entire subsequent run, the global cumulative swap-out
counter did not increase, while swap used fell by 216 MiB. Startup warning
pressure cleared, no critical pressure was sampled, and its system probe batches
took at most 0.095 seconds. One `sample` snapshot reported a 5.3G physical
footprint and a 5.8G peak; that is not continuous footprint measurement.

Swap used alone does not establish responsiveness. Apple describes memory
pressure as depending on free memory, swap rate, wired memory, and cached files.
The kernel distinguishes warning from critical pressure; critical pressure is
associated with expected latency. See [Activity Monitor memory guidance](https://support.apple.com/en-euro/guide/activity-monitor/-actmntr1004/mac)
and [Apple XNU memory pressure documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md).
The read-only sysctl used here exports dispatch flags: normal 1, warning 2,
critical 4, not the kernel's internal enumeration.

Inference remained at CPU niceness 15 and utility QoS with a two-second pause
between decisions. **This is not a hard GPU throttle.** The MLX allocator
setting of 7 GiB is a guideline, not a strict cap; its free cache was limited to
128 MiB. Qwen3.5's model-specific hybrid cache ignores `max_kv_size`, so the
harness instead rejects inputs above 2,048 tokens and caps output at 64 tokens.
No system wired-memory limit or other global resource setting was changed.
Process CPU/RSS omit some GPU and compiler-service costs. Foreground UI,
normal developer workloads, long-duration thermals, and battery impact were not
measured. Additional RAM is expected to offer more headroom, not guaranteed
non-intrusiveness.

## Models and reproducible evidence

The runtime was Python 3.13.15, MLX 0.32.3, and mlx-lm 0.32.0. Full dependency
versions are in [runtime-freeze.txt](../research/local-transcript-models/runtime-freeze.txt).
Inference used local directories with network fallback disabled, remote code
disabled, seed 7, temperature 0, and non-thinking chat templates. The text-only
loader discarded vision weights. The specific conversions tested were:

| Public repository | Pinned revision | Weight bytes |
| --- | --- | ---: |
| mlx-community/Qwen3.5-4B-4bit | `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c` | 3,034,300,695 |
| mlx-community/Qwen3.5-9B-MLX-4bit | `938d8919941c6e7efd3c7150eff7fe9d12afa631` | 5,950,221,072 |

Local SHA-256 digests matched the pinned Hugging Face LFS metadata for all three
weight files. The digest record is [verified-weights.json](../research/local-transcript-models/verified-weights.json).
A small read of norm tensors found no obvious missing unit offset; that check
does not establish equivalence to the original full-precision models. No extra
9B 8-bit or 14B weights were downloaded or authorized.

The evidence bundle is [research/local-transcript-models](../research/local-transcript-models/).
[push-outcome.json](../research/local-transcript-models/push-outcome.json) is the
current result and explicitly supersedes the initial load-abort assessment in
`outcome.json`. `results.json` contains metrics calculated from the raw decision
and monitor JSONL files, including every aborted attempt. Paths and process IDs
inside captured records describe the original Koza run, not the reader's machine.

Run the read-only evidence verification without MLX, weights, hardware, or network:

```sh
python3 research/local-transcript-models/verify_research.py
```

For a new experiment, first copy the bundle into an ignored local directory so
the historical evidence is not overwritten:

```sh
mkdir -p .local/evaluation
research_run_root=$(mktemp -d "$PWD/.local/evaluation/local-models.XXXXXX")
cp -R research/local-transcript-models/. "$research_run_root/"
python3 "$research_run_root/evaluate.py" --self-test
```

Only after the user approves runtime installation and downloads on the target
machine, install the pinned runtime and explicitly download the two approved
models. The downloader never reads account credentials and checks byte counts;
the separate verification step checks the actual file digests before inference.

```sh
UV_CACHE_DIR="$research_run_root/uv-cache" \
UV_PYTHON_INSTALL_DIR="$research_run_root/python" \
uv venv --python 3.13 "$research_run_root/runtime"
UV_CACHE_DIR="$research_run_root/uv-cache" uv pip install \
  --python "$research_run_root/runtime/bin/python" \
  -r "$research_run_root/runtime-freeze.txt"
"$research_run_root/runtime/bin/python" "$research_run_root/download.py"
nice -n 15 python3 "$research_run_root/verify_research.py" --verify-weights
"$research_run_root/runtime/bin/python" "$research_run_root/watch.py" \
  --model-path "$research_run_root/weights/Qwen3.5-4B-4bit" \
  --suite homophones --label new-4b --timeout 600
```

The watchdog defaults remain conservative. A 9B retry with the expanded envelope
requires deliberately selecting the resource options documented above; it is
not the default. Run one model process at a time. `summarize.py` and
`push_summary.py` regenerate JSON reports in the scratch copy; the latter checks
the specifically archived paired runs, not arbitrary future labels.

## Native Foundation and the earlier hosted pilot

The native Foundation Models smoke run is incomplete: four decisions completed
before a hard 120-second timeout. Its original prompt differed from the final
local prompt: it said not to rewrite anything, whereas the final prompt says not
to output a rewritten transcript and explicitly chooses keep when ambiguous.
The captured Foundation run reported an 8,192-token context. These data establish
neither a context-window bottleneck nor a fair native-versus-MLX quality or speed
comparison. The caller's approximately 19 MB RSS does not represent the native
model service's memory. Source and numeric smoke results are included; the
compiled binary and any private inputs are not.

An earlier OpenRouter pilot on Volodobook was **reported by the paired agent,
not independently reproduced here**. The peer reported Qwen3.5-9B on a pinned
DeepInfra BF16 route with zero-data-retention/deny settings, long response times
(roughly 93–201 seconds per window), overload errors, truncation, schema issues,
and unsafe edit proposals. There was no human gold score. That hosted rewrite
task, mixed prompt variants, and BF16 model are not comparable to six-token
local keep/replace decisions. The API key, real transcripts, recordings, and
private pilot outputs are deliberately absent from this branch. Re-check the
original Volodobook artifacts before relying on exact counts or route settings.

## Suggested next evaluation on Volodobook

The partner can fetch this research branch and verify its synthetic evidence
without new runtime installation, downloads, or cloud calls. Suggested later
work, requiring the applicable user authorization, is a private local evaluation
with human-labelled positive and negative ambiguous spans, language/domain
variety, and development/evaluation separation. Compare the Foundation baseline,
4B, and 9B under the same prompt and schema, with and without relevant spoken
context and bounded untrusted OCR.

Measure harmful false replacements, missed corrections, unchanged passages,
schema failures, and resource costs alongside the original text. Known-candidate
judging and discovery of unknown transcription errors need separate tests.
Consider opt-in post-transcription work while idle, a single worker, cancellation,
immutable original text, sparse anchored proposals, and explicit Review acceptance
as design hypotheses, not implemented features. Do not change numbers, negation,
or speaker labels through an unvalidated free rewrite.

This handoff does not authorize automatic production corrections, app lifecycle
changes, real capture, additional downloads on Volodobook, or further cloud
uploads. Existing app and data-handling rules remain in force.
