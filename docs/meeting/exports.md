# Exports

The transcript exports (§4.11). §5.7 (speaker editing and re-export) comes from the build plan and names the PR
that built it; the code cites it for behaviour.

Sections keep their numbers from the meeting design; a bare `§N.M` names one of them, and
[meeting-design.md](../meeting-design.md) lists the file each is in.

### 4.11 Exports

`TranscriptExporter` (PR5c, pure) renders an `ExportDocument`; `SessionExports` (PR7b)
loads session files into one and writes `exports/`. v1 formats are Markdown, plain text,
and JSON.

```swift
public struct ExportMetadata: Sendable, Equatable {
    public var sessionID: String
    public var name: String
    public var createdAt: Date
    public var durationSeconds: Double           // max chunk end over tracks
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    public var timeZone: TimeZone                // for the header's local start time; tests pass UTC
}

public struct ExportDocument: Sendable, Equatable {
    public var metadata: ExportMetadata
    public var transcript: Transcript
    public var run: DiarizationRun?
    public var projection: SpeakerProjection?    // nil → one pseudo-turn per segment named by track
    public var gaps: [TimelineGap]
    public var markers: [TimelineMarker]
}

public enum ExportFormat: String, CaseIterable, Sendable { case md, json, txt }

public struct ExportBlock: Sendable, Equatable {
    public var speakerLabel: String
    public var start: Double
    public var turnIDs: [String]
    public var text: String
    public var overlapWith: [String]             // labels
}

public enum TranscriptExporter {
    public static func render(_ document: ExportDocument, format: ExportFormat) throws -> Data
    /// Turn text: from the first word's UTF-16 offset (or 0 for the segment's first word) to the next
    /// word's offset (or the end of the segment text), per span, joined with " ", trimmed.
    public static func text(of spans: [WordSpan], in transcript: Transcript) -> String
    /// Markdown and text blocks: consecutive turns of the same speaker are merged unless a gap, a marker,
    /// or more than 30 s of silence separates them.
    public static func blocks(_ document: ExportDocument) -> [ExportBlock]
}
```

Common rules: turns in `(start, track)` order; the speaker shown is `label` ("Jim",
"Jim (auto)", "Speaker 3", "Me"); unknown → "Unknown speaker"; without a projection,
names are "Microphone" and "System audio". Suggestions never appear in exports.
Timestamps are `HH:MM:SS` in Markdown.

- **Markdown** (`transcript.md`):

  ```
  # Council meeting

  - Date: 2026-09-23
  - Started: 14:00
  - Duration: 2:58:12
  - Participants: Jim (41:12), Speaker 2 (22:03), Me (15:40)

  **Jim** · 00:12:03

  We should move the vote to next week. The treasurer's report is ready.

  **Speaker 2** · 00:12:40 · overlapping with Jim

  Agreed, but …

  _[Recording paused 00:45:10–00:47:02]_

  _[Marker 01:02:03: Budget vote]_
  ```

  Gap lines by reason: paused "Recording paused", sleep "No audio: computer was asleep",
  deviceChanged/captureRestarted "Audio restarted", audioUnavailable "No audio:
  microphone unavailable", overflow and audioGap "Audio gap". A marker without a label
  prints `_[Marker 01:02:03]_`. Participants are sorted by talk time, descending.
- **Text** (`transcript.txt`): one block per `ExportBlock`: `"<label>  <time>"` (two
  spaces; `mm:ss` below one hour, e.g. `01:05`, and `h:mm:ss` from one hour, e.g.
  `1:02:05`), the text on one line, a blank line. No gap or marker lines and no footer,
  so `OtterTranscriptParser` and the evaluator's header regex (hours may have any number of digits)
  `^\s*\S.*\s{2,}(?:\d+:\d{2}:\d{2}|\d{1,2}:\d{2})\s*$` read it. It replaces the speaker-less
  text `saveTranscript` wrote before (R23).
