# HolosContent

Reading aloud: turning files and web pages into text worth reading, rendering it to an audiobook, and the Reading
list (docs/design.md "Reading section", "Text-to-speech").

**Owns**
- Extraction into `ReadableDocument`: `DocumentLoader` (plain text, Markdown, HTML, PDF, rich text; callable off
  the main actor) and `WebArticleExtractor` (a non-persistent `WKWebView` running Mozilla Readability, embedded
  from `Resources/Readability.js`).
- `ReadingSourceParser`: what the user typed, pasted, dropped or chose, as sources to read.
- `ReadingPipeline`: renders a `ReadingScript` part by part into a resumable cache, then joins the parts
  (`AudioBookWriter`) into one `.m4a`. `SemanticChunker`, `ReadingOutput` (output names and locations),
  `ReadingPreview`.
- `ReadingLibraryStore` / `ReadingLibrary`: the Reading list's index under `<supportRoot>/ReadingLibrary`, and the
  pure decisions about it. `ReadingWorkQueue` runs readings one at a time; `ReadingPlayer` plays a finished one.

**Must not own:** speech recognition, meetings, session folders. Voice rendering stays in `HolosSynthesis`.

**Depends on:** HolosCore, HolosSynthesis. AppKit and PDFKit (`DocumentLoader`), WebKit (`WebArticleExtractor`),
AVFoundation, CryptoKit, NaturalLanguage. This target is not headless.

**Invariants**
- Every file it publishes (a part, a finished reading) goes through `ExclusivePublisher`, so no partial file sits at
  a final path and an existing file is never replaced.
- All of its files live under `HolosPaths.supportRoot` or the user's chosen output folder; tests set
  `HOLOS_SUPPORT_DIR`.
- `WebArticleExtractor` needs a running main run loop (the app, or the CLI's async `main`).

**Known size debt:** `DocumentLoader`, `ReadingPipeline`, `ReadingLibrary` and `WebArticleExtractor` are each over
1,000 lines (`scripts/check-size.sh` keeps them from growing). Move a self-contained part into its own file (for
example one reader out of `DocumentLoader`) before adding features there.

**Tests:** `Tests/HolosContentTests` (`ReadingPipelineTests`, `DocumentReaderTests`, `WebArticleTests` with no
network, `ReadingLibraryTests`, …).
