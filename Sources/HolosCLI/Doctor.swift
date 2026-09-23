import ApplicationServices
import ArgumentParser
import AVFoundation
import Foundation
import FoundationModels
import HolosAudio
import HolosCore
import HolosSpeech
import HolosSynthesis

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect local capabilities without requesting permissions.")
    @Flag(help: "Print machine-readable JSON.") var json = false
    @Option(help: "Check model readiness for this locale.") var locale = "en-CA"

    @MainActor mutating func run() async throws {
        let speech = await AppleSpeechEngine.capabilities(backend: .speech)
        let dictation = await AppleSpeechEngine.capabilities(backend: .dictation)
        let model = SystemLanguageModel.default
        let report = DoctorReport(os: ProcessInfo.processInfo.operatingSystemVersionString,
            microphone: AudioCapture.microphonePermission,
            systemAudioPermission: CGPreflightScreenCaptureAccess(),
            accessibilityPermission: AXIsProcessTrusted(),
            foundationModel: String(describing: model.availability),
            contextSize: model.isAvailable ? model.contextSize : nil,
            voiceCount: NativeSpeechRenderer.voices().count, speech: speech, dictation: dictation,
            speechAssetStatus: (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: .speech)) ?? "unsupported",
            dictationAssetStatus: (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: .dictation)) ?? "unsupported",
            sessionsDirectory: HolosPaths.sessions.path)
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
        Console.output("Install transcription assets with: holos setup --locale en-CA")
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
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install Apple's on-device transcription assets for a locale.")
    @OptionGroup var recognition: RecognitionOptions
    mutating func run() async throws {
        Console.error("Preparing \(recognition.backend.rawValue) assets for \(recognition.locale)…")
        try await AppleSpeechEngine.installAssets(locale: recognition.locale, backend: recognition.backend)
        Console.output("Ready: \(recognition.locale) (\(recognition.backend.rawValue)).")
    }
}
