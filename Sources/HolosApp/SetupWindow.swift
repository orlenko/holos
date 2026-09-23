import AppKit

struct SetupState {
    var microphone: String
    var accessibility: Bool
    var inputMonitoring: Bool
    /// nil while the asset check is still running.
    var assets: String?
    var installingAssets: Bool
    var dictationEnabled: Bool
    var enabling: Bool
    var busy: Bool
    var shortcutTitle: String
    var removeFillers: Bool
    var message: String
}

enum SetupAction: Int, CaseIterable {
    case microphone, accessibility, inputMonitoring, assets, dictation, toggleFillers
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
    private var rows: [SetupAction: Row] = [:]
    private var positioned = false

    var isVisible: Bool { window.isVisible }

    init(perform: @escaping (SetupAction) -> Void, onClose: @escaping () -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        self.perform = perform
        self.onClose = onClose
        super.init()
        window.title = "Holos Setup"
        window.isReleasedWhenClosed = false
        // Holos has no Dock icon, so a window that falls behind System Settings is hard to find again.
        // Keep setup above other apps until the user closes it.
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self

        let grid = NSGridView()
        grid.rowSpacing = 16
        grid.columnSpacing = 12
        let titles: [(SetupAction, String)] = [
            (.microphone, "Microphone"), (.accessibility, "Accessibility"),
            (.inputMonitoring, "Input Monitoring"), (.assets, "English speech assets"), (.dictation, "Dictation"),
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
            This window updates on its own while you change System Settings. After rebuilding Holos, \
            macOS can keep an old entry that looks switched on but no longer matches the app: select Holos \
            in that list, remove it with –, then click Open Settings here to add it again.
            """)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 500

        fillerToggle.target = self
        fillerToggle.action = #selector(buttonPressed(_:))
        fillerToggle.tag = SetupAction.toggleFillers.rawValue

        let stack = NSStackView(views: [messageLabel, grid, fillerToggle, note])
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

        switch state.microphone {
        case "authorized":
            set(.microphone, .done, "Granted", button: "Open Settings")
        case "notDetermined":
            set(.microphone, .pending, "Not requested yet — macOS asks once", button: "Request…")
        default:
            set(.microphone, .problem, "Denied — turn on Holos in System Settings", button: "Open Settings")
        }
        set(.accessibility, state.accessibility ? .done : .problem,
            state.accessibility ? "Granted — used to insert text into the focused field"
                                : "Not granted — turn on Holos in System Settings",
            button: "Open Settings")
        set(.inputMonitoring, state.inputMonitoring ? .done : .problem,
            state.inputMonitoring ? "Granted — used to detect the hold-to-talk shortcut"
                                  : "Not granted — turn on Holos in System Settings",
            button: "Open Settings")

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

        if state.enabling {
            set(.dictation, .pending, "Starting…", button: "Enable", enabled: false)
        } else if state.dictationEnabled {
            set(.dictation, .done, "On — hold \(state.shortcutTitle), wait for Listening, speak, release",
                button: "Disable", enabled: !state.busy)
        } else {
            set(.dictation, .pending, "Off — enable once the steps above are done", button: "Enable",
                enabled: !state.installingAssets)
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

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let action = SetupAction(rawValue: sender.tag) else { return }
        perform(action)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
