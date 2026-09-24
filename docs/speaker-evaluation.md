# Speaker diarization evaluation (spike S1)

**Verdict: go.** FluidAudio 0.17.1's offline pipeline (`OfflineDiarizerManager`,
pyannote Community-1 segmentation + WeSpeaker embeddings + VBx) diarized a 3 h
file in 35 s with a 1.8 GB peak RSS on an M4 Pro. On the three Otter
recordings it disagreed with Otter's speaker on 1.4–5.2 % of the time that both
tools mark as speech. The default configuration did best of every setting
tried. Single-pass diarization is enough for 3 h; the block-wise fallback in
the plan (§4, step 3) is not needed for memory.

All numbers are **agreement with Otter**, not accuracy. Otter's labels have
their own errors, and an Otter "turn" runs from one speaker header to the next,
so it includes pauses. No transcript text or speaker names appear here or in
the probe output.

## Setup

| Item | Value |
| --- | --- |
| Machine | Apple M4 Pro (10 performance + 4 efficiency cores), 48 GB RAM |
| OS / toolchain | macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1) |
| Library | FluidAudio 0.17.1, tag commit `5c51c5c93afff0d89594a2a93c3103e790ba648c` |
| Models | Hugging Face `FluidInference/speaker-diarization-coreml`, revision `df2625ac79a7ac6b65ad868fee6d80f320da4232` (pinned by FluidAudio), 21 MB on disk |
| Pipeline | `OfflineDiarizerManager.process(URL)`, default `OfflineDiarizerConfig()`, compute units `.all` (FBank model is always CPU) |
| Probe | `.local/diarization-probe` (gitignored): `Sources/Probe/main.swift` (release build), `der.py` (scoring), `run1.sh` |
| Inputs | Otter exports 001, 002, 003: 16 kHz mono MP3, read directly by FluidAudio. The 3 h file is 16 kHz mono Int16 WAV made with `afconvert` |

Memory figures: **peak RSS** is `getrusage` `ru_maxrss` at the end of the run;
**footprint peak** is `task_vm_info.ledger_phys_footprint_peak` (what Activity
Monitor calls Memory). Wall time covers `process(url)` only; the models were
already loaded (0.15 s warm).

## Results (default config)

| File | Duration | Wall | RTF | Peak RSS | Footprint peak | Clusters (≥30 s) | Otter labels (≥30 s) | Approx DER | Miss | False alarm | Confusion | Confusion on joint speech |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 002 | 6.9 min | 2.5 s (1.3–1.4 s on later runs) | 0.006 | 363 MB | 819 MB | 2 (2) | 3 (2) | 28.5 % | 26.1 % | 0.5 % | 1.9 % | 2.6 % |
| 001 | 20.2 min | 3.9 s | 0.003 | 466 MB | 852 MB | 7 (7) | 8 (7) | 23.3 % | 22.1 % | 0.0 % | 1.1 % | 1.4 % |
| 003 | 88.9 min | 17.0 s | 0.003 | 947 MB | 1,060 MB | 7 (6) | 11 (8) | 32.4 % | 28.7 % | 0.0 % | 3.7 % | 5.2 % |
| 3 h concat | 180.0 min | 35.4 s | 0.003 | 1,777 MB | 1,288 MB | 14 (12) | 15 (11) | 38.1 % | 30.2 % | 0.0 % | 7.8 % | 11.2 % |

Segments produced: 66, 172, 777 and 1,590. Stage timings for 3 h: segmentation
22.7 s, embedding 28.4 s, clustering 5.7 s, audio load 0.7 s (segmentation and
embedding run concurrently). `/usr/bin/time -l` for the 3 h run: 35.7 s real,
43.1 s user, max RSS 1,863,483,392 bytes, peak footprint 1,350,600,576 bytes.

How to read the columns:

- **Approx DER** = (miss + false alarm + confusion) / scored Otter speech, 10 ms
  frames, 0.25 s collar around every Otter turn boundary, optimal one-to-one
  cluster↔label mapping (Hungarian, `scipy.optimize.linear_sum_assignment`),
  overlap ignored (Otter has none; FluidAudio output is made exclusive).
