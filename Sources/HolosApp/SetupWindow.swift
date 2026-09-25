import AppKit
import HolosCore

struct SetupState {
    var microphone: String
    var accessibility: Bool
    var inputMonitoring: Bool
    /// Screen & System Audio Recording, which meetings need to record the computer's audio; without it they record
    /// the microphone alone.
    var systemAudio = false
    /// Advanced: meetings record the computer's audio (UserDefaults "meetingRecordSystemAudio", on by default).
    var recordSystemAudio = true
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
    /// The dictation language's locale identifier ("fr-CA"), and the ones to offer (`DictationLanguage.groups`);
    /// empty while loading.
    var locale = DictationLanguage.standard
    var localeGroups: [[String]] = []
    /// False while a dictation, install, or enable is in progress.
    var localeChangeable = true
    /// The fillers removed in this language ("euh, heu, …"); nil when it has none.
    var fillerExamples: String?
}

enum SetupAction: Int, CaseIterable {
    case microphone, accessibility, inputMonitoring, assets, dictation, toggleFillers, togglePreview, speakerModels
    case systemAudio
    case toggleAIFix
    case toggleRecordSystemAudio
}

/// A regular titled window, so setup status stays visible while the user works in System Settings.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private enum Mark { case done, pending, problem }
    private struct Row { let icon: NSImageView; let title: NSTextField; let detail: NSTextField; let button: NSButton }

    private let window: NSWindow
    private let perform: (SetupAction) -> Void
    private let onClose: () -> Void
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let fillerToggle = NSButton(checkboxWithTitle: "Remove filler words", target: nil, action: nil)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var onLanguageChange: ((String) -> Void)?
    private var shownLocaleGroups: [[String]]?
    private let previewToggle = NSButton(checkboxWithTitle: "Show the dictation preview while dictating",
                                         target: nil, action: nil)
    private static let aiFixTitle = "Fix misheard words with Apple Intelligence (on-device)"
    private let aiFixToggle = NSButton(checkboxWithTitle: aiFixTitle, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.85, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    /// Advanced, collapsed until its disclosure button is pressed; for this window only.
    private let advancedDisclosure = NSButton(title: "", target: nil, action: nil)
    private let recordSystemAudioToggle = NSButton(
        checkboxWithTitle: "Record the computer's audio (system sound) in meetings", target: nil, action: nil)
    private var advancedContent: NSView?
    private var onOpacityChange: ((Double) -> Void)?
    private var rows: [SetupAction: Row] = [:]
    private var positioned = false

    var isVisible: Bool { window.isVisible }

    init(perform: @escaping (SetupAction) -> Void, onClose: @escaping () -> Void,
         onOpacityChange: ((Double) -> Void)? = nil, onLanguageChange: ((String) -> Void)? = nil) {
        self.onOpacityChange = onOpacityChange
        self.onLanguageChange = onLanguageChange
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
            (.inputMonitoring, "Input Monitoring"), (.assets, "Speech model"), (.dictation, "Dictation"),
            (.speakerModels, "Speaker labels"), (.systemAudio, "System audio"),
        ]
        for (action, title) in titles {
            if action == .assets {
                // The dictation language, just above the speech model it needs.
                let (text, _, detail) = Self.labels("Dictation language")
                detail.stringValue = "Used from the next dictation"
                let icon = NSImageView(image: NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage())
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                icon.contentTintColor = .secondaryLabelColor
                languagePopup.target = self
                languagePopup.action = #selector(languageChosen(_:))
                // Fixed, so the window keeps its size when the list arrives.
                languagePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
                grid.addRow(with: [icon, text, languagePopup])
            }
            let icon = NSImageView()
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            let (text, titleLabel, detail) = Self.labels(title)
            let button = NSButton(title: "", target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .push
            button.tag = action.rawValue
            grid.addRow(with: [icon, text, button])
            rows[action] = Row(icon: icon, title: titleLabel, detail: detail, button: button)
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
        previewToggle.toolTip = "When off, text just streams into the field. Problems that need you (text that could not be written, a failed dictation) are always shown."

        aiFixToggle.target = self
        aiFixToggle.action = #selector(buttonPressed(_:))
        aiFixToggle.tag = SetupAction.toggleAIFix.rawValue
        aiFixToggle.toolTip = "Each phrase is checked by Apple's on-device model before it is typed, which adds about half a second. Only small fixes are kept; Copy Original in the menu has the text as heard."

        let advanced = makeAdvancedSection()

        let stack = NSStackView(views: [messageLabel, grid, fillerToggle, previewToggle, aiFixToggle, opacityRow, note,
                                        advanced])
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

    /// "Advanced": a disclosure button over settings most people never change, collapsed when the window opens.
    private func makeAdvancedSection() -> NSView {
        advancedDisclosure.bezelStyle = .disclosure
        advancedDisclosure.setButtonType(.pushOnPushOff)
        advancedDisclosure.state = .off
        advancedDisclosure.target = self
        advancedDisclosure.action = #selector(advancedToggled(_:))
        let title = NSTextField(labelWithString: "Advanced")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [advancedDisclosure, title])
        header.spacing = 6

        recordSystemAudioToggle.target = self
        recordSystemAudioToggle.action = #selector(buttonPressed(_:))
        recordSystemAudioToggle.tag = SetupAction.toggleRecordSystemAudio.rawValue
        let detail = NSTextField(wrappingLabelWithString: """
            On: meetings record your microphone and everything the Mac plays, and speakers are labelled on both. \
            Off: meetings record the microphone only.
            """)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 480
        let content = NSStackView(views: [recordSystemAudioToggle, detail])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        content.isHidden = true
        advancedContent = content

        let section = NSStackView(views: [header, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    @objc private func advancedToggled(_ sender: NSButton) {
        advancedContent?.isHidden = sender.state != .on
        fitKeepingTopEdge()
    }

    /// Collapses Advanced, as the window is specified to open (the window is reused after it closes).
    private func collapseAdvanced() {
        advancedDisclosure.state = .off
        advancedContent?.isHidden = true
    }

    /// Resizes the window to its content, keeping the top edge where it is while the window grows or shrinks.
    private func fitKeepingTopEdge() {
        var frame = window.frame
        let size = window.frameRect(forContentRect: NSRect(origin: .zero,
                                                           size: window.contentView?.fittingSize ?? frame.size)).size
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: false)
    }

    /// A row's bold title over its detail line.
    private static func labels(_ title: String) -> (NSStackView, title: NSTextField, detail: NSTextField) {
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
        return (text, titleLabel, detail)
    }

    func show() {
        if !positioned {
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
            window.center()
            positioned = true
        } else if !window.isVisible, advancedDisclosure.state == .on {
            // Reopened after the user expanded Advanced: it opens collapsed again. Left alone while the window is
            // already showing.
            collapseAdvanced()
            fitKeepingTopEdge()
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func update(_ state: SetupState) {
        messageLabel.stringValue = "Status: \(state.message)"
        let language = DictationLanguage.name(of: state.locale)
        updateLanguagePopup(state)
        fillerToggle.isEnabled = state.fillerExamples != nil
        fillerToggle.state = state.removeFillers && state.fillerExamples != nil ? .on : .off
        fillerToggle.title = state.fillerExamples.map { "Remove filler words (\($0))" }
            ?? "Remove filler words — none known for \(language)"
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
        recordSystemAudioToggle.state = state.recordSystemAudio ? .on : .off
        // Never marked as a problem: without it meetings record the microphone alone.
        if state.systemAudio {
            set(.systemAudio, .done, state.recordSystemAudio
                ? "Granted — meetings record the computer's audio"
                : "Granted — recording the computer's audio is off under Advanced", button: nil)
        } else if state.recordSystemAudio {
            set(.systemAudio, .pending, "Meetings record the computer's audio (the other side of a call, a video). "
                + "Turn on Voice is Local under Screen & System Audio Recording, then quit and reopen Voice is Local. "
                + "Until then meetings record the microphone only.", button: "Open Settings")
        } else {
            set(.systemAudio, .pending, "Not needed — recording the computer's audio is off under Advanced",
                button: "Open Settings")
        }

        rows[.assets]?.title.stringValue = "Speech model: \(language)"
        let canInstall = !state.installingAssets && !state.busy && !state.dictationEnabled && !state.enabling
        if state.installingAssets || state.assets == "downloading" {
            set(.assets, .pending, "Downloading and installing…", button: "Install", enabled: false)
        } else {
            switch state.assets {
            case nil: set(.assets, .pending, "Checking…", button: "Install", enabled: false)
            case "installed": set(.assets, .done, "Installed", button: nil)
            case "supported": set(.assets, .pending, "Not installed — downloads Apple's model for \(language)",
                                  button: "Install", enabled: canInstall)
            case "unsupported": set(.assets, .problem, "\(language) speech recognition is not supported on this Mac", button: nil)
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

    /// Rebuilt only when the list changes, so a refresh never replaces the menu while the user has it open.
    private func updateLanguagePopup(_ state: SetupState) {
        var groups = state.localeGroups
        if !groups.joined().contains(state.locale) { groups.insert([state.locale], at: 0) }
        if groups != shownLocaleGroups {
            shownLocaleGroups = groups
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
        if languagePopup.selectedItem?.representedObject as? String != state.locale {
            languagePopup.selectItem(at: languagePopup.indexOfItem(withRepresentedObject: state.locale))
        }
        languagePopup.isEnabled = state.localeChangeable
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

    @objc private func languageChosen(_ sender: NSPopUpButton) {
        guard let locale = sender.selectedItem?.representedObject as? String else { return }
        onLanguageChange?(locale)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let action = SetupAction(rawValue: sender.tag) else { return }
        perform(action)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
