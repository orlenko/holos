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
Swift Testing; it forwards additional SwiftPM test options unchanged.

`swift test --filter` still builds the package's other targets, including the CLI.
If an unrelated target is being edited and does not compile yet, build a library
in isolation with `swift build --target HolosSpeech`, then rerun the script after
integration compiles. Warnings about nonexistent Command Line Tools framework
search directories have not prevented builds or tests here.

The initial package build may fetch `swift-argument-parser`. The test script does
not install speech models, request recording permissions, or run speech inference.
