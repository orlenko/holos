# HolosContent

Reading aloud: turning files and web pages into text worth reading, rendering it to an audiobook, and the Reading
list (docs/design.md "Reading section", "Text-to-speech").

**Owns**
- Extraction into `ReadableDocument`: `DocumentLoader` (callable off the main actor) picks a reader by extension:
  `PlainTextReader`, `MarkdownReader`, `HTMLReader`, `PDFReader`, `RichTextReader`, each in its own file, with
  `DocumentText` (`DocumentText.swift`) decoding text bytes. `HTMLReader`'s parts are extensions in
  `HTMLReader+Encoding.swift`, `HTMLReader+Preparation.swift`, `HTMLReader+Walker.swift` and
  `HTMLReader+InlineStyle.swift`. `WebArticleExtractor` is a non-persistent `WKWebView` running Mozilla
  Readability, embedded from `Resources/Readability.js`.
- `ReadingSourceParser`: what the user typed, pasted, dropped or chose, as sources to read.
- `ReadingPipeline`: renders a `ReadingScript` part by part into a resumable cache, then joins the parts
  (`AudioBookWriter`) into one `.m4a`. Beside it, one file each: the manifest and what a render reports
  (`ReadingManifest.swift`), the cache's lock (`ReadingDirectoryLock`), the output's reservation
  (`ReadingOutputReservation`), path identity (`ReadingPathIdentity`), temporary files (`ReadingTemporaries`), cache
  creation (`ReadingCache`), and file reading, checksums, `offMain` and publishing (`ReadingFileIO.swift`).
  `SemanticChunker`, `ReadingOutput` (output names and locations), `ReadingPreview`. `RoutingSpeechRenderer`
  (`ReadingAudioRenderer.swift`) sends natural voices to the natural renderer and the rest to Apple's; a reading
  saves the renderer's settings and the natural voices' model commit in its manifest (`ReadingPipeline+Plan.swift`).
  `ReadingResumeVoice` finds the saved reading a resume continues.
- `DocumentText` (`DocumentText+Strict.swift`): strict reading of a text file for `voiceislocal say --text-file`.
- `ReadingLibraryStore` / `ReadingLibrary`: the Reading list's index under `<supportRoot>/ReadingLibrary`, and the
  decisions about it and its readings' files, in `ReadingLibrary+<Part>.swift` extensions (LaunchPolicy, Location,
  Ownership, FileStatus, Sharing, Deletion, Saved). The list's duration and position texts are the app's
  (`ReadingLibrary+Formatting.swift` in HolosApp). `ReadingWorkQueue` runs readings one at a time; `ReadingPlayer`
  plays a finished one.

**Must not own:** speech recognition, meetings, session folders. Voice rendering stays in `HolosSynthesis`.

**Depends on:** HolosCore, HolosSynthesis. AppKit (`DocumentLoader`, `RichTextReader`), PDFKit (`PDFReader`),
WebKit (`WebArticleExtractor`), AVFoundation, CryptoKit, NaturalLanguage. This target is not headless.

**Invariants**
- Every file it publishes (a part, a finished reading) goes through `ExclusivePublisher`, so an existing file is
  never replaced. On volumes without an exclusive rename the publish is a copy, visible while it runs; the
  reading's manifest keeps `publishing` until it ends, so a copy cut off by a crash is found and removed when
  the reading is resumed.
- A reading resumes only with the model commit, part plan and renderer settings it started with: a natural reading
  from another commit is refused before any voice or pack is checked (`ReadingResumeVoice.checkRevision`).
- All of its files live under `HolosPaths.supportRoot` or the user's chosen output folder; tests set
  `HOLOS_SUPPORT_DIR`.
- `WebArticleExtractor` needs a running main run loop (the app, or the CLI's async `main`).

**Known size debt:** `WebArticleExtractor` is over 1,000 lines (`scripts/check-size.sh` keeps it from growing).
Move a self-contained part into its own file (as each of `DocumentLoader`'s readers has one) before adding features
there.

**Tests:** `Tests/HolosContentTests` (`ReadingPipelineTests`, `DocumentReaderTests`, `WebArticleTests` with no
network, `ReadingLibraryTests`, …).
