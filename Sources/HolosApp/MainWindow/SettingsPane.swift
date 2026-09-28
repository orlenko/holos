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
    /// History and privacy: how long dictations are kept, and how many are kept now.
    var historyRetention = HistoryRetention.standard
    /// Every dictation the file keeps (a newer build's too): what Clear History deletes.
    var historyCount = 0
    /// The history file could not be read: it may still keep dictations, so Clear History stays available.
    var historyUnreadable = false
}

enum SetupAction: Int, CaseIterable {
    case microphone, accessibility, inputMonitoring, assets, dictation, toggleFillers, togglePreview, speakerModels
    case systemAudio
    case toggleAIFix
    case toggleRecordSystemAudio
    /// Settings only: open People, clear the history, run the Setup Assistant.
    case people, clearHistory, setupAssistant
}

/// The main window's Settings section (it replaces the Setup window): cards for Permissions, Dictation, Meetings, and
/// History and privacy, and a way back to the Setup Assistant. It shows `SetupState`, which the app delegate refreshes
/// every second while the section is on screen (TCC has no change notification), and reports each change through its
/// callbacks.
@MainActor
final class SettingsPane: NSViewController, MainSectionContent {
    private enum Mark { case done, pending, problem }
    private struct Row {
        let icon: NSImageView
        let title: NSTextField
        let detail: NSTextField
        let button: NSButton
        let grid: NSGridView
    }

    struct Callbacks {
        var perform: (SetupAction) -> Void
        var opacity: (Double) -> Void
        var language: (String) -> Void
        var shortcut: (HotkeyChoice) -> Void
        var retention: (HistoryRetention) -> Void
    }

    private let callbacks: Callbacks
    private let fillerToggle = NSButton(checkboxWithTitle: "Remove filler words", target: nil, action: nil)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let retentionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var shownLocaleGroups: [[String]]?
    private let previewToggle = NSButton(checkboxWithTitle: "Show the dictation preview while dictating",
                                         target: nil, action: nil)
    private static let aiFixTitle = "Fix misheard words with Apple Intelligence (on-device)"
    private let aiFixToggle = NSButton(checkboxWithTitle: aiFixTitle, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.85, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    private let recordSystemAudioToggle = NSButton(
        checkboxWithTitle: "Record the computer's audio (system sound) in meetings", target: nil, action: nil)
    private let readingVoicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let readingSpeedSlider = NSSlider(value: ReadingSpeed.standard, minValue: ReadingSpeed.range.lowerBound,
                                              maxValue: ReadingSpeed.range.upperBound, target: nil, action: nil)
    private let readingSpeedLabel = NSTextField(labelWithString: "")
    private var readingFolderDetail: NSTextField?
    private var rows: [SetupAction: Row] = [:]
    private static let textWidth: CGFloat = 360

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
        super.init(nibName: nil, bundle: nil)
        view = makeContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let stack = NSStackView(views: [
            permissionsCard(), dictationCard(), meetingsCard(), readingCard(), historyCard(), assistantFooter(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        let fill = stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            fill,
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
        ])
        return scroll
    }

    private func permissionsCard() -> NSView {
        let grid = makeGrid()
        for (action, title) in [(SetupAction.microphone, "Microphone"), (.accessibility, "Accessibility"),
                                (.systemAudio, "System audio"), (.inputMonitoring, "Input Monitoring")] {
            addRow(action, title, to: grid)
        }
        setRowHidden(.inputMonitoring, true)  // until macOS refuses the hotkey tap (`update`)
        let note = Self.note("""
            This updates on its own while you change System Settings. After rebuilding Voice is Local, macOS can \
            keep an old entry that looks switched on but no longer matches the app: select Voice is Local in that \
            list, remove it with –, then click Open Settings here to add it again. An entry named Holos is this app \
            from before it was renamed; remove it the same way.
            """)
        return card("Permissions", [grid, note], widths: [grid, note])
    }

    private func dictationCard() -> NSView {
        let grid = makeGrid()
        addRow(.dictation, "Dictation", to: grid)

        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChosen(_:))
        for (choice, title) in [(HotkeyChoice.rightOption, "Right Option"),
                                (.controlOptionSpace, "Control–Option–Space")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = choice.rawValue
            shortcutPopup.menu?.addItem(item)
        }
        shortcutPopup.setAccessibilityLabel("Hold-to-talk shortcut")
        addControlRow("keyboard", "Hold-to-talk shortcut", "Hold it, wait for Listening, speak, release",
                      control: shortcutPopup, to: grid)

        languagePopup.target = self
        languagePopup.action = #selector(languageChosen(_:))
        languagePopup.setAccessibilityLabel("Dictation language")
        addControlRow("globe", "Dictation language", "Used from the next dictation", control: languagePopup, to: grid)
        addRow(.assets, "Speech model", to: grid)

        for (toggle, action) in [(fillerToggle, SetupAction.toggleFillers), (aiFixToggle, .toggleAIFix),
                                 (previewToggle, .togglePreview)] {
            toggle.target = self
            toggle.action = #selector(buttonPressed(_:))
            toggle.tag = action.rawValue
        }
        previewToggle.toolTip = "When off, text just streams into the field. Problems that need you (text that could not be written, a failed dictation) are always shown."
        aiFixToggle.toolTip = "Each phrase is checked by Apple's on-device model before it is typed, which adds about half a second. Only small fixes are kept; History and Copy Original have the text as heard."

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.isContinuous = true
        opacitySlider.setAccessibilityLabel("Dictation preview opacity")
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        opacityValue.textColor = .secondaryLabelColor
        let opacityRow = NSStackView(views: [NSTextField(labelWithString: "Preview opacity"), opacitySlider,
                                             opacityValue])
        opacityRow.spacing = 10
        opacityRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        return card("Dictation", [grid, fillerToggle, aiFixToggle, previewToggle, opacityRow], widths: [grid])
    }

