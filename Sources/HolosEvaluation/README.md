# HolosEvaluation

The reference evaluation behind `voiceislocal eval` (docs/reference-evaluation.md "Cloud reference"): comparing local
transcription with a cloud reference and with a reviewer's corrections. Developer tooling; only `HolosCLI` links it.

**Owns**
- Cloud reference runs: `CloudEvaluation` (render, segment, upload after consent, save each answer),
  `ConsentGate` (only an explicit yes or `--yes` uploads), `CloudTranscriptionClient` over a `CloudHTTPTransport`
  (`URLSessionTransport`, an ephemeral session), `CloudSegmentation`, `CloudVocabulary`, `CloudModels`.
- Local candidate runs: `EvalLocal`, `EvalAudio`.
- Scoring: `EvalNormalization`, `EvalAlignment`, `EvalCompare` (`CompareReport`), `EvalTerms`.
- Review: `EvalReviewPage` (a local HTML page), `EvalReview`, `EvalApply` (`ReviewDecisions`, `GoldTranscript`).
- Its files: `EvalPaths` (a session's `eval/` and `derived/eval-cloud/` folders) and `EvalStore`.

**Must not own:** anything the app or the recording path needs. Nothing in HolosMeeting or below imports it.

**Depends on:** HolosCore, HolosStorage, HolosAudio, HolosSpeakers, HolosMeeting. AVFoundation, CryptoKit.

**Invariants**
- This is the only code that sends audio off the Mac: `voiceislocal eval cloud` uploads to OpenAI with the key
  from `OPENAI_API_KEY`, and only after `ConsentGate` says yes.
- A run records each track's audio fingerprint (`SessionManifest.audioFingerprint(track:)` in HolosStorage, shared
  with the echo analysis); resuming, comparing and reviewing check it against the session's current audio.
- Its output (reports, the review page, gold transcripts) contains transcript text and stays in the session
  folder on the Mac; never copy it into the repository (`docs/meeting-design.md §1.9`).

**Known size debt:** `EvalNormalization` and `EvalAlignment` are over 1,000 lines.

**Tests:** `Tests/HolosEvaluationTests`. Tests use a fake `CloudHTTPTransport` and never reach the network; tests
that need installed speech assets or models are opt-in.
