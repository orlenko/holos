import AppKit
import HolosCore

/// What the Setup Assistant window shows.
struct SetupAssistantViewState {
    var flow: SetupAssistantFlow
    var facts: SetupAssistantFacts
    /// The one-page check after the assistant reopened Voice is Local.
    var verify: Bool
    /// The dictation language's locale identifier and its display name, and the ones to offer.
    var locale: String
    var language: String
    var localeGroups: [[String]]
    var localeChangeable: Bool
    var shortcutTitle: String
    /// The speaker models' install progress, or the last install's error.
    var speakerModelsDetail: String?
}

enum SetupAssistantAction: Int {
    case start, skip, next, continueWithout, back
    case microphone, accessibility, systemAudio, inputMonitoring, toggleMeetings
    /// Done or Reopen Voice is Local on the Finish page.
    case finish
    /// The check after reopening: open the full Setup window, or close.
    case openSetup, done
}

/// The first-launch Setup Assistant: one page at a time, in `SetupAssistantFlow`'s order. A regular titled window
/// like `SetupWindow`, so it stays visible while the user works in System Settings; it refreshes every second.
@MainActor
final class SetupAssistantWindow: NSObject, NSWindowDelegate {
    private enum Mark: Equatable { case done, pending, problem, off }

    /// Everything a page shows; the window is rebuilt only when this changes, so a refresh never disturbs a click.
    private struct Page: Equatable {
        struct Row: Equatable {
            var mark: Mark
            var title: String
            var detail: String
            var button: String? = nil
            var action: SetupAssistantAction? = nil
        }

        struct Button: Equatable {
            var title: String
            var action: SetupAssistantAction
            var enabled = true
        }

        var title: String
        var body: String
        var showsLanguage = false
        var rows: [Row] = []
        /// "Also set up meetings", when shown.
        var meetings: Bool?
        var note: String?
        /// Background downloads, which continue from page to page.
        var footer: String?
        var leading: [Button] = []
        /// The last one is the default button.
        var trailing: [Button] = []
    }

    private let window: NSWindow
    private let perform: (SetupAssistantAction) -> Void
    private let onClose: () -> Void
    private let onLanguageChange: (String) -> Void
    private let stack = NSStackView()
    /// Kept across pages, so a refresh never replaces the menu while it is open.
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var shownLocaleGroups: [[String]]?
    private var shown: Page?
    private var positioned = false

    var isVisible: Bool { window.isVisible }

    init(perform: @escaping (SetupAssistantAction) -> Void, onClose: @escaping () -> Void,
         onLanguageChange: @escaping (String) -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        self.perform = perform
        self.onClose = onClose
        self.onLanguageChange = onLanguageChange
        super.init()
        window.title = "Voice is Local Setup Assistant"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self

        languagePopup.target = self
        languagePopup.action = #selector(languageChosen(_:))
        languagePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 504),
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

    func close() { window.close() }

    func update(_ state: SetupAssistantViewState) {
        updateLanguagePopup(state)
        let page = Self.page(state)
        guard page != shown else { return }
        shown = page
        render(page)
    }

    // MARK: - Pages

