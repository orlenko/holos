# HolosCLI

The `voiceislocal` command-line tool (ArgumentParser). It is also the child process the app starts for every job
that needs FluidAudio or WhisperKit, and for recording (unless the app's in-process recorder mode is turned on).

**Owns**
- `Holos.swift`: the root command and its subcommands (`doctor`, `setup`, `transcribe`, `record`, `session`,
  `speakers`, `people`, `voices`, `say`, `read`, `history`, `words`, `eval`). Before `people`, `speakers` and
  `session` commands it finishes forgets a crash left pending (`ForgetResume`).
- One file per command (`Record.swift`, `Session*.swift`, `Speakers.swift`, …): parse arguments, call the library,
  print. `Console` writes content to stdout and messages to stderr.

**Must not own:** workflow logic. Most `session` subcommands build a `Request`, call the library's `*Command.run`
(`SessionSummarizeCommand`, `SessionDiarizeCommand`, … in `HolosMeeting`) and print the `Outcome`; `words` calls
`WordListCommand` in `HolosStorage`. The other commands call library types directly, and
`Speakers.swift` and `Eval.swift` still hold more than parsing and printing. New logic goes in the library so the
app and tests can use it.

**Depends on:** every library except HolosDesktop, including HolosDiarization, HolosWhisper and HolosEvaluation
(of the products, only this target links them). ArgumentParser, FoundationModels (`doctor`, `session summarize`).

**Conventions** (`docs/meeting-design.md §1.4`)
- Stdout carries content and `--json` output; progress and messages go to stderr.
- Exit codes: `0` success; `1` failure; `3` the command did its main job but with a warning (for `record`: audio
  saved, but an automatic stop or post-processing partial or failed; `session` commands such as `import`,
  `recover`, `rename`, `summarize`, `echo-analyze` use it the same way); `64` usage errors (ArgumentParser).
- Ctrl-C and SIGTERM differ by command. `read`, `eval`, `session deep-transcribe` and `session echo-analyze` exit
  with `128 + signal` (`InterruptLatch`, `EvalInterrupt`). `record` stops gracefully, saves the audio and exits
  with its outcome's code. `session import` and `session summarize` cancel the work and exit 1 or 3 (their
  outcome's code). Commands that print "press Ctrl-C again" end at once on a second signal.
- Without `--locale`, recognition commands use the supported locale closest to the user's preferred languages
  (`RecognitionOptions`); `session retranscribe` uses the locale the session was recorded with.

**Known size debt:** `Speakers.swift` (1,004 lines).

**Tests:** no test target. Command logic is tested through the library types in `Tests/HolosMeetingTests` and
`Tests/HolosStorageTests`.
