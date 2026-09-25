import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage

/// The People window (docs/meeting-design.md §5.9): the people Holos knows by name and their opt-in voice samples,
/// with "Remember voices", per-person suggestions, rename, merge, and the forget actions. People without samples are
/// listed whatever the setting. Every store read and write runs off the main actor through `VoiceProfileService`;
/// the window shows names and counts, never a voiceprint.
@MainActor
final class PeopleWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = PeopleWindowController()

    /// Called with true when the window opens and false when it closes (the app's Dock presence).
    var onVisibilityChange: ((Bool) -> Void)?

    private enum Column: String {
        case person, summary, meeting, date, condition, speech, forget
    }

    private let store: SpeakerProfileStore
    private let sessionsRoot: URL
    private let window: NSWindow
    private let rememberBox = NSButton(checkboxWithTitle: "Remember voices of people I name", target: nil, action: nil)
    private let peopleTable = NSTableView()
    private let samplesTable = NSTableView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    private let suggestBox = NSButton(checkboxWithTitle: "Suggest in new meetings", target: nil, action: nil)
    private let mergePopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let forgetPersonButton = NSButton(title: "Forget…", target: nil, action: nil)
    private let forgetAllButton = NSButton(title: "Forget All Voices…", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var database = SpeakerProfileDatabase()
    private var people: [SpeakerProfile] = []
    private var busy = false
    private var positioned = false
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(store: SpeakerProfileStore = SpeakerProfileStore(), sessionsRoot: URL = HolosPaths.sessions) {
        self.store = store
        self.sessionsRoot = sessionsRoot
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.title = "People"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 400)
        window.delegate = self
        window.contentView = makeContent()
        updateControls()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        if !positioned {
            window.center()
            positioned = true
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
        refresh()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) { onVisibilityChange?(false) }

    // MARK: - Layout

    private func makeContent() -> NSView {
        rememberBox.target = self
        rememberBox.action = #selector(toggleRemember)
        let explanation = NSTextField(wrappingLabelWithString:
            "Only remember people who agreed to it. Voiceprints are biometric data; they stay on this Mac and are "
                + "not included in Time Machine backups.")
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)

        configure(peopleTable, columns: [(.person, "People", 150), (.summary, "", 90)])
        peopleTable.allowsMultipleSelection = false
        let peopleScroll = scroll(peopleTable)

        nameLabel.font = .boldSystemFont(ofSize: 15)
        nameLabel.lineBreakMode = .byTruncatingTail
        renameButton.target = self
        renameButton.action = #selector(renamePerson)
        renameButton.bezelStyle = .push
        let header = NSStackView(views: [nameLabel, NSView(), renameButton])
        header.distribution = .fill
        suggestBox.target = self
        suggestBox.action = #selector(toggleSuggestions)

        configure(samplesTable, columns: [(.meeting, "Samples", 150), (.date, "", 90), (.condition, "", 45),
                                          (.speech, "", 70), (.forget, "", 70)])
        samplesTable.selectionHighlightStyle = .none
        let samplesScroll = scroll(samplesTable)

        mergePopUp.target = self
        mergePopUp.action = #selector(mergePerson(_:))
        forgetPersonButton.target = self
        forgetPersonButton.action = #selector(forgetPerson)
        forgetPersonButton.bezelStyle = .push
        let actions = NSStackView(views: [mergePopUp, NSView(), forgetPersonButton])
        actions.distribution = .fill

        let detail = NSStackView(views: [header, suggestBox, samplesScroll, actions])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 8
        for view in [header, samplesScroll, actions] {
            view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }

        let split = NSStackView(views: [peopleScroll, detail])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 12
        peopleScroll.widthAnchor.constraint(equalToConstant: 250).isActive = true
        peopleScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        detail.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true

        let footerText = NSTextField(wrappingLabelWithString:
            "Deleting a meeting keeps its voice samples unless you choose to forget them.")
        footerText.textColor = .secondaryLabelColor
        footerText.font = .systemFont(ofSize: 12)
        forgetAllButton.target = self
        forgetAllButton.action = #selector(forgetAllVoices)
        forgetAllButton.bezelStyle = .push
        let footer = NSStackView(views: [footerText, forgetAllButton])
        footer.alignment = .centerY
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [rememberBox, explanation, split, footer, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return content
    }

    private func configure(_ table: NSTableView, columns: [(Column, String, CGFloat)]) {
        for (column, title, width) in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = title
            tableColumn.width = width
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
    }

    private func scroll(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    // MARK: - Data

    /// Reloads the store off the main actor and keeps the same person selected.
    func refresh() {
        let store = self.store
        Task { [weak self] in
            let loaded = await Task.detached { () -> (SpeakerProfileDatabase, [SpeakerProfile])? in
                guard let database = try? store.load() else { return nil }
                return (database, VoiceProfileService.sortedPeople(database.profiles))
            }.value
            guard let self else { return }
            guard let (database, people) = loaded else {
                self.statusLabel.stringValue = "The people store could not be read."
                self.derivedStatus = true
                return
            }
            let selected = self.selectedPerson?.id
            // Anything this window derived from the store is recomputed here, including back to nothing: the
            // condition may have been answered elsewhere (the review window, the CLI) since it was shown, and a
            // window that keeps saying so is telling the user something untrue. What an action of this window
            // reported ("Merged two people.") is not derived and stays until the next action.
            if self.derivedStatus || self.statusLabel.stringValue.isEmpty {
                let reset = !database.isCalibrated && database.calibrationResetAt != nil
                self.statusLabel.stringValue = reset
                    ? "Automatic names are off for new meetings: the calibration was reset when the voice samples "
                        + "changed. Meetings already named keep their names."
                    : ""
                self.derivedStatus = reset
            }
            self.database = database
            self.people = people
            self.peopleTable.reloadData()
            if let selected, let row = people.firstIndex(where: { $0.id == selected }) {
                self.peopleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else if !people.isEmpty, self.peopleTable.selectedRow < 0 {
                self.peopleTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            self.updateControls()
        }
    }

    private var selectedPerson: SpeakerProfile? {
        let row = peopleTable.selectedRow
        return row >= 0 && row < people.count ? people[row] : nil
    }

    private func updateControls() {
        rememberBox.state = database.rememberVoices ? .on : .off
        rememberBox.isEnabled = !busy
        // Also without samples: Forget All deletes every meeting's voice data and recognition results too.
        forgetAllButton.isEnabled = !busy
        let person = selectedPerson
        nameLabel.stringValue = person.map { $0.displayName + ($0.isSelf ? " (you)" : "") } ?? "No person selected"
        renameButton.isEnabled = !busy && person != nil
        suggestBox.title = person.map { "Suggest \($0.displayName) in new meetings" } ?? "Suggest in new meetings"
        suggestBox.state = person?.recognitionEnabled == false ? .off : .on
        suggestBox.isEnabled = !busy && person != nil
        forgetPersonButton.title = person.map { "Forget \($0.displayName)…" } ?? "Forget…"
        forgetPersonButton.isEnabled = !busy && person != nil
        mergePopUp.removeAllItems()
        mergePopUp.addItem(withTitle: "Merge Into…")
        for other in people where other.id != person?.id {
            // Menu items directly: two people may share a name, which `addItem(withTitle:)` would collapse.
            let item = NSMenuItem(title: other.displayName + (other.isSelf ? " (you)" : ""), action: nil,
                                  keyEquivalent: "")
            item.representedObject = other.id
            mergePopUp.menu?.addItem(item)
        }
        mergePopUp.isEnabled = !busy && person != nil && people.count > 1
        samplesTable.reloadData()
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === peopleTable ? people.count : selectedPerson?.samples.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        if column == .forget {
            let button = NSButton(title: "Forget", target: self, action: #selector(forgetSample(_:)))
            button.bezelStyle = .inline
            button.tag = row
            button.isEnabled = !busy
            return button
        }
        let field = NSTextField(labelWithString: text(column, row: row, table: tableView))
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === peopleTable { updateControls() }
    }

    private func text(_ column: Column, row: Int, table: NSTableView) -> String {
        if table === peopleTable {
            guard row < people.count else { return "" }
            let person = people[row]
            switch column {
            case .person: return person.displayName + (person.isSelf ? " (you)" : "")
            case .summary: return Self.summary(person)
            default: return ""
            }
        }
        guard let samples = selectedPerson?.samples, row < samples.count else { return "" }
        let sample = samples[row]
        switch column {
        case .meeting: return sample.sessionName
        case .date: return dateFormatter.string(from: sample.addedAt)
        case .condition: return sample.condition.rawValue
        case .speech: return TimeFormat.duration(sample.speechSeconds) + (sample.weak ? " · weak" : "")
        default: return ""
        }
    }

    /// "no samples", "3 · 2:41", or "1 · weak".
    static func summary(_ person: SpeakerProfile) -> String {
        let samples = person.samples
        guard !samples.isEmpty else { return "no samples" }
        if samples.allSatisfy(\.weak) { return "\(samples.count) · weak" }
        return "\(samples.count) · " + TimeFormat.duration(samples.reduce(0) { $0 + $1.speechSeconds })
    }

    // MARK: - Actions

    @objc private func toggleRemember() {
        let turningOn = rememberBox.state == .on
        rememberBox.state = database.rememberVoices ? .on : .off
        if turningOn {
            perform("Remember voices is on.") { store, root in
                try VoiceProfileService.setRemember(true, forgetExisting: false, store: store, sessionsRoot: root)
            }
            return
        }
        // Also with no samples: a meeting processed with the hidden --voice-data option holds voiceprints of its
        // own, and the choice to remove them is the same one. Asking costs a dialog; not asking leaves biometric
        // data the user believes they were offered the chance to delete.
        let samples = database.sampleCount
        // Forget here is the `.all` path: it removes every meeting's voice data, not only that of the meetings
        // that contributed a sample, so the prompt says so rather than counting the samples' meetings.
        let alert = NSAlert()
        alert.messageText = samples > 0
            ? "Also forget the \(samples) saved voice \(samples == 1 ? "sample" : "samples") and the voice data of "
                + "every meeting?"
            : "Also forget the voice data of every meeting?"
        alert.informativeText = "Names are kept either way. Kept samples are not used while Remember voices is off. "
            + "Voice data is the per-meeting data Holos keeps for evaluation; a meeting that never contributed a "
            + "sample can have some too."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Keep")
        let forget = alert.runModal() == .alertFirstButtonReturn
        perform(forget ? "Remember voices is off; every voice was forgotten." : "Remember voices is off.") { store, root in
            try VoiceProfileService.setRemember(false, forgetExisting: forget, store: store, sessionsRoot: root)
        }
    }

    @objc private func toggleSuggestions() {
        guard let person = selectedPerson else { return }
        let on = suggestBox.state == .on
        perform(nil) { store, _ in try VoiceProfileService.setSuggestions(on, profileID: person.id, store: store) }
    }

    @objc private func renamePerson() {
        guard let person = selectedPerson else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(person.displayName)"
        alert.informativeText = "Meetings keep the name the person had when they were named there."
        let field = NSTextField(string: person.displayName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        guard SpeakerEditor.cleanName(name) != nil else { return }
        perform(nil) { store, _ in try VoiceProfileService.rename(profileID: person.id, to: name, store: store) }
    }

    @objc private func mergePerson(_ sender: NSPopUpButton) {
        guard let person = selectedPerson, let target = sender.selectedItem?.representedObject as? String,
              let other = people.first(where: { $0.id == target }) else { return }
        let alert = NSAlert()
        alert.messageText = "Merge \(person.displayName) into \(other.displayName)?"
        alert.informativeText = "They are one person: \(person.displayName)'s voice samples move to "
            + "\(other.displayName), and \(person.displayName) is removed from People. Meetings keep their names."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Merged \(person.displayName) into \(other.displayName).") { store, _ in
            try VoiceProfileService.merge(profileID: person.id, into: other.id, store: store)
        }
    }

    @objc private func forgetPerson() {
        guard let person = selectedPerson else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(person.displayName)?"
        alert.informativeText = "Holos forgets this person and their \(person.samples.count) voice "
            + "\(person.samples.count == 1 ? "sample" : "samples"). Meetings keep the name they were given. This "
            + "cannot be undone."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Forgot \(person.displayName).") { store, root in
            try VoiceProfileService.forget(profileID: person.id, store: store, sessionsRoot: root)
        }
    }

    @objc private func forgetSample(_ sender: NSButton) {
        guard let person = selectedPerson, sender.tag >= 0, sender.tag < person.samples.count else { return }
        let sample = person.samples[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Forget the voice sample from “\(sample.sessionName)”?"
        alert.informativeText = "\(person.displayName) stays in People. This cannot be undone."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Forgot one voice sample of \(person.displayName).") { store, root in
            try VoiceProfileService.forget(sampleID: sample.id, store: store, sessionsRoot: root)
        }
    }

    @objc private func forgetAllVoices() {
        let samples = database.sampleCount
        let alert = NSAlert()
        alert.messageText = "Forget all voices?"
        alert.informativeText = "Holos forgets \(samples) voice \(samples == 1 ? "sample" : "samples") and the voice "
            + "data of every meeting in the Holos sessions folder. People and the names in your meetings stay. This "
            + "cannot be undone."
        alert.addButton(withTitle: "Forget All Voices")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Forgot every voice.") { store, root in
            try VoiceProfileService.forgetAll(store: store, sessionsRoot: root)
        }
    }

    /// Runs one change off the main actor, then shows `done` (or the error) and reloads.
    /// Whether what the status line shows was derived from the store (a reset calibration, an unreadable store)
    /// rather than reported by an action of this window. Only the derived kind is recomputed by a refresh.
    private var derivedStatus = false

    private func perform(_ done: String?, _ change: @escaping @Sendable (SpeakerProfileStore, URL) throws -> Void) {
        guard !busy else { return }
        busy = true
        updateControls()
        statusLabel.stringValue = "Saving…"
        let store = self.store
        let root = sessionsRoot
        Task { [weak self] in
            let (failure, reset) = await Task.detached { () -> (String?, String?) in
                // A change to the voice samples resets the calibration in its store write; say so.
                let before = try? store.load()
                var failure: String?
                do {
                    try change(store, root)
                } catch {
                    failure = error.localizedDescription
                }
                return (failure, VoiceProfileService.calibrationResetNote(before: before, after: try? store.load()))
            }.value
            guard let self else { return }
            self.busy = false
            self.statusLabel.stringValue = [failure ?? done, reset].compactMap { $0 }.joined(separator: " ")
            self.derivedStatus = false
            self.refresh()
        }
    }
}
