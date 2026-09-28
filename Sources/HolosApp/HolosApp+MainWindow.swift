import AppKit
import HolosCore
import HolosDesktop
import HolosMeeting

/// The main window (docs/design.md "Main window"): created on first use, it hosts History, Corrections, Meetings,
/// People, Reading (a placeholder), and Settings. The menu bar menu, the main menu (⌘0, ⌘1 … ⌘5, ⌘,), and "Setup…"
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
            return PlaceholderPane(title: "Reading", text: "Coming soon — reading articles and documents aloud "
                + "here. Until then, use `voiceislocal read` in Terminal.")
        case .settings:
            return SettingsPane(callbacks: SettingsPane.Callbacks(
                perform: { [weak self] action in self?.performSetup(action) },
                opacity: { [weak self] value in self?.changePreviewOpacity(value) },
                language: { [weak self] identifier in self?.changeLanguage(to: identifier) },
                shortcut: { [weak self] choice in self?.changeShortcut(to: choice) },
                retention: { [weak self] retention in self?.changeHistoryRetention(to: retention) }))
        }
    }

    /// A section came on screen (nil: the window closed).
    private func mainSectionChanged(_ section: MainSection?) {
        if section == .settings {
            startSettingsRefresh()
        } else {
            stopSettingsRefresh()
        }
        if section == .history { history.reload() }
        updateSettings()
    }

    // MARK: - Menu actions (status menu and main menu)

    /// ⌘1 … ⌘5 in the main menu.
    @objc func showMainSection(_ sender: NSMenuItem) {
        guard let section = MainSection(rawValue: sender.tag) else { return }
        showMainWindow(section)
    }

    /// "Open Voice is Local" (⌘0): the window on the section it last showed, or History.
    @objc func showMainWindowFromMenu(_ sender: Any?) {
        showMainWindow(mainWindow?.current ?? .history)
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
