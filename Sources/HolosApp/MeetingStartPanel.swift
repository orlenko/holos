import AppKit
import HolosAudio
import HolosCore
import HolosMeeting

/// "New Meeting Recording" (docs/meeting-design.md §5.8): name, in person or online call, the microphone that will
/// be recorded, the disk estimate, the speaker models, the meeting language and its speech model, and the consent
/// reminder. Start is disabled when the disk policy refuses or, in person, the built-in microphone is missing. A call that would record the microphone while the
/// laptop speakers play gets the echo warning line (PR11). An ordinary window, like Setup.
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
    /// The system default output (PR11), looked up with the environment; nil when unknown.
    private let findOutputRoute: () -> OutputRoute?
    /// Returns the error to show, or nil once the recording is starting.
    private let onStart: (MeetingStartSettings, Bool) -> String?
    private let onInstallSpeakerModels: () -> Void
    /// Asked to check a language's speech model (the answer comes back in `Environment.speechModels`), and to install
    /// it when the user clicks its Install button.
    private let onCheckSpeechModel: (String) -> Void
    private let onInstallSpeechModel: (String) -> Void
    private let onClose: () -> Void

    private let nameField = NSTextField()
    private let inPersonButton = NSButton(radioButtonWithTitle: "In person — microphone", target: nil, action: nil)
    private let callButton = NSButton(radioButtonWithTitle: "Online call — microphone and system audio",
                                      target: nil, action: nil)
    private let appPopup = NSPopUpButton()
    private let othersCheckbox = NSButton(
        checkboxWithTitle: "Others are in the room with me (label speakers on my microphone too)", target: nil, action: nil)
    private let microphoneLabel = NSTextField(wrappingLabelWithString: "")
    private let echoLabel = NSTextField(wrappingLabelWithString: OutputRoute.echoRiskMessage)
    private let diskLabel = NSTextField(wrappingLabelWithString: "")
    private let speakersLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install…", target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    private let speechLabel = NSTextField(wrappingLabelWithString: "")
    private let speechInstallButton = NSButton(title: "Install…", target: nil, action: nil)
    /// The popup's languages as last filled, so a refresh never replaces its menu while it is open.
    private var shownLanguages: [[String]] = []
    /// The chosen meeting languages: exactly one, from the popup, today.
    private var chosenLocales: [String] = []
    /// The user picked the language in the popup since the panel opened.
    private var languagePicked = false
    private let consentLabel = NSTextField(labelWithString: "ⓘ Tell everyone you are recording.")
    private let consentCheckbox = NSButton(checkboxWithTitle: "Don't show this again", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var appRow: NSGridRow?
    private var othersRow: NSGridRow?
    private var echoRow: NSGridRow?
    private var consentRow: NSView?
    /// Bundle IDs of the app popup's items; nil is "Any app".
    private var appIDs: [String?] = [nil]
    private var refreshTask: Task<Void, Never>?
    private var positioned = false

    var isVisible: Bool { window.isVisible }

    init(environment: @escaping () -> Environment, onStart: @escaping (MeetingStartSettings, Bool) -> String?,
         onInstallSpeakerModels: @escaping () -> Void, onCheckSpeechModel: @escaping (String) -> Void,
         onInstallSpeechModel: @escaping (String) -> Void, onClose: @escaping () -> Void,
         findOutputRoute: @escaping () -> OutputRoute? = OutputRoute.current) {
        self.environment = environment
        self.findOutputRoute = findOutputRoute
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
        for button in [inPersonButton, callButton] {
            button.target = self
            button.action = #selector(typeChanged(_:))
        }
        appPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        othersCheckbox.toolTip = "Voice is Local then labels speakers on your microphone track too, not only in the call audio."
        for label in [microphoneLabel, echoLabel, diskLabel, speakersLabel, speechLabel] {
            label.font = .systemFont(ofSize: 12)
            label.preferredMaxLayoutWidth = 320
        }
        echoLabel.textColor = .systemOrange
        installButton.target = self
        installButton.action = #selector(install)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.toolTip = "The language the meeting is transcribed in. Voice is Local remembers it for the next meeting."
        speechInstallButton.target = self
        speechInstallButton.action = #selector(installSpeechModel)
        speechInstallButton.toolTip = "Downloads Apple's on-device speech model for this language."
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

        let types = NSStackView(views: [inPersonButton, callButton])
        types.orientation = .vertical
        types.alignment = .leading
        types.spacing = 4
        let speakers = NSStackView(views: [speakersLabel, installButton])
        speakers.spacing = 8
        let speech = NSStackView(views: [speechLabel, speechInstallButton])
        speech.spacing = 8
        // The language rows are last, so the rows above keep their indexes.
        let grid = NSGridView(views: [
            [Self.title("Name"), nameField],
            [Self.title("Type"), types],
            [NSGridCell.emptyContentView, NSStackView(views: [NSTextField(labelWithString: "App"), appPopup])],
            [NSGridCell.emptyContentView, othersCheckbox],
            [Self.title("Mic"), microphoneLabel],
            [NSGridCell.emptyContentView, echoLabel],
            [Self.title("Disk"), diskLabel],
            [Self.title("Speakers"), speakers],
            [Self.title("Language"), languagePopup],
            [NSGridCell.emptyContentView, speech],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        appRow = grid.row(at: 2)
        othersRow = grid.row(at: 3)
        echoRow = grid.row(at: 5)
        echoRow?.isHidden = true
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

    /// Opens the panel with a fresh default name, the last settings (their type, app, and room choice), and the
    /// meeting languages (`HolosAppDelegate.meetingLocales`).
    func show(name: String, saved: MeetingStartSettings?, locales: [String], consentDismissed: Bool) {
        if !window.isVisible {
            nameField.stringValue = name
            chosenLocales = locales
            languagePicked = false
            if let locale = locales.first { onCheckSpeechModel(locale) }
            let call = saved?.source == .microphoneAndSystem
            inPersonButton.state = call ? .off : .on
            callButton.state = call ? .on : .off
            othersCheckbox.state = saved?.othersInRoom == true ? .on : .off
            fillApps(selecting: saved?.applicationBundleID)
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

    /// Updates the microphone, disk, and speaker lines and whether Start is allowed.
    func refresh() {
        let call = callButton.state == .on
        appRow?.isHidden = !call
        othersRow?.isHidden = !call
        let current = environment()
        var allowed = true

        if call {
            if let input = current.devices.systemDefault {
                microphoneLabel.stringValue = "\(input.name) (system default)"
                microphoneLabel.textColor = .labelColor
            } else {
                microphoneLabel.stringValue = "No microphone: only the call's audio is recorded."
                microphoneLabel.textColor = .systemOrange
            }
        } else if let builtIn = current.devices.builtIn {
            microphoneLabel.stringValue = builtIn.name
            microphoneLabel.textColor = .labelColor
        } else {
            microphoneLabel.stringValue = BuiltInMicrophone.unavailableMessage
            microphoneLabel.textColor = .systemRed
            allowed = false
        }
        // A call recording the microphone while the laptop speakers play: other people's words reach it too (PR11).
        let echoRisk = call && current.devices.systemDefault != nil && findOutputRoute()?.isBuiltInSpeakers == true
        if let echoRow, echoRow.isHidden == echoRisk {
            echoRow.isHidden = !echoRisk
            // Also while the window is hidden: `show` refreshes before it makes the window visible, and it sizes
            // the window itself only the first time, so a row that came or went since the panel was last open
            // would otherwise squeeze the rows below it.
            if positioned {
                window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
            }
        }

        let source: AudioSource = call ? .microphoneAndSystem : .microphone
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
        // to it, as for the echo row.
        if positioned, speechLine != (speechLabel.stringValue, speechInstallButton.isHidden) {
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        }
        startButton.isEnabled = allowed
    }

    /// The language popup, and whether the chosen language's speech model is installed. A missing model does not
    /// block Start (the audio is still saved); it is installed only when the user clicks Install. False while there is
    /// no language yet (the app is still finding the default one).
    private func refreshLanguage(_ current: Environment) -> Bool {
        var groups = current.languages
        if let chosen = chosenLocales.first, !groups.joined().contains(chosen) { groups.insert([chosen], at: 0) }
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
        guard let locale = chosenLocales.first else {
            speechLabel.stringValue = "Finding the meeting language…"
            speechLabel.textColor = .secondaryLabelColor
            speechInstallButton.isHidden = true
            return false
        }
        if languagePopup.selectedItem?.representedObject as? String != locale {
            languagePopup.selectItem(at: languagePopup.indexOfItem(withRepresentedObject: locale))
        }
        let name = DictationLanguage.name(of: locale)
        speechInstallButton.isHidden = true
        speechInstallButton.isEnabled = current.speechInstalling == nil
        speechLabel.textColor = .systemOrange
        if current.speechInstalling == locale {
            speechLabel.stringValue = "Installing the speech model for \(name)…"
            speechLabel.textColor = .secondaryLabelColor
            speechInstallButton.isHidden = false
            return true
        }
        let state = current.speechModels[locale]
        if state != "installed", state != nil, let error = current.speechInstallErrors[locale] {
            speechLabel.stringValue = "Speech model not installed: \(error)"
            speechInstallButton.isHidden = false
            return true
        }
        switch state {
        case "installed":
            speechLabel.stringValue = "Speech model ready"
            speechLabel.textColor = .labelColor
        case "supported":
            speechLabel.stringValue = "Speech model for \(name) not installed: the audio is saved, but not transcribed."
            speechInstallButton.isHidden = false
        case "downloading":
            speechLabel.stringValue = "The speech model for \(name) is downloading."
            speechLabel.textColor = .secondaryLabelColor
        case "unsupported":
            speechLabel.stringValue = "\(name) cannot be transcribed on this Mac."
            speechLabel.textColor = .systemRed
        case let other?:
            speechLabel.stringValue = "Could not check the speech model for \(name) (\(other))."
            speechInstallButton.isHidden = false
        case nil:
            speechLabel.stringValue = "Checking the speech model…"
            speechLabel.textColor = .secondaryLabelColor
        }
        return true
    }

    /// "Any app" and the running apps with a bundle ID, plus a saved app that is not running.
    private func fillApps(selecting saved: String?) {
        let own = Bundle.main.bundleIdentifier
        var apps: [(name: String, id: String)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own else { return nil }
            return (app.localizedName ?? id, id)
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var seen = Set<String>()
        apps = apps.filter { seen.insert($0.id).inserted }
        if let saved, !seen.contains(saved) { apps.append(("\(saved) (not running)", saved)) }
        appPopup.removeAllItems()
        appPopup.addItem(withTitle: "Any app")
        appIDs = [nil]
        for app in apps {
            appPopup.addItem(withTitle: app.name)
            appIDs.append(app.id)
        }
        appPopup.selectItem(at: saved.flatMap { appIDs.firstIndex(of: $0) } ?? 0)
    }

    @objc private func typeChanged(_ sender: NSButton) {
        inPersonButton.state = sender === inPersonButton ? .on : .off
        callButton.state = sender === callButton ? .on : .off
        errorLabel.isHidden = true
        refresh()
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
    }

    @objc private func install() {
        onInstallSpeakerModels()
        refresh()
    }

    /// The meeting languages the app would now show: they change when the supported languages load after `show` and
    /// the default language turns out to be another. A language the user picked in the popup is kept.
    func languagesChanged(to locales: [String]) {
        guard window.isVisible, !languagePicked, !locales.isEmpty, locales != chosenLocales else { return }
        chosenLocales = locales
        if let locale = locales.first { onCheckSpeechModel(locale) }
        refresh()
    }

    @objc private func languageChanged() {
        guard let locale = languagePopup.selectedItem?.representedObject as? String,
              locale != chosenLocales.first else { return }
        languagePicked = true
        chosenLocales = [locale]
        onCheckSpeechModel(locale)
        refresh()
    }

    @objc private func installSpeechModel() {
        guard let locale = chosenLocales.first else { return }
        onInstallSpeechModel(locale)
        refresh()
    }

    @objc private func start() {
        let call = callButton.state == .on
        let index = appPopup.indexOfSelectedItem
        let settings = MeetingStartSettings(
            name: nameField.stringValue, source: call ? .microphoneAndSystem : .microphone,
            applicationBundleID: call && index >= 0 && index < appIDs.count ? appIDs[index] : nil,
            othersInRoom: call && othersCheckbox.state == .on, locales: chosenLocales)
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