- **Miss** is mostly an artefact of the reference: Otter turns include the
  pauses inside and after each turn, and FluidAudio marks those as silence.
  FluidAudio marks 69–76 % of each file as speech; false alarm is near zero.
- **Confusion on joint speech** = confusion / frames where both sides say
  someone is speaking. It isolates the speaker-assignment error that users
  would notice, and is the number to track.
- **Speaker counts.** Otter's 3 / 8 / 11 labels include short or generic labels
  (002: 2 of 3 generic-looking, 003: 4 of 11), and Otter sometimes gives one
  person two labels. Against labels with at least 30 s of speech, FluidAudio
  matches on 001 and 002 and finds 6 of 8 on 003, merging quieter or briefer
  speakers.

### 3 h run

The 3 h file is 003 + 001 + 002 + the first 64.1 min of 003 again (10,800 s).
001 and 003 share six named participants, so the scorer treats a named Otter
label as the same person across files and keeps generic labels ("Speaker N",
"Unknown…") separate per file.

- **Memory**: 1.8 GB peak RSS, 1.3 GB peak footprint. That is well under the
  plan's 4 GB trigger for block-wise processing, so use one pass per track.
- **Time**: 35 s, about 3.3 s per 5 min of audio. That is inside the plan's
  1–2 min per track budget with room for two tracks.
- **Agreement drops in the long file.** Scoring each part of the 3 h output on
  its own gives joint-speech confusion of 11.2 % (003, first copy), 2.9 % (001),
  3.4 % (002) and 15.3 % (003, partial copy). The same 003 audio alone gives
  5.2 %. The 3 h file is synthetic: it repeats audio and joins rooms and
  microphones, so the size of the drop in a real 3 h meeting is unknown. The
  pipeline did link people across the joined recordings: all 12 clusters seen
  in the 001 part also occur in the 003 parts.

## Config tuning tried

Joint-speech confusion (002 / 001 / 003) and cluster count on 003 (Otter: 11,
8 with ≥30 s):

| Setting | 002 | 001 | 003 | Clusters on 003 | Wall on 003 |
| --- | --- | --- | --- | --- | --- |
| default (threshold 0.6, step 0.2, min segment 1.0, Fa 0.07, Fb 0.8) | 2.6 % | 1.4 % | 5.2 % | 7 | 17.0 s |
| `clustering.threshold` 0.5 | 2.6 % | 5.2 % | 4.5 % | 6 | 17.0 s |
| `clustering.threshold` 0.7 | 3.6 % | 1.4 % | 5.2 % | 7 | 16.9 s |
| `clustering.threshold` 0.8 | 3.6 % | 22.1 % | 9.8 % | 6 | 16.9 s |
| `segmentation.stepRatio` 0.1 | 3.2 % | 1.7 % | 6.3 % | 10 | 35.0 s |
| `embedding.minSegmentDurationSeconds` 0.5 | 3.5 % | 1.9 % | 6.1 % | 7 | 17.2 s |
| `zeroVoteReembed` enabled | 3.3 % | 1.6 % | 5.2 % | 7 | 17.1 s |
| `skipStrategy` `.maskSimilarity(0.95)` | 2.6 % | 1.4 % | 5.1 % | 7 | 15.3 s |
| `warmStartFa` 0.1 | – | 1.4 % | 16.7 % | 12 (8 with ≥30 s) | 16.8 s |
| `warmStartFb` 0.6 | – | 1.4 % | 10.3 % | 9 (8 with ≥30 s) | 17.0 s |
| compute units `.cpuOnly` | – | – | 5.1 % | 7 | 43.2 s |
| compute units `.cpuAndGPU` | – | – | 5.1 % | 7 | 25.6 s |

Minimum segment 0.5 s lowers approximate DER (001: 23.3 → 20.8 %, 003: 32.4 →
31.0 %) only because it marks more speech, which shrinks the reference
artefact; confusion rises. Mask-similarity skipping saves about 10 % of time
at no measured cost, but the time is already small. **Keep the defaults.**
Turning on `exposeChunkEmbeddings` changed no output and cost no measurable
memory.

## API facts (read from the 0.17.1 checkout)

