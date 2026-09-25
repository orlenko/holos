import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage
import Quartz
import UniformTypeIdentifiers

/// The saved meetings (docs/meeting-design.md §5.8, §4.13): a table of the session catalog and the actions on the
/// selected meeting. Recover, Label Speakers, and the deletions run `holos` commands through the app delegate; the
/// rest (Show in Finder, the Quick Look preview, Save Transcript As…, Clean Up) happen here. Refreshes every 2 s
/// while visible; the listing is read off the main actor.
@MainActor
final class MeetingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
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
    /// `MeetingController.beginUsing` and `endUsing`: Clean Up and Save Transcript As… hold the meeting while they run.
    private let beginUsing: (String, String) -> Bool
    private let endUsing: (String) -> Void
    private let onClose: () -> Void
    private let window: PreviewingWindow
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var buttons: [String: NSButton] = [:]
    private var sessions: [SessionSummary] = []
    /// Maintenance commands running, by session ID.
    private var running: [String: String] = [:]
    private var pendingSelection: String?
    private var refreshTask: Task<Void, Never>?
    private var loading = false
    private var positioned = false
    private var previewURL: URL?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var isVisible: Bool { window.isVisible }

    init(root: URL, perform: @escaping (Action, SessionSummary) -> Void,
         beginUsing: @escaping (String, String) -> Bool, endUsing: @escaping (String) -> Void,
         onClose: @escaping () -> Void) {
        self.root = root
        self.perform = perform
        self.beginUsing = beginUsing
        self.endUsing = endUsing
        self.onClose = onClose
        window = PreviewingWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: true)
        super.init()
        window.title = "Holos Meetings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 320)
        window.delegate = self
        window.previewController = self

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
        table.doubleAction = #selector(openTranscript)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [
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
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window.contentView = content
        updateButtons()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        buttons[title] = button
        return button
    }

    func show(selecting sessionID: String?) {
        pendingSelection = sessionID
        if !positioned {
            window.center()
            positioned = true
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.window.isVisible else { return }
                self.refresh()
            }
        }
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
            let listed = await Task.detached { () -> ([SessionSummary], Int64?) in
                (SessionCatalog.list(root: root), try? VolumeFreeSpace().availableBytes(at: root))
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
        sessions = listed
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
        switch column {
        case .name:
            cell.stringValue = summary.name
            cell.toolTip = summary.name
        case .date:
            cell.stringValue = dateFormatter.string(from: summary.createdAt)
        case .duration:
            cell.stringValue = MeetingFormat.clock(summary.savedSeconds)
        case .state:
            cell.stringValue = running[summary.id] ?? Self.stateText(summary)
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

    /// The buttons follow `MeetingActionPolicy`, the rules of the commands behind them.
    private func updateButtons() {
        let summary = selectedSession
        let hasExport = summary.map { Self.isRegularFile(SessionPaths.export("md", in: $0.directory)) } ?? false
        let enabled = MeetingActionPolicy.enabled(summary, inUse: summary.map { running[$0.id] != nil } ?? false,
                                                  hasExport: hasExport)
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
            if let message = summary.labelMessage, summary.speakerState != .labelled { parts.append(message) }
            statusLabel.stringValue = parts.joined(separator: " ")
        } else {
            statusLabel.stringValue = ""
        }
    }

    @objc private func recover() { act(.recover) }

    @objc private func labelSpeakers() { act(.labelSpeakers) }

    @objc private func deleteAudio() { act(.deleteAudio) }

    @objc private func deleteMeeting() { act(.deleteMeeting) }

    private func act(_ action: Action) {
        guard let summary = selectedSession else { return }
        perform(action, summary)
        updateButtons()
    }

    @objc private func showInFinder() {
        guard let summary = selectedSession else { return }
        NSWorkspace.shared.activateFileViewerSelecting([summary.directory])
    }

    /// A Quick Look preview of exports/transcript.md (read-only; Save Transcript As… gives an editable copy).
    @objc private func openTranscript() {
        guard let summary = selectedSession else { return }
        let url = SessionPaths.export("md", in: summary.directory)
        guard Self.isRegularFile(url) else { return }
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            window.makeKeyAndOrderFront(nil)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Renders the chosen format from the session (off the main actor) and writes it where the user says.
    @objc private func saveTranscript() {
        guard let summary = selectedSession else { return }
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
        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(chooser) {}
            guard response == .OK, let destination = panel.url else { return }
            let format: ExportFormat = formats.indexOfSelectedItem == 1 ? .txt : .md
            self?.write(format, of: summary, to: destination)
        }
    }

    /// Renders while the meeting is registered as in use, so no relabel or command replaces its labels meanwhile.
    private func write(_ format: ExportFormat, of summary: SessionSummary, to destination: URL) {
        let session = summary.directory
        let id = summary.id
        guard beginUsing(id, "Saving the transcript…") else {
            showSheet("Holos could not save the transcript.", Self.inUseText(running[id]))
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
            self.showSheet("Holos could not save the transcript.", failure)
        }
    }

    /// Deletes leftover speaker-labelling renders under the processing lease, while the meeting is registered as in
    /// use: the automatic relabel skips it, instead of losing the lease race and using up an attempt.
    @objc private func cleanUp() {
        guard let summary = selectedSession else { return }
        let session = summary.directory
        let id = summary.id
        guard beginUsing(id, "Cleaning up…") else {
            showSheet("Holos could not clean up this meeting.", Self.inUseText(running[id]))
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
            self.showSheet("Holos could not clean up this meeting.", failure)
        }
    }

    private func showSheet(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private static func inUseText(_ doing: String?) -> String {
        "Holos is working on this meeting" + (doing.map { " (\($0))" } ?? "") + ". Try again when it finishes."
    }

    // MARK: - Quick Look

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        // The Quick Look panel has this object as its delegate too; only the Meetings window's closing counts.
        guard (notification.object as? NSWindow) === window else { return }
        refreshTask?.cancel()
        refreshTask = nil
        if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, panel.isVisible {
            panel.orderOut(nil)
        }
        onClose()
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

/// The Meetings window, which takes control of the Quick Look panel for the transcript preview. AppKit calls the
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
