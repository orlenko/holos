import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers

/// The right pane of the review window (docs/meeting-design.md §5.10): one row per paragraph (consecutive turns of one
/// speaker, `ReviewParagraphs`) with a timestamp button that plays from there, the speaker pop-up (which lists a voice
/// match's person first, "Jim (suggested)"), and the wrapping text, whose words play from where they are clicked.
/// Uncertain rows look like any other: Next Uncertain finds them, and VoiceOver hears it on their pop-up. While the
/// meeting plays, the paragraph and word playing are tinted. Several rows can be selected with ⇧ and ⌘; whatever acts
/// on rows (assigning a speaker, the selection's turns) acts on every turn of them.
@MainActor
final class TurnListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A timestamp or a word was clicked: play from this session time.
    var onPlay: ((Double) -> Void)?
    var onRevertFix: ((WordRef) -> Void)?
    var onAssign: (([String], ReviewAssignTarget) -> Void)?
    var onNewSpeaker: (([String]) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// "Jim (suggested)" chosen in a row's pop-up: give that turn (its ID) to the named speaker it sounds like.
    var onAcceptHint: ((String) -> Void)?
    /// The reader scrolled the turns themselves.
    var onUserScroll: (() -> Void)?
    /// Edit mode: `words` (shown words of one segment of one turn, in order) are to become `text`; `addTerm`: ⌥Return
    /// asked for the new text in the word list too; `seen`: the revision `words` follow (the field opened under it).
    var onEditWords: ((_ words: [ReviewWord], _ text: String, _ addTerm: Bool, _ seen: ReviewRevision) -> Void)?
    /// The review's word moves (`ReviewSession.wordMoves`) as of the last update: the open field follows them.
    private(set) var wordMoves: [ReviewWordMove] = []
    /// What the edit mode banner says for a moment (a selection stopped at a turn's end), nil for its usual text.
    var onEditMessage: ((String?) -> Void)?
    /// VoiceOver asked to edit a word while edit mode is off: the window turns it on (`editingWords`).
    var onRequestEditing: (() -> Void)?
    /// The text an edit field over `words` starts with (`ReviewSession.shownText`); nil: their text as shown.
    var editText: (([ReviewWord]) -> String?)?
    /// Why `words` cannot be edited, known before a field opens (`ReviewSession.wordEditRefusal`); nil when they can.
    var editRefusal: (([ReviewWord]) -> String?)?
    /// Why the fix on a word cannot be reverted (`ReviewSession.revertRefusal`); nil when it can. The context menu
    /// and VoiceOver offer Revert only then.
    var revertRefusal: ((WordRef) -> String?)?
    /// The deleted words offered for a Restore from a turn (`ReviewSession.deletedWords(near:)`), by turn ID.
    var deletedWords: ((String) -> [ReviewDeletedWords])?
    /// Restore Deleted “…” chosen (context menu, VoiceOver): the segment whose words come back.
    var onRestoreDeleted: ((String) -> Void)?
    /// The open field's edit when it closes for any reason but Esc or a save (`keepWordEdit`: words, what was typed,
    /// the revision its words follow): the window queues it, so it waits for the review rather than being lost.
    var onKeepWordEdit: ((_ words: [ReviewWord], _ text: String, _ seen: ReviewRevision) -> Void)?
    /// Split a turn (or break its paragraph) at a word: Return at a word's start in edit mode, or Split Turn Here in a
    /// word's context menu (`TurnListView+Splitting`): `split`, as `resolveSplit` gave it for `request`.
    var onSplit: ((_ split: ReviewParagraphSplit, _ request: ReviewSplitRequest) -> Void)?
    /// What a split request makes now: the review finds where the word is (following word moves since it was
    /// chosen) and checks the split as it is checked when made (`ReviewSession.splitPlace`, `splitRefusal`).
    var resolveSplit: ((ReviewSplitRequest) -> ReviewSplitResolution)?
    /// A split chosen from a word's menu was refused when it was made (the words changed while the menu was open):
    /// why, for the window to say.
    var onSplitRefused: ((String) -> Void)?
    /// Join a row to the row before it (`TurnListView+Joining`): Backspace at the start of a row's first word in edit
    /// mode (forward Delete at the end of the row before), or Join With Previous Turn on a row's first word: `join`, as
    /// `resolveJoin` gave it for `request`.
    var onJoin: ((_ join: ReviewParagraphJoin, _ request: ReviewJoinRequest) -> Void)?
    /// What a join request makes now: the rows as the window has them (all of them, a search hiding some), and the
    /// review's state (`ReviewWindow.resolveJoin`).
    var resolveJoin: ((ReviewJoinRequest) -> ReviewJoinResolution)?
    /// A join chosen from a word's menu or VoiceOver was refused when it was made: why, for the window to say.
    var onJoinRefused: ((String) -> Void)?
    /// Opens a row's speaker pop-up after a split, so the second part can be given its speaker at once (tests record
    /// it instead: a pop-up's menu tracks the mouse until it closes).
    var openSpeakerMenu: (NSPopUpButton) -> Void = { popUp in
        DispatchQueue.main.async {
            guard TurnListView.mayOpenSpeakerMenu(in: popUp.window) else { return }
            popUp.performClick(nil)
        }
    }

    /// Whether the pop-up may open now, as it is about to: its window has the keyboard (the person may have gone on
    /// to type in another window while the split saved) and no text field in it is being typed in.
    static func mayOpenSpeakerMenu(in window: NSWindow?) -> Bool {
        guard let window, window.isKeyWindow else { return false }
        return (window.firstResponder as? NSText)?.isFieldEditor != true
    }
    /// Words can be edited now (`ReviewSession.canEditWords`); edit mode shows, but a click opens no field, otherwise.
    var canEditWords = true {
        didSet { if !canEditWords { keepWordEdit() } }
    }

    let table = TurnTableView()
    private let scroll = TurnScrollView()
    private(set) var paragraphs: [ReviewParagraph] = []
    /// Row of each shown turn, by turn ID.
    private var rowOf: [String: Int] = [:]
    private var labels: [String: String] = [:]
    /// Turns that sound like a person named in the meeting (`ReviewSession.voiceMatches`), by turn ID.
    private var hints: [String: MeetingTurnHint] = [:]
    private var speakers: [ProjectedSpeaker] = []
    private var people: [SpeakerProfile] = []
    private(set) var editable = true
    private var text: (ProjectedTurn) -> String = { _ in "" }
    private(set) var words: (ProjectedTurn) -> [ReviewWord] = { _ in [] }
    /// Edit mode (the window's Edit Words, ⌘E): word clicks edit words instead of playing from them.
    var editingWords = false {
        didSet {
            guard editingWords != oldValue else { return }
            editingWordsChanged()
        }
    }
    /// The words being edited, while the edit field is open.
    var wordEdit: WordEditTarget? {
        didSet { if wordEdit != nil, oldValue == nil { fieldsOpened += 1 } }
    }
    /// How many times a word's edit field opened: a split that finishes after the person opened one (it may have
    /// closed again since, its row replaced) leaves the keyboard alone.
    private(set) var fieldsOpened = 0
    /// A ⇧-click is on its way: the field losing the keyboard to the table does not save (the selection grows).
    var extendingWordEdit = false
    /// `ReviewSession.wordsEpoch` as of the last update: a field opened before it changed is not put back on its words.
    var wordsEpoch = 0
    /// The speaker labels' run the rows show (`ReviewProjection.runID`), which a split request names.
    var runID: String?
    /// What the rows show as of the last update, as a command hands it back: `wordMoves`, `wordsEpoch`, `runID`.
    var revision: ReviewRevision { ReviewRevision(moves: wordMoves.count, wordsEpoch: wordsEpoch, runID: runID) }
    /// The field's text selection when a ⇧-click came, restored when the selection cannot grow.
    var selectionBeforeExtension: NSRange?
    /// The field over the words being edited.
    let editField = WordEditField()
    /// The paragraph playing (its ID) and the word of it playing, tinted while shown.
    private(set) var playingParagraphID: String?
    private var playingWord: Int?
    /// Row heights by paragraph ID (with the words and text they were measured for), for `heightWidth`.
    private var heights: [String: (spans: [WordSpan], text: String, height: CGFloat)] = [:]
    private var heightWidth: CGFloat = 0
    private var heightsStale = false

    static let textFont = NSFont.systemFont(ofSize: 13)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("turn"))
        column.resizingMask = .autoresizingMask
        column.width = 700
        column.minWidth = TurnCellView.textX + 120
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(columnResized),
                                               name: NSTableView.columnDidResizeNotification, object: table)
        // Dragging the scroller (the wheel and the trackpad come through `TurnScrollView.scrollWheel`).
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(userScrolled), name: name, object: scroll)
        }
        scroll.onUserScroll = { [weak self] in self?.onUserScroll?() }
        table.onKeyboardScroll = { [weak self] in self?.onUserScroll?() }
        table.onWordClick = { [weak self] seconds in self?.onPlay?(seconds) }
        table.onRevertFix = { [weak self] word in self?.onRevertFix?(word) }
        table.deletedWordsOffer = { [weak self] row in self?.deletedWordsOffer(row: row) ?? [] }
        table.onRestoreDeleted = { [weak self] segmentID in self?.onRestoreDeleted?(segmentID) }
        table.onWordEditClick = { [weak self] row, from, to, extend in
            self?.beginEditing(row: row, from: from, through: to, extend: extend)
        }
        table.splitOffer = { [weak self] row, word, index in self?.splitOffer(row: row, word: word, index: index) }
        table.onSplitChosen = { [weak self] choice in self?.splitChosen(choice) }
        table.joinOffer = { [weak self] row, index in self?.joinOffer(row: row, index: index) }
        table.onJoinChosen = { [weak self] choice in self?.joinChosen(choice) }
        table.onEditClickBegan = { [weak self] extend in self?.editClickBegan(extend: extend) }
        table.onEditClickEnded = { [weak self] in self?.editClickEnded() }
        editField.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    /// The deleted words `row`'s menu offers to restore: those offered from any of its turns (`deletedWords`), only
    /// while words can be edited.
    func deletedWordsOffer(row: Int) -> [ReviewDeletedWords] {
        guard editable, canEditWords, row >= 0, row < paragraphs.count, let deletedWords else { return [] }
        return paragraphs[row].turns.flatMap { deletedWords($0.id) }
    }

    // MARK: - Data

    /// Shows `paragraphs`, keeping the selected turns' rows selected (by turn ID, after `resolve`; never a row that
    /// took in turns that were not selected) and reloading only what changed when the rows are the same paragraphs.
    func update(paragraphs newParagraphs: [ReviewParagraph], speakers newSpeakers: [ProjectedSpeaker],
                people newPeople: [SpeakerProfile], editable newEditable: Bool,
                hints newHints: [String: MeetingTurnHint] = [:], text: @escaping (ProjectedTurn) -> String,
                words: @escaping (ProjectedTurn) -> [ReviewWord], resolve: (String) -> String,
                wordMoves newWordMoves: [ReviewWordMove] = []) {
        wordMoves = newWordMoves
        let selected = selectedTurnIDs.map(resolve)
        // The open field's row and turn by their saved IDs: a part made by a split still saving when the field opened
        // had a temporary one, which the saved split replaces (a paragraph's ID is its first turn's).
        if let target = wordEdit {
            wordEdit?.paragraphID = resolve(target.paragraphID)
            wordEdit?.turnID = target.turnID.map(resolve)
        }
        let oldParagraphs = paragraphs
        let oldLabels = labels
        let oldHints = hints
        hints = newHints
        let menusChanged = newSpeakers != speakers || newPeople.map(\.id) != people.map(\.id)
            || newPeople.map(\.displayName) != people.map(\.displayName) || newEditable != editable
        paragraphs = newParagraphs
        var rows: [String: Int] = [:]
        for (row, paragraph) in newParagraphs.enumerated() {
            for id in paragraph.turnIDs where rows[id] == nil { rows[id] = row }
        }
        rowOf = rows
        speakers = newSpeakers
        people = newPeople
        editable = newEditable
        self.text = text
        self.words = words
        labels = Dictionary(newSpeakers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })

        // A word edit (or a word-fix revert) can change a paragraph's text and nothing else about its turns.
        let oldTexts = shownTexts
        shownTexts = Dictionary(newParagraphs.map { ($0.id, self.text(of: $0)) }, uniquingKeysWith: { first, _ in first })
        guard oldParagraphs.map(\.id) == newParagraphs.map(\.id) else {
            table.reloadData()
            restoreSelection(selected)
            followWordEdit()
            return
        }
        var changed = IndexSet()
        var resized = IndexSet()
        for (index, paragraph) in newParagraphs.enumerated() {
            let old = oldParagraphs[index]
            let textChanged = oldTexts[paragraph.id] != shownTexts[paragraph.id]
            if old != paragraph || textChanged || oldLabels[paragraph.speakerID ?? ""] != labels[paragraph.speakerID ?? ""]
                || Self.hint(of: old, in: oldHints) != Self.hint(of: paragraph, in: hints) {
                changed.insert(index)
            }
            if old.spans != paragraph.spans || textChanged { resized.insert(index) }
        }
        if menusChanged, let visible = Range(table.rows(in: table.visibleRect)) {
            changed.formUnion(IndexSet(integersIn: visible))
        }
        // Rows that took in or gave up turns keep their IDs: the selection follows the turns, not the rows.
        if !changed.isEmpty {
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
        }
        restoreSelection(selected)
        followWordEdit()
    }

    /// Each shown paragraph's text, by paragraph ID, as last shown.
    private var shownTexts: [String: String] = [:]

    /// Selects again the rows of the turns selected before an update, only rows all of whose turns were selected: a
    /// row that took in other turns (a turn given to the speaker before it joins that paragraph) is not selected, so
    /// the selection never grows to turns the reader did not choose.
    private func restoreSelection(_ selected: [String]) {
        let wanted = Set(selected)
        let rows = IndexSet(Set(selected.compactMap { rowOf[$0] }).filter { row in
            paragraphs[row].turnIDs.allSatisfy(wanted.contains)
        })
        guard rows != table.selectedRowIndexes else { return }
        table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// Every turn of the selected rows, in row order.
    var selectedTurnIDs: [String] { selectedParagraphs.flatMap(\.turnIDs) }

    /// Every turn of the selected rows, in row order.
    var selectedTurns: [ProjectedTurn] { selectedParagraphs.flatMap(\.turns) }

    var selectedParagraphs: [ReviewParagraph] {
        table.selectedRowIndexes.compactMap { $0 < paragraphs.count ? paragraphs[$0] : nil }
    }

    /// Selects the rows holding `turnIDs`.
    func select(_ turnIDs: [String], scroll: Bool) {
        let rows = IndexSet(turnIDs.compactMap { rowOf[$0] })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { table.scrollRowToVisible(first) }
    }

    /// The turn is in a row shown now (search shows only rows with a match).
    func shows(turnID: String) -> Bool { rowOf[turnID] != nil }

    /// The hint a paragraph's pop-up offers first: its first turn that sounds like someone named in the meeting.
    private static func hint(of paragraph: ReviewParagraph, in hints: [String: MeetingTurnHint]) -> MeetingTurnHint? {
        guard !hints.isEmpty else { return nil }
        return paragraph.turnIDs.lazy.compactMap { hints[$0] }.first
    }

    /// The text a paragraph shows: its turns' texts joined with spaces.
    private func text(of paragraph: ReviewParagraph) -> String {
        paragraph.turns.map(text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { paragraphs.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < paragraphs.count else { return 28 }
        let width = textWidth
        if width != heightWidth {
            heights.removeAll()
            heightWidth = width
        }
        let paragraph = paragraphs[row]
        let spans = paragraph.spans
        // Keyed by ID and checked against the words: a split, or a turn joining or leaving, changes a paragraph's
        // words and keeps its ID.
        let shown = text(of: paragraph)
        if let cached = heights[paragraph.id], cached.spans == spans, cached.text == shown {
            return cached.height
        }
        // Measured as the row's text view lays it out (`TurnCellView.layout`).
        let measured = TurnTextView.height(of: shown, width: TurnCellView.textViewWidth(forTextWidth: width))
        let height = max(28, ceil(measured) + 10)
        heights[paragraph.id] = (spans, shown, height)
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < paragraphs.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("turnCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TurnCellView ?? {
            let cell = TurnCellView()
            cell.identifier = identifier
            cell.timeButton.target = self
            cell.timeButton.action = #selector(timeClicked(_:))
            cell.speakerPopUp.target = self
            cell.speakerPopUp.action = #selector(speakerChosen(_:))
            cell.bodyText.onPlay = { [weak self] seconds in self?.onPlay?(seconds) }
            cell.bodyText.onRevertFix = { [weak self] word in self?.onRevertFix?(word) }
            cell.bodyText.canEditWord = { [weak self] in (self?.editable ?? false) && (self?.canEditWords ?? false) }
            cell.bodyText.revertRefusal = { [weak self] word in self?.revertRefusal?(word) }
            cell.bodyText.onEditWord = { [weak self, weak cell] word in
                guard let self, let cell, self.editable, self.canEditWords else { return false }
                let row = self.table.row(for: cell)
                guard row >= 0 else { return false }
                if !self.editingWords { self.onRequestEditing?() }
                self.beginEditing(row: row, from: word, through: word, extend: false)
                return self.wordEdit != nil
            }
            // Not in edit mode, as the context menu (Return at a word's start splits there).
            cell.bodyText.splitChoices = { [weak self, weak cell] in
                guard let self, let cell, !self.editingWords else { return [] }
                return self.splitRequests(row: self.table.row(for: cell)).map { $0.map(SplitChoice.init) }
            }
            cell.bodyText.onSplitChosen = { [weak self] choice in self?.splitChosen(choice) }
            wireJoin(cell)
            cell.bodyText.deletedWordsChoices = { [weak self, weak cell] in
                guard let self, let cell else { return [] }
                return self.deletedWordsOffer(row: self.table.row(for: cell))
            }
            cell.bodyText.onRestoreDeleted = { [weak self] segmentID in self?.onRestoreDeleted?(segmentID) }
            return cell
        }()
        cell.bodyText.editingWords = editingWords
        let paragraph = paragraphs[row]
        let hint = Self.hint(of: paragraph, in: hints)
        cell.configure(paragraph: paragraph, text: text(of: paragraph), words: paragraph.turns.flatMap(words),
                       menu: (hint.map { AssignMenu.suggestion($0, in: paragraph) } ?? [])
                           + AssignMenu.items(speakers: speakers, people: people),
                       editable: editable, hint: hint)
        let playing = paragraph.id == playingParagraphID
        cell.setPlaying(playing, word: playing ? playingWord : nil)
        return cell
    }

    // MARK: - Playback

    /// Tints the paragraph playing and its word being spoken at `time`: the paragraph of `turnID` (the turn being
    /// spoken; none when it is not shown), or in a pause, the paragraph whose span holds `time` (so a pause inside a
    /// paragraph does not untint it). Nothing in silence between paragraphs. True when the paragraph or the word
    /// shown playing changed (a seek within a paragraph taller than the list moves only the word).
    @discardableResult
    func showPlaying(turnID: String?, at time: Double) -> Bool {
        // A turn spoken that is not shown (search left it out) tints no row, not one it overlaps.
        let row = turnID.map { rowOf[$0] } ?? ReviewParagraphs.index(at: time, in: paragraphs)
        let paragraphID = row.map { paragraphs[$0].id }
        let changed = paragraphID != playingParagraphID
        let previousWord = playingWord
        if changed {
            if let old = playingParagraphID, let oldRow = rowOf[old] { cell(forRow: oldRow)?.setPlaying(false, word: nil) }
            playingParagraphID = paragraphID
            playingWord = nil
        }
        guard let row else { return changed }
        let paragraph = paragraphs[row]
        playingWord = ReviewParagraphs.playingWord(in: paragraph, turnID: turnID, at: time,
                                                   starts: paragraph.turns.map { words($0).map(\.start) })
        // Not on screen: its word is shown when its row is made.
        cell(forRow: row)?.setPlaying(true, word: playingWord)
        return changed || playingWord != previousWord
    }

    /// Nothing is tinted (playback has not started, or is off).
    func clearPlaying() {
        guard let old = playingParagraphID else { return }
        if let row = rowOf[old] { cell(forRow: row)?.setPlaying(false, word: nil) }
        playingParagraphID = nil
        playingWord = nil
    }

    /// Scrolls the paragraph playing into view (with a little room around it); within a paragraph taller than the
    /// list, its playing word. Nothing when it is already in view or not shown.
    func scrollToPlaying() {
        guard let paragraphID = playingParagraphID, let row = rowOf[paragraphID] else { return }
        let visible = table.visibleRect
        var target = table.rect(ofRow: row)
        if target.height > visible.height - 24 {
            // The row's view is made (and laid out) when it is off screen, so the word can be found in it.
            guard let word = playingWord,
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TurnCellView else {
                if !visible.intersects(target) { table.scrollRowToVisible(row) }
                return
            }
            cell.layoutSubtreeIfNeeded()
            guard let wordRect = cell.bodyText.rect(ofWord: word) else {
                if !visible.intersects(target) { table.scrollRowToVisible(row) }
                return
            }
            target = table.convert(wordRect, from: cell.bodyText).insetBy(dx: 0, dy: -24)
        } else {
            target = target.insetBy(dx: 0, dy: -12)
        }
        guard !visible.contains(target) else { return }
        table.scrollToVisible(target)
    }

    private func cell(forRow row: Int) -> TurnCellView? {
        guard row < table.numberOfRows else { return nil }
        return table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView
    }

    @objc private func userScrolled() {
        onUserScroll?()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    @objc private func columnResized() {
        if inLiveResize {
            heightsStale = true
        } else {
            refreshHeights()
        }
        // The text rewraps at once: an open edit field follows its words.
        repositionWordEdit()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if heightsStale { refreshHeights() }
        repositionWordEdit()
    }

    private func refreshHeights() {
        heightsStale = false
        guard textWidth != heightWidth, !paragraphs.isEmpty else { return }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<paragraphs.count))
    }

    private var textWidth: CGFloat {
        (table.tableColumns.first?.width ?? bounds.width) - TurnCellView.textX - 4
    }

    // MARK: - Actions

    @objc private func timeClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < paragraphs.count else { return }
        onPlay?(paragraphs[row].start)
    }

    @objc private func speakerChosen(_ sender: NSPopUpButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < paragraphs.count else { return }
        // "Jim (suggested)": that turn alone goes to Jim, whatever else is selected (`acceptTurnHint`). The pop-up
        // shows the row's speaker again until the change comes back (or is refused, the hint gone).
        if let hint = sender.selectedItem?.representedObject as? HintChoice {
            onAcceptHint?(hint.turnID)
            table.reloadData(forRowIndexes: [row], columnIndexes: [0])
            return
        }
        guard let choice = sender.selectedItem?.representedObject as? AssignChoice else { return }
        // The chosen speaker applies to every turn of the row, and to the whole selection when the row is part of it.
        let ids = table.selectedRowIndexes.contains(row) ? selectedTurnIDs : paragraphs[row].turnIDs
        switch choice.kind {
        case .target(let target): onAssign?(ids, target)
        case .newSpeaker: onNewSpeaker?(ids)
        }
        // Until the labels come back, show the row's current speaker again rather than a menu command.
        if case .newSpeaker = choice.kind { table.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }
}
