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

private final class WordFixChoice: NSObject {
    let word: WordRef
    init(_ word: WordRef) { self.word = word }
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
/// from that word; in edit mode (`editingWords`), a click, a ⇧-click, or a drag over words edits them instead.
final class TurnTableView: NSTableView {
    /// 1–9: assign the selection to the speaker with that number.
    var onDigit: ((Int) -> Void)?
    /// A word was clicked: the session time it starts at.
    var onWordClick: ((Double) -> Void)?
    /// Edit mode: words clicked do not play, they are edited.
    var editingWords = false
    /// Edit mode: words `from`…`to` (indices into the row's words, either order) of `row` were clicked or dragged
    /// over; `extend`: with ⇧, the selection being edited grows to them.
    var onWordEditClick: ((_ row: Int, _ from: Int, _ to: Int, _ extend: Bool) -> Void)?
    /// Revert the automatic fix under a contextual-menu word.
    var onRevertFix: ((WordRef) -> Void)?
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

    /// Edit mode, before a click is handled: `extend` (⇧) keeps the open field's words to grow from; any other click
    /// saves it first. Then `onEditClickEnded` once the click was handled.
    var onEditClickBegan: ((_ extend: Bool) -> Void)?
    var onEditClickEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if editingWords { onEditClickBegan?(modifiers == [.shift]) }
        defer { if editingWords { onEditClickEnded?() } }
        // Selection first (the table tracks the mouse until it is released), as for any click on a row.
        super.mouseDown(with: event)
        var end = point
        if let up = NSApplication.shared.currentEvent, up.type == .leftMouseUp, up.window === window {
            end = convert(up.locationInWindow, from: nil)
        }
        let dragged = abs(end.x - point.x) > 4 || abs(end.y - point.y) > 4
        let row = row(at: point)
        guard event.clickCount == 1, row >= 0,
              let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView,
              let word = cell.bodyText.wordIndex(atPoint: cell.bodyText.convert(point, from: self)) else { return }
        if editingWords {
            // ⇧ extends what is being edited; a drag within the row takes the words it went over.
            guard modifiers.isEmpty || modifiers == [.shift] else { return }
            var last = word
            if dragged, self.row(at: end) == row,
               let other = cell.bodyText.wordIndex(atPoint: cell.bodyText.convert(end, from: self)) {
                last = other
            }
            handleWordClick(row: row, word: word, through: last, extend: modifiers == [.shift])
            return
        }
        // ⇧/⌘ clicks extend the selection, a double click is a second click on the same word, and a drag selects
        // rows: none of them plays.
        guard modifiers.isEmpty, !dragged else { return }
        handleWordClick(row: row, word: word, through: word, extend: false)
    }