- **Entry point**: `OfflineDiarizerManager(config: OfflineDiarizerConfig = .default)`,
  then `try await prepareModels(directory: URL? = nil, configuration: MLModelConfiguration? = nil, forceRedownload: Bool = false)`,
  then `try await process(_ url: URL, progressCallback: (@Sendable (Int, Int) -> Void)?) -> DiarizationResult`.
  Overloads take `[Float]` or an `AudioSampleSource`. `prepare(...)` (segmentation +
  embeddings) and `cluster(_: PreparedDiarization)` are public too, so clustering can
  be re-run with a different config without re-extracting embeddings.
  `process(url)` resamples any AVAudioFile-readable format (MP3 and Int16 WAV
  worked) to 16 kHz through a memory-mapped disk-backed source. The class is
  not `Sendable` and not an actor. Requires macOS 14.
- **Progress**: the callback reports `(chunksProcessed, totalChunks)` per 10 s
  segmentation window on an unspecified executor.
- **Result**: `DiarizationResult.segments: [TimedSpeakerSegment]` (`speakerId`
  "S1"…"Sn", `startTimeSeconds`/`endTimeSeconds` as `Float`, `qualityScore`,
  `embedding`), `speakerDatabase: [String: [Float]]?`,
  `chunkEmbeddings: [ChunkEmbedding]?`, and `timings: PipelineTimings?`.
- **Embeddings**:
  - `TimedSpeakerSegment.embedding` is the **cluster centroid**, the same
    256-d vector for every segment of a cluster. It is not a per-segment
    embedding.
  - `speakerDatabase` maps each speaker ID to that centroid (256-d). Centroids
    are the gamma-weighted mean of raw WeSpeaker embeddings (not PLDA space), so
    cosine matching against stored voiceprints works directly.
  - Per-window embeddings: set `config.exposeChunkEmbeddings = true` to get
    `ChunkEmbedding { speakerId, chunkIndex, speakerIndex, startTimeSeconds,
    endTimeSeconds, embedding256: [Float], rho128: [Double] }`, one per (10 s
    window, local speaker slot): 212 / 686 / 2,833 vectors for 002 / 001 / 003.
    `speakerId` uses the same "S<n>" strings as the segments. For a
    per-segment embedding, `HolosDiarization` averages the chunk embeddings
    with the same `speakerId` whose windows overlap the segment.
- **Config knobs** (`OfflineDiarizerConfig`):
  - `segmentation`: `windowDurationSeconds` 10, `stepRatio` 0.2,
    `minDurationOn`/`Off`, onset/offset thresholds (ignored by the powerset
    model).
  - `embedding`: `batchSize` ≤32, `excludeOverlap`, `minSegmentDurationSeconds`
    1.0, `skipStrategy`.
  - `clustering`: `threshold` 0.6 (AHC cut on unit-norm Euclidean distance),
    `warmStartFa`/`Fb`, `minSpeakers`/`maxSpeakers`/`numSpeakers` (K-Means
    re-cluster), `constrainedAssignment`.
  - Other groups: `vbx` (iterations, tolerance), `postProcessing`
    (`minGapDurationSeconds` 0.1, `exclusiveSegments` true), `zeroVoteReembed`,
    and `export.embeddingsPath`. The convenience `withSpeakers(min:max:)` and
    `withSpeakers(exactly:)` set the speaker-count fields.
- **Model download and cache**:
  - Default directory: `~/Library/Application Support/FluidAudio/Models/speaker-diarization/`
    (`OfflineDiarizerModels.defaultModelsDirectory()` plus the repo folder name).
    Pass `directory:` to use Holos's own location; the probe used
    `.local/diarization-probe/models`.
  - The offline variant downloads only `Segmentation.mlmodelc`,
    `FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc` and
    `plda-parameters.json`, plus `config.json`, `provenance.json`,
    `xvector-transform.json` and a `.fluidaudio-revision` marker.
  - The revision is pinned per repo (`Repo.diarizer.revision`). The cache is
    reused only when the marker matches.
  - FluidAudio checks presence and HTTP size only, **not SHA-256**.
    `provenance.json` lists a SHA-256 for every artifact, so `HolosDiarization`
    can verify against a checked-in copy.
  - On any load failure, `prepareModels` **deletes the repo folder and
    downloads again**.
  - `ModelHub.offlineMode = true` makes loads throw `DownloadError.modelMissing`
    instead of touching the network. `OfflineDiarizerModels.load(from:configuration:)`
    plus `manager.initialize(models:)` skips the purge path.
