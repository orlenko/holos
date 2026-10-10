# Post-processing

`MeetingPostProcessor` and the diarizer seam (`SpeakerDiarizer`, `FluidDiarizer`, `FakeDiarizer`).

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.7 MeetingPostProcessor

`Sources/HolosMeeting/MeetingPostProcessor.swift`. PR1 creates it with its final
signatures; PR7b fills in the stages; PR10 adds voice data and recognition.

```swift
public struct PostProcessingOptions: Sendable, Equatable {
    public var speakers: SpeakerCountHint?
    /// Relabel even when the head run has edits. Names and links carry over (§4.9).
    public var force: Bool
    public var keepDerived: Bool
    /// Overrides meeting.json `othersInRoom` for this run.
    public var othersInRoom: Bool?
    /// Hidden engine settings for evaluation, e.g. ["exclusiveSegments": "true"]; recorded in the run.
    public var engineOverrides: [String: String]
    /// Write speakers/voice/<runID>.json even when "Remember voices" is off (hidden; evaluation sessions only).
    public var forceVoiceData: Bool
    /// The stop reason when called right after a recording; `diskLow` skips rendering.
    public var stopReason: StopReason?
    public init(speakers: SpeakerCountHint? = nil, force: Bool = false, keepDerived: Bool = false,
                othersInRoom: Bool? = nil, engineOverrides: [String: String] = [:], forceVoiceData: Bool = false,
                stopReason: StopReason? = nil)
}

public struct MeetingPostProcessor: Sendable {
    /// PR1: `run` returns a `.skipped` record and writes nothing. From PR7b: runs the stages below;
    /// `diarizer == nil` gives speaker-less exports and the setup hint.
    public init(diarizer: (any SpeakerDiarizer)? = nil, options: PostProcessingOptions = .init(),
                freeSpace: any FreeSpaceProvider = VolumeFreeSpace())
    /// Runs every stage for one finished session under `lease` (nil: acquire one, retry 1 s) and returns the
    /// final postprocess.json record. Throws only when it cannot start (still recording, lease held elsewhere,
    /// unreadable manifest, a postprocess.json written by a newer Holos); stage failures are recorded in the
    /// returned record.
    public func run(session: URL, lease: ProcessingLease?,
                    progress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> PostProcessingRecord
}
```

PR10 adds one initializer parameter, `profiles: SpeakerProfileStore? = nil`; with a
store whose `rememberVoices` is on, stage 7 runs on the in-memory voice data. Stage 6
never writes voice data for normal meetings (only with hidden `forceVoiceData`, §4.10).

Stages (PR7b):

| # | Stage | Does | On failure or not applicable |
|---|---|---|---|
| 0 | — | refuse if `SessionArchive.isActive` ("still recording"); use the given lease or acquire one; refuse (`unavailable`) an existing `postprocess.json` written by a newer Holos, never overwriting it (a damaged one is replaced); `RecorderChannel.markDeadRecorderExited`; delete leftover `derived/`; write `postprocess.json` `{state: running}` | throw |
| 1 | `transcript` | load the current transcript (`transcripts/current.json`, §2.4); after language merging, reconcile live text hints by segment ID or same-track time+words, then run ordinary word fixes | none → `skipped`, no exports; state `skipped` |
| 2 | — | track policies from `meeting.json` (or `MeetingInfo.inferred`), with `options.othersInRoom` overriding: a track is `diarized` if it is `system`, or the mode is `inPerson`, or others are in the room; otherwise `channel("mic:me", "Me")`; tracks without words are `skipped` | — |
| 3 | — | if a head run exists, was built from the current transcript, has applied edits, and `!force`: skip 4–7 with "Speaker labels were edited; relabel with --force (names carry over)". If the head was built from another transcript, relabel. | stages `skipped` |
| 4 | `render` | skip with "Not enough disk space to label speakers. Free some space, then use Label Speakers." when `stopReason == .diskLow` or `DiskPolicy.renderCheck` fails. Otherwise `TrackRenderer.render` each diarized track to `derived/<track>-16k.caf`, compressing long gaps (below) | failed → skip 5–7 |
| 4b | `echo` | when the analysis is needed (§5.11, `EchoAnalysisStage.needed`: a call with microphone and system audio and no saved analysis of that audio), whether or not a track is diarized, also for edited labels stage 3 keeps; not after a `diskLow` stop: renders the track stage 4 did not (the microphone of a call labelled as "Me"), then `EchoAnalysis` on the two renders, saved to `echo/` (`EchoMaskStore`). The run is built without it; the labels' view hides the echo | failed → recorded for reading only; nothing saved, so the next pass (or Recover) tries again |
| 5 | `diarize` | `nil` diarizer → `skipped`, "Speaker models are not installed. Install them from Setup, or run holos setup --speakers." Otherwise `diarizer.diarize` each rendered track, **one track at a time**, then map times to the session timeline with the render's time map. Speaker hint: `options.speakers`, else `meeting.json` `expectedSpeakers` n as `minimum: n − 1, maximum: n + 1` (or the form PR7c found best) | failed → skip 6–7 |
| 6 | `align` | `SpeakerRunBuilder.build` (PR5a, pure) → run (no embeddings) plus in-memory voice data. Under the speaker lock: `writeRun`; `writeHead`; `writeVoiceData` only with `forceVoiceData` (evaluation; never for normal meetings); append carry-over edits (§4.9) when the previous head had names, links, or rejections. Release the lock. | failed → skip 7 |
| 7 | `recognize` | PR10: when "Remember voices" is on and some profile has samples: `SpeakerRecognizer.recognize` on the in-memory centroids → `writeRecognition` (distances only) | failed → continue |
| 8 | `export` | apply live speaker-name hints to the aligned speaker at their words/time unless a later explicit rename governs it; `SessionExports.regenerate` (takes the speaker lock itself; stage 6 has released it) | failed → state `failed` |
| 9 | — | delete `derived/` whatever happened (unless `keepDerived`); write the final record; release the lease if `run` acquired it | — |

