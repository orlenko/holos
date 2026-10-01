import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage
import Quartz
import UniformTypeIdentifiers

/// The saved meetings (docs/meeting-design.md §5.8, §4.13): a table of the session catalog and the actions on the
/// selected meeting. Recover, Label Speakers, and the deletions run `voiceislocal` commands through the app delegate, which
/// also opens Review (PR9, §5.10); the rest (Show in Finder, the Quick Look preview, Save Transcript As…, Clean Up)
/// happen here. The meeting being recorded or saved comes first, marked "● Recording". Double-click (or Return) opens
/// what `MeetingOpenPolicy` says: the live transcript (`LiveMeetingViewController`, shown in place of the list until
/// ‹ Meetings or Escape) for that meeting, Review for a labelled one, the preview otherwise; ⌫ is Delete Meeting….
/// The main window's Meetings section; it refreshes every 2 s while on screen, reading the listing off the main
/// actor.
@MainActor
final class MeetingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate, MainSectionContent {
    enum Action { case recover, labelSpeakers, deleteAudio, deleteMeeting }

    private enum Column: String, CaseIterable {
        case name = "Name", date = "Date", duration = "Duration", state = "State", speakers = "Speakers", size = "Size"

        var width: CGFloat {
            switch self {
            case .name: 220
            case .date: 150
            case .duration: 70
            case .state: 110
            case .speakers: 100
            case .size: 70
            }
        }
    }

    private let root: URL
    private let perform: (Action, SessionSummary) -> Void
    private let openReview: (SessionSummary) -> Void
    /// `MeetingController.beginUsing` and `endUsing`: Clean Up and Save Transcript As… hold the meeting while they run.
    private let beginUsing: (String, String) -> Bool
    private let endUsing: (String) -> Void
    /// The live transcript's header for a meeting (the app delegate describes the meeting state).
    private let liveHeader: (String, SessionSummary?) -> LiveMeetingHeader
    /// The app's meeting state (`MeetingController.state`).
    private var meetingState: MeetingState = .idle
    /// The live transcript shown in place of the list, if any.
    private var live: LiveMeetingViewController?
    private let listView = NSView()
    private let table = KeyTableView()
    private let footer = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var buttons: [String: NSButton] = [:]
    private var sessions: [SessionSummary] = []
    /// Maintenance commands running, by session ID.
    private var running: [String: String] = [:]
    private var pendingSelection: String?
    private var refreshTask: Task<Void, Never>?
    private var loading = false
    private var previewURL: URL?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// On screen: the window is visible and shows this section.
    private var onScreen = false

