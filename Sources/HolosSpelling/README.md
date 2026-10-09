# HolosSpelling

The system spell checker for HolosCore's text processing, kept out of HolosCore so that HolosCore needs no AppKit.

**Owns**
- `SystemSpellChecker`: `NSSpellChecker` as HolosCore's `SpellChecking` protocol: whether a word is a word of the
  dictation language, and which of the spell checker's dictionaries serve that language. `Lexicon` (the guard on
  Apple Intelligence's fix) and `DictationSeams` (pauses inside a sentence) ask it through `SystemSpelling`.

**Must not own:** the questions asked of it (`Lexicon`, `DictationSeams` and `TranscriptFixer` stay in HolosCore),
anything else from AppKit.

**Depends on:** HolosCore. AppKit.

**Invariants**
- Every executable that runs dictation's text steps or the fix installs it at launch, before any lookup:
  `SystemSpelling.install(SystemSpellChecker())` (`HolosAppMain.main`, `Holos.main` in HolosCLI). Without it, a
  process has no dictionary, so every word counts as known.
- `SystemSpellChecker` is called on `SystemSpelling.queue` only; its cached tag and language list are read and
  written there.

**Tests:** no test target of its own. `HolosCoreTests` installs it for the tests that judge words with the real
spell checker (`.systemSpelling` in `SystemSpellingTrait.swift`: `TranscriptFixerTests`, `HeardAsTests`,
`WordListTests`, and `DictationSeamsTests`' system lookups).
