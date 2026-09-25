import AppKit

struct SetupState {
    var microphone: String
    var accessibility: Bool
    var inputMonitoring: Bool
    /// Screen & System Audio Recording, which online calls need to record the other side; in-person meetings do not.
    var systemAudio = false
    /// nil while the asset check is still running.
    var assets: String?
    var installingAssets: Bool
    var dictationEnabled: Bool
    var enabling: Bool
    var busy: Bool
    var shortcutTitle: String
    var removeFillers: Bool
    /// Whether the dictation preview is shown while dictating; problems are always shown.
    var showPreview: Bool
    /// Opacity of the dictation preview, 0.3–1.0.
    var previewOpacity: Double
    var message: String
    /// A meeting is recording, so dictation is paused (docs/meeting-design.md §4.12).
    var dictationPausedForMeeting = false
    /// `voiceislocal doctor --json` speakerModels: "verified", "notInstalled", "damaged"; "installing" while
    /// `voiceislocal setup --speakers` runs; "unavailable" when the voiceislocal tool cannot run; "unknown" when it ran but did not
    /// report them; nil before the first check.
    var speakerModels: String?
    /// Install progress, or the last install's error.
    var speakerModelsDetail: String?
    /// The status is being checked.
    var speakerModelsBusy = false
    /// Fix misheard words with Apple's on-device model before they are written.
    var aiFix = false
    /// Why the on-device model cannot be used; nil when it can.
    var aiFixUnavailable: String?
}

enum SetupAction: Int, CaseIterable {
    case microphone, accessibility, inputMonitoring, assets, dictation, toggleFillers, togglePreview, speakerModels
    case systemAudio
    case toggleAIFix
}

