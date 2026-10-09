import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers

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
    /// Whether each word's fix can be reverted here (`ReviewWord.revertible`).
    private var wordRevertible: [Bool] = []
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
    /// VoiceOver's "Split Turn Before “word”", as the context menu's Split Turn Here: the split before each word of
    /// the text, by index (nil where none is offered: a row's first word; empty in edit mode), asked once per listing
    /// of the actions. Chosen, it is checked then (`onSplitChosen`), and a refusal says why.
    var splitChoices: (() -> [SplitChoice?])?
    var onSplitChosen: ((SplitChoice) -> Void)?
    /// VoiceOver's "Join With Previous Turn", as the context menu's item on the row's first word: nil where none is
    /// offered (the meeting's first row; in edit mode, where Backspace at the row's start joins). Chosen, it is
    /// checked then (`onJoinChosen`), and a refusal says why.
    var joinChoice: (() -> JoinChoice?)?
    var onJoinChosen: ((JoinChoice) -> Void)?
    /// VoiceOver's "Restore Deleted “…”", as the context menu's: the deleted words offered near the text's turns,
    /// asked once per listing of the actions.
    var deletedWordsChoices: (() -> [ReviewDeletedWords])?
    var onRestoreDeleted: ((String) -> Void)?
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
        wordRevertible = words.map(\.revertible)
        // Words the meeting's word fixes changed: a dotted underline, and what was heard there in the tooltip.
        if let storage = textStorage {
            for (index, fix) in wordFixes.enumerated() {
                guard let fix, index < wordRanges.count, let range = wordRanges[index],
                      NSMaxRange(range) <= storage.length else { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .toolTip: TurnTextView.fixDescription(fix, revertible: wordRevertible[index]),
                ], range: range)
            }
        }
        playingWord = nil
        window?.invalidateCursorRects(for: self)
    }

    /// "Heard as “cloud”; a word-list term" — for a fixed word's tooltip and VoiceOver.
    /// `fix` can be reverted now: only while words can be edited (`canEditWord`: not after the transcript changed
    /// under the labels, nor while speaker changes cannot all be read), since a revert publishes new words under the
    /// labels as an edit does (an edit's Revert is another edit).
    /// Nor when its segment refuses every edit and revert (`revertRefusal`: an older automatic fix that cannot be
    /// counted, a damaged mark), where it would fail once asked.
    func canRevert(_ fix: TranscriptWordFix, at word: WordRef) -> Bool {
        (canEditWord?() ?? false) && revertRefusal?(word) == nil
    }
    /// Why the fix on a word cannot be reverted (`ReviewSession.revertRefusal`); nil when it can.
    var revertRefusal: ((WordRef) -> String?)?

    /// With `revertible` false (words edited together, now in two turns), it says how to change them instead.
    static func fixDescription(_ fix: TranscriptWordFix, revertible: Bool = true) -> String {
        "Heard as “\(TranscriptWordEdit.cleaned(fix.heard))”; "
            + (fix.kind == .term ? "a word-list term Apple Intelligence chose"
            : fix.kind == .reviewEdit ? "you edited it" : "fixed by a learned correction")
            + (revertible ? "" : " (" + notRevertible + ")")
    }

    static let notRevertible = "edited together and now in two speaker turns, so it can be neither reverted nor "
        + "edited here; the other words of each turn can"

    /// "Restore Deleted “Thanks,”": the menu item and VoiceOver action for words deleted with their whole segment,
    /// their text shortened to 40 characters.
    static func restoreTitle(_ deleted: ReviewDeletedWords) -> String {
        let text = deleted.text.count > 40 ? String(deleted.text.prefix(39)) + "…" : deleted.text
        return "Restore Deleted “\(text)”"
    }

    static let restoreHelp = "Brings back these words, which were deleted with every other word of their segment, "
        + "as they were, with their times and speaker."

    /// The keyboard and VoiceOver way to a word (VO-⌘-Space lists them): "Play from “budget” (00:12:03)". Made
    /// when asked for, never announced.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        var offeredFixes = Set<[String]>()
        let splits = splitChoices?() ?? []
        if !wordStarts.isEmpty, let join = joinAction() { actions.append(join) }
        for (index, start) in wordStarts.enumerated() {
            let word = index < wordTexts.count ? wordTexts[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let revertible = index < wordRevertible.count ? wordRevertible[index] : true
            let fix = index < wordFixes.count
                ? wordFixes[index].map { ", " + TurnTextView.fixDescription($0, revertible: revertible) } : nil
            let name = "Play from “\(word)” (\(TimeFormat.clock(start))\(fix ?? ""))"
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let onPlay = self?.onPlay else { return false }
                onPlay(start)
                return true
            })
            if canRevertFix, revertible, canEditWord?() ?? false {
                actions.append(NSAccessibilityCustomAction(name: "Edit “\(word)”") { [weak self] in
                    self?.onEditWord?(index) ?? false
                })
            }
            if index < splits.count, let choice = splits[index] {
                actions.append(NSAccessibilityCustomAction(name: "Split Turn Before “\(word)”") { [weak self] in
                    guard let onSplitChosen = self?.onSplitChosen else { return false }
                    onSplitChosen(choice)
                    return true
                })
            }
            if canRevertFix, revertible, index < wordRefs.count, index < wordFixes.count, let fixed = wordFixes[index],
               canRevert(fixed, at: wordRefs[index]) {
                let ref = wordRefs[index]
                let key = [ref.segmentID, String(fixed.first), String(fixed.end)]
                if offeredFixes.insert(key).inserted {
                    let name = "Revert to “\(TranscriptWordEdit.cleaned(fixed.heard))”"
                    actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                        guard let onRevertFix = self?.onRevertFix else { return false }
                        onRevertFix(ref)
                        return true
                    })
                }
            }
        }
        for deleted in deletedWordsChoices?() ?? [] {
            actions.append(NSAccessibilityCustomAction(name: Self.restoreTitle(deleted)) { [weak self] in
                guard let onRestoreDeleted = self?.onRestoreDeleted else { return false }
                onRestoreDeleted(deleted.segmentID)
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
                          fix: index < wordFixes.count ? wordFixes[index] : nil,
                          revertible: index < wordRevertible.count ? wordRevertible[index] : true)
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
