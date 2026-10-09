import Foundation
import HolosCore

/// What `voiceislocal doctor --json` prints: written by the command-line tool and read by the app, which takes the
/// models' states from it (`speakerModels`, `deepTranscriptionModel`).
public struct DoctorReport: Codable, Sendable {
    public var os: String
    public var microphone: String
    public var systemAudioPermission: Bool
    public var accessibilityPermission: Bool
    public var foundationModel: String
    public var contextSize: Int?
    public var voiceCount: Int
    public var speech: SpeechCapabilities
    public var dictation: SpeechCapabilities
    /// The locale `speechAssetStatus` and `dictationAssetStatus` describe: `--locale`, else the default one, which
    /// depends on the Mac's preferred languages.
    public var locale: String
    public var speechAssetStatus: String
    public var dictationAssetStatus: String
    public var sessionsDirectory: String
    /// "verified", "notInstalled", or "damaged" (`ModelInstallStatus.doctorValue`).
    public var speakerModels: String
    /// "installed", "downloading", or "notInstalled" (docs/meeting/deep-transcription.md §4.16).
    public var deepTranscriptionModel: DeepModelStatus
    /// Each natural voice pack ("english", "french"): "installed", "downloading", or "notInstalled".
    public var naturalVoices: [String: DeepModelStatus]?

    public init(os: String, microphone: String, systemAudioPermission: Bool, accessibilityPermission: Bool,
                foundationModel: String, contextSize: Int?, voiceCount: Int, speech: SpeechCapabilities,
                dictation: SpeechCapabilities, locale: String, speechAssetStatus: String,
                dictationAssetStatus: String, sessionsDirectory: String, speakerModels: String,
                deepTranscriptionModel: DeepModelStatus, naturalVoices: [String: DeepModelStatus]? = nil) {
        self.os = os; self.microphone = microphone; self.systemAudioPermission = systemAudioPermission
        self.accessibilityPermission = accessibilityPermission; self.foundationModel = foundationModel
        self.contextSize = contextSize; self.voiceCount = voiceCount; self.speech = speech
        self.dictation = dictation; self.locale = locale; self.speechAssetStatus = speechAssetStatus
        self.dictationAssetStatus = dictationAssetStatus; self.sessionsDirectory = sessionsDirectory
        self.speakerModels = speakerModels; self.deepTranscriptionModel = deepTranscriptionModel
        self.naturalVoices = naturalVoices
    }
}
