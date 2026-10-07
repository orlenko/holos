import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers
import HolosStorage
import UniformTypeIdentifiers

/// A review window as quitting closes it (`ReviewQuit`).
@MainActor
protocol ClosingReview: AnyObject {
    /// Closes it without waiting; the edit its open field holds is queued to be saved at once.
    func startClosing()
    /// Waits until it is closed and its changes are saved.
    func closeAndWait() async
}

/// Quitting with review windows open (docs/meeting-design.md §5.10, "Editing words").
enum ReviewQuit {
    /// Every review starts closing at once, so each queues the edit its open field holds before any slow close (a
    /// voice sync of another review) is waited for; then they are awaited together, at most `limit`. True when all
    /// closed in time.
    @MainActor
    static func closeAll(_ reviews: [any ClosingReview], limit: Duration) async -> Bool {
        for review in reviews { review.startClosing() }
        let closing = Task { @MainActor in
            for review in reviews { await review.closeAndWait() }
        }
        return await waitAtMost(limit, for: closing)
    }
}

/// Closing a review window by hand (its close button, ⌘W) with an edit typed in its field: the window stays open until
/// the edit is saved, and stays open when it is not, so a save that fails (a full disk) never loses what was typed.
/// Quitting, and closing before a meeting is deleted, never come here (`ClosingReview.startClosing` closes the window
/// directly): they keep their bounded wait, and log what was typed when it could not be saved.
@MainActor
final class ReviewCloseGate {
    /// The edit typed when the close was asked for is being saved: another close waits for it.
    private(set) var saving = false

    /// Whether the window may close now. With an edit typed (`typed`), no: `save` saves it (nil when saved, else why,
    /// with what was typed); then `close` closes the window, or `keep` opens the field again with what was typed and
    /// shows why, and the window stays.
    func shouldClose(typed: Bool, save: @escaping () async -> String?, close: @escaping () -> Void,
                     keep: @escaping (String) -> Void) -> Bool {
        if saving { return false }
        guard typed else { return true }
        saving = true
        Task { @MainActor in
            let refusal = await save()
            saving = false
            if let refusal { keep(refusal) } else { close() }
        }
        return false
    }
}

/// The transcript review window (docs/meeting-design.md §5.10): name the speakers of a meeting, play their audio,
/// reassign, merge, split, confirm suggestions in bulk, find more speakers, undo, and export. The model is
/// `ReviewSession` (HolosMeeting); this file only arranges views and routes actions to it. Every change shows at once
/// and saves in the background; errors appear in the footer.
///
/// Holos has no main menu, so the "Speakers" menu is a pull-down in the window's toolbar and the window handles its
/// own shortcuts: Space (or K) play/pause, ←/→ (or J/L) back and ahead 5 seconds, and ⌘←/⌘→ the previous and next
/// turn, anywhere but while typing in a text field; 1–9 assign (in the turn list), ⌘' next uncertain, ⌘Z undo,
/// ⌘F search, ⌘E edit mode (word clicks edit words), ⇧⌘E export, and the usual editing keys in text fields.
///
/// The playback bar above the footer holds Play/Pause, the position, a scrubber, the speed, and who is speaking.
/// Playing goes on through the meeting until paused; a click on a timestamp or on a word plays from there. While a
/// meeting plays, the turn list tints the turn and word playing and keeps them in view, except for a few seconds after
/// the reader scrolls it (`ReviewFollow`).
@MainActor
final class ReviewWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate, ClosingReview {
    let sessionID: String
    let review: ReviewSession
    /// Called once the window has closed and its changes are saved.
    var onClose: (() -> Void)?
    /// Called with true when a relabel starts from the window and false when it ends.
    var onRelabel: ((Bool) -> Void)?
    /// The meeting's title as the Meetings list shows it (`MeetingNaming.currentTitle`): the window's title, and the
    /// name Save As… suggests. A rename in the list sets it.
    var meetingTitle: String {
        didSet { window.title = "\(meetingTitle) — Review" }
    }