    /// Words `word`…`last` of `row` were clicked: edited in edit mode, else played from `word`.
    func handleWordClick(row: Int, word: Int, through last: Int, extend: Bool) {
        if editingWords {
            onWordEditClick?(row, word, last, extend)
            return
        }
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: true) as? TurnCellView,
              let start = cell.bodyText.reviewWord(at: word)?.start else { return }
        onWordClick?(start)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView,
              cell.bodyText.canRevertFix,
              let word = cell.bodyText.word(at: cell.bodyText.convert(point, from: self)),
              let fix = word.fix else { return super.menu(for: event) }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Revert to “\(fix.heard)”", action: #selector(revertFix(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = WordFixChoice(word.ref)
        menu.addItem(item)
        return menu
    }

    @objc private func revertFix(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? WordFixChoice else { return }
        onRevertFix?(choice.word)
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
    private var wordRefs: [WordRef] = []
    /// What the meeting's word fixes changed, per word (nil for a word as recognized).
    private var wordFixes: [TranscriptWordFix?] = []
    private var playingWord: Int?
    /// Plays from a session time: VoiceOver's "Play from …" actions, one per word (clicks go through the table).
    var onPlay: ((Double) -> Void)?
    var onRevertFix: ((WordRef) -> Void)?
    var canRevertFix = false
    /// VoiceOver's "Edit “word”" (word `index` of the text): turns edit mode on and edits that word; false when no
    /// field opened.
    var onEditWord: ((Int) -> Bool)?
    /// Words can be edited now (the list's `canEditWords`): the "Edit" actions are offered only then.
    var canEditWord: (() -> Bool)?
    /// Edit mode: the pointer over the text is an I-beam.
    var editingWords = false {
        didSet { if editingWords != oldValue { window?.invalidateCursorRects(for: self) } }
    }
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
        wordRefs = words.map(\.ref)
        wordFixes = words.map(\.fix)
        // Words the meeting's word fixes changed: a dotted underline, and what was heard there in the tooltip.
        if let storage = textStorage {
            for (index, fix) in wordFixes.enumerated() {
                guard let fix, index < wordRanges.count, let range = wordRanges[index],
                      NSMaxRange(range) <= storage.length else { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .toolTip: TurnTextView.fixDescription(fix),
                ], range: range)
            }
        }
        playingWord = nil
        window?.invalidateCursorRects(for: self)
    }

    /// "Heard as “cloud”; a word-list term" — for a fixed word's tooltip and VoiceOver.
    static func fixDescription(_ fix: TranscriptWordFix) -> String {
        "Heard as “\(fix.heard)”; " + (fix.kind == .term ? "a word-list term Apple Intelligence chose"
            : fix.kind == .reviewEdit ? "you edited it" : "fixed by a learned correction")
    }

    /// The keyboard and VoiceOver way to a word (VO-⌘-Space lists them): "Play from “budget” (00:12:03)". Made
    /// when asked for, never announced.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        var offeredFixes = Set<String>()
        for (index, start) in wordStarts.enumerated() {
            let word = index < wordTexts.count ? wordTexts[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let fix = index < wordFixes.count ? wordFixes[index].map { ", " + TurnTextView.fixDescription($0) } : nil
            let name = "Play from “\(word)” (\(TimeFormat.clock(start))\(fix ?? ""))"
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let onPlay = self?.onPlay else { return false }
                onPlay(start)
                return true
            })
            if canRevertFix, canEditWord?() ?? false {
                actions.append(NSAccessibilityCustomAction(name: "Edit “\(word)”") { [weak self] in
                    self?.onEditWord?(index) ?? false
                })
            }
            if canRevertFix, index < wordRefs.count, index < wordFixes.count, let fixed = wordFixes[index] {
                let ref = wordRefs[index]
                let key = "\(ref.segmentID)\u{1f}\(fixed.first)\u{1f}\(fixed.end)"
                if offeredFixes.insert(key).inserted {
                    actions.append(NSAccessibilityCustomAction(name: "Revert to “\(fixed.heard)”") { [weak self] in
                        guard let onRevertFix = self?.onRevertFix else { return false }
                        onRevertFix(ref)
                        return true
                    })
                }
            }
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
        guard let index = wordIndex(atPoint: point), index < wordStarts.count else { return nil }
        return wordStarts[index]
    }

    /// The review word under `point`, for its contextual action.
    func word(at point: NSPoint) -> ReviewWord? {
        wordIndex(atPoint: point).flatMap(reviewWord(at:))
    }

    /// Word `index` of the text.
    func reviewWord(at index: Int) -> ReviewWord? {
        guard index >= 0, index < wordRefs.count, index < wordTexts.count, index < wordStarts.count else { return nil }
        return ReviewWord(ref: wordRefs[index], text: wordTexts[index], start: wordStarts[index],
                          fix: index < wordFixes.count ? wordFixes[index] : nil)
    }

    /// How many words the text has.
    var wordCount: Int { wordRefs.count }

    /// The text shown from word `first` through word `last` (punctuation between them as shown); nil when one of them
    /// is not in the text.
    func shownText(from first: Int, through last: Int) -> String? {
        guard first <= last, last < wordRanges.count, let start = wordRanges[first], let end = wordRanges[last],
              let storage = textStorage, NSMaxRange(end) <= storage.length else { return nil }
        return (storage.string as NSString).substring(with: NSRange(location: start.location,
                                                                    length: NSMaxRange(end) - start.location))
    }

    func wordIndex(atPoint point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -2, dy: -1).contains(point) else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        return ReviewWordRanges.word(at: character, ranges: wordRanges)
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
        let visible = visibleRect
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            // A line outside the visible part (a row the table laid out off screen) has no cursor rect: the
            // intersection is the null rect, whose infinite origin AppKit rejects with an exception.
            let rect = used.intersection(visible)
            guard !rect.isNull, !rect.isEmpty else { return }
            self.addCursorRect(rect, cursor: self.editingWords ? .iBeam : .pointingHand)
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