    private static func page(_ state: SetupAssistantViewState) -> Page {
        if state.verify { return checklistPage(state) }
        let flow = state.flow
        let facts = state.facts
        switch flow.step {
        case .welcome:
            return Page(
                title: "Set up Voice is Local",
                body: """
                    Voice is Local types what you say: hold a key, speak, release.
                    This assistant picks your language, asks for the Microphone and Accessibility, and downloads \
                    Apple's speech model.
                    Permissions that need Voice is Local to reopen come last, so it reopens only once.
                    """,
                trailing: [Page.Button(title: "Skip — Show All Settings", action: .skip),
                           Page.Button(title: "Start", action: .start)])

        case .basics:
            var page = Page(
                title: "Language and microphone",
                body: "Choose the language you dictate in. Its speech model downloads in the background when you "
                    + "click Next.",
                showsLanguage: true,
                meetings: flow.setUpMeetings)
            page.rows = [microphoneRow(facts), speechModelRow(facts, language: state.language)]
            page.footer = downloads(state)
            if flow.offersContinueWithout(facts) {
                page.note = "Continue Without skips the microphone: dictation then cannot hear you."
            }
            page.leading = [Page.Button(title: "Back", action: .back)]
            page.trailing = continueButtons(flow, facts)
            return page

        case .accessibility:
            var page = Page(
                title: "Allow Accessibility",
                body: "Voice is Local uses Accessibility to notice the hold-to-talk key and to type your words into "
                    + "other apps. It works as soon as you switch it on; nothing needs to reopen.")
            page.rows = [facts.accessibility
                ? Page.Row(mark: .done, title: "Accessibility", detail: "Allowed")
                : Page.Row(mark: .problem, title: "Accessibility",
                           detail: "Not allowed yet. This page checks every second.",
                           button: "Open Settings", action: .accessibility)]
            var note = """
                Click Open Settings. In Accessibility, switch on Voice is Local. If Voice is Local (or Holos, its old \
                name) is already listed and switched on but this step stays unchecked, select it, remove it with –, \
                and click Open Settings again to add it back.
                """
            if flow.offersContinueWithout(facts) {
                note += "\n\nContinue Without skips it: dictation then cannot notice the key or type text."
            }
            page.note = note
            page.footer = downloads(state)
            page.leading = [Page.Button(title: "Back", action: .back)]
            page.trailing = continueButtons(flow, facts)
            return page

        case .reopen:
            var page = Page(
                title: "Permissions that need a reopen",
                body: "These take effect only after Voice is Local quits and opens again. Turn them on now; Voice is "
                    + "Local reopens once, at the end of this setup.")
            if flow.offersSystemAudio(facts) {
                page.rows.append(facts.systemAudio
                    ? Page.Row(mark: .done, title: "Screen & System Audio Recording", detail: "Allowed")
                    : flow.requestedSystemAudio
                    ? Page.Row(mark: .pending, title: "Screen & System Audio Recording",
                               detail: "Takes effect when Voice is Local reopens at the end.",
                               button: "Open Settings", action: .systemAudio)
                    : Page.Row(mark: .pending, title: "Screen & System Audio Recording",
                               detail: "Meetings record the computer's audio (the other side of a call, a video). "
                                   + "Without it, meetings record the microphone only. Optional.",
                               button: "Open Settings", action: .systemAudio))
            }
            if flow.offersInputMonitoring(facts) {
                page.rows.append(facts.inputMonitoring
                    ? Page.Row(mark: .done, title: "Input Monitoring", detail: "Allowed")
                    : flow.requestedInputMonitoring
                    ? Page.Row(mark: .pending, title: "Input Monitoring",
                               detail: "Takes effect when Voice is Local reopens at the end.",
                               button: "Open Settings", action: .inputMonitoring)
                    : Page.Row(mark: .problem, title: "Input Monitoring",
                               detail: "macOS refused the hold-to-talk key although Accessibility is on. On this Mac "
                                   + "the key also needs Input Monitoring.",
                               button: "Open Settings", action: .inputMonitoring))
            }
            page.note = """
                Click Open Settings and switch on Voice is Local. macOS will offer to Quit & Reopen — choose Later. \
                Voice is Local reopens once, at the end of this setup.
                """
            page.footer = downloads(state)
            page.leading = [Page.Button(title: "Back", action: .back)]
            page.trailing = [Page.Button(title: flow.continueSkips(facts) ? "Skip" : "Next", action: .next)]
            return page

        case .finish:
            return checklistPage(state)
        }
    }

