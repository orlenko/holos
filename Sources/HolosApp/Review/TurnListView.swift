import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers

/// A choice in a speaker menu (a turn's pop-up, "Assign to…").
final class AssignChoice: NSObject {
    enum Kind: Equatable {
        case target(ReviewAssignTarget)
        /// "New Speaker…": asks for an optional name first.
        case newSpeaker
    }

    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }
}

/// The items of a speaker menu: the meeting's speakers, the known people without a speaker in it, "Unknown", and
/// "New Speaker…". Menu items are made directly (never by title), so two speakers with one name stay apart.
@MainActor
enum AssignMenu {
    static func items(speakers: [ProjectedSpeaker], people: [SpeakerProfile], unknownTitle: String = "Unknown")
        -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for speaker in speakers {
            items.append(item(title(of: speaker), .target(.speaker(speaker.id))))
        }
        let linked = Set(speakers.compactMap(\.profileID))
        let others = people.filter { !linked.contains($0.id) }
        if !others.isEmpty {
            items.append(.separator())
            items.append(.sectionHeader(title: "People"))
            for person in others {
                items.append(item(person.displayName + (person.isSelf ? " (you)" : ""),
                                  .target(.person(profileID: person.id))))
            }
        }
        items.append(.separator())
        items.append(item(unknownTitle, .target(.unknown)))
        items.append(item("New Speaker…", .newSpeaker))
        return items
    }

    /// "Jim", "Speaker 3", "Jim (auto)", with the number key that assigns to it ("2 · Maria") for speakers 1–9.
    static func title(of speaker: ProjectedSpeaker) -> String {
        (1...9).contains(speaker.ordinal) ? "\(speaker.ordinal) · \(speaker.label)" : speaker.label
    }

    private static func item(_ title: String, _ kind: AssignChoice.Kind) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = AssignChoice(kind)
        return item
    }
}

/// The turn table: the number keys go to the window, everything else to the table (the window takes Space and the
/// playback keys before they get here). A plain single click on a word of a turn's text selects the turn and plays
/// from that word.
final class TurnTableView: NSTableView {
    /// 1–9: assign the selection to the speaker with that number.
    var onDigit: ((Int) -> Void)?
    /// A word was clicked: the session time it starts at.
    var onWordClick: ((Double) -> Void)?
    /// Return or Enter: play the selected turn (the keyboard's way to what a click on its timestamp does).
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers {
            if characters.count == 1, let digit = Int(characters), (1...9).contains(digit) {
                onDigit?(digit)
                return
            }
            if characters == "\r" || characters == "\u{3}" {
                onReturn?()
                return
            }
        }
        // ↑/↓, Page Up/Down, Home/End scroll the list as the reader moves: following playback holds off as for a
        // scroll with the mouse.
        switch event.specialKey {
        case .upArrow?, .downArrow?, .pageUp?, .pageDown?, .home?, .end?: onKeyboardScroll?()
        default: break
        }
        super.keyDown(with: event)
    }

    /// The reader moved through the list with the keyboard.
    var onKeyboardScroll: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        // Selection first (the table tracks the mouse until it is released), as for any click on a row.
        super.mouseDown(with: event)
        // ⇧/⌘ clicks extend the selection, a double click is a second click on the same word, and a drag selects
        // rows: none of them plays.
        guard event.clickCount == 1, modifiers.isEmpty else { return }
        if let up = NSApplication.shared.currentEvent, up.type == .leftMouseUp, up.window === window {
            let end = convert(up.locationInWindow, from: nil)
            guard abs(end.x - point.x) <= 4, abs(end.y - point.y) <= 4 else { return }
        }
        let row = row(at: point)
        guard row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView,
              let start = cell.bodyText.wordStart(at: cell.bodyText.convert(point, from: self)) else { return }
        onWordClick?(start)
    }
}

