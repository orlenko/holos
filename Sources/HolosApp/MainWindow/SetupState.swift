import AppKit
import HolosCore
import HolosDesktop
import HolosSynthesis

struct SetupState {
    var microphone: String
    var accessibility: Bool
    var inputMonitoring: Bool
    /// macOS refused the hotkey's event tap with Accessibility granted (`HotkeyStartError.tapRefused`); only then is
    /// the Input Monitoring row shown.
    var inputMonitoringNeeded = false
    /// Screen & System Audio Recording, which meetings need to record the computer's audio; without it they record
    /// the microphone alone.
    var systemAudio = false
    /// Meetings record the computer's audio (UserDefaults "meetingRecordSystemAudio", on by default).
    var recordSystemAudio = true
    /// Meetings capture the screen (`MeetingScreenPreference`, off by default).
    var screenCaptureDefault = false
    /// nil while the asset check is still running.
    var assets: String?
    var installingAssets: Bool
    var dictationEnabled: Bool
    var enabling: Bool
    var busy: Bool
    var shortcutTitle: String
    /// The hold-to-talk shortcut, and whether it can be changed now (not during a dictation, enable, or meeting).
    var shortcut: HotkeyChoice = .rightOption
    var shortcutChangeable = true
    var removeFillers: Bool
    /// Whether the dictation preview is shown while dictating; problems are always shown.
    var showPreview: Bool
    /// Opacity of the dictation preview, 0.3–1.0.
    var previewOpacity: Double
    var message: String
    /// `voiceislocal doctor --json` speakerModels: "verified", "notInstalled", "damaged"; "installing" while
    /// `voiceislocal setup --speakers` runs; "unavailable" when the voiceislocal tool cannot run; "unknown" when it ran but did not
    /// report them; nil before the first check.
    var speakerModels: String?
    /// Install progress, or the last install's error.
    var speakerModelsDetail: String?
    /// The status is being checked.
    var speakerModelsBusy = false
    /// `voiceislocal doctor --json` deepTranscriptionModel ("installed", "downloading", "notInstalled"),
    /// "installing" while `voiceislocal setup --whisper` runs, "unknown" when not reported; nil before the first check.
    var deepTranscriptionModel: String?
    /// Install progress, or the last install's error.
    var deepTranscriptionDetail: String?
    /// "Deep transcription after meetings" is on.
    var deepTranscriptionEnabled = false
    /// "Title and summarize meetings with Apple Intelligence" is on, and why it cannot run here (nil when it can).
    var meetingSummaries = true
    var meetingSummariesUnavailable: String?
    /// Fix misheard words with Apple's on-device model before they are written.
    var aiFix = false
    /// Why the on-device model cannot be used; nil when it can.
    var aiFixUnavailable: String?
    /// Write spoken paths and commands as code, and wrap them in backticks (never in a terminal).
    var spokenCode = true
    var spokenCodeBackticks = true
    /// The dictation language's locale identifier ("fr-CA"), and the ones to offer (`DictationLanguage.groups`);
    /// empty while loading.
    var locale = DictationLanguage.standard
    var localeGroups: [[String]] = []
    /// False while a dictation, install, or enable is in progress.
    var localeChangeable = true
    /// The fillers removed in this language ("euh, heu, …"); nil when it has none.
    var fillerExamples: String?
    /// Dictation history: how long dictations are kept, and how many are kept now.
    var historyRetention = HistoryRetention.standard
    /// Every dictation the file keeps (a newer build's too): what Clear History deletes.
    var historyCount = 0
    /// The history file could not be read: it may still keep dictations, so Clear History stays available.
    var historyUnreadable = false
    /// Keep the audio of dictations (for Run Again), and what the kept audio takes (nil until measured).
    var historyKeepsAudio = true
    var historyAudioBytes: Int64?
    /// General: open the main window when the app starts (UserDefaults "openWindowAtLaunch", on by default), and the
    /// app's appearance (UserDefaults "appearance").
    var openWindowAtLaunch = true
    var appearance = AppearanceChoice.system
    /// Settings › Reading › Natural voices: each pack's download.
    var naturalVoices: [NaturalVoicePack: NaturalVoiceDownload] = [:]
}

enum SetupAction: Int, CaseIterable {
    case microphone, accessibility, inputMonitoring, assets, dictation, toggleFillers, togglePreview, speakerModels
    case systemAudio
    case toggleAIFix
    case toggleRecordSystemAudio
    /// Settings only: open People, clear the history, run the Setup Assistant.
    case people, clearHistory, setupAssistant
    /// Settings › Dictation history › Keep the audio of dictations.
    case toggleHistoryAudio
    /// Settings › Dictation › Write spoken paths and commands as code, and Wrap them in backticks.
    case toggleSpokenCode, toggleSpokenCodeBackticks
    /// Settings › General › Open the Voice is Local window when it starts.
    case toggleOpenWindowAtLaunch
    case toggleMeetingScreenCapture
    /// Settings › Meetings › Final transcript: download the model, and turn the pass after meetings on or off.
    case deepTranscriptionModel, toggleDeepTranscription
    /// Settings › Reading › Natural voices: download (or cancel) a language pack.
    case naturalVoicesEnglish, naturalVoicesFrench
    /// Settings › Meetings › Title and summarize meetings with Apple Intelligence.
    case toggleMeetingSummaries
    /// A permission row's System Settings… link (or its Open Settings once granted): only opens the page, while
    /// `accessibility`, `inputMonitoring`, and `systemAudio` only ask macOS (`PermissionButtons`).
    case accessibilitySettings, inputMonitoringSettings, systemAudioSettings
}
