# Component and data contracts

Design draft; the signatures below describe the intended architecture, not the
exact current API. The first milestone's compilable contracts live in
`Sources/HolosCore/Models.swift` and the concrete library entry points. They use
string IDs and session-relative `Double` seconds; typed IDs, rational persisted
times, and edit/correction contracts below are still planned. See
[status](status.md) before delegating against these proposed interfaces.
Prefer concrete Swift structs/actors and introduce protocols at actual external
boundaries. Do not build a general plugin framework.

The second milestone adds concrete desktop boundaries in `HolosDesktop`
(`GlobalHotkeyMonitor`, `TextInsertion`, `InsertionTarget`, `InsertionOutcome`)
and `HolosDictation` (`DictationController`, `DictationStatus`). The AppKit shell in
`HolosApp` owns permission/setup actions, non-activating presentation, result
retention, and insertion decisions. Desktop interaction is main-actor-owned;
the dictation controller's injectable capture/speech boundaries allow lifecycle
tests without permissions, microphone use, or cross-app writes. Live permission
ownership and the supported insertion-app matrix remain acceptance gates.

## Ownership boundaries

| Target/component | Owns | Must not own |
| --- | --- | --- |
| `HolosCore` | IDs, clocks, transcript/edit/document values, errors, configuration | Apple engine sessions, UI, permission prompts |
| `HolosStorage` | Session writer, recovery, snapshots, correction SQLite store | Capture callbacks, transcript interpretation |
| `HolosAudio` | Capture adapters, clock mapping, bounded queues, resampling | Corrections, speaker names, UI |
| `HolosSpeech` | Apple transcribers, asset inventory, result normalization | Recording lifetime, focus, transcript editing |
| `HolosCorrections` | Rule matching, candidate retrieval, validated local-model decisions | Unrestricted rewriting, application monitoring |
| `HolosSynthesis` | Voice inventory, buffer rendering, encoding, playback queue | Web fetching, meeting recording |
| `HolosContent` | Input extraction and document chunking | Speech or language-model generation |
| `HolosSpeakers` | Diarization boundary, turn alignment, speaker edit projection | Inferring personal names from text |
| `HolosWorkflows` | Dictation, meeting, reading orchestration and cancellation | Concrete CLI/AppKit views |
| `HolosCLI`, `HolosApp` | Arguments, presentation, app/focus integration | A second copy of workflow business logic |

The app's hotkey/focus adapters can stay in app-owned files. They do not warrant
another package. `HolosSpeakers` initially supports manual labels; an external
diarizer belongs behind its adapter and is conditional on the product choice.

## Shared values

All persistent values have a schema version. Use Codable/Sendable values across
boundaries; do not pass SwiftUI state or AX objects into background workers.

- `SessionID`, `TrackID`, `ChunkID`, `TranscriptRevisionID`, `SpanID`, `SpeakerID`,
  `RuleID`, `UtteranceID`: distinct typed IDs. Speaker IDs are local to a session.
- `MediaTime`: integer value plus positive timescale; ordered/rational comparisons.
  Persist a session-relative monotonic timeline, not wall-clock `Date` arithmetic.
  Keep a separate start date for display. Intervals are half-open `[start, end)`.
- `TrackDescriptor`: source (`microphone`, `system`, `imported`), device/app metadata,
  channel layout, sample format epochs, mapping to session time. Source is not speaker.
- `AudioChunk`: track/epoch, sequence, session interval, native format, frame count,
  relative path, completion state, content hash after finalization. A gap is its own
  event and is never represented by fabricated speech.
- `TimedText`: exact string with timed runs and optional confidence/alternatives.
  Persist text ranges in UTF-16 units because AX/NSRange uses them; convert explicitly
  to Swift string indices and reject invalid boundaries. Test composed characters.
  Word alignment can be absent or coarse; retain that fact.
- `TranscriptSpan`: revision, stable span ID within that revision, source track,
  audio interval, TimedText, optional speaker assignment. Store raw recognition
  separately from the human-corrected presentation.
- `SpeakerTurn`: one or more speaker IDs, audio interval, optional confidence and
  provenance (`manual`, `channelAssumption`, `diarizer`). Unknown is supported.
- `TranscriptEdit`: unique operation ID, base revision, target IDs/intervals, expected
  original text/hash, action, timestamp. Actions include replace text, rename speaker,
  assign speaker, split, and merge. Human edits are retained on reprocessing, with
  conflicts reported when they cannot be mapped safely.
- `CorrectionRule`: source phrase, replacement, locale, app/domain scope, kind,
  priority, confirmation status, evidence references, created/updated timestamps.
- `SourceDocument`: title, source URL/path, retrieval date, language, ordered blocks
  with IDs and source ranges. Heading/paragraph/code/list distinctions remain explicit.
- `SynthesisPart`: document block/range references, text hash, voice identifier,
  synthesis settings, output path, duration, checksum, status. Source coverage must
  be complete even if some parts fail to render.

## Service boundaries

These are semantic contracts. Swift signatures below illustrate the shape and are
not a ready-to-compile API file; the first contract task supplies referenced types.

```swift
protocol TranscriptionEngine: Sendable {
    func capabilities(for locale: Locale) async -> TranscriptionCapabilities
    func makeSession(_ config: TranscriptionConfiguration) async throws
        -> any TranscriptionSession
}

protocol TranscriptionSession: Sendable {
    var events: AsyncThrowingStream<TranscriptEvent, Error> { get }
    func append(_ frame: AudioFrame) async throws
    func finishInput() async throws
    func cancel() async
}

protocol SpeakerDiarizer: Sendable {
    func analyze(_ recording: RecordingSnapshot) async throws -> DiarizationResult
}

protocol CorrectionEngine: Sendable {
    func propose(_ input: CorrectionInput) async throws -> CorrectionPlan
}

protocol SpeechRenderer: Sendable {
    func voices() async -> [VoiceDescriptor]
    func render(_ request: SynthesisRequest, to output: URL) async throws
        -> RenderedAudio
}

protocol ContentExtractor: Sendable {
    func extract(_ source: ContentSource) async throws -> SourceDocument
}
```

