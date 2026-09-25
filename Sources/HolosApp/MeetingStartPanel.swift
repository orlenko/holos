import AppKit
import HolosAudio
import HolosCore
import HolosMeeting

/// "New Meeting Recording" (docs/meeting-design.md §5.8): name, what will be recorded (the system default input and
/// the computer's audio, `MeetingStartSettings.app`), the disk estimate, the speaker models, the meeting language, up
/// to two more languages to detect after the recording (§4.14), their speech models, and the consent reminder. Start
/// is disabled when the disk policy refuses, nothing could be recorded (no microphone, and no computer's audio), or
/// the meeting language is not known yet. An ordinary window, like Setup.
@MainActor
final class MeetingStartPanel: NSObject, NSWindowDelegate {
    /// What the panel shows besides the user's choices; read every 2 s while it is open.
    struct Environment {
        var devices: InputDevices
        var freeBytes: Int64?
        /// `voiceislocal doctor --json` speakerModels, "unavailable" when the voiceislocal tool cannot run, "unknown" when it ran
        /// but did not report them, or nil before the first check.
        var speakerModels: String?
        var checking: Bool
        /// `voiceislocal setup --speakers` progress while it runs.
        var installProgress: String?
        var installError: String?
        /// Setup › Advanced › "Record the computer's audio (system sound) in meetings".
        var recordSystemAudio = true
        /// `CGPreflightScreenCaptureAccess()`: without it the meeting records the microphone alone.
        var systemAudioAllowed = false
        /// The meeting languages to offer (`DictationLanguage.groups`, as for dictation); empty until loaded.
        var languages: [[String]] = []
        /// `AppleSpeechEngine.assetStatus` of each language checked so far ("installed", "supported", …).
        var speechModels: [String: String] = [:]
        /// The language whose speech model is being installed from this panel, and the last failed install of each.
        var speechInstalling: String?
        var speechInstallErrors: [String: String] = [:]

        static let unknown = Environment(devices: InputDevices(builtIn: nil, systemDefault: nil), freeBytes: nil,
                                         speakerModels: nil, checking: false, installProgress: nil, installError: nil)
    }

    private let window: NSWindow
    private let environment: () -> Environment
    /// Returns the error to show, or nil once the recording is starting.
    private let onStart: (MeetingStartSettings, Bool) -> String?
    private let onInstallSpeakerModels: () -> Void
    /// Asked to check a language's speech model (the answer comes back in `Environment.speechModels`), and to install
    /// it when the user clicks its Install button.
    private let onCheckSpeechModel: (String) -> Void
    private let onInstallSpeechModel: (String) -> Void
    private let onClose: () -> Void

