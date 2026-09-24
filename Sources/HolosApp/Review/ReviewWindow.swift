import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage
import UniformTypeIdentifiers

/// The transcript review window (docs/meeting-design.md §5.10): name the speakers of a meeting, play their audio,
/// reassign, merge, split, confirm suggestions in bulk, find more speakers, undo, and export. The model is
/// `ReviewSession` (HolosMeeting); this file only arranges views and routes actions to it. Every change shows at once
/// and saves in the background; errors appear in the footer.
///
/// Holos has no main menu, so the "Speakers" menu is a pull-down in the window's toolbar and the window handles its
/// own shortcuts: Space play/pause and 1–9 assign (in the turn list), ⌘' next uncertain, ⌘Z undo, ⌘F search,
/// ⌘E export, and the usual editing keys in text fields.
@MainActor
final class ReviewWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    let sessionID: String
    let review: ReviewSession
    /// Called once the window has closed and its changes are saved.
    var onClose: (() -> Void)?
    /// Called with true when a relabel starts from the window and false when it ends.
    var onRelabel: ((Bool) -> Void)?

    private let window: ReviewKeyWindow
    private let player = ReviewPlayer()
    private let sidebar = SpeakerSidebarView()
    private let turnList = TurnListView()
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private let nextUncertainButton = NSButton(title: "Next Uncertain", target: nil, action: nil)
    private let assignPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let splitButton = NSButton(title: "Split Turn", target: nil, action: nil)
    private let speakersPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let searchField = NSSearchField()
    private let exportPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let learnBox = NSButton(checkboxWithTitle: "Learn voices of people I name in this meeting", target: nil,
                                    action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let notices = NSStackView()
    /// The last action's error, until the next action.
    private var problem: String?
    private var query = ""
    private var positioned = false
    private var playerWasReady = false
    private var resignedKeyAt: Date?
    private var closeTask: Task<Void, Never>?
    private var splitSheet: SplitSheet?
    private var assignSignature: [String] = []
    private var refreshScheduled = false
    private var shownNotices: [Notice] = []
    /// The manifest chunks playback was last built from.
    private var loadedChunks: [AudioChunkRecord] = []
    private lazy var confirmAllItem = menuItem("Confirm All Suggestions", #selector(confirmAll))
    private lazy var findMoreItem = menuItem("Find More Speakers…", #selector(findMoreSpeakers))
    private lazy var microphoneItem = menuItem("Label Speakers on My Microphone…", #selector(labelMicrophoneSpeakers))
    private lazy var undoItem = menuItem("Undo", #selector(undo))
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Opens the review of a labelled meeting (the labels are loaded off the main actor first).
    static func open(sessionID: String, session: URL, maintenance: MaintenanceLauncher?) async throws -> ReviewWindow {
        let review = try await ReviewSession(session: session, profiles: SpeakerProfileStore(), maintenance: maintenance)
        return ReviewWindow(sessionID: sessionID, review: review)
    }

    init(sessionID: String, review: ReviewSession) {
        self.sessionID = sessionID
        self.review = review
        window = ReviewKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                                 defer: true)
        super.init()
        window.title = "\(review.sessionName) — Review"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.contentView = makeContent()
        wire()
        review.onChange = { [weak self] in self?.scheduleRefresh() }
        review.onRelabelChange = { [weak self] running in self?.onRelabel?(running) }
        player.onChange = { [weak self] in self?.refreshPlayback() }
        reloadPlayback()
        refresh()
    }

    func show() {
        if !positioned {
            window.center()
            positioned = true
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        if turnList.selectedTurnIDs.isEmpty, let first = review.projection.turns.first {
            turnList.select([first.id], scroll: true)
        }
        window.makeFirstResponder(turnList.table)
    }

    /// A maintenance command is about to work on the meeting (`ReviewMaintenance`): the window turns read-only with
    /// `banner`, playback stops and lets go of the audio, and this returns once the window's changes are saved.
    func pauseForMaintenance(key: String, banner: String) async {
        player.invalidate()
        refresh()
        await review.pause(key, reason: banner)
    }

    /// The command ended: the transcript, the labels, and playback are read again from disk, and the window is
    /// editable again.
    func resumeAfterMaintenance(key: String) async {
        await review.resume(key)
        guard !isClosing, review.pauseReason == nil else { return }
        reloadPlayback()
        refresh()
    }

    /// Rereads everything a command may have changed while the window was opening (it opened on older files).
    func reloadAll() {
        Task { [weak self] in
            guard let self, !self.isClosing else { return }
            await self.review.reload()
            guard !self.isClosing, self.review.pauseReason == nil else { return }
            self.reloadPlayback()
        }
    }

    /// Rebuilds playback from the manifest as saved now (off when the audio was deleted).
    private func reloadPlayback() {
        loadedChunks = review.snapshot.manifest.chunks
        player.load(session: review.session, manifest: review.snapshot.manifest,
                    audioDeleted: review.snapshot.audioDeleted)
    }

    /// Rereads the labels after changes made elsewhere (a command in Terminal); rebuilds playback when the audio was
    /// deleted or its chunks changed meanwhile, or when building it failed before.
    private func reloadLabels() {
        Task { [weak self] in
            guard let self, !self.isClosing, self.review.pauseReason == nil else { return }
            await self.review.reload()
            guard !self.isClosing, self.review.pauseReason == nil else { return }
            let deleted = self.review.snapshot.audioDeleted
            let playerSaysDeleted = self.player.state == .unavailable(ReviewPlayer.audioDeletedText)
            if deleted != playerSaysDeleted || self.review.snapshot.manifest.chunks != self.loadedChunks
                || (!deleted && !self.player.hasAudio) {
                self.reloadPlayback()
            }
        }
    }

    /// The window was closed and is still saving its changes (or has finished).
    var isClosing: Bool { closeTask != nil }

    /// Closes the window and waits until its changes are saved (before the meeting is deleted).
    func closeAndWait() async {
        // A minimized window is not visible but must be closed too, or it stays in the Dock.
        if window.isVisible || window.isMiniaturized { window.close() }
        if closeTask == nil { beginClosing() }
        await closeTask?.value
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        playButton.bezelStyle = .push
        playButton.imagePosition = .imageOnly
        playButton.toolTip = "Play or pause (Space)"
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        nextUncertainButton.bezelStyle = .push
        nextUncertainButton.toolTip = "Select and play the next uncertain turn (⌘')"
        assignPopUp.toolTip = "Give the selected turns to a speaker (or press 1–9 in the turn list)"
        splitButton.bezelStyle = .push
        splitButton.toolTip = "Split the selected turn in two"
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        exportPopUp.toolTip = "Save or copy the transcript (⌘E)"
        let toolbar = NSStackView(views: [playButton, timeLabel, nextUncertainButton, assignPopUp, splitButton,
                                          speakersPopUp, NSView(), searchField, exportPopUp])
        toolbar.spacing = 8
        toolbar.alignment = .centerY

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(turnList)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 320)
        sidebarWidth.priority = .defaultLow
        sidebarWidth.isActive = true
        turnList.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        learnBox.toolTip = "When on, naming a person here also learns their voice for suggestions in later meetings. "
            + "Only for people who agreed; voiceprints are biometric data."
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingHead
        let footer = NSStackView(views: [learnBox, NSView(), statusLabel])
        footer.alignment = .centerY
        notices.orientation = .vertical
        notices.alignment = .leading
        notices.spacing = 4

        let stack = NSStackView(views: [toolbar, split, footer, notices])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The panes take the height; the bars keep theirs.
        for bar in [toolbar, footer, notices] { bar.setHuggingPriority(.defaultHigh, for: .vertical) }
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notices.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        split.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return content
    }

    private func wire() {
        playButton.target = self
        playButton.action = #selector(togglePlay)
        nextUncertainButton.target = self
        nextUncertainButton.action = #selector(nextUncertain)
        splitButton.target = self
        splitButton.action = #selector(splitTurn)
        learnBox.target = self
        learnBox.action = #selector(learnChanged)

        let speakersMenu = NSMenu()
        speakersMenu.autoenablesItems = false
        speakersMenu.addItem(NSMenuItem(title: "Speakers", action: nil, keyEquivalent: ""))
        for item in [confirmAllItem, findMoreItem, microphoneItem] { speakersMenu.addItem(item) }
        speakersMenu.addItem(.separator())
        speakersMenu.addItem(undoItem)
        speakersPopUp.menu = speakersMenu

        let exportMenu = NSMenu()
        exportMenu.addItem(NSMenuItem(title: "Export", action: nil, keyEquivalent: ""))
        let save = NSMenuItem(title: "Save As…", action: #selector(saveAs), keyEquivalent: "")
        save.target = self
        exportMenu.addItem(save)
        let copy = NSMenuItem(title: "Copy as Markdown", action: #selector(copyMarkdown), keyEquivalent: "")
        copy.target = self
        exportMenu.addItem(copy)
        exportPopUp.menu = exportMenu

        sidebar.onName = { [weak self] speakerID, text in
            self?.perform { review in try await review.setName(text, speakerID: speakerID) }
        }
        sidebar.onPickPerson = { [weak self] speakerID, profileID in
            self?.perform { review in try await review.link(speakerID: speakerID, to: .existing(profileID: profileID)) }
        }
        sidebar.onConfirm = sidebar.onPickPerson
        sidebar.onPlaySamples = { [weak self] speakerID in
            guard let self else { return }
            self.player.play(clips: self.review.sampleClips(for: speakerID))
        }
        sidebar.onMarkSelf = { [weak self] speakerID in
            self?.perform { review in try await review.markSelf(speakerID: speakerID) }
        }
        sidebar.onMerge = { [weak self] from, into in
            self?.perform { review in try await review.merge(from, into: into) }
        }
        sidebar.onReject = { [weak self] speakerID in
            self?.perform { review in try await review.rejectSuggestion(speakerID: speakerID) }
        }
        sidebar.onConfirmAll = { [weak self] in self?.confirmAll() }

        turnList.onPlay = { [weak self] seconds in self?.player.play(from: seconds) }
        turnList.onAssign = { [weak self] ids, target in
            self?.perform { review in try await review.assign(ids, to: target) }
        }
        turnList.onNewSpeaker = { [weak self] ids in self?.newSpeaker(for: ids) }
        turnList.onSelectionChange = { [weak self] in self?.refreshToolbar() }
        turnList.table.onSpace = { [weak self] in self?.togglePlay() }
        turnList.table.onDigit = { [weak self] digit in self?.assignSelection(toOrdinal: digit) }
    }

    // MARK: - Refreshing

    /// One refresh for however many changes the model reports in one turn of the main queue.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let projection = review.projection
        let turns = query.isEmpty ? projection.turns : review.turns(matching: query)
        let people = review.knownPeople()
        turnList.update(turns: turns, speakers: projection.speakers, people: people, editable: review.isEditable,
                        text: { [review] turn in review.text(of: turn) },
                        resolve: { [review] id in review.resolvedTurnID(id) })
        sidebar.update(rows: sidebarRows(), people: people, editable: review.isEditable,
                       suggestions: projection.speakers.filter { $0.suggestion != nil }.count)
        refreshToolbar()
        refreshFooter()
        refreshPlayback()
    }

    private func sidebarRows() -> [SpeakerSidebarView.Row] {
        let me = review.knownPeople().first(where: \.isSelf)?.id
        return review.projection.speakers.map { speaker in
            SpeakerSidebarView.Row(
                speaker: speaker, previews: review.previews(for: speaker.id),
                isSelf: me != nil && speaker.profileID == me,
                automaticProfileID: review.automaticProfileID(for: speaker.id),
                canPlay: player.isReady && !review.sampleClips(for: speaker.id).isEmpty)
        }
    }

    private func refreshPlayback() {
        let symbol = player.isPlaying ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: player.isPlaying ? "Pause" : "Play")
        playButton.isEnabled = player.isReady
        timeLabel.stringValue = TimeFormat.clock(player.currentTime) + " / " + TimeFormat.duration(review.durationSeconds)
        if player.isReady != playerWasReady {
            playerWasReady = player.isReady
            sidebar.update(rows: sidebarRows(), people: review.knownPeople(), editable: review.isEditable,
                           suggestions: review.projection.speakers.filter { $0.suggestion != nil }.count)
            refreshFooter()
        }
    }

    private func refreshToolbar() {
        let editable = review.isEditable
        let selected = turnList.selectedTurns
        nextUncertainButton.isEnabled = review.projection.turns.contains(where: \.uncertain)

        // Menus are replaced only when their items changed, so an update never swaps a menu that is open.
        let assignItems = AssignMenu.items(speakers: review.projection.speakers, people: review.knownPeople(),
                                           unknownTitle: "Unknown speaker")
        let assignSignature = assignItems.map { item in
            item.isSeparatorItem ? "-" : item.title + "\u{1f}" + String(describing: (item.representedObject as? AssignChoice)?.kind)
        }
        if assignSignature != self.assignSignature {
            let assignMenu = NSMenu()
            assignMenu.autoenablesItems = false
            assignMenu.addItem(NSMenuItem(title: "Assign to…", action: nil, keyEquivalent: ""))
            for item in assignItems {
                if item.representedObject != nil {
                    item.target = self
                    item.action = #selector(assignChosen(_:))
                }
                assignMenu.addItem(item)
            }
            assignPopUp.menu = assignMenu
            self.assignSignature = assignSignature
        }
        assignPopUp.isEnabled = editable && !selected.isEmpty
        splitButton.isEnabled = editable && selected.count == 1
            && review.words(of: selected[0].id).count > 1

        let suggestions = review.projection.speakers.filter { $0.suggestion != nil }.count
        confirmAllItem.isEnabled = editable && suggestions > 0 && review.profiles != nil
        findMoreItem.isEnabled = editable && review.canFindMoreSpeakers
        microphoneItem.isHidden = !review.canLabelMicrophoneSpeakers
        microphoneItem.isEnabled = editable
        undoItem.isEnabled = editable && review.canUndo

        learnBox.isEnabled = review.profiles != nil && review.rememberVoices
        learnBox.state = review.learnVoices && review.rememberVoices ? .on : .off
        if !review.rememberVoices {
            learnBox.toolTip = "Remember voices is off (People…), so no voice is learned. Names are kept either way."
        }
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func refreshFooter() {
        let projection = review.projection
        let changes = review.changeCount
        var parts = ["\(projection.speakers.count) \(projection.speakers.count == 1 ? "speaker" : "speakers")",
                     "\(projection.turns.count) \(projection.turns.count == 1 ? "turn" : "turns")",
                     "\(changes) \(changes == 1 ? "change" : "changes")"]
        if let activity = review.activity {
            parts.append(activity)
        } else if let saved = review.lastSavedAt {
            parts.append("saved \(timeFormatter.string(from: saved))")
        }
        statusLabel.stringValue = parts.joined(separator: " · ")

        var lines: [Notice] = []
        if let reason = review.pauseReason {
            lines.append(Notice(text: reason + " " + ReviewSession.pausedSuffix, color: .systemOrange))
        }
        if let problem { lines.append(Notice(text: "⚠ " + problem, color: .systemRed)) }
        if let runProblem = review.snapshot.runProblem { lines.append(Notice(text: "⚠ " + runProblem, color: .systemRed)) }
        if review.snapshot.transcriptChanged {
            lines.append(Notice(text: "The transcript changed after speakers were labelled.", button: "Label Again",
                                action: #selector(labelAgain), enabled: review.isEditable))
        }
        let stale = review.staleEditCount
        if stale > 0 {
            lines.append(Notice(text: "\(stale) \(stale == 1 ? "change" : "changes") could not be applied.",
                                button: "Show", action: #selector(showStaleEdits)))
        }
        for name in review.movedAsideExports.suffix(3) {
            let original = "transcript." + (name as NSString).pathExtension
            lines.append(Notice(text: "Your edited \(original) was kept as \(name)."))
        }
        if let exportProblem = review.exportProblem {
            lines.append(Notice(text: "⚠ " + exportProblem, color: .systemOrange))
        }
        if case .unavailable(let reason) = player.state { lines.append(Notice(text: reason)) }
        // Rebuilt only when they change, so a notice's button is never removed while it is being clicked.
        guard lines != shownNotices else { return }
        shownNotices = lines
        for view in notices.arrangedSubviews {
            notices.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for line in lines { addNotice(line) }
    }

    /// One line under the footer.
    private struct Notice: Equatable {
        var text: String
        var color: NSColor = .secondaryLabelColor
        var button: String?
        var action: Selector?
        var enabled = true
    }

    private func addNotice(_ notice: Notice) {
        let label = NSTextField(wrappingLabelWithString: notice.text)
        label.textColor = notice.color
        label.font = .systemFont(ofSize: 12)
        var views: [NSView] = [label]
        if let button = notice.button, let action = notice.action {
            let control = NSButton(title: button, target: self, action: action)
            control.bezelStyle = .push
            control.controlSize = .small
            control.isEnabled = notice.enabled
            views.append(control)
        }
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = 8
        notices.addArrangedSubview(row)
    }

    // MARK: - Actions

    /// Runs one change; its error shows in the footer until the next action.
    private func perform(_ change: @escaping @MainActor (ReviewSession) async throws -> Void) {
        problem = nil
        refreshFooter()
        let review = self.review
        Task { [weak self] in
            do {
                try await change(review)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.problem = error.localizedDescription
                self.refreshFooter()
            }
        }
    }

    @objc private func togglePlay() {
        guard player.isReady else { return }
        if player.isPlaying {
            player.pause()
            return
        }
        // From the selected turn, unless the play head is already in it (then resume).
        if let turn = turnList.selectedTurns.first,
           !(turn.start...max(turn.start, turn.end)).contains(player.currentTime) {
            player.play(from: turn.start)
        } else {
            player.togglePlayPause()
        }
    }

    @objc private func nextUncertain() {
        guard let turn = review.nextUncertain(after: turnList.selectedTurnIDs.last) else {
            NSSound.beep()
            return
        }
        if !query.isEmpty, !review.turns(matching: query).contains(where: { $0.id == turn.id }) {
            query = ""
            searchField.stringValue = ""
            refresh()
        }
        turnList.select([turn.id], scroll: true)
        window.makeFirstResponder(turnList.table)
        player.play(from: turn.start)
    }

    @objc private func assignChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AssignChoice else { return }
        let ids = turnList.selectedTurnIDs
        guard !ids.isEmpty else { return }
        switch choice.kind {
        case .target(let target): perform { review in try await review.assign(ids, to: target) }
        case .newSpeaker: newSpeaker(for: ids)
        }
    }

    private func assignSelection(toOrdinal ordinal: Int) {
        let ids = turnList.selectedTurnIDs
        guard !ids.isEmpty, review.isEditable,
              let speaker = review.projection.speakers.first(where: { $0.ordinal == ordinal }) else {
            NSSound.beep()
            return
        }
        perform { review in try await review.assign(ids, to: .speaker(speaker.id)) }
    }

    private func newSpeaker(for ids: [String]) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "New speaker for this turn" : "New speaker for \(ids.count) turns"
        alert.informativeText = "Give the new speaker a name, or leave it empty to name them later."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name (optional)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            self?.perform { review in try await review.assign(ids, to: .newSpeaker(name: name)) }
        }
    }

    @objc private func splitTurn() {
        guard let turn = turnList.selectedTurns.first, turnList.selectedTurns.count == 1 else { return }
        let words = review.words(of: turn.id)
        guard words.count > 1 else { return }
        let sheet = SplitSheet(words: words, onPlay: { [weak self] seconds in self?.player.play(from: seconds) })
        splitSheet = sheet
        window.beginSheet(sheet.panel) { [weak self] response in
            guard let self else { return }
            self.splitSheet = nil
            guard response == .OK, let word = sheet.splitWord else { return }
            let turnID = turn.id
            self.perform { review in try await review.split(turnID: turnID, at: word.ref) }
        }
    }

    @objc private func undo() {
        perform { review in try await review.undo() }
    }

    @objc private func confirmAll() {
        perform { review in try await review.confirmAllSuggestions() }
    }

    @objc private func findMoreSpeakers() {
        guard let minimum = review.findMoreSpeakersMinimum else { return }
        let alert = NSAlert()
        alert.messageText = "Find more speakers?"
        alert.informativeText = "Holos labels the speakers of this meeting again, asking for at least \(minimum) "
            + "speakers. This takes a minute or two. Names you gave carry over to the new speakers that share the "
            + "most speech with them. Turn-level changes (moved or split turns, speakers you added) do not carry "
            + "over, and Undo cannot go back past this."
        alert.addButton(withTitle: "Find More Speakers")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.perform { review in try await review.findMoreSpeakers() }
        }
    }

    @objc private func labelMicrophoneSpeakers() {
        let alert = NSAlert()
        alert.messageText = "Label the speakers on your microphone?"
        alert.informativeText = "This call was labelled with your microphone as you alone. Holos labels its speakers "
            + "again and also splits your microphone into speakers, for people in the room with you. Names carry "
            + "over; turn-level changes do not, and Undo cannot go back past this."
        alert.addButton(withTitle: "Label Speakers")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.perform { review in try await review.labelMicrophoneSpeakers() }
        }
    }

    @objc private func labelAgain() {
        perform { review in try await review.labelAgain() }
    }

    @objc private func showStaleEdits() {
        var reasons: [String: Int] = [:]
        for edit in review.projection.staleEdits { reasons[edit.reason, default: 0] += 1 }
        let lines = reasons.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value) × \($0.key)" }
        let alert = NSAlert()
        alert.messageText = "Changes that could not be applied"
        alert.informativeText = "These saved changes no longer match the labels (usually made from an older view, "
            + "or from the command line), so they are not in effect:\n\n" + lines.joined(separator: "\n")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func learnChanged() {
        review.learnVoices = learnBox.state == .on
    }

    // MARK: - Export

    @objc private func saveAs() {
        let panel = NSSavePanel()
        let formats = NSPopUpButton()
        formats.addItems(withTitles: ["Markdown (.md)", "Plain text (.txt)", "JSON (.json)"])
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Format:"), formats])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.fileName(review.sessionName) + ".md"
        panel.canCreateDirectories = true
        let chooser = ExportFormatChooser(panel: panel, popup: formats)
        formats.target = chooser
        formats.action = #selector(ExportFormatChooser.changed)
        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(chooser) {}
            guard response == .OK, let destination = panel.url else { return }
            let format = ExportFormatChooser.format(at: formats.indexOfSelectedItem)
            self?.perform { review in
                let data = try await review.render(format)
                try await Task.detached {
                    let target = destination.deletingLastPathComponent().resolvingSymlinksInPath()
                        .appendingPathComponent(destination.lastPathComponent)
                    try AtomicFile.write(data, to: target, permissions: 0o600)
                }.value
            }
        }
    }

    @objc private func copyMarkdown() {
        perform { review in
            let data = try await review.render(.md)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        }
    }

    // MARK: - Search

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        query = searchField.stringValue
        refresh()
        if let first = turnList.turns.first, turnList.selectedTurnIDs.isEmpty {
            turnList.select([first.id], scroll: true)
        }
    }

    // MARK: - Keys

    /// Shortcuts of the window (Holos has no main menu to carry them).
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let editingText = window.firstResponder is NSTextView
        if flags == [.command, .shift], key == "z" {
            return editingText && NSApplication.shared.sendAction(Selector(("redo:")), to: nil, from: window)
        }
        guard flags == [.command] else { return false }
        switch key {
        case "'":
            nextUncertain()
            return true
        case "f":
            window.makeFirstResponder(searchField)
            return true
        case "e":
            exportPopUp.performClick(nil)
            return true
        case "w":
            window.performClose(nil)
            return true
        case "z":
            if editingText { return NSApplication.shared.sendAction(Selector(("undo:")), to: nil, from: window) }
            undo()
            return true
        case "x":
            return editingText && NSApplication.shared.sendAction(#selector(NSText.cut(_:)), to: nil, from: window)
        case "c":
            return editingText && NSApplication.shared.sendAction(#selector(NSText.copy(_:)), to: nil, from: window)
        case "v":
            return editingText && NSApplication.shared.sendAction(#selector(NSText.paste(_:)), to: nil, from: window)
        case "a":
            return editingText
                && NSApplication.shared.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: window)
        default:
            return false
        }
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) {
        // Back from elsewhere (a terminal, Meetings): pick up changes made meanwhile.
        if let resigned = resignedKeyAt, Date().timeIntervalSince(resigned) > 2, window.attachedSheet == nil {
            reloadLabels()
        }
        resignedKeyAt = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if window.attachedSheet == nil { resignedKeyAt = Date() }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        beginClosing()
    }

    private func beginClosing() {
        guard closeTask == nil else { return }
        player.invalidate()
        review.onChange = nil
        let review = self.review
        closeTask = Task { [weak self] in
            await review.close()
            guard let self else { return }
            let onClose = self.onClose
            self.onClose = nil
            self.onRelabel = nil
            onClose?()
        }
    }

    /// A file name from the meeting name: no slashes or colons, at most 100 characters.
    private static func fileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }
        let text = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Transcript" : String(text.prefix(100))
    }
}

/// The review window; it handles its own shortcuts first.
final class ReviewKeyWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps the save panel's extension in step with the chosen export format.
@MainActor
private final class ExportFormatChooser: NSObject {
    private weak var panel: NSSavePanel?
    private weak var popup: NSPopUpButton?

    init(panel: NSSavePanel, popup: NSPopUpButton) {
        self.panel = panel
        self.popup = popup
    }

    static func format(at index: Int) -> ExportFormat {
        switch index {
        case 1: .txt
        case 2: .json
        default: .md
        }
    }

    @objc func changed() {
        guard let panel, let popup else { return }
        let format = Self.format(at: popup.indexOfSelectedItem)
        let type: UTType = switch format {
        case .txt: .plainText
        case .json: .json
        case .md: UTType(filenameExtension: "md") ?? .plainText
        }
        panel.allowedContentTypes = [type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + format.rawValue
    }
}

/// Where to split a turn: the turn's words in a read-only text; a click puts the caret where the second part
/// starts. "Play from Here" plays from that word.
@MainActor
private final class SplitSheet: NSObject, NSTextViewDelegate {
    let panel: NSPanel
    private let words: [ReviewWord]
    /// Each word's range in the shown text.
    private var ranges: [NSRange] = []
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView {
        // `scrollableTextView()` always holds a text view.
        scroll.documentView as? NSTextView ?? NSTextView()
    }
    private let hint = NSTextField(labelWithString: "")
    private let splitButton = NSButton(title: "Split", target: nil, action: nil)
    private let playButton = NSButton(title: "Play from Here", target: nil, action: nil)
    private let onPlay: (Double) -> Void

    /// The first word of the second part, when the caret is after the turn's first word.
    private(set) var splitWord: ReviewWord?

    init(words: [ReviewWord], onPlay: @escaping (Double) -> Void) {
        self.words = words
        self.onPlay = onPlay
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled],
                        backing: .buffered, defer: true)
        super.init()
        var text = ""
        for word in words {
            if !text.isEmpty { text += " " }
            let location = (text as NSString).length
            text += word.text
            ranges.append(NSRange(location: location, length: (word.text as NSString).length))
        }
        let title = NSTextField(labelWithString: "Click in the text where the second part starts.")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let textView = self.textView
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        splitButton.keyEquivalent = "\r"
        splitButton.target = self
        splitButton.action = #selector(split)
        playButton.target = self
        playButton.action = #selector(play)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [playButton, NSView(), cancel, splitButton])
        let stack = NSStackView(views: [title, scroll, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        panel.contentView = content
        panel.initialFirstResponder = textView
        update()
    }

    func textViewDidChangeSelection(_ notification: Notification) { update() }

    /// The word containing the caret (or the next one after it) starts the second part; never the first word.
    private func update() {
        let caret = textView.selectedRange().location
        let index = ranges.firstIndex { $0.location + $0.length > caret }
        if let index, index > 0 {
            splitWord = words[index]
            hint.stringValue = "The second part starts at “\(words[index].text)” (\(TimeFormat.clock(words[index].start)))."
        } else {
            splitWord = nil
            hint.stringValue = "Click after the first word, where the second part starts."
        }
        splitButton.isEnabled = splitWord != nil
        playButton.isEnabled = true
    }

    @objc private func split() {
        guard splitWord != nil else { return }
        panel.sheetParent?.endSheet(panel, returnCode: .OK)
    }

    @objc private func cancel() {
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }

    @objc private func play() {
        let caret = textView.selectedRange().location
        let index = ranges.firstIndex { $0.location + $0.length > caret } ?? 0
        onPlay(words[index].start)
    }
}
