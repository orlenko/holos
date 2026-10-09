# Session format

The session folder, the global files, the session timeline, the current transcript, and the contract types with
examples of their JSON.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

## 2. Session folder, global files, session time

### 2.1 Session folder

```
<SESSION-UUID>.holos/                      owner                        notes
  manifest.json                            SessionArchive               schema v1, unchanged
  events.jsonl                             SessionArchive               new kinds: `MeetingModels.swift`; failed appends leave no partial line
  .writer.lock .processing.lock .speakers.lock  PR6                     flock files
  meeting.json                             PR2a (record), PR7c (import) MeetingInfo; absent in old archives
  vocabulary.json                          PR2a (record), PR7c (import) MeetingVocabulary; absent means none
  status.json                              PR2a                         RecorderStatus; kept after exit (phase exited)
  live-hints.json                          live transcript              atomic timed text/speaker corrections
  control/<REQUEST-UUID>.json              PR2a                         ControlRequest; deleted when handled; leftovers deleted at exit
  postprocess.json                         PR7b                         PostProcessingRecord
  audio/{mic,system}/NNNNNN.caf            AudioChunkWriter             Int16 from PR2a, system audio mono; Float32 still readable
  audio-deleted.json                       PR3                          written by Delete Audio; chunks are intentionally absent
  summary.json                             titles-summaries.md §4.17 session summarize      MeetingSummaryRecord: generated title and summary of one transcript
  transcripts/<TRANSCRIPT-UUID>.json       SessionArchive               immutable revisions (also one per language, never current, languages.md §4.14)
  transcripts/current.json                 PR6 (saveTranscript)         TranscriptPointer: which revision is current
  transcripts/current.pending              PR6 (saveTranscript)         TranscriptPointer: the revision a save is publishing; removed when done
  speakers/runs/<RUN-UUID>.json            PR6 API, PR7b writes         immutable DiarizationRun; no voice embeddings
  speakers/head.json                       PR6 API                      SpeakerHead: current run
  speakers/edits.jsonl                     PR6 API, PR8 writes          SpeakerEdit journal; torn tail tolerated
  speakers/edits.torn-<UUID>.jsonl         PR6                          backup of a repaired torn tail
  speakers/voice/<RUN-UUID>.json           PR6 API, PR7b writes         SessionVoiceData; only with hidden forceVoiceData (evaluation)
  speakers/recognition/<RUN-UUID>.json     PR10                         RecognitionResult; distances, no vectors
  exports/transcript.{md,json,txt}         PR7b SessionExports          generated, mode 0400, never contain vectors
  exports/.generated.json                  PR7b                         SHA-256 of each generated file
  exports/edited-<YYYYMMDD-HHMMSS>.<ext>   PR7b                         a hand-edited export, moved aside before regeneration
  echo/mask.json                           online-calls-echo.md §5.11 EchoMaskStore          EchoMaskRecord: a call's acoustic echo analysis, keyed to its audio
  echo/frames-<sha>.bin                    online-calls-echo.md §5.11 EchoMaskStore          AcousticEchoMask bytes (2 per 16 ms frame); only when echo was found
  derived/<track>-16k.caf                  PR7b TrackRenderer           deletable cache; cleared at the start and end of post-processing
```

`SessionPaths` (PR6, `Sources/HolosStorage/SessionPaths.swift`) returns each URL, so no
PR spells a path by hand:

```swift
public enum SessionPaths {
    public static func manifest(_ session: URL) -> URL          // manifest.json
    public static func events(_ session: URL) -> URL            // events.jsonl
    public static func meetingInfo(_ session: URL) -> URL       // meeting.json
    public static func vocabulary(_ session: URL) -> URL        // vocabulary.json
    public static func status(_ session: URL) -> URL            // status.json
    public static func liveHints(_ session: URL) -> URL         // live-hints.json
    public static func controlDirectory(_ session: URL) -> URL  // control/
    public static func postprocess(_ session: URL) -> URL       // postprocess.json
    public static func audioDeleted(_ session: URL) -> URL      // audio-deleted.json
    public static func summary(_ session: URL) -> URL           // summary.json (titles-summaries.md §4.17)
    public static func transcripts(_ session: URL) -> URL       // transcripts/
    public static func transcript(_ id: String, in session: URL) -> URL
    public static func transcriptPointer(_ session: URL) -> URL // transcripts/current.json
    public static func runs(_ session: URL) -> URL              // speakers/runs/
    public static func run(_ id: String, in session: URL) -> URL
    public static func head(_ session: URL) -> URL              // speakers/head.json
    public static func edits(_ session: URL) -> URL             // speakers/edits.jsonl
    public static func voiceDirectory(_ session: URL) -> URL    // speakers/voice/
    public static func voiceData(_ runID: String, in session: URL) -> URL
    public static func recognition(_ runID: String, in session: URL) -> URL
    public static func exports(_ session: URL) -> URL           // exports/
    public static func export(_ fileExtension: String, in session: URL) -> URL // exports/transcript.<ext>
    public static func generatedExports(_ session: URL) -> URL  // exports/.generated.json
    public static func echoDirectory(_ session: URL) -> URL     // echo/ (online-calls-echo.md §5.11)
    public static func echoMask(_ session: URL) -> URL          // echo/mask.json
    // echo/frames-<first 16 hex digits of its SHA-256>.bin: EchoMaskStore.framesURL(session, sha256:)
    public static func derived(_ session: URL) -> URL           // derived/
    public static func render(track: String, in session: URL) -> URL // derived/<track>-16k.caf
}
```

Integrity checks (`inspectRecovery`) keep looking only at the manifest, the journal, and
`audio/`; every new file and folder is outside them, so `derived/` and `speakers/` never
make an archive "need attention". When `audio-deleted.json` exists, missing chunk files
are expected and not reported (PR6).

### 2.2 Global files

```
<support> = HolosPaths.supportRoot = $HOLOS_SUPPORT_DIR, else ~/Library/Application Support/Holos
  Sessions/                                        HolosPaths.sessions (or $HOLOS_DATA_DIR; unchanged)
  Models/speaker-diarization-coreml@df2625ac79a7/  PR7a FluidModels.defaultDirectory, passed to FluidAudio as `directory:`
      speaker-diarization/                         FluidAudio's repo folder (Repo.diarizer.folderName): pinned files
          .fluidaudio-revision                     "df2625ac79a7ac6b65ad868fee6d80f320da4232\n"
  Speakers/profiles.json  profiles.lock            PR10: 0700 folder, 0600 files, excluded from Time Machine
~/Library/Logs/Holos/recorder-<SESSION-UUID>.log   PR4: stdout/stderr of the recorder child; deleted with the meeting
$TMPDIR/holos-vocabulary-<SESSION-UUID>.json       PR4: written 0600 by the app; the recorder copies it to vocabulary.json and deletes it
```

`HolosPaths.supportRoot` is added by PR6 in `Sources/HolosCore/SupportPaths.swift` (not
in `Models.swift`). `HolosPaths.models` (PR7a, in HolosDiarization) and
`HolosPaths.speakerProfiles` (PR10, in HolosStorage) are extensions built on it.

### 2.3 Session time

One timeline for everything: chunk times, transcript segment and word times,
diarization times (after the render time map, post-processing.md §4.7), markers, and gaps. An exported
`[01:12:03]` is 1 h 12 min after the first captured audio.

- **Origin.** Session time 0 is epoch 0's capture origin: `AudioCapture` sets
  `hostTimeOrigin` when capture starts, and epoch-0 frame times are measured from it.
  Before epoch 0 starts, the recorder has no session time (status `elapsedSeconds` 0);
  startup work (archive creation, speech-session setup, a first-run permission prompt)
  is not on the timeline.
- **Clock.** `ContinuousSessionClock(hostTimeOrigin:)` (PR2a) is created right after
  epoch 0's `start()` returns. It samples `mach_continuous_time()` and
  `mach_absolute_time()` together once, converts the host-time origin to continuous
  time, and `now()` returns continuous seconds since it. Continuous time keeps counting
  during sleep; host time does not, which is why later epochs take their offset from
  this clock. `ManualSessionClock` is the test double.
- **Epochs.** Each capture start is an epoch with a fresh `MeetingCapture`.
  `AudioCapture.start(…, timelineOffset:, timelineOffsetHostTime:)` sets its host-time
  origin to `offsetHostTime − timelineOffset`, where `offsetHostTime`
  (`CaptureRequest.offsetHostTime`) is the host time at which the recorder read the
  session clock for the offset (`hostNow` when nil, as for epoch 0). Frame times
  continue on the session timeline, and the capture's own setup time (ScreenCaptureKit's
  content query, the audio engine) is part of the gap before its first frame. Epoch
  k+1 uses `timelineOffset = max(clock.now(), lastFrameEnd + 0.01)`, where
  `lastFrameEnd` is the largest frame end on any track, so a new epoch never overlaps
  the previous one even if the audio clock ran ahead of the host clock.