    private let window: ReviewKeyWindow
    private let player = ReviewPlayer()
    private let sidebar = SpeakerSidebarView()
    private let turnList = TurnListView()
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let speedPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speakingLabel = NSTextField(labelWithString: "")
    /// The scrubber is being dragged: the play head does not move it meanwhile.
    private var scrubbing = false
    /// Playback started at least once (the turn list tints what plays only from then on, paused included).
    private var played = false
    private var follow = ReviewFollow()
    private var announcer = ReviewSpeakerAnnouncer()
    private let nextUncertainButton = NSButton(title: "Next Uncertain", target: nil, action: nil)
    private let assignPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let splitButton = NSButton(title: "Split Turn", target: nil, action: nil)
    private let speakersPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let searchField = NSSearchField()
    private let exportPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let screenTextButton = NSButton(title: "Screen Text…", target: nil, action: nil)
    /// Edit mode (⌘E): word clicks edit the words instead of playing from them (docs/meeting-design.md §5.10,
    /// "Editing words").
    private let editButton = NSButton(title: "Edit Words", target: nil, action: nil)
    private let editBanner = EditModeBanner()
    /// The window's column of bars and panes, and the banner's width in it (made again each time the banner shows: a
    /// hidden arranged view leaves the stack, and its constraints with it).
    private weak var contentStack: NSStackView?
    private var bannerWidth: NSLayoutConstraint?
    /// A name or term the last word edit may have taught, offered for the word list until the next action.
    private var offeredTerm: (term: String, heardAs: String?)?
    /// The word list, as the app keeps it: a term's "often heard as" phrases (nil when the list does not have it), and
    /// adding a term with what it is often heard as (returns what happened). Nil: no word list offers.
    var wordListHeardAs: ((String) -> [String]?)?
    var addWordListTerm: ((_ term: String, _ heardAs: String?) -> String)?
    private var screenTextPanel: ScreenTextPanel?
    private var screenOCRTask: Task<Void, Never>?
    private let learnBox = NSButton(checkboxWithTitle: "Learn voices of people I name in this meeting", target: nil,
                                    action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let notices = NSStackView()
    /// The last action's error, until the next action.
    private var problem: String?
    /// What the last action did, when it says so (a term added to the word list), until the next action.
    private var notice: String?
    private var query = ""
    /// Where "Split Turn" broke a paragraph without splitting a turn: the window's view only, never saved; kept with
    /// its turn on its run and through this window's word-fix reverts, dropped by any other new run (a relabel).
    private var paragraphBreaks = ReviewParagraphBreaks()
    private var positioned = false
    /// The player state the sidebar and the footer last showed.
    private var shownPlayerState = StateChangeTracker<ReviewPlayer.State>()
    private var resignedKeyAt: Date?
    private var closeTask: Task<Void, Never>?
    /// A close by hand waits for the edit typed in the field to be saved (`windowShouldClose`).
    private let closeGate = ReviewCloseGate()
    /// Word edits the field handed over that are still saving (`editWords`): each ends with why it was not saved, nil
    /// when it was. A close by hand waits for them too.
    private var pendingWordEdits: [UUID: Task<String?, Never>] = [:]
    /// The field's edit a close by hand took and has not queued yet (it waits for the edits before it).
    private var heldOpenEdit: OpenWordEdit?

    /// Words can be edited in the window now: the review allows it, and no close by hand is saving the edits before
    /// it closes (no field opens meanwhile, so nothing typed then can be left behind by the close).
    private var canEditWordsNow: Bool { review.canEditWords && !closeGate.saving }
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
    private lazy var autoMergeItem = menuItem("Merge Matching Voices Automatically", #selector(toggleAutoMerge))
    /// "Merge Matching Voices Automatically" (off unless the user turned it on), kept across windows.
    static let autoMergeKey = "reviewAutoMergeVoices"
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Opens the review of a labelled meeting (the labels are loaded off the main actor first).
    static func open(sessionID: String, session: URL, maintenance: MaintenanceLauncher?) async throws -> ReviewWindow {
        let review = try await ReviewSession(session: session, profiles: SpeakerProfileStore(), maintenance: maintenance,
                                             analyseVoices: true, pendingVoices: PendingVoiceSamples())
        review.autoMergeVoices = UserDefaults.standard.bool(forKey: autoMergeKey)
        let title = await Task.detached { MeetingNaming.currentTitle(session: session) }.value
        return ReviewWindow(sessionID: sessionID, review: review, title: title)
    }

    init(sessionID: String, review: ReviewSession, title: String? = nil) {
        self.sessionID = sessionID
        self.review = review
        meetingTitle = title ?? review.sessionName
        window = ReviewKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                                 defer: true)
        super.init()
        window.title = "\(meetingTitle) — Review"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.playbackKeyHandler = { [weak self] event in self?.handlePlaybackKey(event) ?? false }
        player.rate = ReviewPlaybackSpeed.load(from: .standard)
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
    func pauseForMaintenance(_ hold: ReviewMaintenance.Hold, banner: String) async {
        // The review turns read-only, so the open edit field closes: what it holds is saved first, never lost.
        let typed = turnList.takeOpenWordEdit().map { open in
            ReviewSession.TypedEdit(words: open.words.map(\.ref), text: open.text, seenMoves: open.movesSeen,
                                    expected: open.words.map(\.shown))
        }
        player.invalidate()
        refresh()
        if let unsaved = await review.pause(hold, reason: banner, typed: typed) {
            problem = unsaved
            refreshFooter()
        }
    }

    /// The command ended: the transcript, the labels, and playback are read again from disk, and the window is
    /// editable again (unless another command run holds it meanwhile).
    func resumeAfterMaintenance(_ hold: ReviewMaintenance.Hold) async {
        await review.resume(hold)
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
        startClosing()
        await closeTask?.value
    }

    /// Closes the window without waiting: its open edit field's text is queued to be saved at once (`beginClosing`).
    func startClosing() {
        // A minimized window is not visible but must be closed too, or it stays in the Dock.
        if window.isVisible || window.isMiniaturized { window.close() }
        if closeTask == nil { beginClosing() }
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        nextUncertainButton.bezelStyle = .push
        nextUncertainButton.toolTip = "Select and play the next uncertain turn (⌘')"
        assignPopUp.toolTip = "Give the selected turns to a speaker (or press 1–9 in the turn list)"
        splitButton.bezelStyle = .push
        splitButton.toolTip = "Split the selected text in two where a new speaker starts"
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        exportPopUp.toolTip = "Save or copy the transcript (⇧⌘E)"
        screenTextButton.target = self; screenTextButton.action = #selector(showScreenText)
        screenTextButton.bezelStyle = .push
        screenTextButton.toolTip = "Read saved screen OCR and unverified vocabulary candidates; never adds words automatically"
        editButton.bezelStyle = .push
        editButton.setButtonType(.pushOnPushOff)
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editButton.imagePosition = .imageLeading
        editButton.toolTip = Self.editWordsHelp
        editButton.target = self
        editButton.action = #selector(toggleEditMode)
        let toolbar = NSStackView(views: [nextUncertainButton, assignPopUp, splitButton, speakersPopUp, editButton,
                                          NSView(), screenTextButton, searchField, exportPopUp])
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

        let playbackBar = makePlaybackBar()
        editBanner.isHidden = true
        let stack = NSStackView(views: [toolbar, editBanner, split, playbackBar, footer, notices])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The panes take the height; the bars keep theirs.
        for bar in [toolbar, footer, notices] { bar.setHuggingPriority(.defaultHigh, for: .vertical) }
        editBanner.setContentHuggingPriority(.defaultHigh, for: .vertical)
        playbackBar.setContentHuggingPriority(.defaultHigh, for: .vertical)
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
            playbackBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notices.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        split.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentStack = stack
        return content
    }

    /// Play/Pause, "12:04 / 1:28:30", the scrubber, the speed, and who is speaking, in a band across the window.
    private func makePlaybackBar() -> NSView {
        playButton.bezelStyle = .push
        playButton.controlSize = .large
        playButton.imagePosition = .imageLeading
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.toolTip = "Play or pause (Space)"
        playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        scrubber.isContinuous = true
        scrubber.controlSize = .regular
        scrubber.toolTip = "Drag to move through the meeting (← and → move 5 seconds, ⌘← and ⌘→ a turn)"
        scrubber.setAccessibilityLabel("Playback position")
        scrubber.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        for rate in ReviewPlaybackSpeed.rates {
            speedPopUp.addItem(withTitle: ReviewPlaybackSpeed.title(rate))
            speedPopUp.lastItem?.representedObject = rate
        }
        speedPopUp.toolTip = "Playback speed"
        speedPopUp.setAccessibilityLabel("Playback speed")
        speakingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        speakingLabel.lineBreakMode = .byTruncatingTail
        speakingLabel.setAccessibilityLabel("Speaking")
        speakingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        speakingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let speakingWidth = speakingLabel.widthAnchor.constraint(equalToConstant: 220)
        speakingWidth.priority = .defaultLow
        speakingWidth.isActive = true

        let row = NSStackView(views: [playButton, timeLabel, scrubber, speedPopUp, speakingLabel])
        row.spacing = 12
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        let bar = PlaybackBarView()
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.group)
        bar.setAccessibilityLabel("Playback")
        bar.addSubview(row)
        // The controls give the bar its height.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    private func wire() {
        playButton.target = self
        playButton.action = #selector(togglePlay)
        scrubber.target = self
        scrubber.action = #selector(scrubbed(_:))
        speedPopUp.target = self
        speedPopUp.action = #selector(speedChosen(_:))
        if let index = ReviewPlaybackSpeed.rates.firstIndex(of: player.rate) { speedPopUp.selectItem(at: index) }
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
        autoMergeItem.toolTip = "After you name a speaker, merge other speakers whose voice is all but the same into "
            + "them (one Undo takes it back). Off: they are only suggested."
        speakersMenu.addItem(autoMergeItem)
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
            guard let self, self.player.isReady else { return }
            self.played = true
            self.player.play(clips: self.review.sampleClips(for: speakerID))
        }
        sidebar.onMarkSelf = { [weak self] speakerID in
            self?.perform { review in try await review.markSelf(speakerID: speakerID) }
        }
        sidebar.onMerge = { [weak self] from, into in
            self?.perform { review in try await review.merge(from, into: into) }
        }
        sidebar.onReject = { [weak self] speakerID, profileID in
            self?.perform { review in try await review.rejectSuggestion(speakerID: speakerID, profileID: profileID) }
        }
        sidebar.onConfirmAll = { [weak self] in self?.confirmAll() }
        review.speakerBeingNamed = { [weak self] in self?.sidebar.focusedSpeakerID }

        turnList.onAcceptHint = { [weak self] turnID in
            self?.perform { review in try await review.acceptTurnHint(turnID) }
        }
        turnList.onPlay = { [weak self] seconds in self?.play(from: seconds) }
        turnList.onRevertFix = { [weak self] word in self?.revertFix(word) }
        turnList.onEditWords = { [weak self] words, text, addTerm, movesSeen in
            self?.editWords(words, to: text, addTerm: addTerm, movesSeen: movesSeen)
        }
        turnList.onEditMessage = { [weak self] message in self?.editBanner.show(message: message) }
        // The review turned read-only with a field open (an earlier edit's labels could not be reread, say): its edit
        // is queued all the same, and waits for the reread as the changes before it do.
        turnList.onKeepWordEdit = { [weak self] words, text, movesSeen in
            self?.editWords(words, to: text, addTerm: false, movesSeen: movesSeen, whileUnread: true)
        }
        turnList.onRequestEditing = { [weak self] in
            guard let self, self.review.canEditWords else { return }
            self.setEditMode(true)
        }
        turnList.editText = { [review] words in review.shownText(of: words.map(\.ref)) }
        turnList.editRefusal = { [review] words in review.wordEditRefusal(words.map(\.ref)) }
        turnList.revertRefusal = { [review] word in review.revertRefusal(word) }
        turnList.onUserScroll = { [weak self] in
            self?.follow.userScrolled(at: ProcessInfo.processInfo.systemUptime)
        }
        turnList.onAssign = { [weak self] ids, target in
            self?.perform { review in try await review.assign(ids, to: target) }
        }
        turnList.onNewSpeaker = { [weak self] ids in self?.newSpeaker(for: ids) }
        turnList.onSelectionChange = { [weak self] in self?.refreshToolbar() }
        turnList.table.onReturn = { [weak self] in
            guard let self, let turn = self.turnList.selectedTurns.first else { return }
            self.play(from: turn.start)
        }
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
        // A run a word edit or its undo published keeps the turns, and with them the window's paragraph breaks.
        let runID = projection.runID
        var paragraphs = ReviewParagraphs.group(
            projection.turns, breaks: paragraphBreaks.active(in: projection.turns, runID: runID,
                                                             keepsTurnsOf: { [review] old in
                                                                 review.keepsTurns(of: old, in: runID)
                                                             }))
        // A search shows the paragraphs with a matching turn, whole.
        if !query.isEmpty {
            let matching = Set(review.turns(matching: query).map(\.id))
            paragraphs = paragraphs.filter { $0.turnIDs.contains(where: matching.contains) }
        }
        let people = review.knownPeople()
        turnList.update(paragraphs: paragraphs, speakers: projection.speakers, people: people,
                        editable: review.isEditable,
                        hints: review.profiles == nil ? [:] : review.voiceMatches.turnHints,
                        text: { [review] turn in review.text(of: turn) },
                        words: { [review] turn in review.words(of: turn) },
                        resolve: { [review] id in review.resolvedTurnID(id) }, wordMoves: review.shownWordMoves)
        sidebar.update(rows: sidebarRows(), people: people, editable: review.isEditable,
                       suggestions: review.suggestionCount)
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
                suggestion: review.suggestion(for: speaker.id),
                suggestionFromVoice: review.voiceSuggestion(for: speaker.id) != nil,
                canPlay: player.isReady && !review.sampleClips(for: speaker.id).isEmpty)
        }
    }

    private func refreshPlayback() {
        let playing = player.isPlaying
        let title = playing ? "Pause" : "Play"
        if playButton.title != title {
            playButton.title = title
            playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                       accessibilityDescription: nil)
            playButton.setAccessibilityLabel(title)
        }
        playButton.isEnabled = player.isReady
        // The audio's own length once it is ready (chunks missing at the end make it shorter than the meeting), so the
        // scrubber never offers a place playback cannot reach.
        let total = player.isReady && player.duration > 0 ? player.duration : review.durationSeconds
        // A drag that ended without a last action (the button came up elsewhere) ends here.
        if scrubbing, NSEvent.pressedMouseButtons & 1 == 0 { scrubbing = false }
        let shownTime = scrubbing ? scrubber.doubleValue : player.currentTime
        let position = TimeFormat.compact(shownTime) + " / " + TimeFormat.duration(total)
        if timeLabel.stringValue != position { timeLabel.stringValue = position }
        scrubber.isEnabled = player.isReady
        if scrubber.maxValue != max(1, total) { scrubber.maxValue = max(1, total) }
        if !scrubbing { scrubber.doubleValue = player.currentTime }
        scrubber.setAccessibilityValueDescription(TimeFormat.compact(shownTime) + " of " + TimeFormat.duration(total))
        refreshFollowing()
        // Every change of the player's state (loading, ready, off and why) redraws what depends on it: the sidebar's
        // play buttons and the footer's "Playback is off" notice.
        if shownPlayerState.update(player.state) {
            sidebar.update(rows: sidebarRows(), people: review.knownPeople(), editable: review.isEditable,
                           suggestions: review.suggestionCount)
            refreshFooter()
        }
    }

    /// Who is speaking (in the bar), and the turn list's tint and scroll position, for the play head.
    private func refreshFollowing() {
        guard played, player.isReady else {
            turnList.clearPlaying()
            if !speakingLabel.stringValue.isEmpty { speakingLabel.stringValue = "" }
            announcer.reset()
            return
        }
        let time = player.currentTime
        let turns = review.projection.turns
        let turn = ReviewTimeline.turnIndex(at: time, turns: turns.map { ($0.start, $0.end) }).map { turns[$0] }
        let speaker = turn.map { turn in turn.speakerID.flatMap { review.speaker($0)?.label } ?? "Unknown speaker" }
        let speaking = speaker ?? "—"
        if speakingLabel.stringValue != speaking {
            speakingLabel.stringValue = speaking
            speakingLabel.toolTip = speaker.map { "Speaking now: \($0)" }
        }
        // Kept in view while playing, and when a seek while paused moved to another paragraph (also from a pause in
        // one paragraph to a pause in another, where no turn is spoken at either end) or to another word of the same
        // one (in a paragraph taller than the list, the list follows the word).
        let moved = turnList.showPlaying(turnID: turn?.id, at: time)
        if player.isPlaying || moved, follow.isFollowing(at: ProcessInfo.processInfo.systemUptime) {
            turnList.scrollToPlaying()
        }
        guard player.isPlaying else {
            announcer.reset()
            return
        }
        // VoiceOver hears who speaks when that changes, and nothing else while the audio plays.
        if NSWorkspace.shared.isVoiceOverEnabled, let announcement = announcer.announcement(for: speaker) {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: announcement, .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ])
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
        let paragraphs = turnList.selectedParagraphs
        splitButton.isEnabled = editable && paragraphs.count == 1
            && paragraphs[0].turns.reduce(0) { $0 + review.words(of: $1).count } > 1

        let suggestions = review.suggestionCount
        confirmAllItem.title = suggestions > 0 ? "Confirm All Suggestions (\(suggestions))" : "Confirm All Suggestions"
        confirmAllItem.isEnabled = editable && suggestions > 0 && review.profiles != nil
        autoMergeItem.state = review.autoMergeVoices ? .on : .off
        autoMergeItem.isEnabled = review.profiles != nil
        findMoreItem.isEnabled = editable && review.canFindMoreSpeakers
        microphoneItem.isHidden = !review.canLabelMicrophoneSpeakers
        microphoneItem.isEnabled = editable
        undoItem.isEnabled = editable && review.canUndo
        // Read-only (a command holds the review): edit mode can still be left, not entered.
        editButton.isEnabled = canEditWordsNow || turnList.editingWords
        // Why words cannot be edited (the transcript changed after labelling, or speaker changes cannot be read): the
        // button's tooltip says so before edit mode is entered, and in edit mode (no field opens) the banner does.
        editButton.toolTip = review.wordEditingBlocked ?? Self.editWordsHelp
        turnList.canEditWords = canEditWordsNow
        let blockedMessages = [ReviewSession.labelAgainFirst, ReviewSession.speakerChangesUnreadable,
                               ReviewSession.baseUnreadable].map(\.localizedDescription)
        if turnList.editingWords, let blocked = review.wordEditingBlocked {
            editBanner.show(message: blocked)
        } else if turnList.editingWords, blockedMessages.contains(editBanner.label.stringValue) {
            editBanner.show(message: nil)
        }

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
        if let voices = review.voiceStatus { parts.append(voices) }
        statusLabel.stringValue = parts.joined(separator: " · ")

        var lines: [Notice] = []
        if let reason = review.pauseReason {
            lines.append(Notice(text: reason + " " + ReviewSession.pausedSuffix, color: .systemOrange))
        }
        if let reloadProblem = review.reloadProblem {
            lines.append(Notice(text: "⚠ " + reloadProblem, color: .systemRed, button: "Reread",
                                action: #selector(rereadLabels)))
        }
        if let problem { lines.append(Notice(text: "⚠ " + problem, color: .systemRed)) }
        if let notice { lines.append(Notice(text: notice)) }
        if let offered = offeredTerm {
            let heard = offered.heardAs.map { ", often heard as “\($0)”" } ?? ""
            lines.append(Notice(text: "Add “\(offered.term)” to the word list\(heard)? Voice is Local then expects it "
                                + "in dictation and meetings.", button: "Add to Word List",
                                action: #selector(addOfferedTerm), secondButton: "Not Now",
                                secondAction: #selector(dismissOfferedTerm)))
        }
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
        if let voiceProblem = review.voiceProblem {
            lines.append(Notice(text: "⚠ " + voiceProblem, color: .systemOrange))
        }
        if case .failed(let reason) = review.voiceAnalysis {
            lines.append(Notice(text: "Voices can't be compared in this meeting, so no matching speakers are "
                                + "suggested: " + reason))
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
        var secondButton: String?
        var secondAction: Selector?
    }

    private func addNotice(_ notice: Notice) {
        let label = NSTextField(wrappingLabelWithString: notice.text)
        label.textColor = notice.color
        label.font = .systemFont(ofSize: 12)
        var views: [NSView] = [label]
        for (button, action) in [(notice.button, notice.action), (notice.secondButton, notice.secondAction)] {
            guard let button, let action else { continue }
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
        notice = nil
        offeredTerm = nil
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

    /// Play/Pause (the bar's button, Space, K): pauses, or plays on from the play head (from the start once the
    /// audio ended). The selection does not move it: a timestamp or a word plays from elsewhere.
    @objc private func togglePlay() {
        guard player.isReady else { return }
        if player.isPlaying {
            player.pause()
            return
        }
        played = true
        follow.resume()
        player.togglePlayPause()
    }

    /// Plays from `seconds` on through the meeting (a timestamp, a word, the next uncertain turn).
    private func play(from seconds: Double) {
        guard player.isReady else { return }
        played = true
        follow.resume()
        player.play(from: seconds)
    }

    /// Moves the play head, playing on when playing (the scrubber, ←/→, ⌘←/⌘→).
    private func seek(to seconds: Double) {
        guard player.isReady else { return }
        played = true
        follow.resume()
        player.seek(to: seconds)
    }

    @objc private func showScreenText() {
        guard screenTextButton.isEnabled, window.attachedSheet == nil else { return }
        screenTextButton.isEnabled = false
        let session = review.session, id = sessionID
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try ScreenContextStore.readForReview(session: session, sessionID: id) { try WordListStore().load().terms } }
            }.value
            guard let self, !self.isClosing else { return }
            defer { self.screenTextButton.isEnabled = true }
            switch result {
            case .success(let (record, known)):
                guard let record, !record.frames.isEmpty else {
                    self.problem = "No screen snapshots were saved for this meeting."; self.refresh(); return
                }
                let panel = ScreenTextPanel(record: record, known: known, onSeek: { [weak self] in self?.seek(to: $0) },
                    onRecognize: { [weak self] panel in self?.recognizeNextScreenBatch(panel) })
                self.screenTextPanel = panel
                self.window.beginSheet(panel.window) { [weak self] _ in
                    self?.screenOCRTask?.cancel(); self?.screenOCRTask = nil; self?.screenTextPanel = nil
                }
            case .failure:
                self.problem = "Saved screen text could not be read."; self.refresh()
            }
        }
    }

    private func recognizeNextScreenBatch(_ panel: ScreenTextPanel) {
        guard screenOCRTask == nil else { return }
        panel.setProcessing()
        let session = review.session, id = sessionID
        let languages = review.snapshot.transcript.languages ?? [review.snapshot.transcript.locale]
        screenOCRTask = Task { [weak self, weak panel] in
            let worker = Task.detached(priority: .utility) {
                do {
                    let lease = try SessionArchive.acquireProcessingLease(at: session)
                    defer { lease.release() }
                    return try await lease.withUse(for: session) {
                        guard try !SessionArchive.isActive(at: session) else {
                            throw HolosError.unavailable("This meeting is still recording.")
                        }
                        _ = try await MeetingScreenOCR.processBounded(session: session, sessionID: id, languages: languages)
                        return Result<ScreenContextRecord?, Error>.success(try ScreenContextStore.read(session: session, sessionID: id))
                    }
                } catch { return Result<ScreenContextRecord?, Error>.failure(error) }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, let panel, !self.isClosing, self.screenTextPanel === panel else { return }
            self.screenOCRTask = nil
            switch result {
            case .success(let record?): panel.update(record)
            default: panel.failed("OCR could not continue; another operation may be using this meeting. Try again later.")
            }
        }
    }

    private func previousTurn() {
        seek(to: ReviewTimeline.previousTurnStart(before: player.currentTime,
                                                  starts: review.projection.turns.map(\.start)))
    }

    private func nextTurn() {
        guard player.isReady else { return }
        guard let start = ReviewTimeline.nextTurnStart(after: player.currentTime,
                                                       starts: review.projection.turns.map(\.start)) else {
            NSSound.beep()
            return
        }
        seek(to: start)
    }

    @objc private func scrubbed(_ sender: NSSlider) {
        // Continuous: every step of a drag seeks; the time shown follows the knob until it is let go.
        let type = NSApplication.shared.currentEvent?.type
        scrubbing = type == .leftMouseDown || type == .leftMouseDragged
        seek(to: sender.doubleValue)
        refreshPlayback()
    }

    @objc private func speedChosen(_ sender: NSPopUpButton) {
        guard let rate = sender.selectedItem?.representedObject as? Double else { return }
        player.rate = rate
        ReviewPlaybackSpeed.save(rate, to: .standard)
    }

    @objc private func nextUncertain() {
        guard let turn = review.nextUncertain(after: turnList.selectedTurnIDs.last) else {
            NSSound.beep()
            return
        }
        if !query.isEmpty, !turnList.shows(turnID: turn.id) {
            query = ""
            searchField.stringValue = ""
            refresh()
        }
        turnList.select([turn.id], scroll: true)
        window.makeFirstResponder(turnList.table)
        play(from: turn.start)
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
        // Every turn the change moves (a row may hold several).
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

    /// Splits the selected row before a chosen word (`ReviewParagraphs.split`): the turn holding the word is split,
    /// or, at a word that starts a turn, the paragraph only breaks there.
    @objc private func splitTurn() {
        let selected = turnList.selectedParagraphs
        guard selected.count == 1, let paragraph = selected.first else { return }
        let words = paragraph.turns.map { review.words(of: $0) }
        guard words.joined().count > 1 else { return }
        var turnStarts = Set<Int>()
        var offset = 0
        for turnWords in words {
            if offset > 0, !turnWords.isEmpty { turnStarts.insert(offset) }
            offset += turnWords.count
        }
        let sheet = SplitSheet(words: Array(words.joined()), turnStarts: turnStarts,
                               onPlay: { [weak self] seconds in self?.play(from: seconds) })
        // A word edit saved while the sheet is open moves its words: the split follows them (`split(seenMoves:)`).
        let movesSeen = review.shownWordMoves.count
        splitSheet = sheet
        window.beginSheet(sheet.panel) { [weak self] response in
            guard let self else { return }
            self.splitSheet = nil
            guard response == .OK, let index = sheet.splitIndex,
                  let split = ReviewParagraphs.split(paragraph, words: words, at: index) else { return }
            switch split {
            case .splitTurn(let turnID, let word):
                self.perform { review in try await review.split(turnID: turnID, at: word, seenMoves: movesSeen) }
            case .breakBefore(let turnID):
                guard let turn = paragraph.turns.first(where: { $0.id == turnID }) else { return }
                self.paragraphBreaks.insert(before: turn, runID: self.review.projection.runID)
                self.refresh()
                self.turnList.select([turnID], scroll: true)
            }
        }
    }

    /// Reverts a word fix. It publishes a new run with the same turns, whose estimated starts may move, so the
    /// window's paragraph breaks are carried over by turn until it (and any other revert in flight) ends.
    private func revertFix(_ word: WordRef) {
        paragraphBreaks.beginCarryOver()
        perform { [weak self] review in
            defer { self?.endBreakCarryOver() }
            try await review.revertWordFix(word)
        }
    }

    // MARK: - Editing words

    /// Edit Words (the toolbar toggle, ⌘E): on only while the review is editable (not while a command holds it
    /// read-only); off always.
    @objc private func toggleEditMode() {
        let next = Self.editModeAfterToggle(on: turnList.editingWords, editable: canEditWordsNow)
        if next == turnList.editingWords {
            NSSound.beep()
            editButton.state = next ? .on : .off
            return
        }
        setEditMode(next)
    }

    /// The Edit Words button's tooltip while words can be edited.
    static let editWordsHelp = "Edit the transcript's words: click a word to change it (⌘E)"

    /// Edit mode after a toggle from `on`: it turns off whenever asked, and on only while `editable`.
    static func editModeAfterToggle(on: Bool, editable: Bool) -> Bool {
        on ? false : editable
    }

    /// Turns edit mode on or off: the toggle, the banner, and the turn list (an open field closes unsaved when it
    /// turns off). Playback keys work either way; word clicks play only with it off.
    func setEditMode(_ on: Bool) {
        turnList.editingWords = on
        editButton.state = on ? .on : .off
        editButton.setAccessibilityValue(on ? "on" : "off")
        editBanner.show(message: nil)
        editBanner.isHidden = !on
        bannerWidth?.isActive = false
        bannerWidth = nil
        if on, let stack = contentStack {
            let width = editBanner.widthAnchor.constraint(equalTo: stack.widthAnchor)
            width.isActive = true
            bannerWidth = width
        }
        if on, NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: "Editing words", .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
        if !on { window.makeFirstResponder(turnList.table) }
    }

    /// Edit mode is on.
    var isEditingWords: Bool { turnList.editingWords }

    /// Saves an edit made in the turn list. Its new run keeps the turns, as does its undo's (`ReviewSession.keepsTurns`),
    /// so the window's paragraph breaks stay (`refresh`). Once saved, a new text that looks like a name or term is
    /// offered for the word list (with ⌥Return it is added at once). Tracked until it ends (`pendingWordEdits`), so
    /// closing the window by hand waits for it, and stays open when it is not saved.
    private func editWords(_ words: [ReviewWord], to text: String, addTerm: Bool, movesSeen: Int,
                           whileUnread: Bool = false) {
        offeredTerm = nil
        problem = nil
        notice = nil
        refreshFooter()
        let id = UUID()
        let saving: Task<String?, Never> = Task { [weak self] () async -> String? in
            guard let self else { return nil }
            let refusal: String? = await self.saveEdit(words, to: text, addTerm: addTerm, movesSeen: movesSeen,
                                                       whileUnread: whileUnread)
            self.pendingWordEdits[id] = nil
            return refusal
        }
        pendingWordEdits[id] = saving
    }

    /// `editWords`' save: nil when saved (also when its labels could not be reread after it: the edit stands, and
    /// ⌥Return's term is still added), else why, with what was typed (the field opens again with it when its words are
    /// still there). Made on the words as the field showed them: never over words changed elsewhere since.
    private func saveEdit(_ words: [ReviewWord], to text: String, addTerm: Bool, movesSeen: Int,
                          whileUnread: Bool) async -> String? {
        var saved = false
        let committed: (ReviewWordEdit) -> Void = { [weak self] edit in
            saved = true
            self?.offerTerm(after: edit, add: addTerm)
        }
        do {
            _ = try await review.editWords(words.map(\.ref), to: text, seenMoves: movesSeen, whileUnread: whileUnread,
                                           expecting: words.map(\.shown), committed: committed)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            if saved {
                problem = error.localizedDescription
                refreshFooter()
                return nil
            }
            let message = Self.withTyped(error.localizedDescription, text)
            turnList.reopenWordEdit(words, typed: text, message: message)
            problem = message
            refreshFooter()
            return message
        }
    }

    /// `message` with what was typed, unless it says it already.
    private static func withTyped(_ message: String, _ text: String) -> String {
        let typed = TranscriptWordEdit.cleaned(text)
        return message.contains("“\(typed)”") ? message : message + " What you typed: “\(typed)”."
    }

    /// After a saved edit: with `add` (⌥Return), its new text goes into the word list now, with what the recognizer
    /// wrote as "often heard as"; otherwise a new text that looks like a name or term is offered in the footer, unless
    /// the list has it with that phrase already.
    private func offerTerm(after edit: ReviewWordEdit, add: Bool) {
        guard !edit.deletion, let adder = addWordListTerm else { return }
        let dictionary: (String) -> Bool = { word in
            NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0).location == NSNotFound
        }
        guard let offer = Self.wordListTerm(after: edit, add: add, isDictionaryWord: dictionary) else { return }
        let term = offer.term
        let heardAs = offer.heardAs
        if add {
            notice = adder(term, heardAs)
            refreshFooter()
            return
        }
        if let known = wordListHeardAs?(term),
           heardAs.map({ phrase in known.contains { $0.caseInsensitiveCompare(phrase) == .orderedSame } }) ?? true {
            return
        }
        offeredTerm = (term, heardAs)
        refreshFooter()
    }

    /// The word-list term a saved edit gives (with `add`, ⌥Return: what was typed, as it is; else what was typed when
    /// it looks like a name or term) and its "often heard as" phrase. Only what was typed, never the words the edit
    /// took in around it ("Yorkshire", not "New Yorkshire", when only "York" of an automatic "New York" was edited);
    /// "often heard as" only when the recognizer's text for exactly those words is known.
    static func wordListTerm(after edit: ReviewWordEdit, add: Bool,
                             isDictionaryWord: (String) -> Bool) -> (term: String, heardAs: String?)? {
        let typed = edit.typed ?? edit.meant
        let heard = edit.typed == nil ? edit.heard : edit.typedHeard
        let term = add
            ? WordList.typedTerm(typed)
            : TranscriptEditLearning.term(heard: heard ?? "", meant: typed, isDictionaryWord: isDictionaryWord)
        guard let term, !term.isEmpty else { return nil }
        return (term, heard.flatMap { TranscriptEditLearning.heardAs(heard: $0, term: term) })
    }

    @objc private func addOfferedTerm() {
        guard let offered = offeredTerm, let adder = addWordListTerm else { return }
        offeredTerm = nil
        notice = adder(offered.term, offered.heardAs)
        refreshFooter()
    }

    @objc private func dismissOfferedTerm() {
        offeredTerm = nil
        refreshFooter()
    }

    private func endBreakCarryOver() {
        paragraphBreaks.endCarryOver(turns: review.projection.turns, runID: review.projection.runID)
        refresh()
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
        alert.informativeText = "Voice is Local labels the speakers of this meeting again, asking for at least \(minimum) "
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
        alert.informativeText = "This call was labelled with your microphone as you alone. Voice is Local labels its speakers "
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

    /// The labels could not be reread after a change (`ReviewSession.reloadProblem`): try again.
    @objc private func rereadLabels() {
        perform { review in await review.reload() }
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

    @objc private func toggleAutoMerge() {
        review.autoMergeVoices.toggle()
        UserDefaults.standard.set(review.autoMergeVoices, forKey: Self.autoMergeKey)
        refreshToolbar()
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
        panel.nameFieldStringValue = Self.fileName(meetingTitle) + ".md"
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
        if let first = turnList.paragraphs.first, turnList.selectedTurnIDs.isEmpty {
            turnList.select([first.id], scroll: true)
        }
    }

    // MARK: - Keys

    /// Playback keys, anywhere in the window but while typing in a text field (or a sheet is open): Space (except
    /// on a button focused with keyboard navigation) and K play/pause, ← and J back 5 seconds, → and L ahead 5 seconds, ⌘← the previous turn (the start of this one first),
    /// ⌘→ the next turn.
    private func handlePlaybackKey(_ event: NSEvent) -> Bool {
        guard window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let special = event.specialKey
        if flags == [.command] {
            switch special {
            case .leftArrow?: previousTurn()
            case .rightArrow?: nextTurn()
            default: return false
            }
            return true
        }
        guard flags.isEmpty else { return false }
        switch special {
        case .leftArrow?:
            seek(to: player.currentTime - Self.seekStep)
            return true
        case .rightArrow?:
            seek(to: player.currentTime + Self.seekStep)
            return true
        default:
            break
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // With keyboard navigation on, Space presses the focused button, checkbox, or pop-up (K still plays).
        if key == " ", NSApplication.shared.isFullKeyboardAccessEnabled, window.firstResponder is NSButton {
            return false
        }
        switch key {
        case " ", "k":
            // Held down, it would flip on every repeat.
            if !event.isARepeat { togglePlay() }
            return true
        case "j":
            seek(to: player.currentTime - Self.seekStep)
            return true
        case "l":
            seek(to: player.currentTime + Self.seekStep)
            return true
        default:
            return false
        }
    }

    /// Seconds ← and → move the play head.
    private static let seekStep = 5.0

    /// Shortcuts of the window (Holos has no main menu to carry them).
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let editingText = window.firstResponder is NSTextView
        if flags == [.command, .shift], key == "z" {
            return editingText && NSApplication.shared.sendAction(Selector(("redo:")), to: nil, from: window)
        }
        if flags == [.command, .shift], key == "e" {
            exportPopUp.performClick(nil)
            return true
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
            // From the field being edited too: it closes unsaved, as the mode ends.
            toggleEditMode()
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

    /// Closed by hand with an edit typed in the field: saved first, and the window stays open when it is not
    /// (`ReviewCloseGate`).
    /// Also with edits handed over and still saving (Return, then ⌘W at once): the window waits for them, and stays
    /// open when one is not saved (its own failure opens its field again, or says what was typed).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, closeTask == nil else { return true }
        let open: OpenWordEdit? = closeGate.saving ? nil : turnList.takeOpenWordEdit()
        // Held until it is queued: a quit meanwhile closes the review with it (`beginClosing`).
        if open != nil { heldOpenEdit = open }
        let pending: [Task<String?, Never>] = closeGate.saving ? [] : Array(pendingWordEdits.values)
        let outcome = CloseSaveOutcome()
        let save: () async -> String? = { [weak self] in
            await self?.saveBeforeClose(open, after: pending, outcome: outcome)
        }
        let close: () -> Void = { [weak self] in self?.window.close() }
        let keep: (String) -> Void = { [weak self] message in
            self?.keepAfterFailedClose(open, outcome: outcome, message: message)
        }
        let closesNow = closeGate.shouldClose(typed: open != nil || !pending.isEmpty, save: save, close: close,
                                              keep: keep)
        // Saving first: no field opens until the window closes, or stays open (`canEditWordsNow`).
        if !closesNow { refreshToolbar() }
        return closesNow
    }

    /// The open field's edit as `TurnListView.takeOpenWordEdit` hands it over.
    private typealias OpenWordEdit = (words: [ReviewWord], text: String, movesSeen: Int)

    /// What a close by hand found when it saved (`saveBeforeClose`): why the open field's edit was not saved.
    private final class CloseSaveOutcome {
        var openRefusal: String?
    }

    /// Before a close by hand: waits for the edits handed over (in the order they were made), then saves the open
    /// field's. Nil when all were saved, else every refusal, each with what was typed.
    private func saveBeforeClose(_ open: OpenWordEdit?, after pending: [Task<String?, Never>],
                                 outcome: CloseSaveOutcome) async -> String? {
        var refusals: [String] = []
        for edit in pending {
            if let refusal = await edit.value { refusals.append(refusal) }
        }
        // Unless the window's close took it meanwhile (quitting), which queues it itself.
        if open != nil, closeTask == nil, let open = heldOpenEdit {
            heldOpenEdit = nil
            let refusal = await saveTypedEdit(open.words, text: open.text, movesSeen: open.movesSeen)
            outcome.openRefusal = refusal
            if let refusal { refusals.append(refusal) }
        }
        return refusals.isEmpty ? nil : refusals.joined(separator: " ")
    }

    /// A close by hand stopped because an edit was not saved: the open field's edit opens again with what was typed (an
    /// edit handed over before did so itself), and the footer says every edit not saved.
    private func keepAfterFailedClose(_ open: OpenWordEdit?, outcome: CloseSaveOutcome, message: String) {
        // Quitting closed the window meanwhile: its close saves (or logs) what is left.
        guard closeTask == nil else { return }
        // Fields may open again (the close by hand ended).
        refreshToolbar()
        if let open, let refusal = outcome.openRefusal {
            if !turnList.editingWords { turnList.editingWords = true }
            turnList.reopenWordEdit(open.words, typed: open.text, message: refusal)
        }
        problem = message
        refreshFooter()
    }

    /// Saves an edit typed in the field and waits for it: nil when saved (also when its labels could not be reread
    /// after it: the edit stands), else why, with what was typed.
    private func saveTypedEdit(_ words: [ReviewWord], text: String, movesSeen: Int) async -> String? {
        var saved = false
        let committed: (ReviewWordEdit) -> Void = { _ in saved = true }
        do {
            _ = try await review.editWords(words.map(\.ref), to: text, seenMoves: movesSeen, whileUnread: true,
                                           expecting: words.map(\.shown), committed: committed)
            return nil
        } catch {
            return saved ? nil : Self.withTyped(error.localizedDescription, text)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        beginClosing()
    }

    private func beginClosing() {
        guard closeTask == nil else { return }
        screenOCRTask?.cancel()
        player.invalidate()
        review.onChange = nil
        let review = self.review
        // AppKit ends no editing when a window closes: an open edit field's text is saved (and learned) by the close,
        // as is one a close by hand took from the field and has not queued yet (quitting came first).
        let open = turnList.takeOpenWordEdit() ?? heldOpenEdit
        heldOpenEdit = nil
        let typed = open.map { open in
            ReviewSession.TypedEdit(words: open.words.map(\.ref), text: open.text, seenMoves: open.movesSeen,
                                    expected: open.words.map(\.shown))
        }
        closeTask = Task { [weak self] in
            await review.close(typed: typed)
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

/// The band under the toolbar while edit mode is on: a tint of the accent color and what to do, or a passing message.
final class EditModeBanner: NSView {
    static let usual = "Editing — click a word to change it. ⇧-click or drag for more words of the same turn. Return "
        + "saves, ⌥Return saves and adds it to the word list, Tab saves and edits the next word, Esc cancels. "
        + "Space still plays and pauses."
    let label = NSTextField(wrappingLabelWithString: EditModeBanner.usual)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Edit mode")
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { nil }

    /// `message` for now, or the usual text.
    func show(message: String?) {
        let text = message ?? Self.usual
        if label.stringValue != text { label.stringValue = text }
        label.textColor = message == nil ? .labelColor : .systemOrange
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The playback bar's band: a rounded background with a hairline border, in the window's colors.
private final class PlaybackBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The review window; it handles its own shortcuts first, and the playback keys before any view sees them.
final class ReviewKeyWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Key presses on their way to the first responder; true when handled.
    var playbackKeyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, playbackKeyHandler?(event) == true { return }
        super.sendEvent(event)
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

/// Where to split a row: its words in a read-only text; a click puts the caret where the second part starts. "Play
/// from Here" plays from that word. At a word that starts a turn of the row, nothing is split: the row only breaks
/// there.
@MainActor
private final class SplitSheet: NSObject, NSTextViewDelegate {
    let panel: NSPanel
    private let words: [ReviewWord]
    /// Indices of words that start a turn (other than the first).
    private let turnStarts: Set<Int>
    /// Each word's range in the shown text.
    private var ranges: [NSRange] = []
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView {
        // `scrollableTextView()` always holds a text view.
        scroll.documentView as? NSTextView ?? NSTextView()
    }
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let splitButton = NSButton(title: "Split", target: nil, action: nil)
    private let playButton = NSButton(title: "Play from Here", target: nil, action: nil)
    private let onPlay: (Double) -> Void

    /// The first word of the second part (an index into `words`), when the caret is after the first word.
    private(set) var splitIndex: Int?

    init(words: [ReviewWord], turnStarts: Set<Int> = [], onPlay: @escaping (Double) -> Void) {
        self.words = words
        self.turnStarts = turnStarts
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
            splitIndex = index
            hint.stringValue = "The second part starts at “\(words[index].text)” (\(TimeFormat.clock(words[index].start)))."
                + (turnStarts.contains(index) ? " A turn already starts there, so the text only breaks there." : "")
        } else {
            splitIndex = nil
            hint.stringValue = "Click after the first word, where the second part starts."
        }
        splitButton.isEnabled = splitIndex != nil
        playButton.isEnabled = true
    }

    @objc private func split() {
        guard splitIndex != nil else { return }
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