    init(root: URL, perform: @escaping (Action, SessionSummary) -> Void,
         openReview: @escaping (SessionSummary) -> Void,
         beginUsing: @escaping (String, String) -> Bool, endUsing: @escaping (String) -> Void,
         liveHeader: @escaping (String, SessionSummary?) -> LiveMeetingHeader) {
        self.root = root
        self.perform = perform
        self.openReview = openReview
        self.beginUsing = beginUsing
        self.endUsing = endUsing
        self.liveHeader = liveHeader
        super.init(nibName: nil, bundle: nil)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.rawValue
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onReturn = { [weak self] in self?.openSelection() }
        table.onDelete = { [weak self] in self?.deleteMeeting() }
        table.setAccessibilityLabel("Meetings")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [
            button("Live Transcript", #selector(showLiveTranscript)),
            button("Review…", #selector(review)),
            button("Recover…", #selector(recover)), button("Label Speakers", #selector(labelSpeakers)),
            button("Show in Finder", #selector(showInFinder)), button("Open Transcript", #selector(openTranscript)),
            button("Save Transcript As…", #selector(saveTranscript)),
        ])
        row.spacing = 8
        let second = NSStackView(views: [
            button("Delete Audio…", #selector(deleteAudio)), button("Delete Meeting…", #selector(deleteMeeting)),
            button("Clean Up", #selector(cleanUp)),
        ])
        second.spacing = 8
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [scroll, row, second, statusLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: listView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        let content = NSView()
        Self.fill(content, with: listView)
        view = content
        updateButtons()
    }

    private static func fill(_ parent: NSView, with child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredFirstResponder: NSView? { live?.preferredFirstResponder ?? table }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        buttons[title] = button
        return button
    }

    /// Selects the meeting once the list is read (nil keeps the selection).
    func select(sessionID: String?) {
        pendingSelection = sessionID
        refresh()
    }

    func sectionDidShow() {
        onScreen = true
        live?.start()
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.onScreen, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    func sectionDidHide() {
        onScreen = false
        refreshTask?.cancel()
        refreshTask = nil
        live?.stop()
    }

    // MARK: - Live transcript

    /// The meeting the app follows while it starts, records, or saves (`MeetingOpenPolicy.isLive`).
    private var liveSessionID: String? {
        switch meetingState {
        case .starting(let id, _, _), .active(let id, _), .finishing(let id, _): id
        case .idle, .failed: nil
        }
    }

    /// The app's meeting state changed (every status write, about once a second while a meeting records).
    func update(meetingState state: MeetingState) {
        let previous = liveSessionID
        let previousPhase = previous.map { id in
            LiveMeetingPhase.of(sessionID: id, state: meetingState, summary: sessions.first { $0.id == id })
        }
        meetingState = state
        if liveSessionID != previous {
            // A meeting starts or ends: the list's order and its "● Recording" mark change.
            refresh()
        } else if let id = liveSessionID,
                  LiveMeetingPhase.of(sessionID: id, state: state, summary: sessions.first { $0.id == id })
                    != previousPhase {
            // Recording, paused, saving: the State column says which.
            table.reloadData()
            updateButtons()
        }
        updateLiveHeader()
    }

    /// Shows the live transcript of the meeting in `directory` in place of the list (opening a live meeting, the menu
    /// bar's Show Live Transcript…).
    func showLive(sessionID: String, directory: URL) {
        if let live, live.sessionID == sessionID {
            view.window?.makeFirstResponder(live.preferredFirstResponder)
            return
        }
        removeLive()
        let controller = LiveMeetingViewController(
            sessionID: sessionID, directory: directory,
            onBack: { [weak self] in self?.showList() },
            onOpenFinished: { [weak self] in self?.openFinished(sessionID) })
        live = controller
        addChild(controller)
        listView.isHidden = true
        Self.fill(view, with: controller.view)
        updateLiveHeader()
        if onScreen { controller.start() }
        view.window?.makeFirstResponder(controller.preferredFirstResponder)
    }

    /// Back to the list, with the meeting the live transcript showed selected.
    func showList() {
        guard let shown = live else { return }
        removeLive()
        listView.isHidden = false
        select(sessionID: shown.sessionID)
        view.window?.makeFirstResponder(table)
    }

    private func removeLive() {
        guard let live else { return }
        live.stop()
        live.view.removeFromSuperview()
        live.removeFromParent()
        self.live = nil
    }

    private func updateLiveHeader() {
        guard let live else { return }
        let summary = sessions.first { $0.id == live.sessionID }
        let header = liveHeader(live.sessionID, summary)
        let action: String? = summary.flatMap { summary in
            switch MeetingOpenPolicy.finishedTarget(summary, inUse: running[summary.id] != nil,
                                                    hasExport: hasExport(summary)) {
            case .review: "Open Review"
            case .transcript: "Open Transcript"
            case .live, .none: nil
            }
        }
        live.update(header: header, finishedAction: action)
    }

    /// The live transcript's "Open Review" / "Open Transcript" once its meeting is saved.
    private func openFinished(_ sessionID: String) {
        guard let summary = sessions.first(where: { $0.id == sessionID }) else {
            NSSound.beep()
            return
        }
        switch MeetingOpenPolicy.finishedTarget(summary, inUse: running[summary.id] != nil,
                                                hasExport: hasExport(summary)) {
        case .review: openReview(summary)
        case .transcript: preview(summary)
        case .live, .none: NSSound.beep()
        }
    }

    @objc private func showLiveTranscript() {
        guard let summary = selectedSession else { return }
        guard MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID) else {
            NSSound.beep()
            return
        }
        showLive(sessionID: summary.id, directory: summary.directory)
    }

    /// The meetings the app is working on (`MeetingController.sessionsInUse`).
    func update(running: [String: String]) {
        self.running = running
        // The State column shows what a running command is doing; reloading keeps the selection.
        table.reloadData()
        updateButtons()
    }

    /// Reads the catalog off the main actor, then shows it.
    func refresh() {
        guard !loading else { return }
        loading = true
        let root = self.root
        Task { [weak self] in
            // A meeting that misses a language is checked for its speech model, so Label Speakers is offered once
            // the language can be detected (§4.14).
            let listed = await Task.detached { () -> ([SessionSummary], Int64?) in
                (await SessionCatalog.checkingLanguageModels(SessionCatalog.list(root: root)),
                 try? VolumeFreeSpace().availableBytes(at: root))
            }.value
            guard let self else { return }
            self.loading = false
            self.show(listed.0, freeBytes: listed.1)
        }
    }

    private func show(_ listed: [SessionSummary], freeBytes: Int64?) {
        let requested = pendingSelection
        let selected = requested ?? selectedSession?.id
        pendingSelection = nil
        sessions = MeetingOpenPolicy.ordered(listed, liveSessionID: liveSessionID)
        table.reloadData()
        // Rows move when meetings are added or removed: keep the same meeting selected, not the same row.
        if let selected, let index = sessions.firstIndex(where: { $0.id == selected }) {
            if table.selectedRow != index {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            if requested != nil { table.scrollRowToVisible(index) }
        } else {
            table.deselectAll(nil)
        }
        let used = sessions.reduce(Int64(0)) { $0 + $1.bytes }
        footer.stringValue = "Meetings use \(MeetingFormat.gigabytes(used))"
            + (freeBytes.map { " · \(MeetingFormat.gigabytes($0)) free" } ?? "")
        updateButtons()
        updateLiveHeader()
    }

    private var selectedSession: SessionSummary? {
        let row = table.selectedRow
        return row >= 0 && row < sessions.count ? sessions[row] : nil
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), row < sessions.count else {
            return nil
        }
        let summary = sessions[row]
        let identifier = NSUserInterfaceItemIdentifier("cell." + column.rawValue)
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        cell.toolTip = nil
        cell.textColor = .labelColor
        cell.font = .systemFont(ofSize: NSFont.systemFontSize)
        let isLive = MeetingOpenPolicy.isLive(summary, liveSessionID: liveSessionID)
        switch column {
        case .name:
            cell.stringValue = summary.name
            cell.toolTip = summary.name
            if isLive { cell.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }
        case .date:
            cell.stringValue = dateFormatter.string(from: summary.createdAt)
        case .duration:
            cell.stringValue = MeetingFormat.clock(summary.savedSeconds)
        case .state:
            if isLive, running[summary.id] == nil,
               let (text, color) = Self.liveStateText(LiveMeetingPhase.of(sessionID: summary.id, state: meetingState,
                                                                          summary: summary)) {
                cell.stringValue = text
                cell.textColor = color
                cell.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                cell.toolTip = "Double-click or press Return to watch the live transcript."
            } else {
                cell.stringValue = running[summary.id] ?? Self.stateText(summary)
            }
        case .speakers:
            cell.stringValue = Self.speakersText(summary.speakerState)
            cell.toolTip = summary.labelMessage
        case .size:
            cell.stringValue = MeetingFormat.size(summary.bytes)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    /// The State column of the live meeting; nil once it is saved (the catalog's state then).
    static func liveStateText(_ phase: LiveMeetingPhase) -> (String, NSColor)? {
        switch phase {
        case .recording: ("● Recording", .systemRed)
        case .paused: ("● Paused", .systemOrange)
        case .starting: ("Starting…", .secondaryLabelColor)
        case .saving: ("Saving…", .secondaryLabelColor)
        case .saved, .failed: nil
        }
    }

    static func stateText(_ summary: SessionSummary) -> String {
        let text = switch summary.state {
        case .recording: "Recording"
        case .processing: "Processing"
        case .interrupted: "Interrupted"
        case .complete: "Saved"
        case .audioOnly: "Audio only"
        case .transcriptionIncomplete: "Transcript incomplete"
        case .incomplete: "Incomplete"
        case .failed: "Failed"
        case .recovered: "Recovered"
        case .damaged: "Damaged"
        }
        return summary.audioDeleted ? text + " · no audio" : text
    }

    static func speakersText(_ state: SpeakerLabelState) -> String {
        switch state {
        case .none: "—"
        case .running: "Labelling…"
        case .labelled: "Labelled"
        case .notLabelled: "Not labelled"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .unreadable: "Unreadable"
        }
    }

    // MARK: - Buttons

    /// What `MeetingActionPolicy` enables for `summary` now, the rules of the commands behind the actions. The
    /// buttons show it, and every way to an action (button, ⌫, Return, double-click) checks it again when used.
    private func enabledActions(_ summary: SessionSummary?) -> Set<MeetingActionPolicy.Action> {
        MeetingActionPolicy.enabled(summary, inUse: summary.map { running[$0.id] != nil } ?? false,
                                    hasExport: summary.map(hasExport) ?? false)
    }

    /// exports/transcript.md is a regular file.
    private func hasExport(_ summary: SessionSummary) -> Bool {
        Self.isRegularFile(SessionPaths.export("md", in: summary.directory))
    }

    /// What opening `summary` shows (`MeetingOpenPolicy`).
    private func openTarget(_ summary: SessionSummary) -> MeetingOpenPolicy.Target {
        MeetingOpenPolicy.target(summary, liveSessionID: liveSessionID, inUse: running[summary.id] != nil,
                                 hasExport: hasExport(summary))
    }

    /// The selected meeting, when `action` is enabled for it; else nil, and a keyboard use beeps.
    private func selection(for action: MeetingActionPolicy.Action) -> SessionSummary? {
        guard let summary = selectedSession else { return nil }
        guard enabledActions(summary).contains(action) else {
            NSSound.beep()
            updateButtons()
            return nil
        }
        return summary
    }

    /// The buttons follow `MeetingActionPolicy`, the rules of the commands behind them.
    private func updateButtons() {
        let summary = selectedSession
        buttons["Review…"]?.isEnabled = summary.map(canReview) ?? false
        buttons["Live Transcript"]?.isEnabled = summary.map { MeetingOpenPolicy.isLive($0, liveSessionID: liveSessionID) }
            ?? false
        let enabled = enabledActions(summary)
        let titles: [(String, MeetingActionPolicy.Action)] = [
            ("Recover…", .recover), ("Label Speakers", .labelSpeakers), ("Show in Finder", .showInFinder),
            ("Open Transcript", .openTranscript), ("Save Transcript As…", .saveTranscript),
            ("Delete Audio…", .deleteAudio), ("Delete Meeting…", .deleteMeeting), ("Clean Up", .cleanUp),
        ]
        for (title, action) in titles { buttons[title]?.isEnabled = enabled.contains(action) }
        buttons["Clean Up"]?.isHidden = (summary?.derivedBytes ?? 0) == 0
        if let summary {
            var parts: [String] = []
            if let doing = running[summary.id] { parts.append(doing) }
            // While a language is missing, why and what to do stay shown, also for labelled speakers: the window's
            // own message once Label Speakers can detect it (or edited labels keep it from doing so), else the
            // record's, which names the reason and what to install.
            if let work = summary.languageWork, let message = work.message {
                parts.append(message)
            } else if let message = summary.labelMessage,
                      summary.speakerState != .labelled || summary.languageWork != nil {
                parts.append(message)
            }
            if PendingExports().contains(summary.id) {
                parts.append("The transcript files are older than the speaker labels; open Review to update them.")
            }
            statusLabel.stringValue = parts.joined(separator: " ")
        } else {
            statusLabel.stringValue = ""
        }
    }

    /// Review needs speaker labels and no recording, labelling, or command running on the meeting.
    private func canReview(_ summary: SessionSummary) -> Bool {
        MeetingOpenPolicy.canReview(summary, inUse: running[summary.id] != nil)
    }

    @objc private func review() {
        guard let summary = selectedSession else { return }
        guard canReview(summary) else {
            NSSound.beep()
            return
        }
        openReview(summary)
    }

    /// Double-click: as Return.
    @objc private func openSelected() {
        guard table.clickedRow >= 0 else { return }
        openSelection()
    }

    /// Return, or a double-click (`MeetingOpenPolicy`): the live transcript of the meeting being recorded or saved,
    /// Review for a labelled meeting, else the transcript preview (when Open Transcript is enabled; otherwise a beep,
    /// as for any action that is off).
    private func openSelection() {
        guard let summary = selectedSession else { return }
        switch openTarget(summary) {
        case .live: showLive(sessionID: summary.id, directory: summary.directory)
        case .review: openReview(summary)
        case .transcript, .none: openTranscript()
        }
    }

    @objc private func recover() { act(.recover, .recover) }

    @objc private func labelSpeakers() { act(.labelSpeakers, .labelSpeakers) }

    @objc private func deleteAudio() { act(.deleteAudio, .deleteAudio) }

    /// The button, and ⌫ in the list: refused (with a beep) whenever the button is off, for example while another
    /// process holds the meeting.
    @objc private func deleteMeeting() { act(.deleteMeeting, .deleteMeeting) }

    private func act(_ action: Action, _ policy: MeetingActionPolicy.Action) {
        guard let summary = selection(for: policy) else { return }
        perform(action, summary)
        updateButtons()
    }

    @objc private func showInFinder() {
        guard let summary = selection(for: .showInFinder) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([summary.directory])
    }

    /// A Quick Look preview of exports/transcript.md (read-only; Save Transcript As… gives an editable copy).
    @objc private func openTranscript() {
        guard let summary = selection(for: .openTranscript) else { return }
        preview(summary)
    }

    private func preview(_ summary: SessionSummary) {
        let url = SessionPaths.export("md", in: summary.directory)
        guard Self.isRegularFile(url) else { return }
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            view.window?.makeKeyAndOrderFront(nil)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Renders the chosen format from the session (off the main actor) and writes it where the user says.
    @objc private func saveTranscript() {
        guard let summary = selection(for: .saveTranscript) else { return }
        let panel = NSSavePanel()
        let formats = NSPopUpButton()
        formats.addItems(withTitles: ["Markdown (.md)", "Plain text (.txt)"])
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Format:"), formats])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.fileName(summary.name) + ".md"
        panel.canCreateDirectories = true
        let chooser = FormatChooser(panel: panel, popup: formats)
        formats.target = chooser
        formats.action = #selector(FormatChooser.changed)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            withExtendedLifetime(chooser) {}
            guard response == .OK, let destination = panel.url else { return }
            let format: ExportFormat = formats.indexOfSelectedItem == 1 ? .txt : .md
            self?.write(format, of: summary, to: destination)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Renders while the meeting is registered as in use, so no relabel or command replaces its labels meanwhile.
    private func write(_ format: ExportFormat, of summary: SessionSummary, to destination: URL) {
        let session = summary.directory
        let id = summary.id
        guard beginUsing(id, "Saving the transcript…") else {
            showSheet("Voice is Local could not save the transcript.", Self.inUseText(running[id]))
            return
        }
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do {
                    // People's current names, and "Remember voices": off means the kept voice samples, and the
                    // suggestions made from them, are not used, so this export names nobody automatically.
                    let store = SpeakerProfileStore()
                    let data = try SessionExports.render(
                        format, session: session, profileNames: VoiceProfileService.profileNames(store: store),
                        applyRecognition: VoiceProfileService.recognitionAllowed(store: store))
                    let target = destination.deletingLastPathComponent().resolvingSymlinksInPath()
                        .appendingPathComponent(destination.lastPathComponent)
                    try AtomicFile.write(data, to: target, permissions: 0o600)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.endUsing(id)
            guard let failure else { return }
            self.showSheet("Voice is Local could not save the transcript.", failure)
        }
    }

    /// Deletes leftover speaker-labelling renders under the processing lease, while the meeting is registered as in
    /// use: the automatic relabel skips it, instead of losing the lease race and using up an attempt.
    @objc private func cleanUp() {
        guard let summary = selection(for: .cleanUp) else { return }
        let session = summary.directory
        let id = summary.id
        guard beginUsing(id, "Cleaning up…") else {
            showSheet("Voice is Local could not clean up this meeting.", Self.inUseText(running[id]))
            return
        }
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do {
                    try MeetingController.cleanUpDerived(session: session)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.endUsing(id)
            self.refresh()
            guard let failure else { return }
            self.showSheet("Voice is Local could not clean up this meeting.", failure)
        }
    }

    private func showSheet(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private static func inUseText(_ doing: String?) -> String {
        "Voice is Local is working on this meeting" + (doing.map { " (\($0))" } ?? "") + ". Try again when it finishes."
    }

    // MARK: - Quick Look

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }

    // MARK: - Helpers

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// A file name from the meeting name: no slashes or colons, at most 100 characters.
    private static func fileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }
        let text = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Transcript" : String(text.prefix(100))
    }
}

/// Keeps the save panel's extension in step with the chosen format.
@MainActor
private final class FormatChooser: NSObject {
    private weak var panel: NSSavePanel?
    private weak var popup: NSPopUpButton?

    init(panel: NSSavePanel, popup: NSPopUpButton) {
        self.panel = panel
        self.popup = popup
    }

    @objc func changed() {
        guard let panel, let popup else { return }
        let ext = popup.indexOfSelectedItem == 1 ? "txt" : "md"
        panel.allowedContentTypes = [ext == "txt" ? .plainText : (UTType(filenameExtension: "md") ?? .plainText)]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + ext
    }
}

/// The main window, which lets the Meetings section (`previewController`, set while it shows) take control of the
/// Quick Look panel for the transcript preview. AppKit calls the
/// panel-control methods on the main thread.
@MainActor
final class PreviewingWindow: NSWindow {
    weak var previewController: (NSObject & QLPreviewPanelDataSource & QLPreviewPanelDelegate)?

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewController != nil }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = previewController
            panel.delegate = previewController
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
