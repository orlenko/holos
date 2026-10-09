# HolosCLI

The `voiceislocal` command-line tool (ArgumentParser). It is also the child process the app starts for recording
and for every job that needs FluidAudio or WhisperKit.

**Owns**
- `Holos.swift`: the root command and its subcommands (`doctor`, `setup`, `transcribe`, `record`, `session`,
  `speakers`, `people`, `voices`, `say`, `read`, `history`, `words`, `eval`). Before `people`, `speakers` and
  `session` commands it finishes forgets a crash left pending (`ForgetResume`).
- One file per command (`Record.swift`, `Session*.swift`, `Speakers.swift`, …): parse arguments, call the library,
  print. `Console` writes content to stdout and messages to stderr.

**Must not own:** workflow logic. A command builds a `Request`, calls the library's `*Command.run` (mostly in
`HolosMeeting`, e.g. `SessionSummarizeCommand`, `SessionDiarizeCommand`; `WordListCommand` in `HolosStorage`), and
prints the `Outcome`. New logic goes in the library so the app and tests can use it.

**Depends on:** every library except HolosDesktop, including HolosDiarization and HolosWhisper (only this target
links them). ArgumentParser, FoundationModels (`doctor`, `session summarize`).

**Conventions** (docs/meeting-design.md §1.4)
- Stdout carries content and `--json` output; progress and messages go to stderr.
- Exit codes: `0` success, `1` failure, `3` audio saved but with a warning (an automatic stop, or post-processing
  partial or failed), `64` usage errors (ArgumentParser).
- Without `--locale`, commands use the supported locale closest to the user's preferred languages
  (`RecognitionOptions`).

**Known size debt:** `Speakers.swift` (1,004 lines).

**Tests:** no test target. Command logic is tested through the library types in `Tests/HolosMeetingTests` and
`Tests/HolosStorageTests`.