    /// Finish, or the check after reopening: each item with its real state.
    private static func checklistPage(_ state: SetupAssistantViewState) -> Page {
        let flow = state.flow
        let items = flow.checklist(state.facts, verify: state.verify, language: state.language,
                                   shortcut: state.shortcutTitle)
        var page: Page
        if state.verify {
            page = Page(title: "Setup check",
                        body: "Voice is Local reopened. This is where setup stands now.")
            page.trailing = [Page.Button(title: "Open Full Setup", action: .openSetup),
                             Page.Button(title: "Done", action: .done)]
        } else if flow.reopenNeeded {
            page = Page(title: "Finish setup",
                        body: "Click Reopen Voice is Local to finish. It quits and opens again, once, so the new "
                            + "permissions take effect. Dictation turns on as soon as everything it needs is ready.")
            page.leading = [Page.Button(title: "Back", action: .back)]
            page.trailing = [Page.Button(title: "Reopen Voice is Local", action: .finish)]
        } else {
            page = Page(title: "Finish setup",
                        body: "Click Done to finish. Dictation turns on as soon as everything it needs is ready.")
            page.leading = [Page.Button(title: "Back", action: .back)]
            page.trailing = [Page.Button(title: "Done", action: .finish)]
        }
        page.rows = items.map { item in
            let mark: Mark = switch item.state {
            case .done: .done
            case .waiting: .pending
            case .missing: .problem
            case .off: .off
            }
            return Page.Row(mark: mark, title: title(of: item.kind), detail: item.detail)
        }
        if items.contains(where: { $0.state == .missing }) {
            page.note = "Everything here can also be set up later with Setup… in the Voice is Local menu."
        }
        return page
    }

    private static func title(of kind: SetupAssistantItem.Kind) -> String {
        switch kind {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .speechModel: "Speech model"
        case .speakerModels: "Speaker labels"
        case .systemAudio: "System audio"
        case .dictation: "Dictation"
        }
    }

    private static func microphoneRow(_ facts: SetupAssistantFacts) -> Page.Row {
        switch facts.microphone {
        case "authorized":
            Page.Row(mark: .done, title: "Microphone", detail: "Allowed")
        case "notDetermined":
            Page.Row(mark: .pending, title: "Microphone",
                     detail: "Click Allow Microphone, then Allow in the message macOS shows.",
                     button: "Allow Microphone", action: .microphone)
        default:
            Page.Row(mark: .problem, title: "Microphone",
                     detail: "Microphone access is off. Click Open Settings and switch on Voice is Local under "
                         + "Microphone. This page updates on its own.",
                     button: "Open Settings", action: .microphone)
        }
    }

    private static func speechModelRow(_ facts: SetupAssistantFacts, language: String) -> Page.Row {
        let title = "Speech model: \(language)"
        if facts.speechModelDownloading {
            return Page.Row(mark: .pending, title: title, detail: "Downloading…")
        }
        return switch facts.speechModel {
        case "installed": Page.Row(mark: .done, title: title, detail: "Installed")
        case nil: Page.Row(mark: .pending, title: title, detail: "Checking…")
        case "unsupported": Page.Row(mark: .problem, title: title,
                                     detail: "Not supported on this Mac; choose another language")
        default: Page.Row(mark: .pending, title: title, detail: "Downloads Apple's model when you click Next")
        }
    }

    private static func continueButtons(_ flow: SetupAssistantFlow, _ facts: SetupAssistantFacts) -> [Page.Button] {
        var buttons: [Page.Button] = []
        if flow.offersContinueWithout(facts) {
            buttons.append(Page.Button(title: "Continue Without", action: .continueWithout))
        }
        buttons.append(Page.Button(title: "Next", action: .next, enabled: flow.canContinue(facts)))
        return buttons
    }