Final state: `succeeded` if every applicable stage succeeded; `partial` if export
succeeded but a speaker stage failed or was skipped because of existing edits or disk
space; `failed` if export failed. Expected skips (no diarized tracks, speaker models not
installed, "Remember voices" off) do not make the state `partial`, so a recording made
without speaker models still exits 0; the skip message is stored in the record, copied
to `RecorderExit.postprocessingMessage`, and shown in the app ("Saved Council meeting.
No speaker labels: speaker models are not installed. [Install…]"). An explicit
`holos session diarize` without verified models fails early (exit 1) with the setup
hint. `postprocess.json` writes are throttled to one per 250 ms plus every stage change.

Added later before stage 2: stage 1b `languages` (§4.14), stage 1c live text hints, and
stage 1d `wordFixes` (learned corrections and the word list's "often heard as" terms applied
to the live-corrected transcript, which becomes a new current revision; docs/design.md
"Meeting word fixes"). Text-changing stages are skipped with `keepTranscript`; speaker-name
hints are still applied. A live-hint or word-fix problem makes the record `partial` too.
Stage 1b′ `deepTranscription` (docs/meeting-design.md §4.16) runs between 1b and 1c, only when asked for by name
(`PostProcessingOptions.deepTranscribe`).

**Render time map** (PR7b, in `TrackRenderer`). A meeting left paused for hours would
otherwise render hours of silence. Gaps longer than 60 s (including before the first
chunk) become 5 s of silence in the render. `RenderedTrack.timeMap` lists
`RenderSpan(renderStart, sessionStart, duration)` for the audio; `RenderTimeMap.map`
converts a `DiarizerOutput` back to session time: a time inside a span maps linearly, a
time inside inserted silence snaps to the nearest span edge, and a segment or window
that crosses inserted silence is split at the span edges with the silent part dropped.
Renders stay 16 kHz mono Int16; the diarizer reads them with `Int16CAFSampleSource`
(§4.8), never with a Float32 temporary copy.

Callers:

- `RecordingWorkflow.run` through `PostProcessHook` (§4.6): the CLI runs
  `MeetingPostProcessor` in the recorder process; the in-process app runs
  `holos session diarize --after-recording` in a child.
- `holos session diarize` (PR7b), `holos session recover` (PR3), `holos session import`
  (PR7c), and the app's Label Speakers, Find More Speakers, and automatic relabel
  (PR4, PR9) through `holos session diarize`.

### 4.8 SpeakerDiarizer, FluidDiarizer, FakeDiarizer

The protocol is in `Sources/HolosCore/SpeakerModels.swift`. Implementations:

**`FakeDiarizer` (PR5a, `Sources/HolosSpeakers/FakeDiarizer.swift`)**, public so
HolosMeeting tests can use it:

```swift
public struct FakeDiarizer: SpeakerDiarizer {
    public var outputs: [String: DiarizerOutput]      // by track
    public var info: DiarizationEngineInfo
    public var error: HolosError?
    public init(outputs: [String: DiarizerOutput], info: DiarizationEngineInfo = .fake, error: HolosError? = nil)
    /// Throws `error` if set.
    public func engineInfo() async throws -> DiarizationEngineInfo
    /// Calls progress(0) then progress(1); returns outputs[request.track] or an empty output; throws `error` if set.
    public func diarize(_ request: DiarizationRequest,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput
    /// Speakers take turns of `turnSeconds` over [0, duration) in order; centroids are orthogonal
    /// unit vectors of `dimension`; one EmbeddingWindow per turn equal to its speaker's centroid.
    public static func alternating(speakers: [String], turnSeconds: Double, duration: Double,
                                   dimension: Int = 8) -> DiarizerOutput
}
extension DiarizationEngineInfo {
    /// engine "Fake", version "1", no models, embeddingModel ("fake", "1"), dimension 8.
    public static let fake: DiarizationEngineInfo
}
```

**`FluidDiarizer` (PR7a, `Sources/HolosDiarization/`).** Everything below comes from
spike S1: the FluidAudio 0.17.1 checkout (`5c51c5c9`) and runs on the three Otter
recordings plus a synthetic 3 h file ([speaker-evaluation.md](../speaker-evaluation.md)).

FluidAudio API used, and nothing else:

| Purpose | FluidAudio 0.17.1 API |
|---|---|
| Load models, no network | `ModelHub.offlineMode = true`, then `OfflineDiarizerModels.load(from: directory, configuration: nil)` |
| Download (only in `holos setup --speakers`) | `ModelHub.offlineMode = false`, then `OfflineDiarizerModels.load(from: partialDirectory)`, which downloads the pinned revision into `<directory>/speaker-diarization/` |
| Manager | `OfflineDiarizerManager(config:)` and `initialize(models:)`; never `prepareModels`, whose failure path deletes the model folder and downloads again |
| Run | `process(audioSource:audioLoadingSeconds:progressCallback:)`; the callback reports `(chunksProcessed, totalChunks)` per 10 s window on an unspecified executor |
| Audio input | `protocol AudioSampleSource: Sendable { var sampleCount: Int { get }; func copySamples(into: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws }` |
| Config | `OfflineDiarizerConfig.default`; `exposeChunkEmbeddings`; `postProcessing.exclusiveSegments`; `clustering.threshold`; `withSpeakers(min:max:)`, `withSpeakers(exactly:)` |
| Result | `DiarizationResult { segments: [TimedSpeakerSegment], speakerDatabase: [String: [Float]]?, chunkEmbeddings: [ChunkEmbedding]?, timings: PipelineTimings? }` |
| Segment | `TimedSpeakerSegment { speakerId ("S1"…), embedding, startTimeSeconds: Float, endTimeSeconds: Float, qualityScore: Float }`; `embedding` is the cluster centroid, the same vector for every segment of a cluster |
| Window embedding | `ChunkEmbedding { speakerId, chunkIndex, speakerIndex, startTimeSeconds, endTimeSeconds, embedding256: [Float], rho128: [Double] }`, one per (10 s window, local speaker slot) |
| No speech | `OfflineDiarizationError.noSpeechDetected` → an empty `DiarizerOutput` |

```swift
public struct FluidDiarizerConfiguration: Sendable, Equatable {
    /// false keeps overlapping speech so alignment can mark overlap (FluidAudio default is true).
    public var exclusiveSegments: Bool
    /// nil uses FluidAudio's community-1 default (0.6, the best value S1 tried).
    public var clusteringThreshold: Double?
    public static let `default` = FluidDiarizerConfiguration(exclusiveSegments: false, clusteringThreshold: nil)
    /// Applies `PostProcessingOptions.engineOverrides` ("exclusiveSegments", "clusteringThreshold").
    public func overridden(by overrides: [String: String]) throws -> FluidDiarizerConfiguration
}

public actor FluidDiarizer: SpeakerDiarizer {
    public init(modelsDirectory: URL = FluidModels.defaultDirectory,
                configuration: FluidDiarizerConfiguration = .default)
    public func engineInfo() async throws -> DiarizationEngineInfo
    public func diarize(_ request: DiarizationRequest,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerOutput
}

public struct PinnedFile: Sendable, Equatable {
    /// Relative to FluidModels.repoFolder(in:), e.g. "Embedding.mlmodelc/coremldata.bin".
    public let relativePath: String
    public let size: Int
    public let sha256: String
}

public enum ModelInstallStatus: Sendable, Equatable {
    case notInstalled
    case verified
    /// Files that are missing, the wrong size, or fail SHA-256; ".fluidaudio-revision" when the marker differs.
    case corrupt(files: [String])
}

public enum FluidModels {
    public static let repository = "FluidInference/speaker-diarization-coreml"
    /// The revision FluidAudio 0.17.1 pins for this repo (`Repo.diarizer.revision`).
    public static let revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    /// <supportRoot>/Models/speaker-diarization-coreml@df2625ac79a7; passed to FluidAudio as `directory:`.
    public static var defaultDirectory: URL { get }
    /// <directory>/speaker-diarization (FluidAudio's `Repo.diarizer.folderName`), where the files live.
    public static func repoFolder(in directory: URL) -> URL
    /// No network. Checks `.fluidaudio-revision` == revision and every pinned file's size and SHA-256.
    public static func status(directory: URL = defaultDirectory,
                              pinned: [PinnedFile] = PinnedModels.files) -> ModelInstallStatus
    /// Network. Downloads into "<directory>.partial-<UUID>", verifies against `pinned`, renames into place.
    /// Never leaves a partially verified directory at `directory`; deletes the partial folder on failure.
    public static func install(directory: URL = defaultDirectory, pinned: [PinnedFile] = PinnedModels.files,
                               progress: @escaping @Sendable (Double) -> Void) async throws
}
```

Adapter rules:

- **Memory and time: one pass per track, one track at a time.** S1 on this M4 Pro: 3 h
  in 35 s at 1.8 GB peak RSS (1.3 GB peak footprint); 89 min in 17 s at 0.95 GB. That
  is far under the plan's 4 GB trigger, so the block-wise fallback is not built
  (resolution R41). Running tracks one after another keeps the peak at one track's. A
  3 h call with both tracks diarized takes about 70 s plus rendering. CPU-only would be
  about 2.5× slower; compute units stay `.all` (FluidAudio keeps FBank on the CPU).
- **Configuration.** `OfflineDiarizerConfig.default` (clustering threshold 0.6, step
  ratio 0.2, minimum segment 1.0 s, Fa 0.07, Fb 0.8: the best of every setting S1 tried),
  then `exposeChunkEmbeddings = true` (S1: no change in output or memory),
  `postProcessing.exclusiveSegments = configuration.exclusiveSegments`, the speaker hint
  through `withSpeakers(min:max:)` or `withSpeakers(exactly:)`, and the threshold if set.
  S1 scored only `exclusiveSegments = true`. PR7c runs the Otter evaluation with both
  values; keep `false` (needed for overlap marking) unless joint-speech confusion rises
  by more than one percentage point on any recording, in which case the default becomes
  `true` and overlap marking is limited to what alignment infers.
- **Model files and cache.** The offline variant downloads, into
  `<defaultDirectory>/speaker-diarization/`: `Segmentation.mlmodelc`, `FBank.mlmodelc`,
  `Embedding.mlmodelc`, `PldaRho.mlmodelc` (folders), `plda-parameters.json`,
  `xvector-transform.json`, `config.json` (`{}`), `provenance.json`, and the
  `.fluidaudio-revision` marker; 21 MB. FluidAudio checks only presence and HTTP size,
  and in offline mode a marker that does not match the pinned revision makes the load
  throw `modelMissing`. First install took 11.2 s (download plus first Core ML load);
  loading from a fresh path 1.0 s; warm 0.15 s.
- **Loading.** `diarize` first calls `FluidModels.status`; anything but `.verified` throws
  `HolosError.unavailable("Speaker models are missing or damaged. Install them from Setup, or run holos setup --speakers.")`.
  `FluidDiarizer.init` sets `ModelHub.offlineMode = true`; only `FluidModels.install`,
  which runs in its own `holos setup --speakers` process, sets it to false. The actor
  caches the `Sendable` `OfflineDiarizerModels`; each `diarize` creates a local
  `OfflineDiarizerManager`, calls `initialize(models:)`, and runs inside a nonisolated
  async helper (§1.3).
- **Pinned checksums.** `Sources/HolosDiarization/PinnedModels.swift` lists
  `PinnedFile(relativePath, size, sha256)` for every downloaded file, relative to
  `repoFolder`. The 22 artifacts listed in the repo's `provenance.json` (which carries a
  SHA-256 per file; the S1 cache matches all 22) are pinned from it. `config.json` and
  `provenance.json` are not listed in `provenance.json`; pin their SHA-256 after checking
  them against the Hugging Face tree API at the pinned revision
  (`https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml/tree/df2625ac79a7ac6b65ad868fee6d80f320da4232?recursive=1`:
  `lfs.oid` is the SHA-256 of an LFS file; `oid` is the git blob SHA-1 of a small file).
  The PR7a implementer runs `HOLOS_RECORD_MODEL_MANIFEST=1 holos setup --speakers` (prints
  the manifest instead of verifying), checks each entry that way, and commits the list.
  `ModelTreeDigest` = SHA-256 over sorted lines `"<relativePath>\t<size>\t<sha256>\n"`;
  the run records one `ModelDescriptor` for the repo with that digest.