/// A regular titled window, so setup status stays visible while the user works in System Settings.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private enum Mark { case done, pending, problem }
    private struct Row { let icon: NSImageView; let detail: NSTextField; let button: NSButton }

    private let window: NSWindow
    private let perform: (SetupAction) -> Void
    private let onClose: () -> Void
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let fillerToggle = NSButton(checkboxWithTitle: "Remove filler words (um, uh, ah, erm, hmm)",
                                        target: nil, action: nil)
    private let previewToggle = NSButton(checkboxWithTitle: "Show the dictation preview while dictating",
                                         target: nil, action: nil)
    private static let aiFixTitle = "Fix misheard words with Apple Intelligence (on-device)"
    private let aiFixToggle = NSButton(checkboxWithTitle: aiFixTitle, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.85, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    private var onOpacityChange: ((Double) -> Void)?
    private var rows: [SetupAction: Row] = [:]
    private var positioned = false

    var isVisible: Bool { window.isVisible }

    init(perform: @escaping (SetupAction) -> Void, onClose: @escaping () -> Void,
         onOpacityChange: ((Double) -> Void)? = nil) {
        self.onOpacityChange = onOpacityChange
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        self.perform = perform
        self.onClose = onClose
        super.init()
        window.title = "Voice is Local Setup"
        window.isReleasedWhenClosed = false
        // An ordinary window: other apps can cover it. It stays open until the user closes it, and while it
        // is open Holos appears in the Dock and Command-Tab so it can be found again (HolosAppDelegate).
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self

        let grid = NSGridView()
        grid.rowSpacing = 16
        grid.columnSpacing = 12
        let titles: [(SetupAction, String)] = [
            (.microphone, "Microphone"), (.accessibility, "Accessibility"),
            (.inputMonitoring, "Input Monitoring"), (.assets, "English speech assets"), (.dictation, "Dictation"),
            (.speakerModels, "Speaker labels"), (.systemAudio, "System audio (online calls)"),
        ]
        for (action, title) in titles {
            let icon = NSImageView()
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: "")
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 330
            let text = NSStackView(views: [titleLabel, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.widthAnchor.constraint(equalToConstant: 330).isActive = true
            let button = NSButton(title: "", target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .push
            button.tag = action.rawValue
            grid.addRow(with: [icon, text, button])
            rows[action] = Row(icon: icon, detail: detail, button: button)
        }
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 2).xPlacement = .trailing
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.preferredMaxLayoutWidth = 500
        let note = NSTextField(wrappingLabelWithString: """
            This window updates on its own while you change System Settings. After rebuilding Voice is Local, \
            macOS can keep an old entry that looks switched on but no longer matches the app: select Voice is Local \
            in that list, remove it with –, then click Open Settings here to add it again. An entry named Holos \
            is this app from before it was renamed; remove it the same way.
            """)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 500

        fillerToggle.target = self
        fillerToggle.action = #selector(buttonPressed(_:))
        fillerToggle.tag = SetupAction.toggleFillers.rawValue

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.isContinuous = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        opacityValue.textColor = .secondaryLabelColor
        let opacityRow = NSStackView(views: [NSTextField(labelWithString: "Dictation preview opacity"),
                                             opacitySlider, opacityValue])
        opacityRow.spacing = 10

        previewToggle.target = self
        previewToggle.action = #selector(buttonPressed(_:))
        previewToggle.tag = SetupAction.togglePreview.rawValue
        previewToggle.toolTip = "When off, text just streams into the field. Problems that need you (text left on the clipboard, a failed dictation) are always shown."

        aiFixToggle.target = self
        aiFixToggle.action = #selector(buttonPressed(_:))
        aiFixToggle.tag = SetupAction.toggleAIFix.rawValue
        aiFixToggle.toolTip = "Each phrase is checked by Apple's on-device model before it is typed, which adds about half a second. Only small fixes are kept; Copy Original in the menu has the text as heard."

        let stack = NSStackView(views: [messageLabel, grid, fillerToggle, previewToggle, aiFixToggle, opacityRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = content
    }

    func show() {
        if !positioned {
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
            window.center()
            positioned = true
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func update(_ state: SetupState) {
        messageLabel.stringValue = "Status: \(state.message)"
        fillerToggle.state = state.removeFillers ? .on : .off
        previewToggle.state = state.showPreview ? .on : .off
        aiFixToggle.isEnabled = state.aiFixUnavailable == nil
        aiFixToggle.state = state.aiFix && state.aiFixUnavailable == nil ? .on : .off
        aiFixToggle.title = state.aiFixUnavailable.map { "\(Self.aiFixTitle) — unavailable: \($0)" } ?? Self.aiFixTitle
        opacitySlider.isEnabled = state.showPreview
        // Leave the slider alone while the user drags it.
        if NSEvent.pressedMouseButtons == 0 { opacitySlider.doubleValue = state.previewOpacity }
        opacityValue.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded())) %"

        switch state.microphone {
        case "authorized":
            set(.microphone, .done, "Granted", button: "Open Settings")
        case "notDetermined":
            set(.microphone, .pending, "Not requested yet — macOS asks once", button: "Request…")
        default:
            set(.microphone, .problem, "Denied — turn on Voice is Local in System Settings", button: "Open Settings")
        }
        set(.accessibility, state.accessibility ? .done : .problem,
            state.accessibility ? "Granted — used to insert text into the focused field"
                                : "Not granted — turn on Voice is Local in System Settings",
            button: "Open Settings")
        set(.inputMonitoring, state.inputMonitoring ? .done : .problem,
            state.inputMonitoring ? "Granted — used to detect the hold-to-talk shortcut"
                                  : "Not granted — turn on Voice is Local in System Settings",
            button: "Open Settings")
        // Optional, so never marked as a problem: only online calls record the computer's audio.
        set(.systemAudio, state.systemAudio ? .done : .pending,
            state.systemAudio ? "Granted — records the other side of online calls"
                              : "Optional — needed only to record online calls. Turn on Voice is Local under Screen & System "
                                + "Audio Recording, then quit and reopen Voice is Local.",
            button: state.systemAudio ? nil : "Open Settings")

        let canInstall = !state.installingAssets && !state.busy && !state.dictationEnabled && !state.enabling
        if state.installingAssets || state.assets == "downloading" {
            set(.assets, .pending, "Downloading and installing en-CA…", button: "Install", enabled: false)
        } else {
            switch state.assets {
            case nil: set(.assets, .pending, "Checking…", button: "Install", enabled: false)
            case "installed": set(.assets, .done, "Installed (en-CA)", button: nil)
            case "supported": set(.assets, .pending, "Not installed — downloads Apple's en-CA model", button: "Install", enabled: canInstall)
            case "unsupported": set(.assets, .problem, "en-CA speech recognition is not supported on this Mac", button: nil)
            case let other?: set(.assets, .problem, "Status unknown (\(other))", button: "Install", enabled: canInstall)
            }
        }

        if state.dictationPausedForMeeting {
            set(.dictation, .pending, "Paused during meeting recording — resumes when the recording stops",
                button: "Enable", enabled: false)
        } else if state.enabling {
            set(.dictation, .pending, "Starting…", button: "Enable", enabled: false)
        } else if state.dictationEnabled {
            set(.dictation, .done, "On — hold \(state.shortcutTitle), wait for Listening, speak, release",
                button: "Disable", enabled: !state.busy)
        } else {
            set(.dictation, .pending, "Off — enable once the steps above are done", button: "Enable",
                enabled: !state.installingAssets)
        }

        let install = "Install (21 MB download)"
        switch state.speakerModels {
        case "installing":
            set(.speakerModels, .pending, state.speakerModelsDetail ?? "Downloading…", button: install, enabled: false)
        case "verified":
            set(.speakerModels, .done, "Installed — meetings get speaker labels after they are saved", button: nil)
        case "notInstalled":
            set(.speakerModels, state.speakerModelsDetail == nil ? .pending : .problem,
                state.speakerModelsDetail.map { "Install failed: \($0)" }
                    ?? "Not installed — meetings are saved without speaker labels", button: install)
        case "damaged":
            set(.speakerModels, .problem, state.speakerModelsDetail.map { "Install failed: \($0)" }
                ?? "Damaged — install them again", button: install)
        case "unavailable":
            set(.speakerModels, .problem, "The voiceislocal tool is missing from VoiceIsLocal.app; rebuild Voice is Local with scripts/build-app.sh",
                button: nil)
        case "unknown":
            set(.speakerModels, .problem, "Could not check the speaker models; `voiceislocal doctor` shows why", button: install)
        case let other?:
            set(.speakerModels, .problem, "Status unknown (\(other))", button: install)
        case nil:
            set(.speakerModels, .pending, "Checking…", button: install, enabled: false)
        }
    }

    private func set(_ action: SetupAction, _ mark: Mark, _ detail: String, button title: String?, enabled: Bool = true) {
        guard let row = rows[action] else { return }
        let (symbol, color): (String, NSColor) = switch mark {
        case .done: ("checkmark.circle.fill", .systemGreen)
        case .pending: ("circle.dashed", .secondaryLabelColor)
        case .problem: ("exclamationmark.circle.fill", .systemOrange)
        }
        row.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        row.icon.contentTintColor = color
        row.detail.stringValue = detail
        row.button.isHidden = title == nil
        row.button.title = title ?? ""
        row.button.isEnabled = enabled
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        opacityValue.stringValue = "\(Int((sender.doubleValue * 100).rounded())) %"
        onOpacityChange?(sender.doubleValue)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let action = SetupAction(rawValue: sender.tag) else { return }
        perform(action)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
