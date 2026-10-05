import AppKit
import HolosCore
import HolosDesktop
import HolosMeeting

/// The main window (docs/design.md "Main window"): created on first use, it hosts History, Corrections, Meetings,
/// People, Reading, and Settings. The menu bar menu, the main menu (⌘0, ⌘1 … ⌘5, ⌘,), and "Setup…"
/// everywhere open it.
extension HolosAppDelegate {
    /// The window, made on first use.
    func mainWindowController() -> MainWindowController {
        if let mainWindow { return mainWindow }
        let window = MainWindowController { [weak self] section in
            self?.makeSection(section) ?? NSViewController()
        }
        window.onVisibilityChange = { [weak self] visible in
            self?.setDockPresence(visible, for: "main")
            if visible { self?.updateSettings() }
        }
        window.onSectionChange = { [weak self] section in self?.mainSectionChanged(section) }
        // Back from Terminal (`voiceislocal history clear --yes`) with History or Settings on screen: read it again.
        window.onBecomeKey = { [weak self] section in
            if section.map(Self.showsHistory) == true { self?.history.reload() }
        }
        mainWindow = window
        return window
    }

    func showMainWindow(_ section: MainSection) {
        mainWindowController().show(section)
        updateSettings()
    }

    private func makeSection(_ section: MainSection) -> NSViewController {
        switch section {
        case .history:
            return makeHistoryPane()
        case .corrections:
            return makeCorrectionsPane()
        case .meetings:
            guard let pane = makeMeetingsPane() else {
                return PlaceholderPane(title: "Meetings", text: "Meetings are not available: the voiceislocal tool "
                    + "could not be set up. Rebuild Voice is Local with scripts/build-app.sh.")
            }
            return pane
        case .people:
            PeopleLaunch.resumePendingForgetsOnce()
            return PeoplePane()
        case .reading:
            return ReadingPane(controller: readings)
        case .settings:
            return SettingsPane(callbacks: SettingsPane.Callbacks(
                perform: { [weak self] action in self?.performSetup(action) },
                opacity: { [weak self] value in self?.changePreviewOpacity(value) },
                language: { [weak self] identifier in self?.changeLanguage(to: identifier) },
                shortcut: { [weak self] choice in self?.changeShortcut(to: choice) },
                retention: { [weak self] retention in self?.changeHistoryRetention(to: retention) },
                appearance: { [weak self] choice in self?.changeAppearance(to: choice) }))
        }
    }

    /// Settings › General › "Open the Voice is Local window when it starts" (on by default).
    var openWindowAtLaunch: Bool {
        get {
            MainWindowLaunch.opensWindow(
                saved: UserDefaults.standard.object(forKey: MainWindowLaunch.openAtLaunchKey) as? Bool)
        }
        set { UserDefaults.standard.set(newValue, forKey: MainWindowLaunch.openAtLaunchKey) }
    }

    /// Settings › General › Appearance.
    var appearance: AppearanceChoice {
        get { AppearanceChoice(saved: UserDefaults.standard.string(forKey: AppearanceChoice.key)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppearanceChoice.key) }
    }

    /// Sets the appearance of the whole app, so every window follows it (the main window, the dictation preview,
    /// Review, the Setup Assistant, the meeting panels, alerts): nil follows macOS.
    func applyAppearance() {
        NSApplication.shared.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func changeAppearance(to choice: AppearanceChoice) {
        appearance = choice
        applyAppearance()
        updateSettings()
    }

    /// The section the window last showed, in this run or an earlier one; History when none was saved.
    private var lastMainSection: MainSection {
        if let current = mainWindow?.current { return current }
        return UserDefaults.standard.string(forKey: MainWindowLaunch.lastSectionKey)
            .flatMap(MainSection.init(storageName:)) ?? .history
    }

    /// A launch the Setup Assistant and Settings (dictation off) left alone: the main window opens when the setting
    /// is on, on Meetings while a meeting records (the app reattached to it), else on the section it last showed.
    /// A manual launch is the user asking for the app, so the window comes forward like any app's.
    func openMainWindowAtLaunch() {
        guard openWindowAtLaunch else { return }
        let name = MainWindowLaunch.section(
            lastUsed: UserDefaults.standard.string(forKey: MainWindowLaunch.lastSectionKey),
            known: Set(MainSection.allCases.map(\.storageName)),
            meetingRecording: meetingRecordingAtLaunch)
        showMainWindow(MainSection(storageName: name) ?? .history)
    }

    /// A recorder is starting, recording, or saving (the app reattached to it at launch): Meetings shows its progress.
    private var meetingRecordingAtLaunch: Bool {
        switch meeting.controller?.state {
        case .starting, .active, .finishing: return true
        case .idle, .failed, nil: return false
        }
    }

    /// A section came on screen (nil: the window closed).
    private func mainSectionChanged(_ section: MainSection?) {
        // Saved for the next launch, except Settings: it also opens on its own (a launch with dictation off, a refused
        // enable), and a launch opens where the user works.
        if let section, section != .settings {
            UserDefaults.standard.set(section.storageName, forKey: MainWindowLaunch.lastSectionKey)
        }
        if section == .settings {
            startSettingsRefresh()
        } else {
            stopSettingsRefresh()
        }
        if section.map(Self.showsHistory) == true { history.reload() }
        updateSettings()
    }

    /// The sections that show what the history keeps: History, and Settings' count and Clear History….
    private static func showsHistory(_ section: MainSection) -> Bool {
        section == .history || section == .settings
    }

    // MARK: - Menu actions (status menu and main menu)

    /// ⌘1 … ⌘5 in the main menu.
    @objc func showMainSection(_ sender: NSMenuItem) {
        guard let section = MainSection(rawValue: sender.tag) else { return }
        showMainWindow(section)
    }

    /// "Open Voice is Local" (⌘0), and a click on the Dock icon with the window closed: the window on the section it
    /// last showed (in this run or an earlier one), or History.
    @objc func showMainWindowFromMenu(_ sender: Any?) {
        showMainWindow(lastMainSection)
    }

    @objc func showSettingsFromMenu(_ sender: Any?) { showSetup() }

    @objc func showHistoryFromMenu(_ sender: Any?) { showMainWindow(.history) }

    /// ⌘F: the section's search field, while the main window is key.
    @objc func focusSearch(_ sender: Any?) {
        guard let mainWindow, mainWindow.isKey, mainWindow.focusSearch() else {
            NSSound.beep()
            return
        }
    }

    /// The status menu's window items: Open Voice is Local ⌘0, History, Meetings, Settings… ⌘,.
    func addWindowItems(to menu: NSMenu) {
        let open = item("Open Voice is Local", #selector(showMainWindowFromMenu(_:)))
        open.keyEquivalent = "0"
        open.keyEquivalentModifierMask = .command
        menu.addItem(open)
        menu.addItem(item("History", #selector(showHistoryFromMenu(_:))))
        menu.addItem(item("Meetings", #selector(showMeetings)))
        let settings = item("Settings…", #selector(showSettingsFromMenu(_:)))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
    }
}
