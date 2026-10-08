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

/// A word edit the field handed over that was not saved: its words as the field showed them, what was typed, the word
/// moves and `wordsEpoch` they follow, and why (`message`, with what was typed).
struct FailedWordEdit {
    var words: [ReviewWord]
    var text: String
    var movesSeen: Int
    var wordsEpoch: Int
    var message: String
    /// A Restore of deleted words (this segment's), not typed words: no field opens again for it, and it is never kept
    /// as an edit to type again (`UnsavedWordEdits`); its message stays in the footer.
    var restoring: String? = nil
}

/// After a close by hand stopped because edits were not saved (`ReviewWindow.keepAfterFailedClose`): fields could not
/// open while the close waited, so the first failed edit's field opens now, with what was typed and why (`reopen`,
/// false when its words are no longer there). Returns the others (all of them when the field could not open), for the
/// footer (`UnsavedWordEdits`).
enum ReviewCloseRecovery {
    @MainActor
    static func recover(_ failures: [FailedWordEdit], reopen: (FailedWordEdit) -> Bool) -> [FailedWordEdit] {
        guard let first = failures.first else { return [] }
        return reopen(first) ? Array(failures.dropFirst()) : failures
    }
}

/// Word edits not saved whose field could not open again (their words were not shown, another field was open, a close
/// was waiting): the footer lists each with what was typed until its field opens again (`reopenNext`; it is then the
/// field's, saved, queued, or cancelled with Esc as any field's) or the person dismisses it (`dismissNext`). The next
/// edit never clears them.
struct UnsavedWordEdits {
    private(set) var edits: [FailedWordEdit] = []

    mutating func add(_ failed: [FailedWordEdit]) { edits += failed }

    /// Opens the first one's field again (`reopen`); true when it opened, and it leaves the list.
    @MainActor
    mutating func reopenNext(_ reopen: (FailedWordEdit) -> Bool) -> Bool {
        guard let first = edits.first, reopen(first) else { return false }
        edits.removeFirst()
        return true
    }

    mutating func dismissNext() {
        if !edits.isEmpty { edits.removeFirst() }
    }

    /// The footer's lines: each edit's message (it says what was typed).
    var lines: [String] { edits.map { "⚠ Not saved: " + $0.message } }

    /// A close by hand waits: the window stays open until each one is edited again or dismissed (quitting does not
    /// wait; it logs them, `typedTexts`).
    var holdsClose: Bool { !edits.isEmpty }

    /// What was typed in each, for the quit's log.
    var typedTexts: [String] { edits.map(\.text) }
}

/// The transcript review window (docs/meeting-design.md §5.10): name the speakers of a meeting, play their audio,
/// reassign, merge, split, confirm suggestions in bulk, find more speakers, undo, and export. The model is
/// `ReviewSession` (HolosMeeting); this file only arranges views and routes actions to it. Every change shows at once
/// and saves in the background; errors appear in the footer.
///
/// Holos has no main menu, so the "Speakers" menu is a pull-down in the window's toolbar and the window handles its
/// own shortcuts: Space (or K) play/pause, ←/→ (or J/L) back and ahead 5 seconds, and ⌘←/⌘→ the previous and next
/// turn, anywhere but while typing in a text field; 1–9 assign (in the turn list), ⌘' next uncertain, ⌘Z undo,
/// ⌘F search, ⌘E edit mode (word clicks edit words), ⇧⌘E export, ⌥⌘S hide or show the speakers pane, and the usual
/// editing keys in text fields. The app's View menu has Hide Speakers and Show Short Interjections for the key review
/// window (`toggleSpeakers`, `toggleShortInterjections`, reached through the responder chain as the window's delegate).
///
/// The playback bar above the footer holds Play/Pause, the position, a scrubber, the speed, and who is speaking.
/// Playing goes on through the meeting until paused; a click on a timestamp or on a word plays from there. While a
/// meeting plays, the turn list tints the turn and word playing and keeps them in view, except for a few seconds after
/// the reader scrolls it (`ReviewFollow`).
@MainActor
final class ReviewWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSMenuItemValidation, ClosingReview {
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

    /// Internal (as `turnList`) for tests that drive the window.
    let window: ReviewKeyWindow
    private let player = ReviewPlayer()
    private let sidebar = SpeakerSidebarView()
    let turnList = TurnListView()
    /// The speakers pane and the turn list; the speakers pane can be hidden (⌥⌘S).
    private lazy var panes = ReviewPanes(speakers: sidebar, list: turnList)
    /// Hides or shows the speakers pane (also View ▸ Hide Speakers, ⌥⌘S).
    private let speakersButton = NSButton(title: "Hide Speakers", target: nil, action: nil)
    /// "Show Short Interjections" (off unless the user turned it on), kept across windows.
    static let showInterjectionsKey = "reviewShowsShortInterjections"
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
    /// Where "Split Turn" broke a paragraph without splitting a turn, and where a row was joined to the row before
    /// it: the window's view only, never saved; kept with its turn on its run and through this window's word-fix
    /// reverts, dropped by any other new run (a relabel).
    private var paragraphBreaks = ReviewParagraphBreaks()
    /// Every row as grouped, before a search filters them: a join finds the row before or after the one it is asked
    /// at here, never a row the search left next to it.
    private var allParagraphs: [ReviewParagraph] = []
    /// The turns joined to the row before them in this window (for tests).
    var paragraphJoins: Set<String> { paragraphBreaks.joins }
    private var positioned = false
    /// The player state the sidebar and the footer last showed.
    private var shownPlayerState = StateChangeTracker<ReviewPlayer.State>()
    private var resignedKeyAt: Date?
    private var closeTask: Task<Void, Never>?
    /// A close by hand waits for the edit typed in the field to be saved (`windowShouldClose`).
    private let closeGate = ReviewCloseGate()
    /// Word edits the field handed over that are still saving (`editWords`), in the order they were made: each ends
    /// with the edit when it was not saved (`FailedWordEdit`), nil when it was. A close by hand waits for them too.
    private var pendingWordEdits: [(id: UUID, saving: Task<FailedWordEdit?, Never>)] = []
    /// The field's edit a close by hand took and has not queued yet (it waits for the edits before it).
    private var heldOpenEdit: HeldEdit?
    /// Word edits not saved whose field could not open again: in the footer until reopened or dismissed.
    private var unsavedEdits = UnsavedWordEdits()

