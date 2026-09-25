import AppKit
import HolosAudio
import HolosCore
import HolosMeeting

/// "New Meeting Recording" (docs/meeting-design.md §5.8): name, what will be recorded (the system default input and
/// the computer's audio, `MeetingStartSettings.app`), the disk estimate, the speaker models, and the consent reminder.
/// Start is disabled when the disk policy refuses or nothing could be recorded (no microphone, and no computer's
/// audio). An ordinary window, like Setup.
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
    private let sourcesLabel = NSTextField(wrappingLabelWithString: "")
    private let microphoneLabel = NSTextField(wrappingLabelWithString: "")
    private let diskLabel = NSTextField(wrappingLabelWithString: "")
    private let speakersLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install…", target: nil, action: nil)
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
        for label in [sourcesLabel, microphoneLabel, diskLabel, speakersLabel] {
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

        let speakers = NSStackView(views: [speakersLabel, installButton])
        speakers.spacing = 8
        let grid = NSGridView(views: [
            [Self.title("Name"), nameField],
            [Self.title("Records"), sourcesLabel],
            [Self.title("Mic"), microphoneLabel],
            [Self.title("Disk"), diskLabel],
            [Self.title("Speakers"), speakers],
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

    /// Opens the panel with a fresh default name. `saved` is the last settings started; what is recorded does not
    /// come from them but from Setup and the permission (`MeetingStartSettings.app`).
    func show(name: String, saved: MeetingStartSettings?, consentDismissed: Bool) {
        if !window.isVisible {
            nameField.stringValue = name
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

    private static func settings(name: String, _ current: Environment) -> MeetingStartSettings {
        MeetingStartSettings.app(name: name, recordSystemAudio: current.recordSystemAudio,
                                 systemAudioAllowed: current.systemAudioAllowed)
    }

    /// Updates the sources, microphone, disk, and speaker lines and whether Start is allowed.
    func refresh() {
        let current = environment()
        let planned = Self.settings(name: nameField.stringValue, current)
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
        startButton.isEnabled = allowed
    }

    @objc private func install() {
        onInstallSpeakerModels()
        refresh()
    }

    @objc private func start() {
        // The permission as it is now, never a prompt: without it the meeting records the microphone alone.
        let settings = Self.settings(name: nameField.stringValue, environment())
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
