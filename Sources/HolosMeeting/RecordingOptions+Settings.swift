import Foundation
import HolosAudio
import HolosCore

// The one mapping from the start settings of a meeting from the app to the recorder's options (docs/meeting/recorder.md
// §4.1): the in-process recorder builds its options with it, and `ChildProcessLauncher.arguments` hands the same
// values to `voiceislocal record start`, which reads an option it is not given the same way (its default language is
// `AppleSpeechEngine.defaultLocale`, its default microphone `RecordingOptions.microphone(for:)`).

extension MeetingStartSettings {
    /// The microphone choice the recorder is given: none for a recording without the microphone (`.system`, where
    /// `record start` refuses `--microphone`); otherwise the choice, nil leaving the default for the source.
    var recorderMicrophone: MicrophoneSelection? { source == .system ? nil : microphone }

    /// The meeting's languages for the recorder: all of them when there are several, else none (`locale` alone).
    var recorderLanguages: [String] { locales.count > 1 ? locales : [] }
}

extension RecordingOptions {
    /// The options of a meeting started from the app as `sessionID` in `root`. `defaultLocale` gives the language when
    /// `settings` names none (the recorder's default, `RecordingDependencies.defaultLocale`); it is not asked
    /// otherwise.
    init(settings: MeetingStartSettings, sessionID: String, root: URL, vocabulary: [String],
         defaultLocale: () async -> String) async {
        let locale: String
        if let chosen = settings.locale { locale = chosen } else { locale = await defaultLocale() }
        self.init(name: settings.name, source: settings.source, locale: locale, backend: .speech, root: root,
                  applicationBundleID: settings.applicationBundleID, vocabulary: vocabulary, sessionID: sessionID,
                  othersInRoom: settings.othersInRoom, expectedSpeakers: settings.expectedSpeakers, liveText: false,
                  microphone: settings.recorderMicrophone, languages: settings.recorderLanguages,
                  screen: settings.screen, nameSource: settings.nameIsDefault ? .default : .user)
    }
}