### Capture and transcription lifecycle

`AudioFrame` owns its audio samples and timing. An adapter must copy borrowed audio
buffers before their callback lifetime ends, or use a verified immutable ownership
mechanism. Do not hide mutable AVAudioPCMBuffer sharing behind unchecked Sendable.
Raw real-time capture callbacks enqueue quickly; they do not await actors, write
files, resample, or execute model work.

Use a bounded producer/consumer queue with explicit overflow reporting. The writer
has priority over live analysis. The live analyzer may fall back to disk replay;
capture overflow or writer failure must mark lost intervals. An unbounded
AsyncStream is not an acceptable recording buffer.

Only one task appends to a transcription session. Create one independent events
consumer immediately, before feeding input, and keep it alive while finalizing.
`append` provides backpressure outside the audio callback. Cancellation finishes
both sides and releases model/device resources. `finishInput` closes input, drains
pending final results, and completes the events stream; define it as idempotent.

`TranscriptEvent` represents **replacement over an audio interval**, not simply
appended text. It carries engine-run ID, source track, increasing event sequence,
covered range, replacement spans, and finalization boundary. Volatile results can
change segmentation. Normalize them by replacing the affected provisional interval;
never duplicate earlier hypotheses. Finalized spans are immutable within a run.
Reanalysis produces a separate revision. Empty/silence results must not create text.

An engine restart records its input offset and overlap interval. Deduplicate the
overlap by interval/word alignment before committing a revised transcript. Do not
restart at file-chunk boundaries just because the recorder rotates output files.

### Persistence and recovery

The session writer is the only mutable owner of an active archive. Finalized audio
and transcript snapshots are immutable; manifest updates use write/rename. Events
use monotonic sequence IDs, allowing recovery to reject duplicates and a truncated
last line. Batch durability explicitly; measure the maximum possible tail loss.

Store a processing watermark per track and engine run. Recovery validates chunk
metadata/checksums, discovers completed unindexed chunks, marks damaged tails, and
replays transcription with a small context overlap. Never claim finalized text
beyond durable audio. Edits are applied against a named revision and expected text;
a stale edit is a conflict, not an unconditional replacement.

Same-host start/stop/status uses a versioned per-user control endpoint with filesystem
access restrictions, peer identity checks where available, request IDs, and bounded
messages. Commands are an allowlist; a stop request targets an exact session ID and
is idempotent. No network listener or shell command execution is required. The
permissions spike decides XPC versus a Unix socket for each concrete process.

### Corrections and insertion

`CorrectionInput` contains the raw utterance, explicitly allowed short context,
locale/app identity, and retrieved confirmed rules. Never send the whole focused
document by default. The model chooses a supplied candidate ID or `leaveUnchanged`;
it does not return arbitrary executable actions or authoritative confidence.

`CorrectionPlan` contains non-overlapping text edits with expected original text,
replacement selected from candidates, and rule/evidence provenance. Validate ranges,
scope, source hash, candidate membership, and unchanged protected spans before use.
Deterministic precedence: explicit app/domain scope before global rules, then
longest phrase, then priority; unresolved ties leave text unchanged.

An app-owned `InsertionTarget` snapshots PID, focused AX element, selection, and a
small change fingerprint on hotkey down. Keep these objects on their owning actor.
Recheck the live destination after recognition. Insertion produces a receipt with
method and verification state, suitable for undo/correction learning; do not report
success if the adapter could not verify the effect. A timeout returns the text to
the overlay, not a second automatic paste attempt that could duplicate content.

State machine: idle -> capturing -> finalizing -> correcting -> inserting -> idle.
Cancellation is permitted before insertion. A focus mismatch produces
`awaitingExplicitPaste`; device/permission failures produce an actionable status.
Queue or reject a second dictation explicitly while finalizing; never mix utterances.

Local app/session control accepts a small versioned command set and session IDs,
not arbitrary code or shell commands. Restrict a Unix socket to its owning user and
validate peer identity where available, or apply equivalent XPC client validation.
The recorder owns its stop endpoint and archive lock. Define CLI disconnect,
SIGINT, and SIGTERM behavior explicitly; a second signal may stop waiting for
analysis but must preserve the recording already saved.

### Synthesis and documents

Each render request names one voice and exact text/settings. Retain the synthesizer
and its delegate for the entire operation, handle cancellation/completion exactly
once, and validate the emitted format before writing. Publish the completed file
atomically after finalization. No partially written file is a completed part.

Use deterministic semantic chunking and source-range accounting. Resuming compares
manifest hashes/settings rather than trusting a filename. Playback is serialized
across processes independently of rendering. Text extraction and voice selection
fail explicitly when unavailable; neither may silently substitute a summary.

## Errors and observable behavior

Use structured errors for permission denied, unsupported locale, missing assets,
device unavailable, capture gap, disk full, focus changed, unsupported insertion,
model unavailable, generation rejected, invalid correction, extraction failed, and
partial output. Transcription failure after a successful recording must preserve
and identify the saved audio. Show capability degradation at the feature boundary.

CLIs put content or JSON results on stdout and progress on stderr. Cancellation and
partial output have documented exit statuses. Logs expose session IDs, processing
times, queue depth, and failures; logging audio/text requires an explicit diagnostic
mode. Import paths and output directories are handled as paths, never shell source.
