# HolosEvaluation

The reference evaluation behind `voiceislocal eval` (docs/reference-evaluation.md, "Cloud reference"): cloud
reference runs (the OpenAI transcription client, segmentation, vocabulary), local candidate runs, alignment and
normalization, comparison reports, the review page, and applying a reviewer's decisions. Everything it keeps is under
a session's `eval/` and `derived/eval-cloud/` folders (`EvalPaths`).

- **Depends on:** HolosCore, HolosStorage, HolosAudio, HolosSpeakers, HolosMeeting.
- **Depended on by:** HolosCLI only (and its tests, HolosEvaluationTests). The app never links it; nothing in
  HolosMeeting or below may import it.
- The audio fingerprint its run records keep is `SessionManifest.audioFingerprint` in HolosStorage, shared with the
  echo analysis.
