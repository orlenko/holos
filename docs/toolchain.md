# Building and testing with Apple Command Line Tools

Use Swift 6.4 and the macOS 27 SDK selected by `xcode-select`. Build the package
with `swift build`; run its Swift Testing suites with:

```sh
./scripts/test.sh
./scripts/test.sh --filter HolosSpeechTests
```

The script locates `libTestingMacros.dylib` beside the selected `swiftc` and passes
it to SwiftPM's `swiftbuild` driver. On this Command Line Tools installation,
`swift test` can import `Testing` but sometimes fails to discover that macro plugin
after rebuilding the package graph. The explicit plugin argument makes discovery
repeatable. The script uses `--disable-xctest` because the package's tests use
Swift Testing; it forwards additional SwiftPM test options unchanged. It always points
`HOLOS_DATA_DIR` and `HOLOS_SUPPORT_DIR` at a fresh temporary folder, replacing values
set in the shell, so the default suite never reads or writes your real sessions or support files.

`swift test --filter` (and so `./scripts/test.sh --filter`) still builds every
target, including WhisperKit, FluidAudio, the app, and the CLI. To build and run one
test target, use:

```sh
./scripts/test-target.sh HolosStorageTests
./scripts/test-target.sh HolosStorageTests --filter TranscriptPointer
```

It sets up the same environment and plug-in as `scripts/test.sh`, builds only that
target and the modules it depends on (`swift build --target`; SwiftPM still resolves
and checks out every package dependency, but compiles none it does not need), and
runs that target's bundle with SwiftPM's own test runner. Options after the target
go to Swift Testing as `swift test` passes them. If an unrelated target is being
edited and does not compile yet, this is also the way to test a library in
isolation. Shared test helpers are in `Tests/HolosTestSupport` (see its README). Warnings about nonexistent Command Line Tools framework
search directories have not prevented builds or tests here.

Both scripts take two options of their own (`scripts/test-options.sh`):

```sh
./scripts/test.sh --no-parallel --summary
./scripts/test-target.sh HolosStorageTests --summary --filter-file filters.txt
```

`--summary` prints only compile errors, `Build complete`, the `Test run with ...` line
and each failed test (`✘`), then the path of a log file with the full output; the exit
status is the run's. If the run fails without such a line (a crash), the last 20 lines
of the log are printed too. `--filter-file PATH` reads test-name patterns, one per
line (blank lines and `#` comments skipped), and passes them as one `--filter`.

The initial package build may fetch `swift-argument-parser`. The test script does
not install speech models, request recording permissions, or run speech inference.
