import Foundation
import HolosCore
import HolosMeeting
import HolosSpeech

/// The meeting language: chosen in the start panel from the same list as dictation, remembered in `meetingLocales`
/// (a list, so a later version can transcribe mixed-language meetings; one language today), and its speech model,
/// which is checked when the panel shows it and installed only when the user clicks Install.
extension HolosAppDelegate {
    /// The languages and speech model states for the start panel.
    func addLanguages(to environment: inout MeetingStartPanel.Environment) {
        environment.languages = localeGroups
        environment.speechModels = meeting.speechModels
        environment.speechInstalling = meeting.speechModelInstalling
        environment.speechInstallErrors = meeting.speechModelErrors
    }

    /// The supported languages loaded, or could not be (`loadLanguages`): the start panel fills its popup, and takes
    /// the default language if it opened before it was known (it keeps Start off until then).
    func languagesLoaded() {
        meeting.startPanel?.languagesChanged(to: meetingLocales ?? [])
        meeting.startPanel?.refresh()
    }

    /// Keeps the languages of a meeting that started, for the next one.
    func rememberMeetingLocales(_ settings: MeetingStartSettings) {
        let locales = settings.normalized().locales
        if !locales.isEmpty { meetingLocales = locales }
    }

    /// Checks `locale`'s speech model for the start panel; the panel refreshes with the answer.
    func checkMeetingSpeechModel(_ locale: String) {
        Task { [weak self] in
            // The check throws only for a language the transcriber does not support (as `voiceislocal doctor` reads it).
            let state = (try? await AppleSpeechEngine.assetStatus(locale: locale, backend: .speech)) ?? "unsupported"
            guard let self else { return }
            self.meeting.speechModels[locale] = state
            self.meeting.startPanel?.refresh()
        }
    }

    /// Installs `locale`'s speech model, which may download Apple's model: only from the start panel's Install button.
    func installMeetingSpeechModel(_ locale: String) {
        guard meeting.speechModelInstalling == nil else { return }
        meeting.speechModelInstalling = locale
        meeting.speechModelErrors[locale] = nil
        meeting.startPanel?.refresh()
        Task { [weak self] in
            var failure: String?
            do {
                try await AppleSpeechEngine.installAssets(locale: locale, backend: .speech)
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.meeting.speechModelInstalling = nil
            self.meeting.speechModelErrors[locale] = failure
            self.meeting.speechModels[locale] = nil
            self.checkMeetingSpeechModel(locale)
            self.meeting.startPanel?.refresh()
        }
    }
}
