import AppKit
import HolosDictation
import HolosDesktop
import HolosCore
import HolosMeeting

/// The two choices are independent so switching to Live remembers the selected local model.
struct AccurateDictationSettings {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        get { defaults.bool(forKey: "dictationAfterRelease") }
        nonmutating set { defaults.set(newValue, forKey: "dictationAfterRelease") }
    }

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
    let mode = NSPopUpButton()
    let model = NSPopUpButton()
    let status = NSTextField(labelWithString: "")
    let download = NSButton()
    private let runner: CommandRunner
    private var states: [AccurateDictationModel: State] = [:]
    private var changeable = true
    var modeChanged: () -> Void = {}

    private enum State { case checking, missing, installing, externalDownload, installed, checkFailed, downloadFailed }

    init(settings: AccurateDictationSettings = .init(),
         launcher: MaintenanceLauncher = MaintenanceLauncher(executable: ChildProcessLauncher.bundledExecutable)) {
        self.settings = settings
        runner = CommandRunner(launcher: launcher)
        mode.addItems(withTitles: ["Live", "Accurate after release"])
        mode.selectItem(at: settings.enabled ? 1 : 0)
        mode.setAccessibilityLabel("Dictation mode")
        mode.target = self
        mode.action = #selector(chooseMode)
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

    func refresh(changeable: Bool) {
        self.changeable = changeable
        mode.isEnabled = changeable
        model.isEnabled = changeable && settings.enabled
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
        status.isHidden = !settings.enabled
        let canRecheck = state == .checkFailed || state == .externalDownload
        download.title = canRecheck ? "Check again" : "Download (\(choice == .whisper ? "1.6 GB" : "632 MB"))"
        download.isHidden = !settings.enabled || (state != .missing && state != .downloadFailed && !canRecheck)
        download.isEnabled = changeable
        if settings.enabled, state == nil { checkSelected() }
    }

    func checkSelected() {
        let choice = settings.model
        guard settings.enabled, states[choice] != .installing, states[choice] != .checking else { return }
        states[choice] = .checking
        refresh(changeable: changeable)
        Task {
            let result = try? await runner.run(["setup", "--\(choice.rawValue)", "--status"],
                output: "json", errors: nil, maxOutputBytes: 4096, as: DeepModelStatus.self)
            if result?.code == 0, let outcome = result?.outcome {
                states[choice] = outcome == .installed ? .installed : (outcome == .downloading ? .externalDownload : .missing)
            } else {
                states[choice] = .checkFailed
            }
            refresh(changeable: changeable)
        }
    }

    @objc func downloadChosen() {
        let choice = settings.model
        if states[choice] == .checkFailed || states[choice] == .externalDownload { checkSelected(); return }
        guard settings.enabled, changeable, states[choice] == .missing || states[choice] == .downloadFailed else { return }
        states[choice] = .installing
        refresh(changeable: changeable)
        Task {
            let result = try? await runner.run(["setup", "--\(choice.rawValue)"], output: "out", errors: nil,
                                               maxOutputBytes: 4096, decode: { _ in true })
            states[choice] = result?.code == 0 ? .installed : .downloadFailed
            refresh(changeable: changeable)
        }
    }

    @objc func chooseMode() {
        settings.enabled = mode.indexOfSelectedItem == 1
        if settings.enabled { checkSelected() }
        refresh(changeable: changeable)
        modeChanged()
    }

    @objc func chooseModel() {
        guard let choice = AccurateDictationModel.allCases.first(where: { $0.title == model.titleOfSelectedItem }) else { return }
        settings.model = choice
        checkSelected()
        refresh(changeable: changeable)
    }
}

extension SettingsPane {
    func addRecognitionRows(to grid: NSGridView, modeChanged: @escaping () -> Void) {
        recognition.modeChanged = modeChanged
        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChosen(_:))
        for (choice, title) in [(HotkeyChoice.rightOption, "Right Option"),
                                (.controlOptionSpace, "Control–Option–Space")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = choice.rawValue
            shortcutPopup.menu?.addItem(item)
        }
        shortcutPopup.setAccessibilityLabel("Hold-to-talk shortcut")
        addControlRow(.dictation, "keyboard", "Hold-to-talk shortcut", "Hold it, wait for Listening, speak, release",
                      keywords: ["hotkey", "key", "right option", "control option space", "push to talk"],
                      control: shortcutPopup, to: grid)

        addControlRow(.dictation, "waveform", "Dictation mode", "Accurate recognizes the recording after you release the shortcut.",
                      keywords: ["live", "accurate", "after release"], control: recognition.mode, to: grid)
        let controls = NSStackView(views: [recognition.model, recognition.status, recognition.download])
        controls.orientation = .vertical
        controls.alignment = .trailing
        addControlRow(.dictation, "cpu", "Accurate dictation model",
                      "Downloaded models recognize your recording on this Mac.",
                      keywords: ["local", "whisper", "parakeet", "download"], control: controls, focus: recognition.model, to: grid)
    }
}