- **Audio source.** `Int16CAFSampleSource` implements `AudioSampleSource` over an mmap of
  the rendered CAF (data offset from `AudioFileGetProperty(kAudioFilePropertyDataOffset)`;
  requires 16 kHz, mono, 16-bit little-endian) and converts to Float in `copySamples`.
  The mmap wrapper is `@unchecked Sendable` with its invariant stated. There is no
  `process(url)` fallback: it would add a ~690 MB Float32 temporary copy for 3 h on a
  nearly full disk.
- **Mapping.** `TimedSpeakerSegment` → `RawDiarizationSegment(speaker: speakerId,
  start:, end:, quality: qualityScore)`; `speakerDatabase` → `centroids` (raw WeSpeaker
  256-d space, not PLDA space, so cosine comparison is meaningful); `chunkEmbeddings` →
  `windows` (`embedding256`); `timings.totalProcessingSeconds` → `processingSeconds`.
  These vectors stay in memory; only the post-processor decides whether any are
  persisted (§4.10).
- **engineInfo():** engine `FluidAudio.OfflineDiarizerManager`, version `0.17.1`, one
  `ModelDescriptor(id: FluidModels.repository, revision:, sha256: <tree digest>)`,
  `embeddingModel = EmbeddingModelID(id: "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
  revision: FluidModels.revision)`, dimension 256, flattened configuration.