- **JSON** (`transcript.json`, format `holos-transcript`, `schemaVersion` 1), per turn,
  with no vectors of any kind:

  ```json
  {
    "schemaVersion": 1, "format": "holos-transcript",
    "session": {"id": "…", "name": "…", "createdAt": "…", "durationSeconds": 10692.4,
                "source": "mic+system", "locale": "en-CA", "backend": "speech"},
    "transcriptID": "…", "runID": "…",
    "engine": { DiarizationEngineInfo }, "alignment": { AlignmentInfo },
    "speakers": [{"id": "system:S1", "ordinal": 2, "name": "Jim", "label": "Jim",
                  "provenance": {"userConfirmed": {}}, "automatic": false, "profileID": "…",
                  "talkSeconds": 2472.3, "turnCount": 88}],
    "turns": [{"id": "T1", "speakerID": "system:S1", "track": "system", "start": 12.1, "end": 18.7,
               "text": "…", "overlap": false, "otherSpeakers": [], "score": 0.97,
               "timing": "measured", "words": [{"segmentID": "…", "first": 0, "end": 17}]}],
    "gaps": [ TimelineGap ], "markers": [ TimelineMarker ],
    "edits": {"applied": 5, "stale": 0, "otherRuns": 0}
  }
  ```

  `otherSpeakers` maps `otherClusters` to current speaker IDs. `engine`, `alignment`,
  `runID` are `null` without a run.

**Generated files are protected, not overwritten.** `exports/` is a generated cache.
`SessionExports.regenerate` writes each file with mode 0400 and records its SHA-256 in
`exports/.generated.json`. Before writing, if a file on disk no longer matches its
recorded digest (someone edited it), it moves that file to
`exports/edited-<YYYYMMDD-HHMMSS>.<ext>` (0600) and returns it in `movedAside`; the
review window's status line and `holos session export --all` say so. Without a usable record (none,
or a damaged one), the speaker-less files the recording wrote for the current transcript still count
as generated, so they are rewritten rather than moved aside. The app's "Open
Transcript" shows a Quick Look preview; "Save Transcript As…" (NSSavePanel, default
`~/Documents/<meeting name>.md`, or `.txt`) makes the editable copy.

```swift
public enum SessionExports {
    /// Takes the speaker lock, loads the snapshot, writes exports/transcript.{md,json,txt}, releases the lock.
    @discardableResult
    public static func regenerate(session: URL, profileNames: [String: String] = [:]) throws -> ExportWriteResult
    /// Caller holds the speaker lock.
    @discardableResult
    public static func regenerateLocked(session: URL, profileNames: [String: String] = [:]) throws -> ExportWriteResult
    /// One format, not written anywhere.
    public static func render(_ format: ExportFormat, session: URL,
                              profileNames: [String: String] = [:]) throws -> Data
}
public struct ExportWriteResult: Sendable, Equatable {
    public var written: [URL]
    public var movedAside: [URL]
}
```

### 5.7 PR8: CLI speaker editing and re-export (wave 3)

**Goal.** One edit API used by the CLI now and the review window later, `holos speakers`
commands, and `holos session export`.

**Files.**

- Add `Sources/HolosMeeting/SpeakerEditor.swift`, `Sources/HolosMeeting/SpeakerSelector.swift`,
  `Sources/HolosMeeting/SessionLocator.swift`.
- Add `Sources/HolosCLI/Speakers.swift`, `Sources/HolosCLI/SessionExport.swift`.
- Change `Sources/HolosCLI/Holos.swift` (add `Speakers.self`), `Sources/HolosCLI/Session.swift`
  (add `Export.self`).
- Tests: `Tests/HolosMeetingTests/{SpeakerEditorTests, SpeakerSelectorTests}.swift`. PR8
  owns `Fakes.swift` and `SessionFixtures.swift` edits in wave 3.

**API.**

```swift
public enum SpeakerEditor {
    /// docs/meeting/speaker-labels.md §4.9. Under the speaker lock: loads the current snapshot; refuses the batch (nothing written) when the
    /// head run is not `view.runID` or any action's fingerprint on `view` (applied sequentially) differs from the
    /// current state; checks every target exists (throws invalidInput otherwise); appends all lines with one
    /// batchID in one write. Then releases the lock and regenerates exports unless told not to.
    /// Throws unavailable when there is no head run.
    @discardableResult
    public static func apply(_ actions: [SpeakerEditAction], view: SpeakerProjection, session: URL, source: String,
                             regenerateExports: Bool = true,
                             profileNames: [String: String] = [:]) throws -> SpeakerEditResult
    /// Appends a revert for every edit of `view.lastUndoableBatchID` (same refusal rules).
    @discardableResult
    public static func undoLast(view: SpeakerProjection, session: URL, source: String,
                                regenerateExports: Bool = true) throws -> SpeakerEditResult
}

public struct SpeakerEditResult: Sendable {
    public var snapshot: SpeakerSessionSnapshot
    /// True when the batch changed a turn's speaker, turn boundaries, merges, exclusions, or links of a
    /// speaker whose profile has a sample from this session (PR10 sets it; always false before PR10).
    /// The caller must then `await VoiceProfileService.refreshSamples(session:extractor:store:)`.
    public var needsSampleRefresh: Bool
}

public enum SpeakerTarget: Sendable, Equatable { case speaker(String), unknown }

public enum SpeakerSelector {
    /// In order: exact speaker ID ("system:S2"); engine label if unique ("S2"); ordinal ("2", "Speaker 2");
    /// name (case-insensitive, unique); "unknown". Errors list the candidates.
    public static func speaker(_ text: String, in projection: SpeakerProjection) throws -> SpeakerTarget
    /// "T12" or "T12/…" exactly; or a time ("01:12:03", "12:03.5", "723.5") → the turn containing it,
    /// requiring `track` when both tracks have one there.
    public static func turn(_ text: String, track: String?, in projection: SpeakerProjection) throws -> String
    public static func time(_ text: String) throws -> Double
}

public enum SessionLocator {
    /// A path to a .holos folder, or a session UUID under `root`.
    public static func resolve(_ text: String, root: URL = HolosPaths.sessions) throws -> URL
}
```