- **First run** (clean cache): `prepareModels` took **11.2 s** (21 MB download
  plus first Core ML load and ANE specialization), with peak RSS 103 MB and
  peak footprint 476 MB. The same files copied to a new path loaded in 1.0 s,
  and a warm load takes 0.15 s. The bundles ship precompiled (`.mlmodelc`), so
  "compile" is load and device specialization.
- **Build**:
  - FluidAudio links a prebuilt binary target, `NemoTextProcessing.xcframework`
    (GitHub release v0.3.1, SwiftPM checksum
    `5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa`), used
    only for text normalization.
  - `Package@swift-6.2.swift` exposes it as the default trait
    `NemoTextProcessing`. Opting out with
    `.package(..., exact: "0.17.1", traits: [])` **failed to link** in an
    incremental build here: `TextNormalizer` still saw
    `canImport(CNemoTextProcessing)`, leaving `_nemo_*` symbols undefined.
    A clean build with the opt-out was not tried.
  - A clean release build of FluidAudio plus the probe took about 70–80 s.
    The probe binary is 18 MB, and `.build` is 1.6 GB.

## License facts

| Component | License | Where read |
| --- | --- | --- |
| FluidAudio code | Apache License 2.0 | `LICENSE` and README "License" section in the 0.17.1 checkout |
| VBx port / fastcluster / NemoTextProcessing binary | Apache 2.0 / BSD-2-Clause-style / Apache 2.0 (its bundled deps Apache-2.0 or MIT) | `ThirdPartyLicenses/vbx-LICENSE.md`, `fastcluster-LICENSE.md`, `NemoTextProcessing-LICENSE.md` in the checkout |
| Offline diarization models (`Segmentation`, `FBank`, `Embedding`, `PLDA`, `PldaRho`, `plda-parameters.json`, `xvector-transform.json`) | Model card front matter: `license: other`, `license_name: scoped-cc-by-4.0`. Card text: "The supported Community-1 artifact set is distributed under CC-BY-4.0." | Hugging Face `FluidInference/speaker-diarization-coreml` at `df2625ac…`: `README.md`, `NOTICE.md` |
| Upstream pipeline | "The underlying Community-1 pipeline is published by pyannote under CC-BY-4.0" (the upstream repo is gated: access requires accepting its conditions) | `NOTICE.md`; `PROVENANCE.md` ("Access to the gated upstream model and acceptance of its user conditions are required") |
| PLDA parameters | "The rights holder explicitly licenses `plda.npz` and `xvec_transform.npz` under CC-BY-4.0, including commercial use" (Brno University of Technology / BUT Speech@FIT) | `NOTICE.md` |
| Legacy models (`pyannote_segmentation`, `wespeaker*`) | "not covered by this Community-1 provenance and license-scope confirmation"; the offline pipeline does not download them | `NOTICE.md`, `README.md` |

`NOTICE.md` asks that attribution "identify pyannote, WeSpeaker, BUT Speech@FIT,
and Fluid Inference, retain the citations in README.md, link CC-BY-4.0, and
indicate that the files are modified Core ML conversions". Holos's credits
screen and `THIRD_PARTY_NOTICES` need that text. `PROVENANCE.md` says the
segmentation and embedding binaries are "historically reconstructed, not
build-attested": the exact 2025 converter commit was not recorded.

## Recommendation

Go with FluidAudio 0.17.1 `OfflineDiarizerManager` and default config:

1. One pass per track after stop. Drop the block-wise fallback from PR7 unless
   a longer recording than 3 h is supported.
2. `HolosDiarization` owns the model directory, passes it to
   `prepareModels`/`OfflineDiarizerModels.load`, and verifies SHA-256 against
   a checked-in copy of `provenance.json` at revision `df2625ac…`. After install,
   run with `ModelHub.offlineMode = true` so diarization never downloads on
   its own and a failed load cannot purge and refetch.