- **Accuracy to expect.** Joint-speech confusion against Otter was 1.4–5.2 % on the real
  recordings and 11.2 % on the synthetic 3 h file. Speaker counts are approximate: on
  the 89-minute recording FluidAudio found 6 of 8 people with at least 30 s of speech,
  merging quieter or briefer speakers into others. The review window's New Speaker,
  split, and Find More Speakers tools matter more than merge (PR9).
- **License and credits.** PR7a writes `THIRD_PARTY_NOTICES.md` at the repo root:
  1. FluidAudio 0.17.1 (`https://github.com/FluidInference/FluidAudio`, tag v0.17.1,
     commit `5c51c5c9`): Apache License 2.0, with the full text of the checkout's
     `LICENSE`, and every file in its `ThirdPartyLicenses/` folder verbatim (VBx port,
     Apache 2.0; fastcluster, BSD-2-clause style; NemoTextProcessing binary v0.3.1,
     Apache 2.0; and the text-frontend notices that ship in the same module).
  2. The speaker diarization models, with this text:

     > Speaker labels use `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`,
     > `PldaRho.mlmodelc`, `plda-parameters.json`, and `xvector-transform.json` from
     > https://huggingface.co/FluidInference/speaker-diarization-coreml (revision
     > df2625ac79a7ac6b65ad868fee6d80f320da4232), downloaded by `holos setup --speakers`
     > and not included in the app. They are licensed under the Creative Commons
     > Attribution 4.0 International License (CC BY 4.0,
     > https://creativecommons.org/licenses/by/4.0/). They are modified Core ML conversions,
     > made by Fluid Inference, of the pyannote Community-1 speaker diarization pipeline
     > (pyannote, CC BY 4.0), which uses WeSpeaker speaker embeddings and PLDA parameters
     > licensed by BUT Speech@FIT under CC BY 4.0. The model card describes the
     > segmentation and embedding conversions as historically reconstructed, not
     > build-attested.
     >
     > Citations:
     > - Alexis Plaquet and Hervé Bredin. "Powerset multi-class cross entropy loss for
     >   neural speaker diarization." Proc. INTERSPEECH 2023.
     > - Hongji Wang, Chengdong Liang, Shuai Wang, Zhengyang Chen, Binbin Zhang, Xu Xiang,
     >   Yanlei Deng, and Yanmin Qian. "Wespeaker: A research and production oriented
     >   speaker embedding learning toolkit." ICASSP 2023.
     > - Federico Landini, Ján Profant, Mireia Diez, and Lukáš Burget. "Bayesian HMM
     >   clustering of x-vector sequences (VBx) in speaker diarization: theory,
     >   implementation and analysis on standard tasks." Computer Speech & Language, 2022.

  `holos setup --speakers` prints one credits line after installing ("Speaker models by
  Fluid Inference (pyannote, WeSpeaker, BUT Speech@FIT), CC BY 4.0; see
  THIRD_PARTY_NOTICES.md."). PR4's About panel embeds the model text above and the
  FluidAudio line as a string constant (the app has no resource bundle).
