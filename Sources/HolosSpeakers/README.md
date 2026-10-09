# HolosSpeakers

Pure speaker algorithms over values: who said which words, how edits apply, and how a meeting is exported.
`docs/meeting/post-processing.md §4.8` to `docs/meeting/exports.md §4.11` describe the rules.

**Owns**
- Labelling: `DiarizationNormalizer`, `SpeakerAlignment` (words to diarization segments), `WordTiming`,
  `SpeakerRunBuilder` (turns of a run), `ShortInterjections`, `TurnOrder`, `FakeDiarizer` (the test diarizer).
- Edits: `SpeakerProjection` (a run with its edit journal applied: the view exports, Review, the CLI and enrollment
  read), `SpeakerCarryOver` (names carried to a new labelling), `SameNameSpeakers` (same name in one meeting shows
  as one speaker; display only), `ReviewJournalClaim` (which lines a reread journal adds are the Review window's
  own).
- Voices: `TurnEmbeddings`, `VoiceEnrollment`, `SpeakerRecognizer`, `RecognitionCalibration`, `MeetingVoiceMatcher`,
  `VectorMath`.
- Echo of call audio on the microphone: `EchoFilter` (word copies), `EchoAnalysis` and `AcousticEchoMask`
  (acoustic, over an `EchoAudioSource`).
- Exports: `ExportDocument` and `TranscriptExporter` (Markdown, text, JSON). Evaluation helpers:
  `OtterTranscriptParser`, `DiarizationScoring`.

**Must not own:** any file I/O (callers in `HolosMeeting` read and write through `HolosStorage`), diarization
engines, clocks, names inferred from transcript text.

**Depends on:** HolosCore only. Accelerate (`EchoAnalysis`).

**Invariants**
- No I/O and no mutable global state. The current date and new IDs arrive as parameters (`now:`, `createdAt:`, `id:`,
  defaulted), so tests pass fixed ones.
- Every journal line of a run ends up in exactly one of applied, reverted, stale, or an effective revert
  (`SpeakerProjection`).
- `SameNameSpeakers` never merges: it joins same-name speakers for display only, from the journal alone. (Review's
  opt-in "Merge matching voices automatically", in HolosMeeting, writes real merge edits.)
- Do not import FluidAudio here: its `WordTiming` and `AudioSource` clash with Holos types
  (`docs/conventions.md §1.1`).

**Tests:** `Tests/HolosSpeakersTests` (`ProjectionTests`, `AlignmentTests`, `CarryOverTests`, `SameNameSpeakerTests`,
`ExportTests`, …), all over in-memory values.
