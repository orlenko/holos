import ApplicationServices
import ArgumentParser
import AVFoundation
import Foundation
import FoundationModels
import HolosAudio
import HolosCore
import HolosDiarization
import HolosSpeech
import HolosSynthesis
import Synchronization

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect local capabilities without requesting permissions.")
    @Flag(help: "Print machine-readable JSON.") var json = false
    @Option(help: "Check model readiness for this locale.") var locale = "en-CA"

    @MainActor mutating func run() async throws {
        let speech = await AppleSpeechEngine.capabilities(backend: .speech)
        let dictation = await AppleSpeechEngine.capabilities(backend: .dictation)
        let model = SystemLanguageModel.default
        // Files only: checking the speaker models never touches the network.
        let speakerModels = FluidModels.status()
        let report = DoctorReport(os: ProcessInfo.processInfo.operatingSystemVersionString,
            microphone: AudioCapture.microphonePermission,
            systemAudioPermission: CGPreflightScreenCaptureAccess(),
            accessibilityPermission: AXIsProcessTrusted(),
            foundationModel: String(describing: model.availability),
            contextSize: model.isAvailable ? model.contextSize : nil,
            voiceCount: NativeSpeechRenderer.voices().count, speech: speech, dictation: dictation,
            speechAssetStatus: (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: .speech)) ?? "unsupported",
            dictationAssetStatus: (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: .dictation)) ?? "unsupported",
            sessionsDirectory: HolosPaths.sessions.path,
            speakerModels: speakerModels)
        if json { try Console.json(report); return }
        Console.output("Holos — local capability report")
        Console.output("macOS: \(report.os)")
        Console.output("Microphone: \(report.microphone)")
        Console.output("Screen/system audio permission: \(report.systemAudioPermission ? "granted" : "not granted to this process")")
        Console.output("Accessibility: \(report.accessibilityPermission ? "granted" : "not granted")")
        Console.output("On-device language model: \(report.foundationModel)")
        if let size = report.contextSize { Console.output("Model context: \(size) tokens") }
        Console.output("Available voices: \(report.voiceCount)")
        for item in [speech, dictation] {
            Console.output("\(item.backend.rawValue): \(item.isAvailable ? "available" : "unavailable"); installed locales: \(item.installedLocales.joined(separator: ", "))")
        }
        Console.output("\(locale) configured assets: speech=\(report.speechAssetStatus), dictation=\(report.dictationAssetStatus)")
        Console.output("Sessions: \(report.sessionsDirectory)")
        Console.output("Speaker models: \(speakerModels.summary)")
        Console.output("Install transcription assets with: holos setup --locale en-CA")
        if speakerModels != .verified { Console.output("Install speaker models with: holos setup --speakers") }
    }
}

private struct DoctorReport: Encodable {
    var os: String
    var microphone: String
    var systemAudioPermission: Bool
    var accessibilityPermission: Bool
    var foundationModel: String
    var contextSize: Int?
    var voiceCount: Int
    var speech: SpeechCapabilities
    var dictation: SpeechCapabilities
    var speechAssetStatus: String
    var dictationAssetStatus: String
    var sessionsDirectory: String
    /// Encodes as "verified", "notInstalled", or "damaged" (`ModelInstallStatus.doctorValue`).
    var speakerModels: ModelInstallStatus
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install Apple's on-device transcription assets for a locale, or the speaker models.",
        discussion: """
            --speakers downloads the speaker-labelling models (about 21 MB, pinned and checked by SHA-256) \
            into Holos's Application Support folder instead of installing transcription assets. Installed models \
            that are verified and load on this Mac are kept; models that fail either check are downloaded again. \
            --force downloads them again in any case.
            """)
    @OptionGroup var recognition: RecognitionOptions
    @Flag(help: "Download and verify the speaker models used to label speakers (network).") var speakers = false
    @Flag(help: "With --speakers: download and install the speaker models again even when they are verified.")
    var force = false

    func validate() throws {
        if force && !speakers { throw ValidationError("--force applies only with --speakers.") }
    }

    mutating func run() async throws {
        if speakers {
            try await SpeakerModelSetup.run(force: force)
            return
        }
        Console.error("Preparing \(recognition.backend.rawValue) assets for \(recognition.locale)…")
        try await AppleSpeechEngine.installAssets(locale: recognition.locale, backend: recognition.backend)
        Console.output("Ready: \(recognition.locale) (\(recognition.backend.rawValue)).")
    }
}

/// `holos setup --speakers` (docs/meeting-design.md §5.5 PR7a).
enum SpeakerModelSetup {
    static func run(force: Bool) async throws {
        let directory = FluidModels.defaultDirectory
        let source = "\(FluidModels.repository)@\(FluidModels.revision.prefix(12))"
        let progress = ProgressPrinter()
        if ProcessInfo.processInfo.environment["HOLOS_RECORD_MODEL_MANIFEST"] == "1" {
            // The one-time pinning step: print what the pinned revision contains; install nothing.
            Console.error("Downloading \(source) to record its file manifest; nothing is installed…")
            let files = try await FluidModels.recordManifest(directory: directory, progress: progress.report)
            for file in files { Console.output("\(file.relativePath)\t\(file.size)\t\(file.sha256)") }
            Console.error("\(files.count) files; tree digest \(ModelTreeDigest.digest(of: files)).")
            return
        }
        try await FluidModels.setUp(directory: directory, force: force, notice: { Console.error($0) },
                                    progress: progress.report)
        Console.output(FluidModels.readyMessage)
        Console.output(FluidModels.creditsLine)
    }
}

/// Prints "Speaker models: N%" to stderr at each new 10 % step; progress may arrive from any thread.
private final class ProgressPrinter: Sendable {
    private let lastStep = Mutex(-1)

    var report: @Sendable (Double) -> Void {
        { [self] fraction in
            guard fraction.isFinite else { return }
            let step = Int(min(1, max(0, fraction)) * 10)
            let isNew = lastStep.withLock { last in
                guard step > last else { return false }
                last = step
                return true
            }
            if isNew { Console.error("Speaker models: \(step * 10)%") }
        }
    }
}