Every CLI edit command loads the snapshot, resolves its selectors against that
snapshot's projection, and passes the same projection as `view`, so a relabel between
load and apply is refused rather than applied to a different turn.

**CLI.**

```
holos speakers list <session> [--turns] [--json]
holos speakers rename <session> <speaker> <name|--clear>
holos speakers merge <session> <from-speaker> <into-speaker>
holos speakers assign <session> <turn>... --to <speaker|unknown|new[:NAME]>
holos speakers split <session> <turn> (--at-word N | --at <time>)
holos speakers exclude <session> <turn>...
holos speakers undo <session>
holos session export <session> --format md|json|txt [--output FILE]
holos session export <session> --all
```

`speakers list` output:

```
Council meeting (3F2A9C1E…) · run 5C1D7E2A (FluidAudio 0.17.1) · 11 speakers · 343 turns · 5 changes

  #  Speaker     Name        Talk     Turns  Label
  1  mic:me      Me          15:40       60  channel
  2  system:S1   Jim         41:12       88  renamed
  3  system:S2   Speaker 3   22:03       51  diarizer   suggestion: Maybe Maria (0.33)
```

`--turns` adds `T12  00:12:03–00:12:40  system  Jim  0.92  overlap  <first 60 characters>`.
Each edit command prints one line (`Renamed system:S2 to Maria.`) and regenerates
exports. `new[:NAME]` creates `user:<UUID>`. `session export` writes to stdout without
`--output`; `--output` refuses to overwrite; `--all` rewrites `exports/` and prints its
path plus any moved-aside edited files. No export contains vectors.

**Tests.**

| Test | Input | Expected |
|---|---|---|
| `editJournalExportEndToEnd` | fixture session with a 2-speaker head run; rename `system:S1` "Jim" | one journal line with `expected == ""`; `exports/transcript.txt` has a `Jim  00:0…` header; Markdown has `**Jim**` |
| `missingTargetWritesNothing` | rename `system:S9` | throws; journal unchanged |
| `editAgainstReplacedHeadIsRefused` | view from run A; head moved to run B | throws "changed since this view was loaded"; journal unchanged |
| `concurrentReassignIsRefused` | view V shows T4 as S1; another apply reassigns T4 to S2; then reassign T4 from V | refused; nothing written |
| `unrelatedConcurrentEditStillApplies` | view V; another apply renames S3; then rename S1 from V | applied |
| `batchFingerprintsAreSequential` | one batch: rename S1 "A", rename S1 "B" | second line's `expected` is "A"; both share a batchID |
| `exportsRegenerateAfterLockRelease` | apply with `regenerateExports: true` | no lock timeout; exports updated |
| `undoRevertsNewestBatch` | batch (link + rename), then a reassign; undo; undo | first undo reverts the reassign; second reverts both batch lines |
| `concurrentEditorsSerialize` | two tasks × 20 renames of different speakers, each reloading its view, `regenerateExports: false` | 40 lines, all readable, none stale |
| `selectorResolvesIDsLabelsOrdinalsNames` | "system:S2", "S2", "3", "Speaker 3", "maria" | same speaker |
| `ambiguousSelectorListsCandidates` | "S1" when mic:S1 and system:S1 exist | throws, message lists both |
| `timeSelectorFindsTurn` | "00:12:05" on system | T12 |
| `exportFormatsRenderWithoutWriting` | `SessionExports.render(.txt)` | Data; `exports/` unchanged |

**Does not touch.** `SessionArchive.swift`, `Record.swift`, `TranscriptRebuilder.swift`,
`SessionCatalog.swift`, `MeetingPostProcessor.swift`, HolosApp, `Package.swift`,
README and `docs/status.md`.