- **Frame continuity** (`FrameContinuity`, PR2a, HolosAudio; used by `AudioChunkWriter`
  and `LiveTrack`). Within an epoch, per track, with `expected` = previous frame end:
  - `|start − expected| < 0.05 s`: contiguous. The samples follow directly; the frame's
    own time is ignored. Drift above 10 ms is logged (category `capture`) at most once a
    minute per track.
  - `start ≥ expected + 0.05`: a gap. The writer closes the chunk and records
    `audioDiscontinuity` with the pending reason (recorder.md §4.3) or `timestampGap`.
  - `start ≤ expected − 0.05`: an overlap. The leading samples up to `expected` are
    dropped (the whole frame if it lies entirely before `expected`) and
    `timestampOverlap {track, previousEnd, nextStart, droppedSeconds}` is recorded.
    Audio is never written twice and no chunk starts before the previous one ends, so
    `TrackRenderer`, `SessionAudioComposition`, and `AppleSpeechSession.append` ("ordered
    and nonoverlapping") never see overlapping audio.
- **Speech sessions are rebased.** A `LiveSpeechSession` always sees frame times that
  start at 0. `LiveTrack` and `TrackReplayer` remember each session's base (the session
  time of its first frame) and add it to every returned segment and word time. This is
  correct whether SpeechAnalyzer reports times from the `AVAudioTime` it is given or
  from its first buffer; the opt-in `HOLOS_SPEECH_FIXTURE` test (PR2a) checks it with
  real speech. A new speech session starts at every epoch boundary and at every gap over
  1 s (resolution R19).
- **Watchdog time** is the session-clock time at which the consumer received a frame,
  not the frame's media time (recorder.md §4.2).
- **Markers** use the session time at which the recorder handles the request (≤ 100 ms
  after it is written; R32).

### 2.4 Current transcript and run pairing

- The current transcript is named by `transcripts/current.json`
  (`TranscriptPointer {schemaVersion, transcriptID, updatedAt}`, PR6), which
  `SessionArchive.saveTranscript` rewrites atomically after writing each revision.
  `SessionArchive.currentTranscriptID(at:)` reads it. Saving an existing revision again is
  refused unless `transcripts/current.pending` names it (a save that failed after creating
  it); a later save replaces that marker, so an older revision is never republished. Archives from before PR6 have at
  most one transcript (`holos session retranscribe` writes outside the archive); if a
  legacy archive has several and no pointer, the newest `createdAt` wins and a warning
  is logged.
- The current run is named by `speakers/head.json`. A run references segments of
  `run.transcriptID`, so `SpeakerSessionSnapshot` loads **that** transcript, not the
  current one. If they differ, the snapshot reports `transcriptChanged` and the UI says
  "The transcript changed after speakers were labelled. Label speakers again to update
  them." The post-processor relabels in that case (post-processing.md §4.7 stage 3).
- On load, every turn span is validated (the segment exists and
  `0 ≤ first < end ≤ effectiveWords.count`). A run with any invalid span is reported as
  unusable (`runProblem`), exports fall back to speaker-less output, and nothing traps.
- Every fallback or skipped piece of data in a snapshot (an unusable head, run, or run
  transcript; stale edits; a changed transcript; unreadable or torn journal lines; an
  unreadable recognition result; a damaged meeting.json; skipped event log entries) is in
  `SpeakerSnapshotDiagnostics`, whose notes every command that shows or writes speaker
  labels prints on stderr. An unusable head says the labels were left out and to run
  `holos session diarize --force`, which replaces a damaged `head.json` too. After an edit
  or undo, the diagnostics merge the journal as read before the append, since the append
  repairs a torn last line (`SpeakerSnapshotDiagnostics.merging`).

## 3. Contract files

### 3.0 Rules

