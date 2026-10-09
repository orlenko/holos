# HolosEvaluation

The reference evaluation behind `voiceislocal eval` (docs/reference-evaluation.md "Cloud reference"): comparing local
transcription with a cloud reference and with a reviewer's corrections. Developer tooling; of the products, only
`HolosCLI` links it.

**Owns**
- Cloud reference runs: `CloudEvaluation` (render, segment, upload, save each answer),
  `ConsentGate` (only an explicit yes or `--yes` uploads), `CloudTranscriptionClient` over a `CloudHTTPTransport`
  (`URLSessionTransport`, an ephemeral session), `CloudSegmentation`, `CloudVocabulary`, `CloudModels`.
- The library side of `voiceislocal eval`: `EvalCloudCommand` (lease, preparation, the caller's consent question,
  upload), `EvalLocalCommand`, `EvalCompareCommand`, `EvalReviewCommand`, `EvalApplyCommand`, `EvalDeleteCommand`.
  They report what they say as `EvalCommandMessage`s in order with their steps, run their long steps through an
  `EvalInterruption` (the CLI's stops them on Ctrl-C), and read the user's files through `EvalUserFiles`.
- Local candidate runs: `EvalLocal`, `EvalAudio`.
- Scoring: `EvalNormalization`, `EvalAlignment`, `EvalCompare` (`CompareReport`), `EvalTerms`.
- Review: `EvalReviewPage` (a local HTML page), `EvalReview`, `EvalApply` (`ReviewDecisions`, `GoldTranscript`).
- Its files: `EvalPaths` (a session's `eval/` and `derived/eval-cloud/` folders) and `EvalStore`.

**Must not own:** anything the app or the recording path needs. Nothing in HolosMeeting or below imports it.

**Depends on:** HolosCore, HolosStorage, HolosAudio, HolosSpeakers, HolosMeeting. AVFoundation, CryptoKit.

**Invariants**
- This is the only code that sends audio off the Mac: `voiceislocal eval cloud` uploads to OpenAI with the key
  from `OPENAI_API_KEY`. `EvalCloudCommand` uploads only when its caller's consent callback (the CLI's
  `ConsentGate` question) says to proceed; `CloudEvaluation.upload` itself does not ask, so any other caller must ask
  first.
- A run records each track's audio fingerprint (`SessionManifest.audioFingerprint(track:)` in HolosStorage, shared
  with the echo analysis). Resuming a cloud run, and building a review page while the audio is still there, refuse
  when it no longer matches the session's audio. Comparing a saved local run with a cloud run checks that the two
  runs recorded the same fingerprint and audio digest (reading the current audio only for older cloud runs
  without a digest); comparing the current transcript with a cloud run does no audio check.
- Its output (reports, the review page, gold transcripts) contains transcript text and stays in the session
  folder on the Mac; never copy it into the repository (`docs/meeting-design.md §1.9`).

**Known size debt:** `EvalNormalization` and `EvalAlignment` are over 1,000 lines.

**Tests:** `Tests/HolosEvaluationTests`. Tests use a fake `CloudHTTPTransport` and never reach the network; tests
that need installed speech assets or models are opt-in.
