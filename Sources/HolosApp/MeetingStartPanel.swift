import AppKit
import HolosAudio
import HolosCore
import HolosMeeting

/// "New Meeting Recording" (docs/meeting-design.md §5.8): name, in person or online call, the microphone that will
/// be recorded, the disk estimate, the speaker models, and the consent reminder. Start is disabled when the disk
/// policy refuses or, in person, the built-in microphone is missing. An ordinary window, like Setup.
@MainActor
final class MeetingStartPanel: NSObject, NSWindowDelegate {
    /// What the panel shows besides the user's choices; read every 2 s while it is open.
    struct Environment {
        var devices: InputDevices
        var freeBytes: Int64?
        /// `holos doctor --json` speakerModels, "unavailable", or nil while unknown.
        var speakerModels: String?
        var checking: Bool
        /// `holos setup --speakers` progress while it runs.
        var installProgress: String?
        var installError: String?

        static let unknown = Environment(devices: InputDevices(builtIn: nil, systemDefault: nil), freeBytes: nil,
                                         speakerModels: nil, checking: false, installProgress: nil, installError: nil)
    }

    private let window: NSWindow
    private let environment: () -> Environment
    /// Returns the error to show, or nil once the recording is starting.
    private let onStart: (MeetingStartSettings, Bool) -> String?
    private let onInstallSpeakerModels: () -> Void
    private let onClose: () -> Void

    private let nameField = NSTextField()
    private let inPersonButton = NSButton(radioButtonWithTitle: "In person — microphone", target: nil, action: nil)
    private let callButton = NSButton(radioButtonWithTitle: "Online call — microphone and system audio",
                                      target: nil, action: nil)
    private let appPopup = NSPopUpButton()
    private let othersCheckbox = NSButton(
        checkboxWithTitle: "Others are in the room with me (label speakers on my microphone too)", target: nil, action: nil)
    private let microphoneLabel = NSTextField(wrappingLabelWithString: "")
    private let diskLabel = NSTextField(wrappingLabelWithString: "")
    private let speakersLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install…", target: nil, action: nil)
    private let consentLabel = NSTextField(labelWithString: "ⓘ Tell everyone you are recording.")
    private let consentCheckbox = NSButton(checkboxWithTitle: "Don't show this again", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var appRow: NSGridRow?
    private var othersRow: NSGridRow?
    private var consentRow: NSView?
    /// Bundle IDs of the app popup's items; nil is "Any app".
    private var appIDs: [String?] = [nil]
    private var refreshTask: Task<Void, Never>?
    private var positioned = false

    var isVisible: Bool { window.isVisible }

    init(environment: @escaping () -> Environment, onStart: @escaping (MeetingStartSettings, Bool) -> String?,
         onInstallSpeakerModels: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.environment = environment
        self.onStart = onStart
        self.onInstallSpeakerModels = onInstallSpeakerModels
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
        othersCheckbox.toolTip = "Holos then labels speakers on your microphone track too, not only in the call audio."
        for label in [microphoneLabel, diskLabel, speakersLabel] {
            label.font = .systemFont(ofSize: 12)
            label.preferredMaxLayoutWidth = 320
        }
        installButton.target = self
        installButton.action = #selector(install)
        installButton.bezelStyle = .push
        installButton.controlSize = .small
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
        let grid = NSGridView(views: [
            [Self.title("Name"), nameField],
            [Self.title("Type"), types],
            [NSGridCell.emptyContentView, NSStackView(views: [NSTextField(labelWithString: "App"), appPopup])],
            [NSGridCell.emptyContentView, othersCheckbox],
            [Self.title("Mic"), microphoneLabel],
            [Self.title("Disk"), diskLabel],
            [Self.title("Speakers"), speakers],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        appRow = grid.row(at: 2)
        othersRow = grid.row(at: 3)
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

    /// Opens the panel with a fresh default name and the last settings (their type, app, and room choice).
    func show(name: String, saved: MeetingStartSettings?, consentDismissed: Bool) {
        if !window.isVisible {
            nameField.stringValue = name
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
        if !positioned {
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
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
                speakersLabel.stringValue = "The holos tool is missing from Holos.app"
                speakersLabel.textColor = .systemRed
            default:
                speakersLabel.stringValue = current.checking ? "Checking speaker models…" : "Speaker models: unknown"
                speakersLabel.textColor = .secondaryLabelColor
            }
        }
        startButton.isEnabled = allowed
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

    @objc private func start() {
        let call = callButton.state == .on
        let index = appPopup.indexOfSelectedItem
        let settings = MeetingStartSettings(
            name: nameField.stringValue, source: call ? .microphoneAndSystem : .microphone,
            applicationBundleID: call && index >= 0 && index < appIDs.count ? appIDs[index] : nil,
            othersInRoom: call && othersCheckbox.state == .on)
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
