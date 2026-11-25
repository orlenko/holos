import ApplicationServices
import ArgumentParser
import AVFoundation
import Foundation
import FoundationModels
import HolosAudio
import HolosCore
import HolosDiarization
import HolosLlama
import HolosMeeting
import HolosSpeech
import HolosSynthesis
import HolosWhisper

extension TidyModel.Variant: ExpressibleByArgument {}
import Synchronization

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect local capabilities without requesting permissions.")
    @Flag(help: "Print machine-readable JSON.") var json = false
    @Option(help: ArgumentHelp("Check model readiness for this locale.",
                               discussion: "Default: the speech locale closest to your preferred languages, else en-CA."))
    var locale: String?

    @MainActor mutating func run() async throws {
        let speech = await AppleSpeechEngine.capabilities(backend: .speech)
        let locale = locale ?? DictationLanguage.preferredForSystem(supported: speech.supportedLocales)
        let dictation = await AppleSpeechEngine.capabilities(backend: .dictation)
        let model = SystemLanguageModel.default
        // Files only: checking the speaker models never touches the network.
        let speakerModels = FluidModels.status()
        let whisperModel = WhisperModels.status()
        let report = DoctorReport(os: ProcessInfo.processInfo.operatingSystemVersionString,
            microphone: AudioCapture.microphonePermission,
            systemAudioPermission: CGPreflightScreenCaptureAccess(),
            accessibilityPermission: AXIsProcessTrusted(),
            foundationModel: String(describing: model.availability),
            contextSize: model.isAvailable ? model.contextSize : nil,
            voiceCount: NativeSpeechRenderer.voices().count, speech: speech, dictation: dictation, locale: locale,
            speechAssetStatus: await AppleSpeechEngine.assetStatusOrUnknown(locale: locale, backend: .speech),
            dictationAssetStatus: await AppleSpeechEngine.assetStatusOrUnknown(locale: locale, backend: .dictation),
            sessionsDirectory: HolosPaths.sessions.path,
            speakerModels: speakerModels.doctorValue, deepTranscriptionModel: whisperModel,
            naturalVoices: Dictionary(uniqueKeysWithValues: NaturalVoicePack.allCases.map {
                ($0.rawValue, NaturalVoiceModels.status(pack: $0))
            }), tidyModel: TidyModel.status())
        if json { try Console.json(report); return }
        Console.output("Voice is Local — local capability report")
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
        Console.output("\(report.locale) configured assets: speech=\(report.speechAssetStatus), dictation=\(report.dictationAssetStatus)")
        Console.output("Sessions: \(report.sessionsDirectory)")
        Console.output("Speaker models: \(speakerModels.summary)")
        Console.output("Deep transcription model (\(DeepTranscriptionModel.displayName)): \(whisperModel.summary)")
        for pack in NaturalVoicePack.allCases {
            Console.output("Natural voices (\(pack.languageName)): \(report.naturalVoices?[pack.rawValue]?.summary ?? "unknown")")
        }
        Console.output("Tidy Up model (\(TidyModel.displayName)): \(report.tidyModel?.summary ?? "unknown")")
        let recognizers = RecognizerLocales(speech: speech.supportedLocales, dictation: dictation.supportedLocales)
        if let backend = recognizers.knownBackend(for: locale) {
            Console.output("Install transcription assets with: voiceislocal setup --locale \(locale)"
                + (backend == .dictation ? " --backend dictation" : ""))
        } else {
            Console.output(recognizers.isComplete ? "No Apple recognizer supports \(locale)."
                : "Language lists are incomplete; retry doctor for an installation command.")
        }
        if speakerModels != .verified { Console.output("Install speaker models with: voiceislocal setup --speakers") }
        if whisperModel == .notInstalled {
            Console.output("Install the deep transcription model with: voiceislocal setup --whisper (about 1.6 GB)")
        }
        if report.tidyModel == .notInstalled {
            Console.output("Install the Tidy Up model with: voiceislocal setup --tidy-model (about 5.7 GB)")
        }
    }
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install Apple's on-device transcription assets for a locale, the speaker models, or the deep transcription model.",
        discussion: """
            --speakers downloads the speaker-labelling models (about 21 MB, pinned and checked by SHA-256) \
            into Voice is Local's Application Support folder instead of installing transcription assets. Installed models \
            that are verified and load on this Mac are kept; models that fail either check are downloaded again. \
            --whisper downloads the deep transcription model (Whisper large-v3 turbo for WhisperKit, about 1.6 GB, \
            from Hugging Face) into the same folder and loads it once, so voiceislocal session deep-transcribe can \
            transcribe meetings again after they end; an interrupted download resumes. An installed model is kept. \
            --natural-voices downloads the natural Reading voices (Kyutai Pocket TTS, through FluidAudio, from \
            Hugging Face) for English (about \(NaturalVoicePack.english.downloadSize)), or for French with \
            --language fr (about \(NaturalVoicePack.french.downloadSize)), into the same folder, and prepares them \
            for this Mac (the first time takes a few minutes). \
            --tidy-model downloads Tidy Up's model (\(TidyModel.displayName), a GGUF file of about 5.7 GB from \
            Hugging Face, pinned and checked by SHA-256) into the same folder; an interrupted download resumes. With \
            --from FILE it checks and copies a copy of that file already on this Mac instead. \
            --remove-tidy-model deletes it. \
            --force downloads any of them again in any case.
            """)
    @OptionGroup var recognition: RecognitionOptions
    @Flag(help: "Download and verify the speaker models used to label speakers (network).") var speakers = false
    @Flag(help: "Download and check the deep transcription model used after meetings (network, about 1.6 GB).")
    var whisper = false
    @Flag(help: "Download and verify Parakeet Ultra (about 632 MB).") var parakeet = false
    @Flag(help: "With --parakeet or --whisper, print local installation status as JSON.") var status = false
    @Flag(help: "Download and prepare the natural Reading voices (network; English unless --language fr).")
    var naturalVoices = false
    @Flag(help: "Download and check a Tidy Up model (network).") var tidyModel = false
    @Option(help: "With --tidy-model or --remove-tidy-model: qwen (default), qwen4b, s1-mini, or muesli.")
    var model: TidyModel.Variant?
    @Option(help: ArgumentHelp("With --tidy-model: copy this model file, already on this Mac, instead of downloading.",
                               valueName: "file"))
    var from: String?
    @Flag(help: "Delete Tidy Up's model and any unfinished download.") var removeTidyModel = false
    @Option(help: ArgumentHelp("With --natural-voices: en (the default) or fr.", valueName: "language"))
    var language: String?
    @Flag(help: "With --speakers, --whisper, --parakeet, --natural-voices, or --tidy-model: download and install the models again even when they are installed.")
    var force = false

    func validate() throws {
        let chosen = [speakers, whisper, parakeet, naturalVoices, tidyModel, removeTidyModel].filter { $0 }.count
        if status && ((!parakeet && !whisper) || force) {
            throw ValidationError("--status requires --parakeet or --whisper, without --force.")
        }
        if force && (chosen == 0 || removeTidyModel) {
            throw ValidationError("--force applies only with --speakers, --whisper, --parakeet, --natural-voices, or --tidy-model.")
        }
        if chosen > 1 {
            throw ValidationError("Choose one of --speakers, --whisper, --parakeet, --natural-voices, --tidy-model, and --remove-tidy-model.")
        }
        if from != nil && !tidyModel { throw ValidationError("--from applies only with --tidy-model.") }
        if model != nil && !tidyModel && !removeTidyModel {
            throw ValidationError("--model applies only with --tidy-model or --remove-tidy-model.")
        }
        if language != nil && !naturalVoices { throw ValidationError("--language applies only with --natural-voices.") }
        if let language, NaturalVoicePack.allCases.first(where: { $0.languageCode == language }) == nil {
            throw ValidationError("--language must be en or fr.")
        }
    }

    mutating func run() async throws {
        if status {
            let state: DeepModelStatus = whisper ? WhisperModels.status() : try (ParakeetModels.isInstalled() ? .installed : .notInstalled)
            try Console.json(state)
            return
        }
        if parakeet {
            try await ParakeetModels.setUp(force: force, progress: ProgressPrinter(label: "Parakeet Ultra").report)
            Console.output("Parakeet Ultra is ready.")
            return
        }
        if naturalVoices {
            let pack = NaturalVoicePack.allCases.first { $0.languageCode == (language ?? "en") } ?? .english
            try await NaturalVoiceSetup.run(pack: pack, force: force)
            return
        }
        if tidyModel {
            let variant = model ?? .qwen
            let source = from.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let progress = ProgressPrinter(label: "Tidy Up model")
            try await TidyModelInstall.setUp(variant: variant, force: force, source: source, notice: { Console.error($0) },
                                             progress: progress.report)
            Console.output(variant == .qwen ? TidyModel.readyMessage : "Ready: Tidy Up model (\(variant.displayName)).")
            Console.output(variant == .qwen ? TidyModel.creditsLine : "See THIRD_PARTY_NOTICES.md for model credits.")
            return
        }
        if removeTidyModel {
            let variant = model ?? .qwen
            try TidyModelInstall.remove(variant: variant)
            Console.output(variant == .qwen ? "Removed: Tidy Up model." : "Removed: \(variant.displayName).")
            return
        }
        if speakers {
            try await SpeakerModelSetup.run(force: force)
            return
        }
        if whisper {
            try await WhisperModelSetup.run(force: force)
            return
        }
        let locale = await recognition.resolvedLocale()
        Console.error("Preparing \(recognition.backend.rawValue) assets for \(locale)…")
        try await AppleSpeechEngine.installAssets(locale: locale, backend: recognition.backend)
        Console.output("Ready: \(locale) (\(recognition.backend.rawValue)).")
    }
}

/// `voiceislocal setup --speakers` (docs/meeting/speaker-labels.md §5.5).
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

/// `voiceislocal setup --whisper` (docs/meeting/deep-transcription.md §4.16).
enum WhisperModelSetup {
    static func run(force: Bool) async throws {
        let progress = ProgressPrinter(label: "Deep transcription model")
        try await WhisperModels.setUp(force: force, notice: { Console.error($0) }, progress: progress.report)
        Console.output(WhisperModels.readyMessage)
        Console.output(WhisperModels.creditsLine)
    }
}

/// Prints "<label>: N%" to stderr at each new 10 % step; progress may arrive from any thread.
private final class ProgressPrinter: Sendable {
    private let lastStep = Mutex(-1)
    private let label: String

    init(label: String = "Speaker models") { self.label = label }

    var report: @Sendable (Double) -> Void {
        { [self] fraction in
            guard fraction.isFinite else { return }
            let step = Int(min(1, max(0, fraction)) * 10)
            let isNew = lastStep.withLock { last in
                guard step > last else { return false }
                last = step
                return true
            }
            if isNew { Console.error("\(label): \(step * 10)%") }
        }
    }
}
