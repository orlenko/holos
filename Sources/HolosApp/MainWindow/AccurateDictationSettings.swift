import AppKit
import HolosDictation
import HolosDesktop
import HolosCore
import HolosMeeting

struct AccurateDictationSettings {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    var model: AccurateDictationModel {
        get { defaults.string(forKey: "accurateDictationModel").flatMap(AccurateDictationModel.init) ?? .whisper }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "accurateDictationModel") }
    }
}

/// Invariants:
/// 1. A status or install belongs to its model, even when the selection changes before completion.
/// 2. Only the Download button starts setup. Selecting a model only checks its files.
@MainActor
final class AccurateDictationControls {
    let settings: AccurateDictationSettings
    let model = NSPopUpButton()
    let status = NSTextField(labelWithString: "")
    let download = NSButton()
    private let runner: CommandRunner
    private var states: [AccurateDictationModel: State] = [:]
    private var changeable = true
    private var enabled = true

    private enum State { case checking, missing, installing, externalDownload, installed, checkFailed, downloadFailed }

    init(settings: AccurateDictationSettings = .init(),
         launcher: MaintenanceLauncher = MaintenanceLauncher(executable: ChildProcessLauncher.bundledExecutable)) {
        self.settings = settings
        runner = CommandRunner(launcher: launcher)
        model.addItems(withTitles: AccurateDictationModel.allCases.map(\.title))
        model.selectItem(withTitle: settings.model.title)
        model.setAccessibilityLabel("Accurate dictation model")
        model.target = self
        model.action = #selector(chooseModel)
        download.target = self
        download.action = #selector(downloadChosen)
        download.bezelStyle = .rounded
        status.font = .preferredFont(forTextStyle: .caption1)
    }

    func refresh(changeable: Bool, enabled: Bool) {
        self.changeable = changeable
        self.enabled = enabled
        model.isEnabled = changeable && enabled
        let choice = settings.model
        let state = states[choice]
        status.stringValue = switch state {
        case .installed: "Installed"
        case .missing: "Not installed"
        case .externalDownload: "Download in progress"
        case .installing: "Downloading and verifying…"
        case .checkFailed: "Could not check installation"
        case .downloadFailed: "Download or verification failed. Retry when connected."
        case .checking, nil: "Checking…"
        }
        status.isHidden = !enabled
        let canRecheck = state == .checkFailed || state == .externalDownload
        download.title = canRecheck ? "Check again" : "Download (\(choice == .whisper ? "1.6 GB" : "632 MB"))"
        download.isHidden = !enabled || (state != .missing && state != .downloadFailed && !canRecheck)
        download.isEnabled = changeable
        if enabled, state == nil { checkSelected() }
    }

    func checkSelected() {
        let choice = settings.model
        guard enabled, states[choice] != .installing, states[choice] != .checking else { return }
        states[choice] = .checking
        refresh(changeable: changeable, enabled: enabled)
        Task {
            let result = try? await runner.run(["setup", "--\(choice.rawValue)", "--status"],
                output: "json", errors: nil, maxOutputBytes: 4096, as: DeepModelStatus.self)
            if result?.code == 0, let outcome = result?.outcome {
                states[choice] = outcome == .installed ? .installed : (outcome == .downloading ? .externalDownload : .missing)
            } else {
                states[choice] = .checkFailed
            }
            refresh(changeable: changeable, enabled: enabled)
        }
    }

    @objc func downloadChosen() {
        let choice = settings.model
        if states[choice] == .checkFailed || states[choice] == .externalDownload { checkSelected(); return }
        guard enabled, changeable, states[choice] == .missing || states[choice] == .downloadFailed else { return }
        states[choice] = .installing
        refresh(changeable: changeable, enabled: enabled)
        Task {
            let result = try? await runner.run(["setup", "--\(choice.rawValue)"], output: "out", errors: nil,
                                               maxOutputBytes: 4096, decode: { _ in true })
            states[choice] = result?.code == 0 ? .installed : .downloadFailed
            refresh(changeable: changeable, enabled: enabled)
        }
    }

    @objc func chooseModel() {
        guard let choice = AccurateDictationModel.allCases.first(where: { $0.title == model.titleOfSelectedItem }) else { return }
        settings.model = choice
        checkSelected()
        refresh(changeable: changeable, enabled: enabled)
    }
}

extension SettingsPane {
    func addRecognitionRows(to grid: NSGridView) {
        for (popup, title) in [(shortcutPopup, "Live shortcut"), (accurateShortcutPopup, "Accurate shortcut")] {
            popup.target = self
            popup.action = #selector(shortcutChosen(_:))
            popup.menu?.autoenablesItems = false
            for choice in HotkeyChoice.allCases {
                let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
                item.representedObject = choice.rawValue
                popup.menu?.addItem(item)
            }
            popup.setAccessibilityLabel(title)
        }
        let keywords = ["hotkey", "key", "right option", "control option space", "push to talk"]
        addControlRow(.dictation, "keyboard", "Live shortcut", "Shows and inserts text while you speak.",
                      keywords: keywords, control: shortcutPopup, to: grid)
        addControlRow(.dictation, "waveform", "Accurate shortcut", "Recognizes after release. For the default chord, hold Right Command first.",
                      keywords: keywords + ["right command", "after release"], control: accurateShortcutPopup, to: grid)
        let controls = NSStackView(views: [recognition.model, recognition.status, recognition.download])
        controls.orientation = .vertical
        controls.alignment = .trailing
        addControlRow(.dictation, "cpu", "Accurate dictation model",
                      "Downloaded models recognize your recording on this Mac.",
                      keywords: ["local", "whisper", "parakeet", "download"], control: controls, focus: recognition.model, to: grid)
    }

    func updateShortcutRows(_ state: SetupState) {
        let shortcuts = state.shortcuts
        for (popup, choice, other) in [(shortcutPopup, shortcuts.live, shortcuts.accurate),
                                       (accurateShortcutPopup, shortcuts.accurate, shortcuts.live)] {
            popup.selectItem(withTitle: choice.title)
            popup.isEnabled = state.shortcutChangeable
            for item in popup.itemArray { item.isEnabled = other == .off || item.title != other.title }
        }
        recognition.refresh(changeable: state.shortcutChangeable, enabled: shortcuts.accurate != .off)
    }
}