- The contract types are defined in `Sources/HolosCore/HolosJSON.swift` (`HolosJSON`, `OpenStringCode`),
  `Sources/HolosCore/MeetingModels.swift` (recorder, status, control and post-processing records) and
  `Sources/HolosCore/SpeakerModels.swift` (diarization runs, the edit journal, voice data and recognition).
  Read those files; this document does not copy them.
- The §3.4 examples show the JSON these types encode with `HolosJSON`.
- The `// MARK: - Voice data` comment in `SpeakerModels.swift` says voice data is
  "written only while Remember voices is on". people-voice.md §4.10 governs: normal post-processing never
  writes `speakers/voice/`; only hidden evaluation runs (`forceVoiceData`) do.
- A contract file changes only additively: a new optional field (with a default in the
  initializer) or a new static constant of an open code, made by the change that needs it
  and stated in its description. Anything else is a design change.
- Types a feature needs beyond these go into its own target, not into these files.

### 3.4 JSON examples

Generated by encoding the contract types (§3.0) with `HolosJSON` (pretty files use
JSONEncoder's `"key" : value` spacing). Real embeddings are 256-dimensional.

#### meeting.json

```json
{
  "applicationBundleID" : "us.zoom.xos",
  "createdAt" : "2026-09-23T14:00:00Z",
  "mode" : "call",
  "nameSource" : "default",
  "origin" : "recorded",
  "othersInRoom" : false,
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10"
}
```

`nameSource` (titles-summaries.md §4.17) is written since the meeting titles; older files have none.

#### vocabulary.json

```json
{
  "schemaVersion" : 1,
  "strings" : [
    "Maria Chen",
    "strata",
    "bylaw 12"
  ]
}
```

#### control/7C0E….json (marker)

```json
{
  "command" : "marker",
  "createdAt" : "2026-09-23T15:02:03Z",
  "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
  "label" : "Budget vote",
  "schemaVersion" : 1,
  "sender" : "app",
  "sentAtNanos" : 912345678901234,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10"
}
```

#### status.json (recording)

```json
{
  "bytesWritten" : 715000000,
  "elapsedSeconds" : 3723.6,
  "freeBytes" : 22800000000,
  "handledRequests" : [
    {
      "command" : "marker",
      "handledAt" : "2026-09-23T15:02:03Z",
      "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
      "result" : "applied"
    }
  ],
  "lastPhrase" : "…",
  "markers" : 1,
  "microphoneName" : "AirPods Pro",
  "name" : "Council meeting",
  "phase" : "recording",
  "pid" : 48211,
  "recordedSeconds" : 3601.2,
  "schemaVersion" : 1,
  "sequence" : 3724,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "source" : "mic+system",
  "startedAt" : "2026-09-23T14:00:00Z",
  "tracks" : [
    {
      "backlogSeconds" : 0.2,
      "channels" : 1,
      "lastFinalizedSeconds" : 3719.8,
      "lastFrameSeconds" : 3723.5,
      "sampleRate" : 48000,
      "stalled" : false,
      "track" : "mic",
      "transcription" : "live"
    },
    {
      "backlogSeconds" : 0.1,
      "channels" : 1,
      "lastFinalizedSeconds" : 2410,
      "lastFrameSeconds" : 3723.4,
      "sampleRate" : 48000,
      "stalled" : false,
      "track" : "system",
      "transcription" : "behind"
    }
  ],
  "updatedAt" : "2026-09-23T15:02:04Z",
  "warnings" : [
    {
      "code" : "transcriptionBehind",
      "message" : "System audio transcription is behind; it will finish after you stop.",
      "since" : "2026-09-23T14:40:11Z"
    }
  ]
}
```

#### status.json (exited)

```json
{
  "bytesWritten" : 2072000000,
  "elapsedSeconds" : 10795.2,
  "exit" : {
    "archiveStatus" : "complete",
    "postprocessing" : "succeeded",
    "reason" : "requested"
  },
  "freeBytes" : 21400000000,
  "handledRequests" : [
    {
      "command" : "marker",
      "handledAt" : "2026-09-23T15:02:03Z",
      "id" : "7C0E5B0A-1D2F-4C3B-8E9A-6F5D4C3B2A10",
      "result" : "applied"
    }
  ],
  "markers" : 1,
  "microphoneName" : "AirPods Pro",
  "name" : "Council meeting",
  "phase" : "exited",
  "pid" : 48211,
  "recordedSeconds" : 10790,
  "schemaVersion" : 1,
  "sequence" : 11020,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "source" : "mic+system",
  "startedAt" : "2026-09-23T14:00:00Z",
  "tracks" : [

  ],
  "updatedAt" : "2026-09-23T17:03:40Z",
  "warnings" : [

  ]
}
```

#### postprocess.json (running)

```json
{
  "othersInRoom" : false,
  "pid" : 48211,
  "progress" : {
    "fraction" : 0.42,
    "message" : "Labelling speakers (system audio)…",
    "stage" : "diarize",
    "track" : "system"
  },
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "stages" : [
    {
      "result" : "succeeded",
      "seconds" : 0.4,
      "stage" : "transcript"
    },
    {
      "result" : "succeeded",
      "seconds" : 21.7,
      "stage" : "render"
    }
  ],
  "startedAt" : "2026-09-23T17:00:00Z",
  "state" : "running",
  "transcriptID" : "9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A",
  "updatedAt" : "2026-09-23T17:00:40Z"
}
```

#### speakers/head.json

```json
{
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "updatedAt" : "2026-09-23T17:01:40Z"
}
```

#### speakers/runs/5C1D….json (no voice embeddings)

```json
{
  "alignment" : {
    "parameters" : {
      "echoMinRunWords" : 3,
      "flickerBoundarySeconds" : 0.3,
      "flickerMaxGapSeconds" : 0.25,
      "flickerMaxSeconds" : 0.4,
      "flickerMaxWords" : 2,
      "flickerMinOwnSegmentSeconds" : 0.3,
      "gapSnapSeconds" : 0.5,
      "offsetSearchSeconds" : 0.5,
      "offsetStepSeconds" : 0.02,
      "overlapMinFraction" : 0.5,
      "overlapMinSeconds" : 0.1,
      "turnPauseSeconds" : 1.5
    },
    "trackOffsets" : {
      "system" : 0.06
    },
    "version" : 1
  },
  "createdAt" : "2026-09-23T17:01:40Z",
  "droppedWords" : [

  ],
  "engine" : {
    "configuration" : {
      "clusteringThreshold" : "0.6",
      "exclusiveSegments" : "false",
      "exposeChunkEmbeddings" : "true"
    },
    "embeddingDimension" : 256,
    "embeddingModel" : {
      "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
      "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    },
    "engine" : "FluidAudio.OfflineDiarizerManager",
    "engineVersion" : "0.17.1",
    "models" : [
      {
        "id" : "FluidInference/speaker-diarization-coreml",
        "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        "sha256" : "<tree digest>"
      }
    ]
  },
  "id" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "speakers" : [
    {
      "clusterIDs" : [

      ],
      "displayName" : "Me",
      "id" : "mic:me",
      "ordinal" : 1,
      "provenance" : {
        "channelAssumption" : {

        }
      }
    },
    {
      "clusterIDs" : [
        "system:S1"
      ],
      "id" : "system:S1",
      "ordinal" : 2,
      "provenance" : {
        "diarizer" : {

        }
      }
    },
    {
      "clusterIDs" : [
        "system:S2"
      ],
      "id" : "system:S2",
      "ordinal" : 3,
      "provenance" : {
        "diarizer" : {

        }
      }
    }
  ],
  "tracks" : [
    {
      "clusters" : [

      ],
      "policy" : {
        "channel" : {
          "displayName" : "Me",
          "speakerID" : "mic:me"
        }
      },
      "segments" : [

      ],
      "track" : "mic"
    },
    {
      "clusters" : [
        {
          "clusterID" : "system:S1",
          "speechSeconds" : 2472.3,
          "track" : "system"
        },
        {
          "clusterID" : "system:S2",
          "speechSeconds" : 1323,
          "track" : "system"
        }
      ],
      "policy" : {
        "diarized" : {

        }
      },
      "segments" : [
        {
          "clusterID" : "system:S1",
          "end" : 19.4,
          "overlapCount" : 0,
          "quality" : 0.91,
          "start" : 12,
          "track" : "system"
        },
        {
          "clusterID" : "system:S2",
          "end" : 25,
          "overlapCount" : 1,
          "quality" : 0.84,
          "start" : 18.9,
          "track" : "system"
        }
      ],
      "track" : "system"
    }
  ],
  "transcriptID" : "9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A",
  "turns" : [
    {
      "assignmentScore" : 0.97,
      "clusterID" : "system:S1",
      "end" : 18.7,
      "id" : "T1",
      "otherClusters" : [

      ],
      "overlap" : false,
      "spans" : [
        {
          "end" : 17,
          "first" : 0,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000001"
        }
      ],
      "speakerID" : "system:S1",
      "start" : 12.1,
      "timing" : "measured",
      "track" : "system"
    },
    {
      "assignmentScore" : 0.88,
      "clusterID" : "system:S2",
      "end" : 24.8,
      "id" : "T2",
      "otherClusters" : [
        "system:S1"
      ],
      "overlap" : true,
      "spans" : [
        {
          "end" : 21,
          "first" : 17,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000001"
        },
        {
          "end" : 9,
          "first" : 0,
          "segmentID" : "A1B2C3D4-0000-4000-8000-000000000002"
        }
      ],
      "speakerID" : "system:S2",
      "start" : 19,
      "timing" : "measured",
      "track" : "system"
    }
  ]
}
```

#### speakers/voice/5C1D….json (evaluation sessions only, hidden forceVoiceData; 2-d vectors shown, real ones are 256-d)

```json
{
  "centroids" : {
    "system:S1" : "fPKwPbN78rw=",
    "system:S2" : "CtejPK5H4T0="
  },
  "createdAt" : "2026-09-23T17:01:40Z",
  "embeddingModel" : {
    "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
    "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
  },
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "sessionID" : "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10",
  "turnEmbeddings" : [
    {
      "speechSeconds" : 6.6,
      "turnID" : "T1",
      "vector" : "uB4FPgrXo7w="
    }
  ]
}
```

#### speakers/recognition/5C1D….json

```json
{
  "createdAt" : "2026-09-23T17:01:41Z",
  "embeddingModel" : {
    "id" : "FluidInference/speaker-diarization-coreml/Embedding.mlmodelc",
    "revision" : "df2625ac79a7ac6b65ad868fee6d80f320da4232"
  },
  "matches" : [
    {
      "distance" : 0.21,
      "profileID" : "D4C3B2A1-1111-4222-8333-944455566677",
      "profileName" : "Jim",
      "speakerID" : "system:S1",
      "tier" : "possible"
    },
    {
      "distance" : 0.33,
      "profileID" : "E5F6A7B8-1111-4222-8333-944455566677",
      "profileName" : "Maria",
      "speakerID" : "system:S2",
      "tier" : "possible"
    }
  ],
  "mergeSuggestions" : [

  ],
  "runID" : "5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6",
  "schemaVersion" : 1,
  "skippedProfiles" : [

  ],
  "thresholds" : {
    "likelyMaxDistance" : 0,
    "likelyMinMargin" : 0.1,
    "minSampleSeconds" : 20,
    "possibleMaxDistance" : 0.4
  }
}
```

#### speakers/edits.jsonl (four lines: one two-line batch, then two single edits)

```json
{"action":{"linkProfile":{"profileID":"E5F6A7B8-1111-4222-8333-944455566677","speakerID":"system:S2"}},"at":"2026-09-23T17:11:40Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","expected":"","id":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","schemaVersion":1,"source":"app"}
{"action":{"rename":{"name":"Maria","speakerID":"system:S2"}},"at":"2026-09-23T17:11:40Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9","expected":"","id":"0B1C2D3E-4F50-4162-8374-95A6B7C8D9EA","schemaVersion":1,"source":"app"}
{"action":{"reassignTurns":{"to":"system:S1","turnIDs":["T7","T9"]}},"at":"2026-09-23T17:12:00Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"1B2C3D4E-5F60-4172-8384-95A6B7C8D9EA","expected":"system:S2,system:S2","id":"1B2C3D4E-5F60-4172-8384-95A6B7C8D9EA","schemaVersion":1,"source":"cli"}
{"action":{"splitTurn":{"at":{"segmentID":"A1B2C3D4-0000-4000-8000-000000000031","word":6},"turnID":"T12"}},"at":"2026-09-23T17:12:20Z","baseRunID":"5C1D7E2A-0B3C-4D5E-8F90-A1B2C3D4E5F6","batchID":"2C3D4E5F-6071-4283-9495-A6B7C8D9EAFB","id":"2C3D4E5F-6071-4283-9495-A6B7C8D9EAFB","schemaVersion":1,"source":"app"}
```