/// The right pane of the review window (docs/meeting-design.md §5.10): one row per paragraph (consecutive turns of one
/// speaker, `ReviewParagraphs`) with a timestamp button that plays from there, the speaker pop-up, a warning when a
/// turn of it is uncertain, and the wrapping text, whose words play from where they are clicked. While the meeting
/// plays, the paragraph and word playing are tinted. Several rows can be selected with ⇧ and ⌘; whatever acts on rows
/// (assigning a speaker, the selection's turns) acts on every turn of them.
@MainActor
final class TurnListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A timestamp or a word was clicked: play from this session time.
    var onPlay: ((Double) -> Void)?
    var onRevertFix: ((WordRef) -> Void)?
    var onAssign: (([String], ReviewAssignTarget) -> Void)?
    var onNewSpeaker: (([String]) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// "⚠ Jim?" clicked: give that turn (its ID) to the named speaker it sounds like.
    var onAcceptHint: ((String) -> Void)?
    /// The reader scrolled the turns themselves.
    var onUserScroll: (() -> Void)?
    /// Edit mode: `words` (shown words of one segment of one turn, in order) are to become `text`; `addTerm`: ⌥Return
    /// asked for the new text in the word list too; `movesSeen`: how many of the review's word moves `words` follow.
    var onEditWords: ((_ words: [ReviewWord], _ text: String, _ addTerm: Bool, _ movesSeen: Int) -> Void)?
    /// The review's word moves (`ReviewSession.wordMoves`) as of the last update: the open field follows them.
    private(set) var wordMoves: [ReviewWordMove] = []
    /// What the edit mode banner says for a moment (a selection stopped at a turn's end), nil for its usual text.
    var onEditMessage: ((String?) -> Void)?
    /// VoiceOver asked to edit a word while edit mode is off: the window turns it on (`editingWords`).
    var onRequestEditing: (() -> Void)?
    /// The text an edit field over `words` starts with (`ReviewSession.shownText`); nil: their text as shown.
    var editText: (([ReviewWord]) -> String?)?
    /// Words can be edited now (`ReviewSession.canEditWords`); edit mode shows, but a click opens no field, otherwise.
    var canEditWords = true {
        didSet { if !canEditWords { loseWordEdit() } }
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
    var wordEdit: WordEditTarget?
    /// A ⇧-click is on its way: the field losing the keyboard to the table does not save (the selection grows).
    var extendingWordEdit = false
    /// The field over the words being edited.
    let editField = WordEditField()
    /// The paragraph playing (its ID) and the word of it playing, tinted while shown.
    private(set) var playingParagraphID: String?
    private var playingWord: Int?
    /// Row heights by paragraph ID (with the words they were measured for, and whether a hint and a warning are
    /// stacked), for `heightWidth`.
    private var heights: [String: (spans: [WordSpan], stacked: Bool, text: String, height: CGFloat)] = [:]
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
        table.onWordEditClick = { [weak self] row, from, to, extend in
            self?.beginEditing(row: row, from: from, through: to, extend: extend)
        }
        table.onEditClickBegan = { [weak self] extend in self?.editClickBegan(extend: extend) }
        table.onEditClickEnded = { [weak self] in self?.editClickEnded() }
        editField.delegate = self
    }

    required init?(coder: NSCoder) { nil }

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
            if old.spans != paragraph.spans || textChanged
                || TurnCellView.stacksWarning(old, hint: Self.hint(of: old, in: oldHints))
                != TurnCellView.stacksWarning(paragraph, hint: Self.hint(of: paragraph, in: hints)) {
                resized.insert(index)
            }
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

    /// The hint a paragraph shows: its first turn that sounds like someone named in the meeting.
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
        let stacked = TurnCellView.stacksWarning(paragraph, hint: Self.hint(of: paragraph, in: hints))
        // Keyed by ID and checked against the words: a split, or a turn joining or leaving, changes a paragraph's
        // words and keeps its ID.
        let shown = text(of: paragraph)
        if let cached = heights[paragraph.id], cached.spans == spans, cached.stacked == stacked, cached.text == shown {
            return cached.height
        }
        // Measured as the row's text view lays it out (`TurnCellView.layout`).
        let measured = TurnTextView.height(of: shown, width: TurnCellView.textViewWidth(forTextWidth: width))
        let height = max(stacked ? TurnCellView.stackedHeight : 28, ceil(measured) + 10)
        heights[paragraph.id] = (spans, stacked, shown, height)
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
            cell.hintButton.target = self
            cell.hintButton.action = #selector(hintClicked(_:))
            cell.bodyText.onPlay = { [weak self] seconds in self?.onPlay?(seconds) }
            cell.bodyText.onRevertFix = { [weak self] word in self?.onRevertFix?(word) }
            cell.bodyText.canEditWord = { [weak self] in (self?.editable ?? false) && (self?.canEditWords ?? false) }
            cell.bodyText.onEditWord = { [weak self, weak cell] word in
                guard let self, let cell, self.editable, self.canEditWords else { return false }
                let row = self.table.row(for: cell)
                guard row >= 0 else { return false }
                if !self.editingWords { self.onRequestEditing?() }
                self.beginEditing(row: row, from: word, through: word, extend: false)
                return self.wordEdit != nil
            }
            return cell
        }()
        cell.bodyText.editingWords = editingWords
        let paragraph = paragraphs[row]
        cell.configure(paragraph: paragraph, text: text(of: paragraph), words: paragraph.turns.flatMap(words),
                       menu: AssignMenu.items(speakers: speakers, people: people), editable: editable,
                       hint: Self.hint(of: paragraph, in: hints))
        let playing = paragraph.id == playingParagraphID
        cell.setPlaying(playing, word: playing ? playingWord : nil)
        return cell
    }

    @objc private func hintClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < paragraphs.count, let hint = Self.hint(of: paragraphs[row], in: hints) else { return }
        onAcceptHint?(hint.turnID)
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
        guard row >= 0, row < paragraphs.count, let choice = sender.selectedItem?.representedObject as? AssignChoice
        else { return }
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