3. Store `speakerDatabase` centroids per cluster. Enable
   `exposeChunkEmbeddings` and derive per-segment embeddings by averaging, for
   the split and assign tools and voiceprint samples.
4. Report progress from `progressCallback`. Expect about 35 s for 3 h on this
   machine with the ANE, and about 2.5× that on CPU only.
5. Treat speaker count as approximate. Quiet or brief speakers merge into
   others (003: 6 clusters with ≥30 s against 8 Otter labels with ≥30 s), so
   the review UI's split tool matters more than the merge tool.

## Reproduce

```sh
cd .local/diarization-probe
swift build -c release
.build/release/Probe --prepare-only --models "$PWD/models"
./run1.sh 003 5332.968 default                 # probe + der.py, counts only
python3 der.py --ref "<transcript>:0:<duration>" --hyp runs/003.default.segments.json
```

Probe flags: `--models DIR`, `--out PATH`, `--threshold`, `--step-ratio`,
`--min-segment`, `--fa`, `--fb`, `--num-speakers`, `--max-speakers`,
`--skip-mask`, `--zero-vote`, `--chunk-embeddings`, `--compute cpu|gpu|ane|all`.
The 3 h WAV was deleted after the run (345 MB).

## PR7a results

Measured 2026-09-24 on the same machine with `HolosDiarization` (`FluidDiarizer`,
default configuration with `exclusiveSegments` false).

### Pinned model files

`HOLOS_RECORD_MODEL_MANIFEST=1 holos setup --speakers` listed 24 files
(21,786,966 bytes) at revision `df2625ac…`; tree digest
`9540dc3b91e348d28110db4caf560d7c2d5bdd6d54e3658ad8e7ae0a7d809da6`.

- The 22 model artifacts match the SHA-256 and size in the repo's
  `provenance.json`. It lists 17 more (`PLDA.mlmodelc`, `mlpackages/`) that the
  offline variant does not download.
- All 24 files, including `config.json` and `provenance.json`, match the Hugging
  Face tree API at the pinned revision (`lfs.oid` for LFS files, the git blob
  SHA-1 for the others).
- `holos setup --speakers`: download 8.4 s, then SHA-256 verification and the
  first Core ML load (1.16 s) before the folder is renamed into place.

### Three-voice fixture

`HOLOS_DIARIZATION_FIXTURE=1` (`threeVoiceFixtureMeetsDER`): 12 alternating
turns of 5–8 s from three system voices, 0.6 s of silence between turns, 85.8 s
rendered to a 16 kHz Int16 CAF and read through `Int16CAFSampleSource`. The
reference marks where each turn is audible (10 ms frames above −40 dBFS, pauses
under 0.25 s bridged); DER uses a 0.25 s collar. Debug test build.

| Voices | Clusters | DER | Miss | False alarm | Confusion | Scored | Diarize wall |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Moira (en-IE), Evan (en-US), Daniel (en-GB): the fixture's choice | 3 | 1.63 % | 0.00 s | 0.20 s | 0.91 s | 68.2 s | 0.79 s |
| Samantha (en-US), Evan, Daniel | 3 | 1.48 % | 0.00 s | 0.11 s | 0.91 s | 69.0 s | 0.79 s |
| Samantha, Evan, Rishi (en-IN) | 3 | 0.65 % | 0.35 s | 0.10 s | 0.00 s | 69.7 s | 0.76 s |
| Samantha, Evan, Karen (en-AU, super-compact) | 2 | 34.1 % | 0.00 s | 0.30 s | 23.21 s | 68.9 s | 0.76 s |

The two female compact voices (Samantha, Karen) merged into one cluster, so the
fixture picks a female voice, a male voice, and a second male voice from another
English locale. FluidAudio's `totalProcessingSeconds`, which includes the model
load time, was 1.1 s per run. It adds that load time on every call, even when the
models are cached, so `FluidDiarizer` records its own wall time as
`processingSeconds` instead (the load counts only on the call that loads).

## PR7c results

