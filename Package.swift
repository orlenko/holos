// swift-tools-version: 6.2
import PackageDescription
import Foundation

let cliInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Resources/CLI-Info.plist").path

let package = Package(
    name: "Holos",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "voiceislocal", targets: ["HolosCLI"]),
        .executable(name: "HolosApp", targets: ["HolosApp"]),
        .library(name: "HolosCore", targets: ["HolosCore"]),
        .library(name: "HolosSpeech", targets: ["HolosSpeech"]),
        .library(name: "HolosSynthesis", targets: ["HolosSynthesis"]),
        .library(name: "HolosStorage", targets: ["HolosStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.1"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        // Every source target excludes its README.md (module notes for contributors, AGENTS.md).
        .target(name: "HolosCore", exclude: ["README.md"]),
        .target(name: "HolosSpeech", dependencies: ["HolosCore"], exclude: ["README.md"]),
        .target(name: "HolosSynthesis", dependencies: ["HolosCore"], exclude: ["README.md"]),
        // Readability.js is compiled into the binary (no resource bundle), so the voiceislocal tool stays one file.
        .target(name: "HolosContent", dependencies: ["HolosCore", "HolosSynthesis"], exclude: ["README.md"],
                resources: [.embedInCode("Resources/Readability.js")]),
        .target(name: "HolosStorage", dependencies: ["HolosCore"], exclude: ["README.md"]),
        .target(name: "HolosAudio", dependencies: ["HolosCore", "HolosStorage"], exclude: ["README.md"]),
        .target(name: "HolosDesktop", dependencies: ["HolosCore"], exclude: ["README.md"]),
        .target(name: "HolosDictation", dependencies: ["HolosCore", "HolosAudio", "HolosSpeech"],
                exclude: ["README.md"]),
        .target(name: "HolosSpeakers", dependencies: ["HolosCore"], exclude: ["README.md"]),
        // The system spell checker (AppKit) behind HolosCore's `SpellChecking`; each executable installs it at launch.
        .target(name: "HolosSpelling", dependencies: ["HolosCore"], exclude: ["README.md"]),
        .target(name: "HolosMeeting", dependencies: [
            "HolosCore", "HolosStorage", "HolosAudio", "HolosSpeech", "HolosSpeakers",
        ], exclude: ["README.md"]),
        // The reference evaluation (docs/reference-evaluation.md): only the command-line tool links it.
        .target(name: "HolosEvaluation", dependencies: [
            "HolosCore", "HolosStorage", "HolosAudio", "HolosSpeakers", "HolosMeeting",
        ], exclude: ["README.md"]),
        .target(name: "HolosDiarization", dependencies: [
            "HolosCore", .product(name: "FluidAudio", package: "FluidAudio"),
        ], exclude: ["README.md"]),
        // Deep transcription after a meeting (docs/meeting/deep-transcription.md §4.16): WhisperKit's Core ML Whisper models. Only
        // the command-line tool links it; the app runs the pass through voiceislocal.
        .target(name: "HolosWhisper", dependencies: [
            "HolosCore", .product(name: "WhisperKit", package: "WhisperKit"),
        ], exclude: ["README.md"]),
        // Natural voices for Reading (docs/design.md "Natural voices"): Kyutai Pocket TTS through FluidAudio. Only the
        // command-line tool links it; the app renders natural parts through voiceislocal.
        .target(name: "HolosPocket", dependencies: [
            "HolosCore", "HolosSynthesis", .product(name: "FluidAudio", package: "FluidAudio"),
        ], exclude: ["README.md"]),
        // App-only models without AppKit (settings search, setup assistant flow, ...): the app's logic that tests can
        // reach without building the app executable.
        .target(name: "HolosAppModel", dependencies: ["HolosCore"], exclude: ["README.md"]),
        .executableTarget(name: "HolosApp", dependencies: [
            "HolosCore", "HolosAppModel", "HolosAudio", "HolosSpeech", "HolosDesktop", "HolosDictation",
            "HolosStorage", "HolosSpeakers", "HolosMeeting", "HolosSynthesis", "HolosContent", "HolosSpelling",
        ], exclude: ["README.md"]),
        .executableTarget(name: "HolosCLI", dependencies: [
            "HolosCore", "HolosSpeech", "HolosSynthesis", "HolosStorage", "HolosAudio", "HolosContent",
            "HolosMeeting", "HolosSpeakers", "HolosDiarization", "HolosDictation", "HolosWhisper", "HolosEvaluation",
            "HolosPocket", "HolosSpelling",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], exclude: ["README.md"], linkerSettings: [.unsafeFlags([
            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist,
        ])]),
        // Helpers only test targets depend on (Tests/HolosTestSupport/README.md).
        .target(name: "HolosTestSupport", dependencies: ["HolosCore"], path: "Tests/HolosTestSupport",
                exclude: ["README.md"]),
        .target(name: "HolosSessionTestSupport", dependencies: ["HolosCore", "HolosStorage"],
                path: "Tests/HolosSessionTestSupport"),
        .testTarget(name: "HolosCoreTests", dependencies: ["HolosCore", "HolosSpelling", "HolosStorage"]),
        .testTarget(name: "HolosAppModelTests", dependencies: ["HolosAppModel", "HolosCore"]),
        .testTarget(name: "HolosAppTests", dependencies: ["HolosApp", "HolosContent", "HolosCore", "HolosMeeting", "HolosSynthesis",
                                                         "HolosStorage", "HolosTestSupport"]),
        .testTarget(name: "HolosStorageTests", dependencies: [
            "HolosStorage", "HolosCore", "HolosTestSupport", "HolosSessionTestSupport",
        ]),
        .testTarget(name: "HolosTestSupportTests", dependencies: [
            "HolosTestSupport", "HolosSessionTestSupport", "HolosMeeting", "HolosStorage", "HolosCore",
        ]),
        .testTarget(name: "HolosSpeechTests", dependencies: ["HolosSpeech", "HolosCore"]),
        .testTarget(name: "HolosSynthesisTests", dependencies: ["HolosSynthesis", "HolosCore", "HolosTestSupport"]),
        .testTarget(name: "HolosAudioTests", dependencies: ["HolosAudio", "HolosCore", "HolosStorage"]),
        .testTarget(name: "HolosContentTests", dependencies: ["HolosContent", "HolosCore"]),
        .testTarget(name: "HolosDesktopTests", dependencies: ["HolosDesktop", "HolosCore"]),
        .testTarget(name: "HolosDictationTests", dependencies: [
            "HolosDictation", "HolosCore", "HolosAudio", "HolosStorage", "HolosSpeech", "HolosSynthesis",
        ]),
        .testTarget(name: "HolosSpeakersTests", dependencies: ["HolosSpeakers", "HolosCore", "HolosTestSupport"]),
        .testTarget(name: "HolosMeetingTests", dependencies: [
            "HolosMeeting", "HolosCore", "HolosStorage", "HolosAudio", "HolosSpeakers", "HolosSynthesis",
            "HolosTestSupport",
        ]),
        .testTarget(name: "HolosEvaluationTests", dependencies: [
            "HolosEvaluation", "HolosMeeting", "HolosCore", "HolosStorage", "HolosAudio", "HolosSpeakers",
            "HolosSynthesis", "HolosTestSupport",
        ]),
        .testTarget(name: "HolosWhisperTests", dependencies: [
            "HolosWhisper", "HolosMeeting", "HolosEvaluation", "HolosCore", "HolosSynthesis", "HolosAudio",
            "HolosStorage", .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .testTarget(name: "HolosPocketTests", dependencies: ["HolosPocket", "HolosSynthesis", "HolosCore", "HolosTestSupport"]),
        .testTarget(name: "HolosDiarizationTests", dependencies: [
            "HolosDiarization", "HolosSpeakers", "HolosSynthesis", "HolosAudio", "HolosCore",
        ]),
    ],
    swiftLanguageModes: [.v6]
)