/// A turn's text: wrapping, neither editable nor selectable, with each word's start time for playing from it. Clicks
/// go through to the table (`TurnTableView.mouseDown`), the pointer is a pointing hand over the text, and the word
/// playing is tinted. Laid out with TextKit 1 exactly as `height(of:width:)` measures it.
@MainActor
final class TurnTextView: NSTextView {
    private var wordRanges: [NSRange?] = []
    private var wordStarts: [Double] = []
    private var wordTexts: [String] = []
    private var playingWord: Int?
    /// Plays from a session time: VoiceOver's "Play from …" actions, one per word (clicks go through the table).
    var onPlay: ((Double) -> Void)?
    private var textColorShown: NSColor = .labelColor
    /// The root of this view's text system (it keeps the layout manager and the container): a text view made with
    /// its own container does not own its storage.
    private var ownedStorage: NSTextStorage?

    static func make() -> TurnTextView {
        let (storage, _, container) = textSystem()
        let view = TurnTextView(frame: .zero, textContainer: container)
        view.ownedStorage = storage
        view.isEditable = false
        view.isSelectable = false
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.font = TurnListView.textFont
        view.setAccessibilityHelp("Click a word to play from it, or choose a word in the actions.")
        return view
    }

    /// A text storage, layout manager, and container set up as every turn text is laid out.
    private static func textSystem() -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    private static let measurer: (NSTextStorage, NSLayoutManager, NSTextContainer) = {
        let system = textSystem()
        system.2.widthTracksTextView = false
        return system
    }()

    /// The height `text` takes laid out `width` wide, as a turn text view lays it out.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let (storage, layout, container) = measurer
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: TurnListView.textFont]))
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height
        storage.setAttributedString(NSAttributedString())
        return height
    }

    // Mouse events belong to the table (row selection, then a word click).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    func show(text: String, words: [ReviewWord], color: NSColor) {
        setPlayingWord(nil)
        textColorShown = color
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: TurnListView.textFont, .foregroundColor: color,
        ]))
        wordRanges = ReviewWordRanges.ranges(of: words.map(\.text), in: text)
        wordStarts = words.map(\.start)
        wordTexts = words.map(\.text)
        playingWord = nil
        window?.invalidateCursorRects(for: self)
    }

    /// The keyboard and VoiceOver way to a word (VO-⌘-Space lists them): "Play from “budget” (00:12:03)". Made
    /// when asked for, never announced.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        for (index, start) in wordStarts.enumerated() {
            let word = index < wordTexts.count ? wordTexts[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let name = "Play from “\(word)” (\(TimeFormat.clock(start)))"
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let onPlay = self?.onPlay else { return false }
                onPlay(start)
                return true
            })
        }
        return actions.isEmpty ? nil : actions
    }

    /// The text color for the row's background (white on a selected row).
    func setTextColor(_ color: NSColor) {
        guard color != textColorShown, let storage = textStorage, storage.length > 0 else {
            textColorShown = color
            return
        }
        textColorShown = color
        storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
    }

    /// Tints word `index` (nil: none) while it plays.
    func setPlayingWord(_ index: Int?) {
        guard index != playingWord, let layout = layoutManager, let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
        playingWord = index
        guard let index, index < wordRanges.count, let range = wordRanges[index],
              NSMaxRange(range) <= storage.length else { return }
        layout.addTemporaryAttributes([
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.25),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ], forCharacterRange: range)
    }

    /// The word being spoken at `time` in this text (nil before its first word).
    func wordIndex(at time: Double) -> Int? {
        ReviewTimeline.wordIndex(at: time, starts: wordStarts)
    }

    /// The start time of the word under `point` (in this view), or nil when the point is not on the text.
    func wordStart(at point: NSPoint) -> Double? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -2, dy: -1).contains(point) else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        guard let word = ReviewWordRanges.word(at: character, ranges: wordRanges), word < wordStarts.count else {
            return nil
        }
        return wordStarts[word]
    }

    /// Where word `index` is drawn, in this view; nil when it is not in the text.
    func rect(ofWord index: Int) -> NSRect? {
        guard index < wordRanges.count, let range = wordRanges[index], let layout = layoutManager,
              let container = textContainer else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
    }

    override func resetCursorRects() {
        guard let layout = layoutManager, let container = textContainer, !wordStarts.isEmpty else { return }
        let glyphs = layout.glyphRange(for: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            self.addCursorRect(used.intersection(self.visibleRect), cursor: .pointingHand)
        }
    }
}