    private func meetingsCard() -> NSView {
        recordSystemAudioToggle.target = self
        recordSystemAudioToggle.action = #selector(buttonPressed(_:))
        recordSystemAudioToggle.tag = SetupAction.toggleRecordSystemAudio.rawValue
        let detail = Self.note("""
            On: meetings record your microphone and everything the Mac plays, and speakers are labelled on both. \
            Off: meetings record the microphone only.
            """)
        let grid = makeGrid()
        addRow(.speakerModels, "Speaker labels", to: grid)
        addRow(.people, "Remember voices", to: grid)
        set(.people, .pending, "Whether Voice is Local remembers the voices of people you name is set in People, "
            + "with each person's samples.", button: "Open People")
        rows[.people]?.icon.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        rows[.people]?.icon.contentTintColor = .secondaryLabelColor
        return card("Meetings", [recordSystemAudioToggle, detail, grid], widths: [detail, grid])
    }

    /// Settings › Reading: what new readings in the Reading section start with, and where their files go.
    private func readingCard() -> NSView {
        let grid = makeGrid()
        readingVoicePopup.target = self
        readingVoicePopup.action = #selector(readingVoiceChosen(_:))
        readingVoicePopup.setAccessibilityLabel("Default reading voice")
        addControlRow("person.wave.2", "Voice", "Premium voices sound best; add them in System Settings › "
                      + "Accessibility › Spoken Content", control: readingVoicePopup, to: grid)

        readingSpeedSlider.numberOfTickMarks = 7
        readingSpeedSlider.allowsTickMarkValuesOnly = true
        readingSpeedSlider.target = self
        readingSpeedSlider.action = #selector(readingSpeedChanged(_:))
        readingSpeedSlider.setAccessibilityLabel("Default reading speed")
        readingSpeedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        readingSpeedLabel.textColor = .secondaryLabelColor
        let speed = NSStackView(views: [readingSpeedSlider, readingSpeedLabel])
        speed.spacing = 8
        addControlRow("gauge.with.needle", "Speed", "0.8× to 1.4× of the voice's normal pace", control: speed, to: grid)

        let (text, _, detail) = Self.labels("Save audio files in")
        readingFolderDetail = detail
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseReadingFolder))
        choose.bezelStyle = .push
        choose.setAccessibilityLabel("Choose the folder audio files are saved in")
        grid.addRow(with: [icon, text, choose])
        finishRow(in: grid)

        let note = Self.note("""
            Readings are made on this Mac: nothing is uploaded, and the only thing fetched is the page you paste. \
            While a reading is made, its parts are kept in Application Support so it can continue after a stop.
            """)
        refreshReadingCard()
        return card("Reading", [grid, note], widths: [grid, note])
    }

    /// Shows Settings › Reading as saved (and the voices installed now).
    private func refreshReadingCard() {
        ReadingVoicePopup.fill(readingVoicePopup, selecting: ReadingPreferences.voice)
        readingSpeedSlider.doubleValue = ReadingPreferences.speed
        readingSpeedLabel.stringValue = ReadingSpeed.label(readingSpeedSlider.doubleValue)
        readingFolderDetail?.stringValue = ReadingPreferences.folderText
    }

    func sectionDidShow() {
        refreshReadingCard()
    }

    @objc private func readingVoiceChosen(_ sender: NSPopUpButton) {
        ReadingPreferences.voice = sender.selectedItem?.representedObject as? String
    }

    @objc private func readingSpeedChanged(_ sender: NSSlider) {
        readingSpeedLabel.stringValue = ReadingSpeed.label(sender.doubleValue)
        ReadingPreferences.speed = sender.doubleValue
    }

    @objc private func chooseReadingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ReadingPreferences.folder
        panel.message = "Choose the folder new readings' audio files are saved in."
        panel.prompt = "Choose"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            MainActor.assumeIsolated {
                ReadingPreferences.folder = folder
                self?.refreshReadingCard()
            }
        }
    }

    private func historyCard() -> NSView {
        let grid = makeGrid()
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChosen(_:))
        for retention in HistoryRetention.allCases {
            let item = NSMenuItem(title: retention.title, action: nil, keyEquivalent: "")
            item.representedObject = retention.rawValue
            retentionPopup.menu?.addItem(item)
        }
        retentionPopup.setAccessibilityLabel("Keep dictations")
        addControlRow("clock.arrow.circlepath", "Keep dictations", "Off stops recording new dictations",
                      control: retentionPopup, to: grid)
        addRow(.clearHistory, "History", to: grid)
        let note = Self.note("""
            History keeps each dictation's text, the text as heard, the app, and the language, only on this Mac. \
            Nothing is copied to the clipboard unless you choose Copy.
            """)
        return card("History and privacy", [grid, note], widths: [grid, note])
    }

    private func assistantFooter() -> NSView {
        let button = NSButton(title: "Run Setup Assistant…", target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .push
        button.tag = SetupAction.setupAssistant.rawValue
        let text = Self.note("Walks through permissions, the speech model, and meetings again, step by step.")
        let stack = NSStackView(views: [button, text])
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }

    /// A card: a bold title over a rounded box holding `views`; `widths` stretch to the box.
    private func card(_ title: String, _ views: [NSView], widths: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.setAccessibilityRole(.staticText)
        let inner = NSStackView(views: views)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        let box = CardView()
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
        for view in widths { view.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true }
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(title)
        let section = NSStackView(views: [heading, box])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        box.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeGrid() -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        return grid
    }

    private func finishRow(in grid: NSGridView) {
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 2).xPlacement = .trailing
        grid.row(at: grid.numberOfRows - 1).yPlacement = .center
    }

    /// A status row: icon, bold title over a detail line, and a button (`set`).
    private func addRow(_ action: SetupAction, _ title: String, to grid: NSGridView) {
        let icon = NSImageView()
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let (text, titleLabel, detail) = Self.labels(title)
        let button = NSButton(title: "", target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .push
        button.tag = action.rawValue
        grid.addRow(with: [icon, text, button])
        finishRow(in: grid)
        rows[action] = Row(icon: icon, title: titleLabel, detail: detail, button: button, grid: grid)
    }

    /// A row whose control is a pop-up menu.
    private func addControlRow(_ symbol: String, _ title: String, _ detailText: String, control: NSView,
                               to grid: NSGridView) {
        let (text, _, detail) = Self.labels(title)
        detail.stringValue = detailText
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        control.widthAnchor.constraint(equalToConstant: 200).isActive = true
        grid.addRow(with: [icon, text, control])
        finishRow(in: grid)
    }

    /// A row's bold title over its detail line.
    private static func labels(_ title: String) -> (NSStackView, title: NSTextField, detail: NSTextField) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = textWidth
        let text = NSStackView(views: [titleLabel, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return (text, titleLabel, detail)
    }

    private static func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 560
        return note
    }

    // MARK: - State

    func update(_ state: SetupState) {
        let language = DictationLanguage.name(of: state.locale)
        updateLanguagePopup(state)
        select(shortcutPopup, state.shortcut.rawValue)
        shortcutPopup.isEnabled = state.shortcutChangeable
        select(retentionPopup, state.historyRetention.rawValue)
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
        // Accessibility is what the hotkey tap needs; this row appears only after macOS refused the tap anyway.
        setRowHidden(.inputMonitoring, !state.inputMonitoringNeeded)
        set(.inputMonitoring, state.inputMonitoring ? .done : .problem,
            state.inputMonitoring ? "Granted — quit and reopen Voice is Local if the shortcut still does not work"
                                  : "macOS refused the hold-to-talk shortcut with Accessibility on. Turn on Voice is "
                                    + "Local under Input Monitoring, then quit and reopen Voice is Local.",
            button: "Open Settings")
        recordSystemAudioToggle.state = state.recordSystemAudio ? .on : .off
        // Never marked as a problem: without it meetings record the microphone alone.
        if state.systemAudio {
            set(.systemAudio, .done, state.recordSystemAudio
                ? "Granted — meetings record the computer's audio"
                : "Granted — recording the computer's audio is off under Meetings", button: nil)
        } else if state.recordSystemAudio {
            set(.systemAudio, .pending, "Meetings record the computer's audio (the other side of a call, a video). "
                + "Turn on Voice is Local under Screen & System Audio Recording, then quit and reopen Voice is Local. "
                + "Until then meetings record the microphone only.", button: "Open Settings")
        } else {
            set(.systemAudio, .pending, "Not needed — recording the computer's audio is off under Meetings",
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
                button: "Turn On", enabled: false)
        } else if state.enabling {
            set(.dictation, .pending, "Starting…", button: "Turn On", enabled: false)
        } else if state.dictationEnabled {
            set(.dictation, .done, "On — hold \(state.shortcutTitle), wait for Listening, speak, release",
                button: "Turn Off", enabled: !state.busy)
        } else {
            set(.dictation, .pending, "Off — turn it on once the permissions and speech model are ready",
                button: "Turn On", enabled: !state.installingAssets)
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

        let count = state.historyCount
        let kept = state.historyUnreadable ? "History could not be read; it may still keep dictations on this Mac"
            : count == 0 ? "No dictations kept"
            : "\(count) \(count == 1 ? "dictation" : "dictations") kept on this Mac"
        let recording = state.historyRetention.records ? "" : " — History is off; new dictations are not kept"
        set(.clearHistory, state.historyUnreadable ? .problem : count == 0 ? .pending : .done, kept + recording,
            button: "Clear History…", enabled: count > 0 || state.historyUnreadable)
        rows[.clearHistory]?.icon.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
        rows[.clearHistory]?.icon.contentTintColor = .secondaryLabelColor
    }

    private func select(_ popup: NSPopUpButton, _ value: String) {
        guard popup.selectedItem?.representedObject as? String != value else { return }
        popup.selectItem(at: popup.indexOfItem(withRepresentedObject: value))
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
        select(languagePopup, state.locale)
        languagePopup.isEnabled = state.localeChangeable
    }

    private func setRowHidden(_ action: SetupAction, _ hidden: Bool) {
        guard let row = rows[action], let gridRow = row.grid.cell(for: row.icon)?.row, gridRow.isHidden != hidden else {
            return
        }
        gridRow.isHidden = hidden
    }

    private func set(_ action: SetupAction, _ mark: Mark, _ detail: String, button title: String?, enabled: Bool = true) {
        guard let row = rows[action] else { return }
        let (symbol, color): (String, NSColor) = switch mark {
        case .done: ("checkmark.circle.fill", .systemGreen)
        case .pending: ("circle.dashed", .secondaryLabelColor)
        case .problem: ("exclamationmark.circle.fill", .systemOrange)
        }
        let description: String = switch mark {
        case .done: "Done"
        case .pending: "Not done yet"
        case .problem: "Needs attention"
        }
        row.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        row.icon.contentTintColor = color
        row.detail.stringValue = detail
        // A view shown inside a hidden grid row is left unplaced and draws over another row.
        let rowHidden = row.grid.cell(for: row.icon)?.row?.isHidden ?? false
        row.button.isHidden = title == nil || rowHidden
        row.button.title = title ?? ""
        row.button.isEnabled = enabled
        row.button.setAccessibilityLabel(title.map { "\($0) — \(row.title.stringValue)" })
    }

    // MARK: - Actions

    @objc private func opacityChanged(_ sender: NSSlider) {
        opacityValue.stringValue = "\(Int((sender.doubleValue * 100).rounded())) %"
        callbacks.opacity(sender.doubleValue)
    }

    @objc private func languageChosen(_ sender: NSPopUpButton) {
        guard let locale = sender.selectedItem?.representedObject as? String else { return }
        callbacks.language(locale)
    }

    @objc private func shortcutChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let choice = HotkeyChoice(rawValue: raw) else {
            return
        }
        callbacks.shortcut(choice)
    }

    @objc private func retentionChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let retention = HistoryRetention(rawValue: raw) else { return }
        callbacks.retention(retention)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let action = SetupAction(rawValue: sender.tag) else { return }
        callbacks.perform(action)
    }
}

/// A rounded box in the control background colour, with a hairline border; follows light and dark mode.
@MainActor
final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