    /// Words can be edited in the window now: the review allows it, and no close by hand is saving the edits before
    /// it closes (no field opens meanwhile, so nothing typed then can be left behind by the close).
    private var canEditWordsNow: Bool { review.canEditWords && !closeGate.saving }
    private var splitSheet: SplitSheet?
    private var assignSignature: [String] = []
    private var refreshScheduled = false
    private var shownNotices: [Notice] = []
    /// The manifest chunks playback was last built from.
    private var loadedChunks: [AudioChunkRecord] = []
    /// The echo mask the microphone's volume was last read for: another one in the labels reads it again.
    private var echoMaskFollow = ReviewEchoMaskFollow()
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
        review.showsShortInterjections = UserDefaults.standard.bool(forKey: showInterjectionsKey)
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
        if turnList.selectedTurnIDs.isEmpty, let first = review.shownTurns.first {
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
                                    expected: open.words.map(\.shown), seenEpoch: open.wordsEpoch)
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
            } else {
                await self.refreshMicVolume()
            }
        }
    }

    /// The echo analysis may have changed meanwhile (`voiceislocal session echo-analyze`): the microphone's volume
    /// is read again and, when it changed, set on the playing item without rebuilding it.
    private func refreshMicVolume() async {
        // Without system audio in the playback the echo is never muted.
        guard player.isReady, let systemPlaced = player.systemPlaced else { return }
        let session = review.session, manifest = review.snapshot.manifest, duration = player.duration
        // The player drops the result when a newer refresh or a rebuilt playback came meanwhile.
        await player.refreshMicVolume {
            await Task.detached(priority: .utility) {
                ReviewEchoMute.micVolume(session: session, manifest: manifest, duration: duration,
                                         systemPlaced: systemPlaced)
            }.value
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
        speakersButton.bezelStyle = .push
        speakersButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        speakersButton.imagePosition = .imageLeading
        speakersButton.target = self
        speakersButton.action = #selector(toggleSpeakers(_:))
        let toolbar = NSStackView(views: [speakersButton, nextUncertainButton, assignPopUp, splitButton, speakersPopUp,
                                          editButton, NSView(), screenTextButton, searchField, exportPopUp])
        toolbar.spacing = 8
        toolbar.alignment = .centerY

        // A meeting opens with the speakers pane as it was left (`ReviewSpeakersPaneMemory`).
        panes.setSpeakersHidden(ReviewSpeakersPaneMemory().isHidden(sessionID: sessionID), animated: false)
        panes.onSpeakersHiddenChange = { [weak self] hidden in self?.speakersHiddenChanged(hidden) }
        refreshSpeakersButton()
        let split = panes.view

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
        turnList.onEditWords = { [weak self] words, text, addTerm, movesSeen, wordsEpoch in
            self?.editWords(words, to: text, addTerm: addTerm, movesSeen: movesSeen, wordsEpoch: wordsEpoch)
        }
        turnList.onEditMessage = { [weak self] message in self?.editBanner.show(message: message) }
        // Return at a word's start in edit mode, or Split Turn Here: the split, checked as the review checks it, then
        // the second part's speaker pop-up.
        turnList.onSplit = { [weak self] split, request in
            guard let self else { return }
            // The word is where `resolveSplit` found it just now, among the words shown: a word edit saved before the
            // split runs moves it from there; words changed elsewhere since it was chosen still refuse it.
            // Of the labels run shown now, which `resolveSplit` found the split on.
            self.applySplit(split, movesSeen: self.review.shownWordMoves.count, epoch: request.wordsEpoch,
                            runID: self.review.projection.runID, focus: true,
                            field: request.field.map { ($0, request.movesSeen, request.after, request.turnID) })
        }
        turnList.resolveSplit = { [weak self] request in
            self?.resolveSplit(request) ?? .refused("The review is closing.")
        }
        turnList.onSplitRefused = { [weak self] why in
            self?.problem = why
            self?.refreshFooter()
        }
        // Backspace at a row's start in edit mode (forward Delete at its end), or Join With Previous Turn.
        turnList.resolveJoin = { [weak self] request in
            self?.resolveJoin(request) ?? .refused("The review is closing.")
        }
        turnList.onJoin = { [weak self] join, request in self?.applyJoin(join, request: request) }
        turnList.onJoinRefused = { [weak self] why in
            self?.problem = why
            self?.refreshFooter()
        }
        // The review turned read-only with a field open (an earlier edit's labels could not be reread, say): its edit
        // is queued all the same, and waits for the reread as the changes before it do.
        turnList.onKeepWordEdit = { [weak self] words, text, movesSeen, wordsEpoch in
            self?.editWords(words, to: text, addTerm: false, movesSeen: movesSeen, wordsEpoch: wordsEpoch,
                            whileUnread: true)
        }
        turnList.onRequestEditing = { [weak self] in
            guard let self, self.review.canEditWords else { return }
            self.setEditMode(true)
        }
        turnList.editText = { [review] words in review.shownText(of: words.map(\.ref)) }
        turnList.editRefusal = { [review] words in review.wordEditRefusal(words.map(\.ref)) }
        turnList.revertRefusal = { [review] word in review.revertRefusal(word) }
        turnList.deletedWords = { [review] turnID in review.deletedWords(near: turnID) }
        turnList.onRestoreDeleted = { [weak self] segmentID in self?.restoreDeleted(segmentID) }
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

    /// Internal for tests (a refresh at a chosen moment).
    func refresh() {
        // Labels that came with another echo mask (a relabel here, a reload, `session echo-analyze`): the playing
        // item's microphone volume follows it.
        if echoMaskFollow.update(review.snapshot.echoMaskIdentity, playerReady: player.isReady) {
            Task { [weak self] in await self?.refreshMicVolume() }
        }
        let projection = review.projection
        // A run a word edit or its undo published keeps the turns, and with them the window's paragraph breaks (kept
        // for every turn, a hidden interjection's too).
        let runID = projection.runID
        // An undo saved here or elsewhere (a command) since the last refresh: every join goes.
        let reverts = projection.revertedEditIDs.count
        if reverts > revertsSeen {
            joinsCleared += 1
            paragraphBreaks.clearJoins()
        }
        revertsSeen = reverts
        // A break or join made on a split's second part while the split saved names its temporary ID: resolved.
        let breaks = paragraphBreaks.active(in: projection.turns, runID: runID, keepsTurnsOf: { [review] old in
            review.keepsTurns(of: old, in: runID)
        }, resolve: { [review] id in review.resolvedTurnID(id) })
        // The turns as shown: short interjections attached to a neighbour or left out (§5.10).
        var paragraphs = ReviewParagraphs.group(review.shownTurns, breaks: breaks, joins: paragraphBreaks.joins)
        allParagraphs = paragraphs
        // A search shows the paragraphs with a matching turn, whole.
        if !query.isEmpty {
            let matching = Set(review.turns(matching: query).map(\.id))
            paragraphs = paragraphs.filter { $0.turnIDs.contains(where: matching.contains) }
        }
        let people = review.knownPeople()
        // Words changed elsewhere since a field opened: it is not put back on them (`TurnListView.followWordEdit`).
        turnList.wordsEpoch = review.wordsEpoch
        turnList.runID = runID
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
            // A new player: its playback read the echo mask while it was built (possibly before the labels adopted
            // another one), so the microphone's volume is read once more against the labels' mask now.
            if player.isReady, echoMaskFollow.playerBecameReady(labels: review.snapshot.echoMaskIdentity) {
                Task { [weak self] in await self?.refreshMicVolume() }
            }
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
        // As listed: an attached interjection plays as its neighbour's speaker. A hidden one is still speech: it is
        // the turn spoken (unknown speaker), and, not being listed, tints no row, as a turn a search left out.
        let turns = review.projection.shownTurnsWithHidden
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
        nextUncertainButton.isEnabled = review.shownTurns.contains(where: \.uncertain)

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
        let shown = review.shownTurns.count
        var parts = ["\(projection.speakers.count) \(projection.speakers.count == 1 ? "speaker" : "speakers")",
                     "\(shown) \(shown == 1 ? "turn" : "turns")",
                     "\(changes) \(changes == 1 ? "change" : "changes")"]
        // Short interjections left out of the list (View ▸ Show Short Interjections lists them).
        let hidden = review.showsShortInterjections ? 0 : projection.turns.count - projection.shownTurns.count
        if hidden > 0 { parts.insert("\(hidden) short \(hidden == 1 ? "interjection" : "interjections") hidden", at: 2) }
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
        if let problem, !unsavedEdits.edits.contains(where: { $0.message == problem }) {
            lines.append(Notice(text: "⚠ " + problem, color: .systemRed))
        }
        // Each edit not saved whose field could not open, with what was typed; the first can be edited again.
        for (index, line) in unsavedEdits.lines.enumerated() {
            lines.append(index == 0
                ? Notice(text: line, color: .systemRed, button: "Edit Again", action: #selector(editUnsavedAgain),
                         secondButton: "Dismiss", secondAction: #selector(dismissUnsaved))
                : Notice(text: line, color: .systemRed))
        }
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
        clearTransientMessages()
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
                // A change that failed: every join goes (they are only how rows read).
                self.clearJoins()
            }
        }
    }

    /// A change begins: the footer stops saying what happened to the one before (a problem, a notice, a term offered).
    private func clearTransientMessages() {
        problem = nil
        notice = nil
        offeredTerm = nil
        refreshFooter()
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
                                                  starts: review.shownTurns.map(\.start)))
    }

    private func nextTurn() {
        guard player.isReady else { return }
        guard let start = ReviewTimeline.nextTurnStart(after: player.currentTime,
                                                       starts: review.shownTurns.map(\.start)) else {
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
        // Kept beside Return at a word's start and Split Turn Here: choosing a place by keyboard, playing from it first.
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
        let epoch = review.wordsEpoch
        let runID = review.projection.runID
        splitSheet = sheet
        window.beginSheet(sheet.panel) { [weak self] response in
            guard let self else { return }
            self.splitSheet = nil
            guard response == .OK, let index = sheet.splitIndex,
                  let split = ReviewParagraphs.split(paragraph, words: words, at: index) else { return }
            self.applySplit(split, movesSeen: movesSeen, epoch: epoch, runID: runID, focus: false)
        }
    }

    /// Makes `split`: the review splits the turn (undoable; a word edit saved since moves the word, `movesSeen`, and
    /// words changed elsewhere refuse it, `epoch`), or the row breaks before a turn it holds (this window only). With
    /// `focus` (Return at a word's start, Split Turn Here), the second part's row is selected and its speaker pop-up
    /// opens, so it can be given its speaker at once (`TurnListView.focusSpeaker`).
    /// `field`: the edit field Return asked from (its words and text, the word moves they follow, and whether the
    /// caret was at its end): refused once queued (an edit saved meanwhile changed what the split can do), the field
    /// opens again over its words once the labels are read again (a row the refused split showed for a moment is gone
    /// by then), with the caret where it was and the reason, as before Return.
    /// `runID`: the labels run `split`'s turn is of; labelled again before the split runs (it waits behind other
    /// changes), it is refused (`ReviewSession.splitRunRefusal`).
    private func applySplit(_ split: ReviewParagraphSplit, movesSeen: Int?, epoch: Int, runID: String, focus: Bool,
                            field: SplitField? = nil) {
        // A word's field opened while the split saves (open still, or closed again since): the person went on
        // editing, so no pop-up takes the keyboard, nor a refused split's field.
        let fieldsOpened = turnList.fieldsOpened
        switch split {
        case .splitTurn(let turnID, let word):
            perform { [weak self] review in
                let second: WordRef
                do {
                    second = try await review.split(turnID: turnID, at: word, seenMoves: movesSeen, seenEpoch: epoch,
                                                    seenRun: runID)
                } catch let error where !(error is CancellationError) {
                    guard let self else { throw error }
                    // Saved, but its labels could not be reread (`incomplete`): the split stands, so its second part
                    // gets its pop-up as any; the footer says what failed after it.
                    if case HolosError.incomplete = error {
                        if focus, self.turnList.fieldsOpened == fieldsOpened {
                            self.refresh()
                            let moved = ReviewSession.follow([word],
                                                             through: review.shownWordMoves.dropFirst(movesSeen ?? 0))
                            self.focusSpeaker(startingAt: moved.refs.first ?? word,
                                              splitOf: review.resolvedTurnID(turnID))
                        }
                        throw error
                    }
                    if let field {
                        await self.restoreSplitField(field, epoch: epoch, fieldsOpened: fieldsOpened,
                                                     why: error.localizedDescription)
                    }
                    throw error
                }
                guard focus, let self, self.turnList.fieldsOpened == fieldsOpened else { return }
                self.refresh()
                // Where the word is now (an edit saved before the split ran may have moved it), in the part split
                // from `turnID` (its saved ID: a part made by a split still saving had a temporary one).
                self.focusSpeaker(startingAt: second, splitOf: review.resolvedTurnID(turnID))
            }
        case .breakBefore(let turnID):
            guard let turn = review.projection.turns.first(where: { $0.id == turnID }) else { return }
            // Made here, not through `perform`: what the footer said of an earlier change (a split refused) goes, as
            // it does for any change.
            clearTransientMessages()
            paragraphBreaks.insert(before: turn, runID: review.projection.runID)
            refresh()
            turnList.select([turnID], scroll: true)
            if focus, let first = review.words(of: turn).first {
                focusSpeaker(startingAt: first.ref, turnID: turnID)
            }
        }
    }

    /// A split asked from the field and refused once queued: once the labels are read again (a row the refused split
    /// showed for a moment is gone by then), the field opens again over its words with the caret where Return found
    /// it and why; when an edit saved meanwhile replaced its word, over the words that replaced it (nothing was typed
    /// in it, so their own text is what it shows).
    /// The field the split was asked from: its words and text, the word moves they follow, whether the caret was at
    /// its end, and the turn it was opened in.
    private typealias SplitField = (field: ReviewSplitRequest.Field, movesSeen: Int, atEnd: Bool, turnID: String?)

    /// In the turn the field was opened in (overlapping turns may show a word twice), so Return there asks for that
    /// turn's split again; a word replaced meanwhile is taken at the edge of what replaced it (the end, for a split
    /// after it), never inside words edited together.
    /// `fieldsOpened`: `TurnListView.fieldsOpened` when the split was asked.
    private func restoreSplitField(_ field: SplitField, epoch: Int, fieldsOpened: Int, why: String) async {
        await review.reload()
        refresh()
        guard Self.reopensRefusedSplitField(typingElsewhere: turnList.typingElsewhere,
                                            editingWords: turnList.editingWords,
                                            fieldOpenedSince: turnList.fieldsOpened != fieldsOpened) else { return }
        let text = field.field.text
        // Its saved ID: a part made by a split still saving when the field opened had a temporary one.
        let turnID = field.turnID.map(review.resolvedTurnID)
        let reopen = { [self] () -> Bool in
            if turnList.reopenWordEdit(field.field.words, typed: text, message: why, movesSeen: field.movesSeen,
                                       wordsEpoch: epoch, caret: field.atEnd ? (text as NSString).length : 0,
                                       inTurn: turnID) {
                return true
            }
            guard epoch == review.wordsEpoch,
                  let place = Self.splitBoundary(field.atEnd ? field.field.words.last : field.field.words.first,
                                                 atEnd: field.atEnd,
                                                 through: review.shownWordMoves.dropFirst(field.movesSeen))
            else { return false }
            if turnList.reopenField(at: place.word, atEnd: place.atEnd, message: why, inTurn: turnID) { return true }
            // The same boundary from the word before it (a deleted last word leaves no word after it).
            guard !place.atEnd, place.word.word > 0 else { return false }
            return turnList.reopenField(at: WordRef(segmentID: place.word.segmentID, word: place.word.word - 1),
                                        atEnd: true, message: why, inTurn: turnID)
        }
        if reopen() { return }
        // A search hiding the row (an edit saved meanwhile changed what it matched): cleared, as for a split made.
        guard !query.isEmpty else { return }
        query = ""
        searchField.stringValue = ""
        refresh()
        _ = reopen()
    }

    /// Whether a refused split's field opens again once the labels are read again. Not while the person types
    /// elsewhere (another word, a speaker's name, a search), which keeps the keyboard; nor once edit mode is off (the
    /// field was asked from edit mode, which only the person turns off), so word clicks play, as they asked; nor once
    /// a word's field opened since the split was asked (`fieldOpenedSince`: closed again, its row gone with the
    /// refused split, it was still where the person was typing). The refusal is in the footer either way.
    static func reopensRefusedSplitField(typingElsewhere: Bool, editingWords: Bool, fieldOpenedSince: Bool) -> Bool {
        !typingElsewhere && editingWords && !fieldOpenedSince
    }

    /// Where a split asked at the start (or end, `atEnd`) of `word` is after the word moves since: the same edge of
    /// the word, or of what replaced it (never inside words edited together); a deleted word's boundary is the start
    /// of the next word, else the end of the one before. Nil when there is no word.
    static func splitBoundary(_ word: ReviewWord?, atEnd: Bool,
                              through moves: ArraySlice<ReviewWordMove>) -> (word: WordRef, atEnd: Bool)? {
        guard let word else { return nil }
        var ref = word.ref
        var atEnd = atEnd
        for move in moves {
            guard ref.segmentID == move.segmentID, move.replaced.contains(ref.word) else {
                ref = move.map(ref).ref
                continue
            }
            if move.replacement.isEmpty {
                // Deleted: the boundary is where the words after it now start (`restoreSplitField` takes the end of
                // the word before when none is left after it).
                ref.word = move.replacement.lowerBound
                atEnd = false
            } else {
                ref.word = atEnd ? move.replacement.upperBound - 1 : move.replacement.lowerBound
            }
        }
        return (ref, atEnd)
    }

    /// The second part's speaker pop-up after a split (`TurnListView.focusSpeaker`); a search hiding its row is cleared
    /// first, as Next Uncertain clears one hiding where it goes.
    private func focusSpeaker(startingAt word: WordRef, turnID: String? = nil, splitOf: String? = nil) {
        // The person went on typing meanwhile (another word, a speaker's name, a search): it keeps the keyboard, and
        // the search is not cleared under it.
        guard !turnList.typingElsewhere else { return }
        if turnList.focusSpeaker(startingAt: word, turnID: turnID, splitOf: splitOf) { return }
        guard !query.isEmpty else { return }
        query = ""
        searchField.stringValue = ""
        refresh()
        turnList.focusSpeaker(startingAt: word, turnID: turnID, splitOf: splitOf)
    }

    /// What a split asked for at a word makes now (`TurnListView.resolveSplit`): the review finds where the word is
    /// (`ReviewSession.splitPlace`, following word moves since it was chosen); inside a turn, that turn's split,
    /// checked as it is when made (`ReviewSession.splitRefusal`); at a turn's start or end, a break of the row before
    /// the turn there, when the row goes on past it.
    private func resolveSplit(_ request: ReviewSplitRequest) -> ReviewSplitResolution {
        // Held read-only (a maintenance command, labels that could not be reread): no split, nor a row break, as the
        // toolbar's Split Turn is disabled then.
        guard review.isEditable else {
            return .refused(review.pauseReason ?? review.reloadProblem ?? "This meeting cannot be changed right now.")
        }
        // Labelled again since the rows the split was chosen on: a turn ID may name another turn now.
        if let refusal = review.splitRunRefusal(seenRun: request.runID) { return .refused(refusal) }
        let place: ReviewSplitPlace?
        do {
            place = try review.splitPlace(at: request.word, after: request.after, in: request.turnID,
                                          seenMoves: request.movesSeen, seenEpoch: request.wordsEpoch)
        } catch {
            return .refused(error.localizedDescription)
        }
        return Self.splitResolution(place, paragraphs: turnList.paragraphs) { [review] turnID, word in
            review.splitRefusal(turnID: turnID, at: word)
        }
    }

    /// `resolveSplit`'s rule for a place the review found (`place`) in the rows shown (`paragraphs`); `refusal`: why a
    /// turn cannot be split before a word (`ReviewSession.splitRefusal`).
    static func splitResolution(_ place: ReviewSplitPlace?, paragraphs: [ReviewParagraph],
                                refusal: (String, WordRef) -> String?) -> ReviewSplitResolution {
        switch place {
        case .inside(let turnID, let word)?:
            if let refusal = refusal(turnID, word) { return .refused(refusal) }
            return .split(.splitTurn(turnID: turnID, at: word))
        case .turnStart(let turnID)?:
            guard let paragraph = paragraphs.first(where: { $0.contains(turnID: turnID) }),
                  paragraph.turns.first?.id != turnID else { return .refused(TurnListView.alreadyStartsHere) }
            return .split(.breakBefore(turnID: turnID))
        case .turnEnd(let turnID)?:
            guard let paragraph = paragraphs.first(where: { $0.contains(turnID: turnID) }),
                  let index = paragraph.turns.firstIndex(where: { $0.id == turnID }),
                  index + 1 < paragraph.turns.count else { return .refused(TurnListView.alreadyEndsHere) }
            return .split(.breakBefore(turnID: paragraph.turns[index + 1].id))
        case nil:
            return .refused("Those words are no longer shown; try the split again.")
        }
    }

    // MARK: - Joining rows

    /// What a join asked at a row's edge makes now (`TurnListView.resolveJoin`): checked as a split is (the review
    /// editable, the same labels run), then found among every row grouped (`joinResolution`).
    private func resolveJoin(_ request: ReviewJoinRequest) -> ReviewJoinResolution {
        // Held read-only (a maintenance command, labels that could not be reread): no join, as no split.
        guard review.isEditable else {
            return .refused(review.pauseReason ?? review.reloadProblem ?? "This meeting cannot be changed right now.")
        }
        if let seen = request.runID, seen != review.projection.runID,
           !review.keepsTurns(of: seen, in: review.projection.runID) {
            return .refused(Self.joinRelabelled)
        }
        return Self.joinResolution(paragraphID: review.resolvedTurnID(request.paragraphID), forward: request.forward,
                                   paragraphs: allParagraphs)
    }

    static let joinRelabelled = "The speakers were labelled again since; try the join again."
    static let joinNotShown = "That turn no longer starts a row; try the join again."

    /// `resolveJoin`'s rule over every row grouped (`paragraphs`, before a search filters them): the row
    /// `paragraphID` joins the row before it (with `forward`, the row after it joins it). Nothing to join with at the
    /// meeting's first row (last, `forward`); refused when no row starts with that turn any more.
    static func joinResolution(paragraphID: String, forward: Bool,
                               paragraphs: [ReviewParagraph]) -> ReviewJoinResolution {
        guard let index = paragraphs.firstIndex(where: { $0.id == paragraphID }) else { return .refused(joinNotShown) }
        let earlier = forward ? index : index - 1
        guard earlier >= 0 else { return .nothing(TurnListView.nothingBefore) }
        guard earlier + 1 < paragraphs.count else { return .nothing(TurnListView.nothingAfter) }
        return .join(ReviewParagraphs.join(paragraphs[earlier + 1], to: paragraphs[earlier]))
    }

    /// Makes `join`: the window joins each turn of the later row to the paragraph before it
    /// (`ReviewParagraphBreaks.join`, never saved; every turn, so the row stays whole through its new speaker), and
    /// when the rows' speakers differ, the later row's turns take the earlier row's speaker through the review's
    /// assignment (undoable with ⌘Z and learned from as any made with the row's pop-up), refused when the meeting was
    /// labelled again since the rows were shown. Joins are only how rows read, with the simplest life: made at once,
    /// and all dropped on any Undo, any change that fails, and any relabel (`clearJoins`). Then, asked from the field,
    /// the field opens again where the rows met (the caret at the start of the later row's first word, or at the end
    /// of the earlier row's last word for forward Delete), where that word is after the word edits saved meanwhile
    /// (`joinBoundary`), so typing goes on there; asked from the menu, the joined row is selected. VoiceOver hears
    /// that the rows were joined. Nothing of that once the joins were dropped meanwhile (⌘Z pressed, say).
    private func applyJoin(_ join: ReviewParagraphJoin, request: ReviewJoinRequest) {
        let runID = review.projection.runID
        // The rows the join was asked on: labelled again since, a turn or speaker ID may name another now.
        let seenRun = request.runID ?? runID
        let sameLabels = { [review] in
            seenRun == review.projection.runID || review.keepsTurns(of: seenRun, in: review.projection.runID)
        }
        guard sameLabels() else {
            problem = Self.joinRelabelled
            refreshFooter()
            return
        }
        let turns = join.turnIDs.compactMap { id in review.projection.turns.first { $0.id == id } }
        guard !turns.isEmpty else { return }
        // A word's field opened since the join was asked (the speaker change took a while): it keeps the keyboard.
        let fieldsOpened = turnList.fieldsOpened
        let message = join.reassign.isEmpty ? TurnListView.joined : TurnListView.joinedSpeaker
        let finish = { [weak self] in
            guard let self else { return }
            self.refresh()
            if NSWorkspace.shared.isVoiceOverEnabled {
                NSAccessibility.post(element: self.window, notification: .announcementRequested, userInfo: [
                    .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            }
            guard !self.turnList.typingElsewhere, self.turnList.fieldsOpened == fieldsOpened else { return }
            if request.fromField, self.turnList.editingWords, self.reopenJoinField(request, message: message) { return }
            self.turnList.select([self.review.resolvedTurnID(join.turnID)], scroll: true)
        }
        // Made here, as a row break is: what the footer said of an earlier change goes.
        clearTransientMessages()
        for turn in turns { paragraphBreaks.join(turn, runID: runID) }
        guard !join.reassign.isEmpty else {
            finish()
            return
        }
        refresh()
        let cleared = joinsCleared
        let target: ReviewAssignTarget = join.speakerID.map { .speaker($0) } ?? .unknown
        perform { [weak self] review in
            // Checked again as the assignment is queued: a reload may have adopted a relabel since.
            guard sameLabels() else { throw HolosError.invalidInput(Self.joinRelabelled) }
            try await review.assign(join.reassign, to: target)
            // Dropped meanwhile (⌘Z pressed, a change failed): no field, no announcement.
            guard let self, self.joinsCleared == cleared else { return }
            finish()
        }
    }

    /// How many times every join was dropped (`clearJoins`).
    private var joinsCleared = 0
    /// How many reverts the labels shown had at the last refresh: one more (an undo saved, here or elsewhere) drops
    /// every join.
    private var revertsSeen = 0

    /// Drops every join (Undo, a change that failed, a relabel): rows read as they group on their own again.
    private func clearJoins() {
        joinsCleared += 1
        guard !paragraphBreaks.joins.isEmpty else { return }
        paragraphBreaks.clearJoins()
        refresh()
    }

    /// Opens the field again where a join from it met the rows: `request.word`, followed through the word moves saved
    /// since it was chosen (a word edit queued before the join's speaker change saves first), at the same edge; at a
    /// word deleted meanwhile, the start of the word after it, else the end of the one before. Nothing when the words
    /// were changed elsewhere since.
    private func reopenJoinField(_ request: ReviewJoinRequest, message: String) -> Bool {
        guard request.wordsEpoch == review.wordsEpoch,
              let place = Self.joinBoundary(request.word, atEnd: request.forward,
                                            through: review.shownWordMoves.dropFirst(request.movesSeen)) else {
            return false
        }
        let turnID = request.turnID.map(review.resolvedTurnID)
        if turnList.reopenField(at: place.word, atEnd: place.atEnd, message: message, inTurn: turnID) { return true }
        guard !place.atEnd, place.word.word > 0 else { return false }
        return turnList.reopenField(at: WordRef(segmentID: place.word.segmentID, word: place.word.word - 1),
                                    atEnd: true, message: message, inTurn: turnID)
    }

    /// Where the edge of `word` (its start; its end, `atEnd`) is after `moves`, as for a split
    /// (`splitBoundary`).
    static func joinBoundary(_ word: WordRef, atEnd: Bool,
                             through moves: ArraySlice<ReviewWordMove>) -> (word: WordRef, atEnd: Bool)? {
        splitBoundary(ReviewWord(ref: word, text: "", start: 0), atEnd: atEnd, through: moves)
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

    /// The Edit menu item's title (`restoreDeletedWords`).
    static let restoreDeletedWordsTitle = "Restore Deleted Words…"

    /// Edit ▸ Restore Deleted Words…: every segment whose words were all deleted that can be restored
    /// (`ReviewSession.deletedWords()`), in a menu over the Edit Words button, one item each ("00:10  Restore Deleted
    /// “Cheers.”"). It needs no turn shown near them, so none is out of reach when every turn around them went too.
    /// The deleted words Restore Deleted Words… offers now: none while no field could open (`canEditWordsNow`, a close
    /// waiting for earlier saves among the reasons), as for every word edit.
    var restorableDeletedWords: [ReviewDeletedWords] { canEditWordsNow ? review.deletedWords() : [] }

    @objc func restoreDeletedWords(_ sender: Any?) {
        let deleted = restorableDeletedWords
        guard !deleted.isEmpty else {
            NSSound.beep()
            return
        }
        openRestoreMenu(Self.restoreMenu(deleted, target: self, action: #selector(restoreChosen(_:))), editButton)
    }

    /// Opens Restore Deleted Words' menu over `button` (tests record it instead: a menu tracks the mouse until it
    /// closes).
    var openRestoreMenu: (NSMenu, NSView) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Restore Deleted Words' menu: one item per deleted segment, its time and text, sending `action` to `target` with
    /// the segment ID.
    static func restoreMenu(_ deleted: [ReviewDeletedWords], target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Restore Deleted Words")
        menu.autoenablesItems = false
        for words in deleted {
            let item = NSMenuItem(title: TimeFormat.compact(words.start) + "  " + TurnTextView.restoreTitle(words),
                                  action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = words.segmentID
            item.toolTip = TurnTextView.restoreHelp
            menu.addItem(item)
        }
        return menu
    }

    @objc private func restoreChosen(_ sender: NSMenuItem) {
        guard let segmentID = sender.representedObject as? String else { return }
        restoreDeleted(segmentID)
    }

    /// Restore Deleted “…”: segment `segmentID`'s words, all deleted earlier, come back to the turns that held them.
    /// Its run keeps the turns, as a word edit's does, so the paragraph breaks stay. It is a word edit for the window
    /// (`trackWordChange`): offered and made only while a field could open (`canEditWordsNow`: not while a close waits
    /// for earlier saves), queued in the review before this returns, tracked until it ends so a close waits for it,
    /// and saved once its `committed` says so, also when the labels could not be reread afterwards. Nothing was typed,
    /// so a failure is said in the footer and never held as an edit to type again (`UnsavedWordEdits`).
    func restoreDeleted(_ segmentID: String) {
        guard canEditWordsNow else {
            NSSound.beep()
            return
        }
        clearTransientMessages()
        paragraphBreaks.beginCarryOver()
        trackWordChange([], text: "", movesSeen: review.shownWordMoves.count, wordsEpoch: review.wordsEpoch,
                        restoring: segmentID, saved: { _ in }, ended: { [weak self] in self?.endBreakCarryOver() }) {
            [review] committed in
            try review.queueRestoreDeletedWords(segmentID: segmentID, committed: committed)
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
    /// `wordsEpoch`: the review's when the field opened over `words`; the save is refused when words were changed
    /// elsewhere since, even when the list has not shown that yet.
    private func editWords(_ words: [ReviewWord], to text: String, addTerm: Bool, movesSeen: Int, wordsEpoch: Int,
                           whileUnread: Bool = false) {
        offeredTerm = nil
        problem = nil
        notice = nil
        refreshFooter()
        trackWordChange(words, text: text, movesSeen: movesSeen, wordsEpoch: wordsEpoch,
                        saved: { [weak self] edit in self?.offerTerm(after: edit, add: addTerm) }) {
            [review] committed in
            try review.queueWordEdit(words.map(\.ref), to: text, seenMoves: movesSeen, whileUnread: whileUnread,
                                     expecting: words.map(\.shown), seenEpoch: wordsEpoch, committed: committed)
        }
    }

    /// The one way a word change (an edit, or a Restore of deleted words: `restoring` its segment) is made and
    /// followed: `queue` queues it in the review at once, before anything else runs, so a close or a quit right after
    /// finds it there (saved before the review closes, listed by `unsavedWordEdits` meanwhile), never only in a task
    /// of the window's; `saved` runs once it is committed (`ReviewSession`'s `committed`, also when the labels could
    /// not be reread afterwards: the change stands); it is tracked until it ends (`pendingWordEdits`), so closing the
    /// window by hand waits for it and stays open when it is not saved; `ended` runs then.
    private func trackWordChange(
        _ words: [ReviewWord], text: String, movesSeen: Int, wordsEpoch epoch: Int, restoring: String? = nil,
        saved: @escaping (ReviewWordEdit) -> Void, ended: (() -> Void)? = nil,
        queue: (@escaping (ReviewWordEdit) -> Void) throws -> (@MainActor () async throws -> ReviewWordEdit?)?
    ) {
        let id = UUID()
        let flag = SavedFlag()
        let committed: (ReviewWordEdit) -> Void = { edit in
            flag.value = true
            saved(edit)
        }
        let queued: Result<(@MainActor () async throws -> ReviewWordEdit?)?, any Error>
        do {
            queued = .success(try queue(committed))
        } catch {
            queued = .failure(error)
        }
        let saving: Task<FailedWordEdit?, Never> = Task { [weak self] () async -> FailedWordEdit? in
            guard let self else { return nil }
            let refusal: String? = await self.saveEdit(words, to: text, queued: queued, saved: flag,
                                                       movesSeen: movesSeen, seenEpoch: epoch, restoring: restoring)
            self.pendingWordEdits.removeAll { $0.id == id }
            ended?()
            return refusal.map {
                FailedWordEdit(words: words, text: text, movesSeen: movesSeen, wordsEpoch: epoch, message: $0,
                               restoring: restoring)
            }
        }
        pendingWordEdits.append((id, saving))
    }

    /// Whether a word edit was saved (`ReviewSession.queueWordEdit`'s `committed`), read when it then throws.
    private final class SavedFlag {
        var value = false
    }

    /// `editWords`' save, already queued (`queued`): nil when saved (also when its labels could not be reread after
    /// it: the edit stands, and ⌥Return's term is still added), else why, with what was typed (the field opens again
    /// with it when its words are still there). Made on the words as the field showed them: never over words changed
    /// elsewhere since.
    private func saveEdit(_ words: [ReviewWord], to text: String,
                          queued: Result<(@MainActor () async throws -> ReviewWordEdit?)?, any Error>,
                          saved: SavedFlag, movesSeen: Int, seenEpoch: Int, restoring: String? = nil) async -> String? {
        do {
            if let wait = try queued.get() { _ = try await wait() }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            // A change that failed: every join goes (they are only how rows read).
            clearJoins()
            if saved.value {
                problem = error.localizedDescription
                refreshFooter()
                return nil
            }
            // A Restore: nothing was typed, no field to open again or edit to keep; the footer says why.
            if restoring != nil {
                let message = Self.restoreFailed(error)
                problem = message
                refreshFooter()
                return message
            }
            let message = Self.withTyped(error.localizedDescription, text)
            // Where its words are now: through the moves saved since, never across words changed elsewhere.
            let reopened = turnList.reopenWordEdit(words, typed: text, message: message, movesSeen: movesSeen,
                                                   wordsEpoch: seenEpoch)
            // Reopened: said once, in the banner over the field that holds what was typed, as every other refusal of
            // an edit is (`reopenWordEdit`). Not reopened: in the footer, kept until reopened or dismissed (the next
            // edit never clears it); a close waiting for it keeps it itself (`keepAfterFailedClose`).
            if !reopened {
                if !closeGate.saving {
                    unsavedEdits.add([FailedWordEdit(words: words, text: text, movesSeen: movesSeen,
                                                     wordsEpoch: seenEpoch, message: message)])
                }
                problem = message
                refreshFooter()
            }
            return message
        }
    }

    /// What the footer says of a Restore of deleted words that was not saved.
    static func restoreFailed(_ error: any Error) -> String {
        "The deleted words were not restored: " + error.localizedDescription
    }

    /// `message` with what was typed, unless it says it already or nothing was typed (a deletion).
    private static func withTyped(_ message: String, _ text: String) -> String {
        TranscriptWordEdit.withTyped(message, text)
    }

    /// After a saved edit: with `add` (⌥Return), its new text goes into the word list now, with what the recognizer
    /// wrote as "often heard as"; otherwise a new text that looks like a name or term is offered in the footer, unless
    /// the list has it with that phrase already.
    private func offerTerm(after edit: ReviewWordEdit, add: Bool) {
        // A deletion, or nothing typed (a Restore of deleted words): no term.
        guard !edit.deletion, !(edit.typed ?? edit.meant).isEmpty, let adder = addWordListTerm else { return }
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

    /// "Edit Again" on an edit not saved: its field opens with what was typed, when its words are still shown.
    @objc private func editUnsavedAgain() {
        guard canEditWordsNow else { return }
        if !turnList.editingWords { setEditMode(true) }
        let opened = unsavedEdits.reopenNext { failed in
            turnList.reopenWordEdit(failed.words, typed: failed.text, message: failed.message,
                                    movesSeen: failed.movesSeen, wordsEpoch: failed.wordsEpoch)
        }
        notice = opened ? nil : "Those words are no longer shown as they were; edit them again, or dismiss this."
        refreshFooter()
    }

    @objc private func dismissUnsaved() {
        unsavedEdits.dismissNext()
        if !unsavedEdits.holdsClose, notice == Self.unsavedBeforeClose { notice = nil }
        refreshFooter()
    }

    static let unsavedBeforeClose = "Some words you edited were not saved. Edit them again or dismiss each one, then "
        + "close the window."

    /// What was typed in each edit not saved whose field could not open again (`UnsavedWordEdits`): quitting logs them.
    var unsavedEditTexts: [String] { unsavedEdits.typedTexts }

    private func endBreakCarryOver() {
        paragraphBreaks.endCarryOver(turns: review.projection.turns, runID: review.projection.runID)
        refresh()
    }

    /// Undo (⌘Z, the menu): the review's newest change goes back, and every join with it.
    @objc private func undo() {
        clearJoins()
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

    // MARK: - View options

    /// Hide Speakers / Show Speakers (the toolbar button, View menu, ⌥⌘S): the speakers pane collapses and the turn
    /// list takes its width. Speakers can still be named from each row's speaker pop-up.
    @objc func toggleSpeakers(_ sender: Any?) {
        let hide = !panes.speakersHidden
        // A name being typed in the pane ends first (as a click elsewhere would end it). While a field is edited the
        // first responder is the window's field editor, whose delegate is the field.
        if hide, Self.isEditing(in: sidebar, responder: window.firstResponder) {
            window.makeFirstResponder(turnList.table)
        }
        panes.setSpeakersHidden(hide, animated: true)
    }

    /// `responder` is in `pane`, or is the field editor of a field in it.
    static func isEditing(in pane: NSView, responder: NSResponder?) -> Bool {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field.isDescendant(of: pane)
        }
        return (responder as? NSView)?.isDescendant(of: pane) ?? false
    }

    /// The pane was hidden or shown (also by dragging the divider): remembered for this meeting. Hidden by a drag with a
    /// name being typed there, the field ends now, so nothing typed goes to a field out of sight.
    private func speakersHiddenChanged(_ hidden: Bool) {
        if hidden, Self.isEditing(in: sidebar, responder: window.firstResponder) {
            window.makeFirstResponder(turnList.table)
        }
        ReviewSpeakersPaneMemory().setHidden(hidden, sessionID: sessionID)
        refreshSpeakersButton()
    }

    private func refreshSpeakersButton() {
        let title = Self.speakersTitle(hidden: panes.speakersHidden)
        if speakersButton.title != title { speakersButton.title = title }
        speakersButton.toolTip = (panes.speakersHidden ? "Show the speakers pane" : "Hide the speakers pane; name "
            + "speakers from each row's speaker pop-up meanwhile") + " (⌥⌘S)"
    }

    /// The button's and the View menu item's title.
    static func speakersTitle(hidden: Bool) -> String { hidden ? "Show Speakers" : "Hide Speakers" }

    /// Show Short Interjections (View menu): the short turns of the unknown speaker the list leaves out are listed
    /// again (docs/meeting-design.md §5.10); the exports leave them out either way. Kept across windows.
    @objc func toggleShortInterjections(_ sender: Any?) {
        review.showsShortInterjections.toggle()
        UserDefaults.standard.set(review.showsShortInterjections, forKey: Self.showInterjectionsKey)
        refresh()
    }

    /// The View menu's review items: their titles and check marks follow this window. Every other item it is asked
    /// about (the Export pull-down) stays enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSpeakers(_:))?:
            menuItem.title = Self.speakersTitle(hidden: panes.speakersHidden)
        case #selector(toggleShortInterjections(_:))?:
            menuItem.state = review.showsShortInterjections ? .on : .off
        case #selector(restoreDeletedWords(_:))?:
            return !restorableDeletedWords.isEmpty
        default:
            break
        }
        return true
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

    /// Whether ⌘Z undoes typing (the text being edited) rather than the review's newest change: in a text field whose
    /// own undo has something to undo (`typingToUndo`, whatever the text reads now: "cat" typed over "dog" typed over
    /// "cat" is still typing).
    static func undoIsTyping(editingText: Bool, typingToUndo: Bool) -> Bool {
        editingText && typingToUndo
    }

    /// Shortcuts of the window (Holos has no main menu to carry them). Internal for tests.
    func handleKey(_ event: NSEvent) -> Bool {
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
        if flags == [.command, .option], key == "s" {
            toggleSpeakers(nil)
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
            // In a text field with typing to undo, ⌘Z undoes the typing (it leaves the review, and its joins, alone);
            // with none (a word's field opened again after a join, say), it is the review's, as the banner says.
            let typingToUndo = (window.firstResponder as? NSTextView)?.undoManager?.canUndo ?? false
            if Self.undoIsTyping(editingText: editingText, typingToUndo: typingToUndo) {
                return NSApplication.shared.sendAction(Selector(("undo:")), to: nil, from: window)
            }
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
        // Edits not saved whose fields could not open again: closing would drop what was typed, so the window stays
        // open, its footer offering Edit Again or Dismiss for each (`UnsavedWordEdits`). A close already saving decides
        // itself.
        if unsavedEdits.holdsClose, !closeGate.saving {
            notice = Self.unsavedBeforeClose
            refreshFooter()
            return false
        }
        let open: OpenWordEdit? = closeGate.saving ? nil : turnList.takeOpenWordEdit()
        // Held until it is queued, with the `wordsEpoch` its field opened under: a quit meanwhile closes the review
        // with it (`beginClosing`); words changed elsewhere since the field opened refuse it.
        if let open { heldOpenEdit = HeldEdit(edit: open, epoch: open.wordsEpoch) }
        let epoch = open?.wordsEpoch ?? review.wordsEpoch
        let pending: [Task<FailedWordEdit?, Never>] = closeGate.saving ? [] : pendingWordEdits.map(\.saving)
        let outcome = CloseSaveOutcome()
        let save: () async -> String? = { [weak self] in
            await self?.saveBeforeClose(open, after: pending, outcome: outcome)
        }
        let close: () -> Void = { [weak self] in self?.window.close() }
        let keep: (String) -> Void = { [weak self] message in
            self?.keepAfterFailedClose(open, epoch: epoch, outcome: outcome, message: message)
        }
        let closesNow = closeGate.shouldClose(typed: open != nil || !pending.isEmpty, save: save, close: close,
                                              keep: keep)
        // Saving first: no field opens until the window closes, or stays open (`canEditWordsNow`).
        if !closesNow { refreshToolbar() }
        return closesNow
    }

    /// The open field's edit as `TurnListView.takeOpenWordEdit` hands it over.
    private typealias OpenWordEdit = (words: [ReviewWord], text: String, movesSeen: Int, wordsEpoch: Int)

    /// The field's edit a close by hand took, and the `wordsEpoch` its field opened under.
    private struct HeldEdit {
        let edit: OpenWordEdit
        let epoch: Int
    }

    /// What a close by hand found when it saved (`saveBeforeClose`): every edit not saved, in the order they were made
    /// (those handed over before, then the open field's).
    private final class CloseSaveOutcome {
        var failures: [FailedWordEdit] = []
    }

    /// Before a close by hand: waits for the edits handed over (in the order they were made), then saves the open
    /// field's. Nil when all were saved, else every refusal, each with what was typed. While it waits no field can open
    /// (`canEditWordsNow`), so each edit not saved is kept (`outcome`) for when the window stays open.
    private func saveBeforeClose(_ open: OpenWordEdit?, after pending: [Task<FailedWordEdit?, Never>],
                                 outcome: CloseSaveOutcome) async -> String? {
        for edit in pending {
            if let failed = await edit.value { outcome.failures.append(failed) }
        }
        // Unless the window's close took it meanwhile (quitting), which queues it itself.
        if open != nil, closeTask == nil, let held = heldOpenEdit {
            heldOpenEdit = nil
            let open = held.edit
            if let refusal = await saveTypedEdit(open.words, text: open.text, movesSeen: open.movesSeen,
                                                 seenEpoch: held.epoch) {
                outcome.failures.append(FailedWordEdit(words: open.words, text: open.text, movesSeen: open.movesSeen,
                                                       wordsEpoch: held.epoch, message: refusal))
            }
        }
        return outcome.failures.isEmpty ? nil : outcome.failures.map(\.message).joined(separator: " ")
    }

    /// A close by hand stopped because edits were not saved: fields may open again, so the first one's field opens with
    /// what was typed and why, and the footer says every other one, each with what was typed
    /// (`ReviewCloseRecovery`).
    private func keepAfterFailedClose(_ open: OpenWordEdit?, epoch: Int, outcome: CloseSaveOutcome,
                                      message: String) {
        // Quitting closed the window meanwhile: its close saves (or logs) what is left.
        guard closeTask == nil else { return }
        // Fields may open again (the close by hand ended).
        refreshToolbar()
        // Restores not saved have nothing typed to keep: the footer says why (`problem`).
        let typed = outcome.failures.filter { $0.restoring == nil }
        let restores = outcome.failures.filter { $0.restoring != nil }.map(\.message)
        if !typed.isEmpty, !turnList.editingWords { turnList.editingWords = true }
        let others = ReviewCloseRecovery.recover(typed) { failed in
            // Where its words are now: through the moves saved since, never across words changed elsewhere.
            turnList.reopenWordEdit(failed.words, typed: failed.text, message: failed.message,
                                    movesSeen: failed.movesSeen, wordsEpoch: failed.wordsEpoch)
        }
        // The others stay in the footer, each with what was typed, until reopened or dismissed.
        unsavedEdits.add(others)
        problem = outcome.failures.isEmpty ? message : restores.isEmpty ? nil : restores.joined(separator: " ")
        refreshFooter()
    }

    /// Saves an edit typed in the field and waits for it: nil when saved (also when its labels could not be reread
    /// after it: the edit stands), else why, with what was typed.
    private func saveTypedEdit(_ words: [ReviewWord], text: String, movesSeen: Int,
                               seenEpoch: Int) async -> String? {
        var saved = false
        let committed: (ReviewWordEdit) -> Void = { _ in saved = true }
        do {
            _ = try await review.editWords(words.map(\.ref), to: text, seenMoves: movesSeen, whileUnread: true,
                                           expecting: words.map(\.shown), seenEpoch: seenEpoch,
                                           committed: committed)
            return nil
        } catch {
            // A change that failed: every join goes, as for any other (`saveEdit`).
            clearJoins()
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
        let fromField = turnList.takeOpenWordEdit()
        let held = heldOpenEdit
        heldOpenEdit = nil
        let open = fromField ?? held?.edit
        let epoch = fromField?.wordsEpoch ?? held?.epoch ?? review.wordsEpoch
        let typed = open.map { open in
            ReviewSession.TypedEdit(words: open.words.map(\.ref), text: open.text, seenMoves: open.movesSeen,
                                    expected: open.words.map(\.shown), seenEpoch: epoch)
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
        + "Return at the start of a word (← first) splits the turn before it; at its end (→ first), after it. Space "
        + "still plays and pauses."
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