    private let nameField = NSTextField()
    private let sourcesLabel = NSTextField(wrappingLabelWithString: "")
    private let microphoneLabel = NSTextField(wrappingLabelWithString: "")
    private let diskLabel = NSTextField(wrappingLabelWithString: "")
    private let speakersLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install…", target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    /// "Also detect": a pull-down of the other languages, each with a checkmark when chosen.
    private let alsoDetectPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let speechLabel = NSTextField(wrappingLabelWithString: "")
    private let speechInstallButton = NSButton(title: "Install…", target: nil, action: nil)
    /// The popups' languages as last filled, so a refresh never replaces their menus while one is open.
    private var shownLanguages: [[String]] = []
    private var shownAlsoDetect: [[String]] = []
    /// The chosen meeting languages: the popup's first, then the ones to detect too (at most two).
    private var chosenLocales: [String] = []
    /// The language whose model the Install… button installs: the first chosen one whose model is not ready.
    private var installTarget: String?
    /// The user picked a language in either popup since the panel opened.
    private var languagePicked = false
    private let consentLabel = NSTextField(labelWithString: "ⓘ Tell everyone you are recording.")
    private let consentCheckbox = NSButton(checkboxWithTitle: "Don't show this again", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var consentRow: NSView?
    private var refreshTask: Task<Void, Never>?
    private var positioned = false

    var isVisible: Bool { window.isVisible }

    init(environment: @escaping () -> Environment, onStart: @escaping (MeetingStartSettings, Bool) -> String?,
         onInstallSpeakerModels: @escaping () -> Void, onCheckSpeechModel: @escaping (String) -> Void,
         onInstallSpeechModel: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.environment = environment
        self.onStart = onStart
        self.onInstallSpeakerModels = onInstallSpeakerModels
        self.onCheckSpeechModel = onCheckSpeechModel
        self.onInstallSpeechModel = onInstallSpeechModel
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380), styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "New Meeting Recording"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self

        nameField.placeholderString = "Meeting name"
        nameField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        for label in [sourcesLabel, microphoneLabel, diskLabel, speakersLabel, speechLabel] {
            label.font = .systemFont(ofSize: 12)
            label.preferredMaxLayoutWidth = 320
        }
        installButton.target = self
        installButton.action = #selector(install)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.toolTip = "The language the meeting is transcribed in. Voice is Local remembers it for the next meeting."
        alsoDetectPopup.target = self
        alsoDetectPopup.action = #selector(alsoDetectChanged)
        alsoDetectPopup.menu?.autoenablesItems = false
        alsoDetectPopup.toolTip = "Other languages spoken in the meeting. After the recording, Voice is Local "
            + "transcribes the audio again in each and keeps, every few seconds, the language that fits; this takes "
            + "a few extra minutes. The live transcript stays in the meeting language."
        speechInstallButton.target = self
        speechInstallButton.action = #selector(installSpeechModel)
        speechInstallButton.toolTip = "Downloads Apple's on-device speech model for the language named."
        for button in [installButton, speechInstallButton] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.preferredMaxLayoutWidth = 400
        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"

        let speakers = NSStackView(views: [speakersLabel, installButton])
        speakers.spacing = 8
        let speech = NSStackView(views: [speechLabel, speechInstallButton])
        speech.spacing = 8
        // The language rows are last, so the rows above keep their indexes.
        let grid = NSGridView(views: [
            [Self.title("Name"), nameField],
            [Self.title("Records"), sourcesLabel],
            [Self.title("Mic"), microphoneLabel],
            [Self.title("Disk"), diskLabel],
            [Self.title("Speakers"), speakers],
            [Self.title("Language"), languagePopup],
            [Self.title("Also detect"), alsoDetectPopup],
            [NSGridCell.emptyContentView, speech],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        for index in 0..<grid.numberOfRows { grid.row(at: index).rowAlignment = .firstBaseline }

        consentLabel.font = .systemFont(ofSize: 12)
        let consent = NSStackView(views: [consentLabel, consentCheckbox])
        consent.spacing = 12
        consentRow = consent
        let buttons = NSStackView(views: [cancelButton, startButton])
        buttons.spacing = 8
        let footer = NSStackView(views: [NSView(), buttons])
        footer.distribution = .fill

        let stack = NSStackView(views: [grid, consent, errorLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = content
    }

    private static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    /// Opens the panel with a fresh default name and the meeting languages (`HolosAppDelegate.meetingLocales`).
    /// `saved` is the last settings started; what is recorded does not come from them but from Setup and the
    /// permission (`MeetingStartSettings.app`).
    func show(name: String, saved: MeetingStartSettings?, locales: [String], consentDismissed: Bool) {
        if !window.isVisible {
            nameField.stringValue = name
            chosenLocales = DictationLanguage.meetingLanguages(locales)
            languagePicked = false
            for locale in chosenLocales { onCheckSpeechModel(locale) }
            consentCheckbox.state = .off
            consentRow?.isHidden = consentDismissed
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }
        refresh()
        // The panel is not resizable, so its size is always the one its rows need: fit it on every show, and
        // place it only the first time.
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        if !positioned {
            window.center()
            positioned = true
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nameField)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.window.isVisible else { return }
                self.refresh()
            }
        }
    }

    private static func settings(name: String, _ current: Environment, locales: [String]) -> MeetingStartSettings {
        MeetingStartSettings.app(name: name, recordSystemAudio: current.recordSystemAudio,
                                 systemAudioAllowed: current.systemAudioAllowed, locales: locales)
    }

    /// Updates the sources, microphone, disk, and speaker lines and whether Start is allowed.
    func refresh() {
        let current = environment()
        let planned = Self.settings(name: nameField.stringValue, current, locales: chosenLocales)
        let source = planned.source
        var allowed = true

        // What a meeting started now records: the microphone, plus the computer's audio unless it is off in Setup's
        // Advanced section or not allowed.
        let sources = MeetingStartSettings.sourcesDescription(recordSystemAudio: current.recordSystemAudio,
                                                              systemAudioAllowed: current.systemAudioAllowed)
        if sourcesLabel.stringValue != sources {
            sourcesLabel.stringValue = sources
            // The line may wrap differently (the setting changed in Setup while the panel is open).
            if positioned { window.setContentSize(window.contentView?.fittingSize ?? window.frame.size) }
        }
        if let input = current.devices.systemDefault {
            microphoneLabel.stringValue = "\(input.name) (system default)"
            microphoneLabel.textColor = .labelColor
        } else if source == .microphoneAndSystem {
            microphoneLabel.stringValue = "No microphone: only the computer's audio is recorded."
            microphoneLabel.textColor = .systemOrange
        } else {
            microphoneLabel.stringValue = "No microphone is connected."
            microphoneLabel.textColor = .systemRed
            allowed = false
        }

        if let free = current.freeBytes {
            let estimate = DiskPolicy.estimateText(source: source, hours: 3, freeBytes: free)
            switch DiskPolicy.startCheck(freeBytes: free, source: source) {
            case .refuse(let message):
                diskLabel.stringValue = "\(estimate)\n\(message)"
                diskLabel.textColor = .systemRed
                allowed = false
            case .warn(let message):
                diskLabel.stringValue = "\(estimate)\n\(message)"
                diskLabel.textColor = .systemOrange
            case .ok, .stop:
                diskLabel.stringValue = estimate
                diskLabel.textColor = .labelColor
            }
        } else {
            diskLabel.stringValue = "Free space unknown"
            diskLabel.textColor = .secondaryLabelColor
        }

        installButton.isHidden = true
        installButton.isEnabled = true
        speakersLabel.textColor = .labelColor
        if let progress = current.installProgress {
            speakersLabel.stringValue = progress
            installButton.isHidden = false
            installButton.isEnabled = false
        } else {
            switch current.speakerModels {
            case "verified":
                speakersLabel.stringValue = "Speaker labels ready"
            case "notInstalled", "damaged":
                speakersLabel.stringValue = current.installError.map { "Speaker models not installed: \($0)" }
                    ?? "Speaker models not installed"
                speakersLabel.textColor = .systemOrange
                installButton.isHidden = false
            case "unavailable":
                speakersLabel.stringValue = "The voiceislocal tool is missing from VoiceIsLocal.app"
                speakersLabel.textColor = .systemRed
            case "unknown" where !current.checking:
                // `voiceislocal doctor` ran but did not say: the models may still be missing, so Install stays offered.
                speakersLabel.stringValue = current.installError.map { "Speaker models: the install failed: \($0)" }
                    ?? "Could not check the speaker models"
                speakersLabel.textColor = .systemOrange
                installButton.isHidden = false
            default:
                speakersLabel.stringValue = current.checking ? "Checking speaker models…" : "Speaker models: unknown"
                speakersLabel.textColor = .secondaryLabelColor
            }
        }
        let speechLine = (speechLabel.stringValue, speechInstallButton.isHidden)
        // No language yet: the default one is known once the supported languages load (`languagesChanged`), and a
        // meeting started before then would be transcribed in `DictationLanguage.standard`.
        if !refreshLanguage(current) { allowed = false }
        // The speech model's line arrives after the panel is shown and can wrap onto a second line: fit the window
        // to it.
        if positioned, speechLine != (speechLabel.stringValue, speechInstallButton.isHidden) {
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        }
        startButton.isEnabled = allowed
    }

    /// The language popups, and whether the chosen languages' speech models are installed: the line names the first
    /// chosen language whose model is not ready, and Install… installs that one. A missing model does not block Start
    /// (the audio is still saved; a language to detect is left out afterwards, and the finished message says so); it
    /// is installed only when the user clicks Install. False while there is no language yet (the app is still finding
    /// the default one).
    private func refreshLanguage(_ current: Environment) -> Bool {
        var groups = current.languages
        for chosen in chosenLocales.reversed() where !groups.joined().contains(chosen) { groups.insert([chosen], at: 0) }
        if groups != shownLanguages {
            shownLanguages = groups
            languagePopup.removeAllItems()
            for (index, group) in groups.enumerated() {
                if index > 0 { languagePopup.menu?.addItem(.separator()) }
                for locale in group {
                    let item = NSMenuItem(title: DictationLanguage.name(of: locale), action: nil, keyEquivalent: "")
                    item.representedObject = locale
                    languagePopup.menu?.addItem(item)
                }
            }
        }
        refreshAlsoDetect(groups)
        installTarget = nil
        speechInstallButton.isHidden = true
        guard let locale = chosenLocales.first else {
            speechLabel.stringValue = "Finding the meeting language…"
            speechLabel.textColor = .secondaryLabelColor
            return false
        }
        if languagePopup.selectedItem?.representedObject as? String != locale {
            languagePopup.selectItem(at: languagePopup.indexOfItem(withRepresentedObject: locale))
        }
        speechInstallButton.isEnabled = current.speechInstalling == nil
        speechLabel.textColor = .systemOrange
        if let installing = current.speechInstalling, chosenLocales.contains(installing) {
            speechLabel.stringValue = "Installing the speech model for \(DictationLanguage.name(of: installing))…"
            speechLabel.textColor = .secondaryLabelColor
            speechInstallButton.isHidden = false
            return true
        }
        for (index, language) in chosenLocales.enumerated() {
            let state = current.speechModels[language]
            guard state != "installed" else { continue }
            let name = DictationLanguage.name(of: language)
            // What is lost without the model: the transcript for the meeting language, the detection for another.
            let loss = index == 0 ? "the audio is saved, but not transcribed." : "\(name) will not be detected."
            installTarget = language
            if state != nil, let error = current.speechInstallErrors[language] {
                speechLabel.stringValue = "Speech model for \(name) not installed: \(error)"
                speechInstallButton.isHidden = false
                return true
            }
            switch state {
            case "supported":
                speechLabel.stringValue = "Speech model for \(name) not installed: \(loss)"
                speechInstallButton.isHidden = false
            case "downloading":
                speechLabel.stringValue = "The speech model for \(name) is downloading."
                speechLabel.textColor = .secondaryLabelColor
            case "unsupported":
                speechLabel.stringValue = index == 0 ? "\(name) cannot be transcribed on this Mac."
                    : "\(name) cannot be detected on this Mac."
                speechLabel.textColor = .systemRed
            case let other?:
                speechLabel.stringValue = "Could not check the speech model for \(name) (\(other))."
                speechInstallButton.isHidden = false
            case nil:
                speechLabel.stringValue = chosenLocales.count > 1 ? "Checking the speech models…"
                    : "Checking the speech model…"
                speechLabel.textColor = .secondaryLabelColor
            }
            return true
        }
        speechLabel.stringValue = chosenLocales.count > 1 ? "Speech models ready" : "Speech model ready"
        speechLabel.textColor = .labelColor
        return true
    }

    /// The "Also detect" pull-down: its title names the languages chosen to detect ("None" without any), and its menu
    /// the same languages as the Language pop-up, a checkmark on each chosen one. Another region of a chosen language
    /// (the meeting language included) cannot be chosen, nor more than two.
    private func refreshAlsoDetect(_ groups: [[String]]) {
        guard let menu = alsoDetectPopup.menu else { return }
        if groups != shownAlsoDetect {
            shownAlsoDetect = groups
            menu.removeAllItems()
            menu.addItem(NSMenuItem(title: "None", action: nil, keyEquivalent: ""))
            let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            none.representedObject = ""
            menu.addItem(none)
            for group in groups {
                menu.addItem(.separator())
                for locale in group {
                    let item = NSMenuItem(title: DictationLanguage.name(of: locale), action: nil, keyEquivalent: "")
                    item.representedObject = locale
                    menu.addItem(item)
                }
            }
        }
        let primary = chosenLocales.first
        let extras = Array(chosenLocales.dropFirst())
        let full = chosenLocales.count >= DictationLanguage.maximumMeetingLanguages
        let title = extras.isEmpty ? "None" : extras.map { DictationLanguage.name(of: $0) }.joined(separator: ", ")
        menu.items.first?.title = title
        alsoDetectPopup.setTitle(title)
        for item in menu.items.dropFirst() {
            guard let locale = item.representedObject as? String else { continue }
            if locale.isEmpty {
                item.state = extras.isEmpty ? .on : .off
                item.isEnabled = true
                continue
            }
            let chosen = extras.contains(locale)
            item.state = chosen ? .on : .off
            item.isEnabled = primary != nil
                && (chosen || (!full && !chosenLocales.contains { DictationLanguage.sameLanguage($0, locale) }))
        }
        alsoDetectPopup.isEnabled = primary != nil
    }

    @objc private func install() {
        onInstallSpeakerModels()
        refresh()
    }

    /// The meeting languages the app would now show: they change when the supported languages load after `show` and
    /// the default language turns out to be another. A language the user picked in the popup is kept.
    func languagesChanged(to locales: [String]) {
        let locales = DictationLanguage.meetingLanguages(locales)
        guard window.isVisible, !languagePicked, !locales.isEmpty, locales != chosenLocales else { return }
        chosenLocales = locales
        for locale in locales { onCheckSpeechModel(locale) }
        refresh()
    }

    /// A new meeting language keeps the languages to detect, except one that is now the same language.
    @objc private func languageChanged() {
        guard let locale = languagePopup.selectedItem?.representedObject as? String,
              locale != chosenLocales.first else { return }
        languagePicked = true
        chosenLocales = DictationLanguage.meetingLanguages([locale] + chosenLocales.dropFirst())
        onCheckSpeechModel(locale)
        refresh()
    }

    /// Checks or unchecks the language picked in "Also detect" ("None" unchecks them all).
    @objc private func alsoDetectChanged() {
        guard let primary = chosenLocales.first,
              let locale = alsoDetectPopup.selectedItem?.representedObject as? String else { return }
        languagePicked = true
        var extras = Array(chosenLocales.dropFirst())
        if locale.isEmpty {
            extras = []
        } else if let index = extras.firstIndex(of: locale) {
            extras.remove(at: index)
        } else {
            extras.append(locale)
            onCheckSpeechModel(locale)
        }
        chosenLocales = DictationLanguage.meetingLanguages([primary] + extras)
        refresh()
        // The title can be longer or shorter now.
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
    }

    @objc private func installSpeechModel() {
        guard let locale = installTarget ?? chosenLocales.first else { return }
        onInstallSpeechModel(locale)
        refresh()
    }

    @objc private func start() {
        // The permission as it is now, never a prompt: without it the meeting records the microphone alone.
        let settings = Self.settings(name: nameField.stringValue, environment(), locales: chosenLocales)
        if let error = onStart(settings, consentCheckbox.state == .on) {
            errorLabel.stringValue = error
            errorLabel.isHidden = false
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
            return
        }
        window.close()
    }

    @objc private func cancel() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
        onClose()
    }
}