/// The turn list's scroll view: reports scrolling the reader does (wheel, trackpad, scroller), which pauses following
/// playback for a few seconds (`ReviewFollow`); scrolling done by the window is not reported.
final class TurnScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

/// The right pane of the review window (docs/meeting-design.md §5.10): one row per turn with a timestamp button that
/// plays from there, the speaker pop-up, a warning for uncertain turns, and the wrapping text, whose words play from
/// where they are clicked. While the meeting plays, the playing turn and word are tinted. Several turns can be
/// selected with ⇧ and ⌘.
@MainActor
final class TurnListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A timestamp or a word was clicked: play from this session time.
    var onPlay: ((Double) -> Void)?
    var onAssign: (([String], ReviewAssignTarget) -> Void)?
    var onNewSpeaker: (([String]) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// The reader scrolled the turns themselves.
    var onUserScroll: (() -> Void)?

    let table = TurnTableView()
    private let scroll = TurnScrollView()
    private(set) var turns: [ProjectedTurn] = []
    /// Row of each shown turn, by ID.
    private var rowOf: [String: Int] = [:]
    private var labels: [String: String] = [:]
    private var speakers: [ProjectedSpeaker] = []
    private var people: [SpeakerProfile] = []
    private var editable = true
    private var text: (ProjectedTurn) -> String = { _ in "" }
    private var words: (ProjectedTurn) -> [ReviewWord] = { _ in [] }
    /// The turn playing (its ID) and the word of it playing, tinted while shown.
    private(set) var playingTurnID: String?
    private var playingWord: Int?
    /// Row heights by turn ID (with the words they were measured for), for `heightWidth`.
    private var heights: [String: (spans: [WordSpan], height: CGFloat)] = [:]
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
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Data

    /// Shows `turns`, keeping the selected turns selected (by ID, after `resolve`) and reloading only what changed
    /// when the rows are the same turns.
    func update(turns newTurns: [ProjectedTurn], speakers newSpeakers: [ProjectedSpeaker], people newPeople: [SpeakerProfile],
                editable newEditable: Bool, text: @escaping (ProjectedTurn) -> String,
                words: @escaping (ProjectedTurn) -> [ReviewWord], resolve: (String) -> String) {
        let selected = selectedTurnIDs.map(resolve)
        let oldTurns = turns
        let oldLabels = labels
        let menusChanged = newSpeakers != speakers || newPeople.map(\.id) != people.map(\.id)
            || newPeople.map(\.displayName) != people.map(\.displayName) || newEditable != editable
        turns = newTurns
        rowOf = Dictionary(newTurns.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        speakers = newSpeakers
        people = newPeople
        editable = newEditable
        self.text = text
        self.words = words
        labels = Dictionary(newSpeakers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })

        guard oldTurns.map(\.id) == newTurns.map(\.id) else {
            table.reloadData()
            select(selected, scroll: false)
            return
        }
        var changed = IndexSet()
        var resized = IndexSet()
        for (index, turn) in newTurns.enumerated() {
            let old = oldTurns[index]
            if old != turn || oldLabels[turn.speakerID ?? ""] != labels[turn.speakerID ?? ""] { changed.insert(index) }
            if old.spans != turn.spans { resized.insert(index) }
        }
        if menusChanged, let visible = Range(table.rows(in: table.visibleRect)) {
            changed.formUnion(IndexSet(integersIn: visible))
        }
        guard !changed.isEmpty else { return }
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
    }

    var selectedTurnIDs: [String] {
        table.selectedRowIndexes.compactMap { $0 < turns.count ? turns[$0].id : nil }
    }

    var selectedTurns: [ProjectedTurn] {
        table.selectedRowIndexes.compactMap { $0 < turns.count ? turns[$0] : nil }
    }

    func select(_ turnIDs: [String], scroll: Bool) {
        let wanted = Set(turnIDs)
        let rows = IndexSet(turns.indices.filter { wanted.contains(turns[$0].id) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { table.scrollRowToVisible(first) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { turns.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < turns.count else { return 28 }
        let width = textWidth
        if width != heightWidth {
            heights.removeAll()
            heightWidth = width
        }
        let turn = turns[row]
        // Keyed by ID and checked against the words: a split changes a turn's words and keeps its ID.
        if let cached = heights[turn.id], cached.spans == turn.spans { return cached.height }
        // Measured as the row's text view lays it out (`TurnCellView.layout`).
        let measured = TurnTextView.height(of: text(turn), width: TurnCellView.textViewWidth(forTextWidth: width))
        let height = max(28, ceil(measured) + 10)
        heights[turn.id] = (turn.spans, height)
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < turns.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("turnCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TurnCellView ?? {
            let cell = TurnCellView()
            cell.identifier = identifier
            cell.timeButton.target = self
            cell.timeButton.action = #selector(timeClicked(_:))
            cell.speakerPopUp.target = self
            cell.speakerPopUp.action = #selector(speakerChosen(_:))
            cell.bodyText.onPlay = { [weak self] seconds in self?.onPlay?(seconds) }
            return cell
        }()
        let turn = turns[row]
        cell.configure(turn: turn, text: text(turn), words: words(turn),
                       menu: AssignMenu.items(speakers: speakers, people: people), editable: editable)
        let playing = turn.id == playingTurnID
        cell.setPlaying(playing, word: playing ? playingWord : nil)
        return cell
    }

    // MARK: - Playback

    /// Tints the turn playing (`turnID`, nil: none) and its word being spoken at `time`.
    func showPlaying(turnID: String?, at time: Double) {
        if turnID != playingTurnID {
            if let old = playingTurnID { cell(forTurn: old)?.setPlaying(false, word: nil) }
            playingTurnID = turnID
            playingWord = nil
        }
        guard let turnID, let cell = cell(forTurn: turnID) else {
            // Not on screen: its word is found when its row is made.
            if let turnID, let row = rowOf[turnID] {
                playingWord = ReviewTimeline.wordIndex(at: time, starts: words(turns[row]).map(\.start))
            }
            return
        }
        playingWord = cell.bodyText.wordIndex(at: time)
        cell.setPlaying(true, word: playingWord)
    }

    /// Scrolls the playing turn into view (with a little room around it); within a turn taller than the list, its
    /// playing word. Nothing when it is already in view or not shown.
    func scrollToPlaying() {
        guard let turnID = playingTurnID, let row = rowOf[turnID] else { return }
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

    private func cell(forTurn turnID: String) -> TurnCellView? {
        guard let row = rowOf[turnID], row < table.numberOfRows else { return nil }
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
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if heightsStale { refreshHeights() }
    }

    private func refreshHeights() {
        heightsStale = false
        guard textWidth != heightWidth, !turns.isEmpty else { return }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<turns.count))
    }

    private var textWidth: CGFloat {
        (table.tableColumns.first?.width ?? bounds.width) - TurnCellView.textX - 4
    }

    // MARK: - Actions

    @objc private func timeClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < turns.count else { return }
        onPlay?(turns[row].start)
    }

    @objc private func speakerChosen(_ sender: NSPopUpButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < turns.count, let choice = sender.selectedItem?.representedObject as? AssignChoice else {
            return
        }
        // The chosen speaker applies to the whole selection when the row is part of it.
        let ids = table.selectedRowIndexes.contains(row) ? selectedTurnIDs : [turns[row].id]
        switch choice.kind {
        case .target(let target): onAssign?(ids, target)
        case .newSpeaker: onNewSpeaker?(ids)
        }
        // Until the labels come back, show the turn's current speaker again rather than a menu command.
        if case .newSpeaker = choice.kind { table.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }
}

/// One turn row: timestamp button, speaker pop-up, uncertainty warning, and text. Laid out by hand (fixed columns,
/// wrapping text), matching `TurnListView`'s row heights. The turn playing has a tinted background and an accent bar
/// on its leading edge.
@MainActor
final class TurnCellView: NSTableCellView {
    static let timeWidth: CGFloat = 72
    static let popUpWidth: CGFloat = 176
    static let warningWidth: CGFloat = 86
    static let gap: CGFloat = 6
    static var textX: CGFloat { 4 + timeWidth + gap + popUpWidth + gap + warningWidth + gap }
    /// Space on each side of the text inside its column (what a wrapping label kept).
    static let textInset: CGFloat = 2

    let timeButton = NSButton(title: "", target: nil, action: nil)
    let speakerPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let warningLabel = NSTextField(labelWithString: "")
    let bodyText = TurnTextView.make()
    private var menuSignature: [String] = []
    private var isPlayingTurn = false

    override var isFlipped: Bool { true }

    /// The width a turn's text is laid out in, for a text column `textWidth` wide.
    static func textViewWidth(forTextWidth textWidth: CGFloat) -> CGFloat {
        max(40, textWidth) - 2 * textInset
    }

    init() {
        super.init(frame: .zero)
        timeButton.bezelStyle = .inline
        timeButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeButton.toolTip = "Play from here"
        speakerPopUp.controlSize = .small
        speakerPopUp.font = .systemFont(ofSize: 12)
        warningLabel.textColor = .systemOrange
        warningLabel.font = .systemFont(ofSize: 11)
        for view in [timeButton, speakerPopUp, warningLabel, bodyText] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { bodyText.setTextColor(textColor) }
    }

    private var textColor: NSColor {
        backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
    }

    /// Tints this row as the turn playing, with `word` (nil: none) as the word being spoken.
    func setPlaying(_ playing: Bool, word: Int?) {
        if playing != isPlayingTurn {
            isPlayingTurn = playing
            needsDisplay = true
        }
        bodyText.setPlayingWord(playing ? word : nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isPlayingTurn else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }

    func configure(turn: ProjectedTurn, text: String, words: [ReviewWord], menu items: [NSMenuItem], editable: Bool) {
        timeButton.title = TimeFormat.clock(turn.start)
        // The menu is replaced only when its items changed, so an update never swaps a menu that is open.
        let signature = items.map { item in
            item.isSeparatorItem ? "-" : item.title + "\u{1f}" + String(describing: (item.representedObject as? AssignChoice)?.kind)
        }
        if signature != menuSignature {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items { menu.addItem(item) }
            speakerPopUp.menu = menu
            menuSignature = signature
        }
        let current: ReviewAssignTarget = turn.speakerID.map { .speaker($0) } ?? .unknown
        if let index = speakerPopUp.itemArray.firstIndex(where: {
            ($0.representedObject as? AssignChoice)?.kind == .target(current)
        }) {
            speakerPopUp.selectItem(at: index)
        }
        speakerPopUp.isEnabled = editable
        warningLabel.stringValue = Self.warning(turn)
        warningLabel.toolTip = Self.warningHelp(turn)
        bodyText.show(text: text, words: words, color: textColor)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        timeButton.frame = NSRect(x: 4, y: 4, width: Self.timeWidth, height: 20)
        speakerPopUp.frame = NSRect(x: 4 + Self.timeWidth + Self.gap, y: 2, width: Self.popUpWidth, height: 22)
        warningLabel.frame = NSRect(x: 4 + Self.timeWidth + Self.gap + Self.popUpWidth + Self.gap, y: 6,
                                    width: Self.warningWidth, height: 16)
        // The row is `measured + 10` tall (`TurnListView.tableView(_:heightOfRow:)`): 5 above the text, 5 below.
        let width = Self.textViewWidth(forTextWidth: bounds.width - Self.textX - 4)
        let frame = NSRect(x: Self.textX + Self.textInset, y: 5, width: width, height: max(18, height - 10))
        guard bodyText.frame != frame else { return }
        bodyText.frame = frame
        bodyText.window?.invalidateCursorRects(for: bodyText)
    }

    /// "⚠ overlap", "⚠ unknown", "⚠ unsure", or nothing.
    static func warning(_ turn: ProjectedTurn) -> String {
        guard turn.uncertain else { return "" }
        if turn.overlap { return "⚠ overlap" }
        if turn.speakerID == nil { return "⚠ unknown" }
        return "⚠ unsure"
    }

    static func warningHelp(_ turn: ProjectedTurn) -> String? {
        guard turn.uncertain else { return nil }
        if turn.overlap { return "Someone else spoke at the same time." }
        if turn.speakerID == nil { return "No speaker was found for this turn." }
        return "The speaker is uncertain here."
    }
}