Measured 2026-09-24 on the same machine (Apple M4 Pro, 48 GB) with a release build
of `holos` (PR7c branch). Each Otter recording was imported once with
`holos session import` (en-CA, Speech backend), then labelled with
`holos session diarize --force` in each configuration and scored with
`holos session score`. The session's rendered 16 kHz Int16 track goes through
`FluidDiarizer` (§4.8), not `process(url)` on the MP3 as in S1. Everything else is
the default configuration.

All numbers are **agreement with Otter**, as in S1: confusion is the share of the
time where both Otter and Holos have a speaker whose speaker differs after the best
one-to-one mapping, with a 0.25 s collar around Otter turn boundaries. "Segments"
scores the diarizer's segments (S1's measure, "confusion on joint speech"); "turns"
scores the labelled transcript's turns, one speaker per word. Otter's last turn runs
to the end of the audio. Speaker counts in parentheses have at least 30 s (Otter:
turn time; Holos: speech).

### Imports

| Pair | Audio | Import (copy + transcription) |
| --- | ---: | ---: |
| 002 | 411.8 s | 5.2 s |
| 001 | 1,211.4 s | 12.8 s |
| 003 | 5,333.0 s | 64.5 s |

### Speaker labels per configuration

| Pair | Configuration | Otter speakers | Holos speakers | Confusion, segments | Compared | Confusion, turns | Compared | Diarize | Whole command | Peak RSS | Peak footprint | Mic offset |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 002 | default (`exclusiveSegments` false) | 3 (2) | 2 (2) | 1.9 % | 277.8 s | 3.0 % | 298.5 s | 1.4 s | 1.7 s | 376 MB | 851 MB | 0.00 s |
| 002 | `exclusiveSegments` true | 3 (2) | 2 (2) | 2.6 % | 277.6 s | 3.3 % | 299.1 s | 1.5 s | 1.8 s | 367 MB | 842 MB | 0.00 s |
| 002 | hint 1–3 (n − 1 to n + 1) | 3 (2) | 2 (2) | 1.9 % | 277.8 s | 3.0 % | 298.5 s | 1.4 s | 1.7 s | 347 MB | 815 MB | 0.00 s |
| 002 | exactly 2 | 3 (2) | 2 (2) | 1.9 % | 277.8 s | 3.0 % | 298.5 s | 1.3 s | 1.6 s | 370 MB | 843 MB | 0.00 s |
| 002 | at least 2 | 3 (2) | 2 (2) | 1.9 % | 277.8 s | 3.0 % | 298.5 s | 1.4 s | 1.6 s | 346 MB | 815 MB | 0.00 s |
| 001 | default (`exclusiveSegments` false) | 8 (7) | 7 (7) | 1.4 % | 919.5 s | 1.7 % | 1,004.7 s | 3.8 s | 4.2 s | 427 MB | 846 MB | 0.00 s |
| 001 | `exclusiveSegments` true | 8 (7) | 7 (7) | 1.4 % | 919.5 s | 1.7 % | 1,004.7 s | 3.7 s | 4.1 s | 427 MB | 827 MB | 0.00 s |
| 001 | hint 6–8 | 8 (7) | 7 (7) | 1.4 % | 919.5 s | 1.7 % | 1,004.7 s | 3.7 s | 4.1 s | 427 MB | 823 MB | 0.00 s |
| 001 | exactly 7 | 8 (7) | 7 (7) | 1.4 % | 919.5 s | 1.7 % | 1,004.7 s | 3.8 s | 4.2 s | 428 MB | 845 MB | 0.00 s |
| 001 | at least 7 | 8 (7) | 7 (7) | 1.4 % | 919.5 s | 1.7 % | 1,004.7 s | 4.5 s | 5.0 s | 439 MB | 861 MB | 0.00 s |
| 003 | default (`exclusiveSegments` false) | 11 (8) | 7 (6) | 5.1 % | 3,688.5 s | 5.0 % | 3,987.2 s | 15.8 s | 17.1 s | 783 MB | 1,052 MB | 0.00 s |
| 003 | `exclusiveSegments` true | 11 (8) | 7 (6) | 5.2 % | 3,684.3 s | 5.1 % | 3,988.1 s | 15.2 s | 16.6 s | 783 MB | 1,054 MB | 0.00 s |
| 003 | hint 7–9 | 11 (8) | 7 (6) | 5.1 % | 3,688.5 s | 5.0 % | 3,987.2 s | 15.3 s | 16.5 s | 784 MB | 1,058 MB | 0.00 s |
| 003 | exactly 8 | 11 (8) | 8 (8) | 17.1 % | 3,663.9 s | 17.3 % | 3,977.5 s | 16.6 s | 17.8 s | 736 MB | 1,056 MB | 0.00 s |
| 003 | at least 8 | 11 (8) | 8 (8) | 17.1 % | 3,663.9 s | 17.3 % | 3,977.5 s | 16.9 s | 18.3 s | 741 MB | 1,057 MB | 0.00 s |