    /// The downloads started when Basics was left; they go on while the other pages are open.
    private static func downloads(_ state: SetupAssistantViewState) -> String? {
        guard state.flow.startedInstalls else { return nil }
        var lines: [String] = []
        let facts = state.facts
        if facts.speechModelDownloading {
            lines.append("Speech model (\(state.language)): downloading…")
        } else if facts.speechModel == "installed" {
            lines.append("Speech model (\(state.language)): installed")
        }
        if facts.speakerModels == "installing" {
            lines.append("Speaker labels: \(state.speakerModelsDetail ?? "downloading…")")
        } else if facts.speakerModels == "verified", state.flow.setUpMeetings {
            lines.append("Speaker labels: installed")
        } else if state.flow.setUpMeetings, let error = state.speakerModelsDetail {
            lines.append("Speaker labels: \(error)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Views

    private func render(_ page: Page) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let title = NSTextField(labelWithString: page.title)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(wrapping(page.body, size: 13, color: .labelColor))

        if page.showsLanguage {
            let label = NSTextField(labelWithString: "Dictation language")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            let row = NSStackView(views: [label, languagePopup])
            row.spacing = 12
            stack.addArrangedSubview(row)
        }
        if !page.rows.isEmpty { stack.addArrangedSubview(grid(page.rows)) }
        if let meetings = page.meetings {
            let toggle = NSButton(checkboxWithTitle: "Also set up meetings (speaker labels, downloads models)",
                                  target: self, action: #selector(buttonPressed(_:)))
            toggle.tag = SetupAssistantAction.toggleMeetings.rawValue
            toggle.state = meetings ? .on : .off
            stack.addArrangedSubview(toggle)
        }
        if let note = page.note { stack.addArrangedSubview(wrapping(note, size: 12, color: .secondaryLabelColor)) }
        if let footer = page.footer {
            stack.addArrangedSubview(wrapping(footer, size: 11, color: .secondaryLabelColor))
        }
        stack.addArrangedSubview(buttonBar(page))
        fitKeepingTopEdge()
    }

    private func wrapping(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.preferredMaxLayoutWidth = 504
        return label
    }

    private func grid(_ rows: [Page.Row]) -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        for row in rows {
            let (symbol, color): (String, NSColor) = switch row.mark {
            case .done: ("checkmark.circle.fill", .systemGreen)
            case .pending: ("circle.dashed", .secondaryLabelColor)
            case .problem: ("exclamationmark.circle.fill", .systemOrange)
            case .off: ("minus.circle", .tertiaryLabelColor)
            }
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            icon.contentTintColor = color
            let title = NSTextField(labelWithString: row.title)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: row.detail)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 330
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.widthAnchor.constraint(equalToConstant: 330).isActive = true
            var cells: [NSView] = [icon, text]
            if let button = row.button, let action = row.action {
                let control = NSButton(title: button, target: self, action: #selector(buttonPressed(_:)))
                control.bezelStyle = .push
                control.tag = action.rawValue
                cells.append(control)
            } else {
                cells.append(NSGridCell.emptyContentView)
            }
            grid.addRow(with: cells)
        }
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 2).xPlacement = .trailing
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }
        grid.widthAnchor.constraint(equalToConstant: 504).isActive = true
        return grid
    }

    private func buttonBar(_ page: Page) -> NSView {
        func make(_ spec: Page.Button) -> NSButton {
            let button = NSButton(title: spec.title, target: self, action: #selector(buttonPressed(_:)))
            button.bezelStyle = .push
            button.tag = spec.action.rawValue
            button.isEnabled = spec.enabled
            return button
        }
        let trailing = page.trailing.map(make)
        trailing.last?.keyEquivalent = "\r"
        let bar = NSStackView()
        bar.spacing = 10
        bar.setViews(page.leading.map(make), in: .leading)
        bar.setViews(trailing, in: .trailing)
        bar.widthAnchor.constraint(equalToConstant: 504).isActive = true
        return bar
    }

    /// Resizes the window to its content, keeping the top edge where it is (before the first `show`, only resizes).
    private func fitKeepingTopEdge() {
        guard let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        var frame = window.frame
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentView.fittingSize)).size
        if positioned { frame.origin.y += frame.height - size.height }
        frame.size = size
        window.setFrame(frame, display: true, animate: false)
    }

    /// Rebuilt only when the list changes, so a refresh never replaces the menu while the user has it open.
    private func updateLanguagePopup(_ state: SetupAssistantViewState) {
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

    @objc private func languageChosen(_ sender: NSPopUpButton) {
        guard let locale = sender.selectedItem?.representedObject as? String else { return }
        onLanguageChange(locale)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let action = SetupAssistantAction(rawValue: sender.tag) else { return }
        perform(action)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
