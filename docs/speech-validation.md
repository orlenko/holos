# Native speech validation

Validated on macOS 27.0 with Apple Swift 6.4 using a local 7.670385-second,
22,050 Hz mono Int16 WAV fixture. The fixture stays outside the repository.
Neither test records audio or plays sound.

## Asset readiness

`SpeechTranscriber.installedLocales` listed `en_CA` and `en_US` while the exact
configured module initially had `AssetInventory.Status.supported`. The locale
inventory alone does not establish readiness for a specific transcriber preset.
`AppleSpeechEngine.assetStatus(locale:backend:)` reports that configured status
as `unsupported`, `downloading`, `supported`, or `installed`.

The CLI's `holos setup --locale en-CA` installed the speech configuration, and
`holos setup --locale en-CA --backend dictation` installed the dictation
configuration. Apple's `assetInstallationRequest(supporting:)` automatically
reserves required locales, so setup did not need a separate `reserve(locale:)`
call. The Swift test bundle initially still reported `supported`; explicitly
installing assets under that test identity made its runtime test ready. This is
consistent with Apple's per-app reservation model, although the exact cause of
the different initial statuses was not independently established.

## File result

Both engines returned the two spoken sentences with source path, final text,
time ranges, confidence attributes, and UTF-16 word ranges. `SpeechTranscriber`
finalized two segments at 0–4.98 and 5.04–7.670375 seconds;
`DictationTranscriber` finalized one segment at 0–7.670375 seconds. Both heard
the first proper name as “Polo”; the remaining words were coherent, including
“meeting” and “Friday.” This fixture alone does not establish which engine is
more accurate or faster in general.

## Repeatable opt-in test

First install assets for the selected backend with `holos setup`. Then run:

```sh
HOLOS_SPEECH_TEST_AUDIO=/absolute/path/to/sample.wav \
HOLOS_SPEECH_TEST_INSTALL_ASSETS=1 \
./scripts/test.sh --filter optInNativeFileAndStreamingFixture
```

Set `HOLOS_SPEECH_TEST_BACKEND=dictation` to run the alternate engine; default
is `speech`. `HOLOS_SPEECH_TEST_LOCALE` defaults to `en-CA`. The explicit install
flag allows the test bundle to request its own configured assets. Without the
flag, the test requires those assets to be installed already. Without the audio
environment variable, the test returns without reading media or installing
assets.

The test transcribes the file, then replays it through `AppleSpeechSession` in
2,048-frame owned `PCMFrame` chunks starting at session time 2.5 seconds. It
checks final text contains both fixture keywords, segments stay ordered without
overlap, final update IDs are unique, timed word UTF-16 ranges stay within their
segments, and streaming timestamps preserve the nonzero origin. Both backends
passed this test after explicit setup under the test bundle. Separate unit tests
cover volatile replacement, final flush, backpressure failure, and cancellation.

The test does not benchmark latency, exercise microphone or system capture, or
prove network disconnection. It does not assess diarization or other languages.