"Diarize" is the post-processor's diarize stage; "whole command" is the
`holos session diarize` process (render, diarize, align, exports), and peak RSS and
footprint are that process's `/usr/bin/time -l` "maximum resident set size" and
"peak memory footprint". An earlier full run gave the same confusion values and
speaker counts, with diarize times within 0.8 s.

What these settle:

- **`exclusiveSegments` stays false.** With overlapping segments kept, confusion is
  equal (001) or lower (002: 1.9 % against 2.6 %; 003: 5.1 % against 5.2 %), on
  segments and on turns alike. The §4.8 rule switches the default only when false
  raises joint-speech confusion by more than one percentage point on any recording.
  The `exclusiveSegments` true row reproduces S1's joint-speech confusion (2.6 %,
  1.4 %, 5.2 %).
- **The speaker-count hint does not recover merged speakers.** The design's
  n − 1 to n + 1 hint (n = Otter labels with at least 30 s) changed nothing: the
  diarizer's own count was already inside the range on all three recordings.
  Forcing the count up (exactly 8, or at least 8, on 003) gave 8 clusters but
  raised confusion from 5.1 % to 17.1 %: the extra cluster splits people rather than
  separating the merged ones. On 001 and 002 the stronger hints changed nothing.
- **Track offsets are 0.** `AlignmentInfo.trackOffsets["mic"]` was 0.00 s in every
  run: no shift within ±0.5 s covered 1 % more word time than none.
- **Time and memory.** The 89-minute recording diarizes in 15–17 s at 736–784 MB
  peak RSS (S1: 17.0 s and 947 MB with `process(url)`), and the whole command takes
  under 19 s. Importing it (copying the audio and transcribing it once) took 65 s.
- Not measured here: a real 3 h meeting (H20); S1's synthetic 3 h file rose from
  5.2 % to 11.2 % confusion.

### Calibration: cross-recording centroid distances

`--calibrate` labelled 001 and 003 with the hidden `--voice-data` (default
configuration) and compared each Holos cluster mapped to a named Otter label in 001
with each one in 003: cosine distance (1 − cosine similarity) between the cluster
centroids (raw 256-d WeSpeaker space). Same person means the same named label in
both files. No mapped cluster had a generic Otter label ("Speaker N"). Only 5 of the
six shared participants were mapped to a cluster in both files.

| Pairs | Count | Min | 5th pct | Median | 95th pct | Max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Same person | 5 | 0.076 | 0.077 | 0.197 | 0.235 | 0.244 |
| Different people | 37 | 0.421 | 0.514 | 0.846 | 0.992 | 1.044 |

The smallest distance with at most 5 % of the different-person pairs below it is
**0.444** (1 of 37 pairs, 0.421, lies below it); all 5 same-person pairs are at or
below it. This is the measurement §4.10 asks PR10 to use for
`defaultThresholds.possibleMaxDistance`; the sample is small (42 pairs from two
recordings of one team).

### Reproduce

```sh
swift build -c release --product holos
holos=.build/release/holos
"$holos" setup --locale en-CA            # the CLI needs its own speech assets
"$holos" setup --speakers
swift scripts/evaluate-references.swift \
  --input .local/diarization-probe/data --reference-format otter \
  --cli "$holos" --speakers --calibrate
```

The script prints and writes (`summary.json`, `summary.md` under
`.local/evaluation/`) counts, seconds, ratios, and distances only. Otter labels
appear only as hashed keys inside `holos session score --json`, which the script
reads but does not keep. The temporary sessions are deleted unless
`--keep-sessions`.
