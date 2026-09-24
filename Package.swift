// swift-tools-version: 6.2
import PackageDescription
import Foundation

let cliInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Resources/CLI-Info.plist").path

let package = Package(
    name: "Holos",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "holos", targets: ["HolosCLI"]),
        .executable(name: "HolosApp", targets: ["HolosApp"]),
        .library(name: "HolosCore", targets: ["HolosCore"]),
        .library(name: "HolosSpeech", targets: ["HolosSpeech"]),
        .library(name: "HolosSynthesis", targets: ["HolosSynthesis"]),
        .library(name: "HolosStorage", targets: ["HolosStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.1"),
    ],
    targets: [
        .target(name: "HolosCore"),
        .target(name: "HolosSpeech", dependencies: ["HolosCore"]),
        .target(name: "HolosSynthesis", dependencies: ["HolosCore"]),
        .target(name: "HolosContent", dependencies: ["HolosCore", "HolosSynthesis"]),
        .target(name: "HolosStorage", dependencies: ["HolosCore"]),
        .target(name: "HolosAudio", dependencies: ["HolosCore", "HolosStorage"]),
        .target(name: "HolosDesktop", dependencies: ["HolosCore"]),
        .target(name: "HolosDictation", dependencies: ["HolosCore", "HolosAudio", "HolosSpeech"]),
        .target(name: "HolosSpeakers", dependencies: ["HolosCore"]),
        .target(name: "HolosMeeting", dependencies: [
            "HolosCore", "HolosStorage", "HolosAudio", "HolosSpeech", "HolosSpeakers",
        ]),
        .target(name: "HolosDiarization", dependencies: [
            "HolosCore", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .executableTarget(name: "HolosApp", dependencies: [
            "HolosCore", "HolosAudio", "HolosSpeech", "HolosDesktop", "HolosDictation",
            "HolosStorage", "HolosSpeakers", "HolosMeeting",
        ]),
        .executableTarget(name: "HolosCLI", dependencies: [
            "HolosCore", "HolosSpeech", "HolosSynthesis", "HolosStorage", "HolosAudio", "HolosContent",
            "HolosMeeting", "HolosSpeakers", "HolosDiarization",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], linkerSettings: [.unsafeFlags([
            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist,
        ])]),
        .testTarget(name: "HolosCoreTests", dependencies: ["HolosCore"]),
        .testTarget(name: "HolosStorageTests", dependencies: ["HolosStorage", "HolosCore"]),
        .testTarget(name: "HolosSpeechTests", dependencies: ["HolosSpeech", "HolosCore"]),
        .testTarget(name: "HolosSynthesisTests", dependencies: ["HolosSynthesis", "HolosCore"]),
        .testTarget(name: "HolosAudioTests", dependencies: ["HolosAudio", "HolosCore", "HolosStorage"]),
        .testTarget(name: "HolosContentTests", dependencies: ["HolosContent", "HolosCore"]),
        .testTarget(name: "HolosDesktopTests", dependencies: ["HolosDesktop", "HolosCore"]),
        .testTarget(name: "HolosDictationTests", dependencies: ["HolosDictation", "HolosCore"]),
        .testTarget(name: "HolosSpeakersTests", dependencies: ["HolosSpeakers", "HolosCore"]),
        .testTarget(name: "HolosMeetingTests", dependencies: [
            "HolosMeeting", "HolosCore", "HolosStorage", "HolosAudio", "HolosSpeakers",
        ]),
        .testTarget(name: "HolosDiarizationTests", dependencies: [
            "HolosDiarization", "HolosSpeakers", "HolosSynthesis", "HolosAudio", "HolosCore",
        ]),
    ],
    swiftLanguageModes: [.v6]
)