/// One paragraph row: timestamp button, speaker pop-up, uncertainty warning, and text. Laid out by hand (fixed
/// columns, wrapping text), matching `TurnListView`'s row heights. The paragraph playing has a tinted background and
/// an accent bar on its leading edge.
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
    /// "⚠ Jim?": a turn of the paragraph sounds like a person named in the meeting; a click gives that turn to them.
    /// Shown instead of that turn's warning; the warning of the paragraph's other turns shows under it.
    let hintButton = NSButton(title: "", target: nil, action: nil)
    let bodyText = TurnTextView.make()
    private var menuSignature: [String] = []
    private var isPlayingTurn = false
    /// The hint and a warning of other turns both show: the warning goes under the hint.
    private var stacked = false
    /// The least height of a row whose hint and warning are stacked.
    static let stackedHeight: CGFloat = 46

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
        hintButton.bezelStyle = .inline
        hintButton.controlSize = .small
        hintButton.font = .systemFont(ofSize: 11)
        hintButton.contentTintColor = .systemOrange
        hintButton.lineBreakMode = .byTruncatingTail
        hintButton.isHidden = true
        for view in [timeButton, speakerPopUp, warningLabel, hintButton, bodyText] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { bodyText.setTextColor(textColor) }
    }

    private var textColor: NSColor {
        backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
    }

    /// Tints this row as the paragraph playing, with `word` (nil: none) as the word being spoken.
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

    func configure(paragraph: ReviewParagraph, text: String, words: [ReviewWord], menu items: [NSMenuItem],
                   editable: Bool, hint: MeetingTurnHint? = nil) {
        timeButton.title = TimeFormat.clock(paragraph.start)
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
        let current: ReviewAssignTarget = paragraph.speakerID.map { .speaker($0) } ?? .unknown
        if let index = speakerPopUp.itemArray.firstIndex(where: {
            ($0.representedObject as? AssignChoice)?.kind == .target(current)
        }) {
            speakerPopUp.selectItem(at: index)
        }
        speakerPopUp.isEnabled = editable
        bodyText.canRevertFix = editable
        // The hinted turn's own warning gives way to the hint; the other turns' warning stays.
        warningLabel.stringValue = Self.warning(paragraph, excluding: hint?.turnID)
        warningLabel.toolTip = Self.warningHelp(paragraph, excluding: hint?.turnID)
        if let hint {
            hintButton.title = "⚠ \(hint.name)?"
            // In a paragraph of several turns, the hint names the turn it is about by its start.
            let turn = paragraph.turns.count > 1 ? paragraph.turns.first { $0.id == hint.turnID } : nil
            let what = turn.map { "The part from \(TimeFormat.clock($0.start))" } ?? "This turn"
            hintButton.toolTip = "\(what) sounds like \(hint.name), whom you named in this meeting. Click to give "
                + "it to \(hint.name)."
            hintButton.setAccessibilityLabel("\(what) sounds like \(hint.name). Give it to \(hint.name).")
            hintButton.isEnabled = editable
        }
        hintButton.isHidden = hint == nil
        warningLabel.isHidden = warningLabel.stringValue.isEmpty
        stacked = Self.stacksWarning(paragraph, hint: hint)
        bodyText.show(text: text, words: words, color: textColor)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        timeButton.frame = NSRect(x: 4, y: 4, width: Self.timeWidth, height: 20)
        speakerPopUp.frame = NSRect(x: 4 + Self.timeWidth + Self.gap, y: 2, width: Self.popUpWidth, height: 22)
        warningLabel.frame = NSRect(x: 4 + Self.timeWidth + Self.gap + Self.popUpWidth + Self.gap,
                                    y: stacked ? 25 : 6, width: Self.warningWidth, height: 16)
        hintButton.frame = NSRect(x: warningLabel.frame.minX, y: 3, width: Self.warningWidth, height: 20)
        // The row is `measured + 10` tall (`TurnListView.tableView(_:heightOfRow:)`): 5 above the text, 5 below.
        let width = Self.textViewWidth(forTextWidth: bounds.width - Self.textX - 4)
        let frame = NSRect(x: Self.textX + Self.textInset, y: 5, width: width, height: max(18, height - 10))
        guard bodyText.frame != frame else { return }
        bodyText.frame = frame
        bodyText.window?.invalidateCursorRects(for: bodyText)
    }

    /// A hint shows and so does a warning of the paragraph's other turns.
    static func stacksWarning(_ paragraph: ReviewParagraph, hint: MeetingTurnHint?) -> Bool {
        guard let hint else { return false }
        return !warning(paragraph, excluding: hint.turnID).isEmpty
    }

    /// "⚠ overlap", "⚠ unknown", "⚠ unsure", or nothing: a paragraph warns when any of its turns (but `excluded`) is
    /// uncertain, of an overlap when one of those overlaps.
    static func warning(_ paragraph: ReviewParagraph, excluding excluded: String? = nil) -> String {
        let uncertain = paragraph.turns.filter { $0.uncertain && $0.id != excluded }
        guard !uncertain.isEmpty else { return "" }
        if uncertain.contains(where: \.overlap) { return "⚠ overlap" }
        if paragraph.speakerID == nil { return "⚠ unknown" }
        return "⚠ unsure"
    }

    static func warningHelp(_ paragraph: ReviewParagraph, excluding excluded: String? = nil) -> String? {
        let uncertain = paragraph.turns.filter { $0.uncertain && $0.id != excluded }
        guard !uncertain.isEmpty else { return nil }
        if uncertain.contains(where: \.overlap) { return "Someone else spoke at the same time." }
        if paragraph.speakerID == nil { return "No speaker was found for this text." }
        return "The speaker is uncertain here."
    }
}
