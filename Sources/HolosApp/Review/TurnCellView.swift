import AppKit
import HolosMeeting
import HolosSpeakers

/// One paragraph row: timestamp button, speaker pop-up, and text. Laid out by hand (two fixed columns, then the text
/// wrapping in the rest of the row), matching `TurnListView`'s row heights. The paragraph playing has a tinted
/// background and an accent bar on its leading edge. Nothing on the row marks an uncertain turn: the pop-up's
/// VoiceOver label says "uncertain" or "overlap" and its tooltip why.
@MainActor
final class TurnCellView: NSTableCellView {
    static let timeWidth: CGFloat = 72
    static let popUpWidth: CGFloat = 176
    static let gap: CGFloat = 6
    /// Where the text starts: right after the pop-up.
    static var textX: CGFloat { 4 + timeWidth + gap + popUpWidth + gap }
    /// Space on each side of the text inside its column (what a wrapping label kept).
    static let textInset: CGFloat = 2

    let timeButton = NSButton(title: "", target: nil, action: nil)
    /// The row's speaker; first, when a turn of the row sounds like a person named in the meeting, "Jim (suggested)".
    let speakerPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
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
        for view in [timeButton, speakerPopUp, bodyText] as [NSView] { addSubview(view) }
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
                + "\u{1f}" + ((item.representedObject as? HintChoice)?.turnID ?? "")
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
        // What the warning column used to show is heard and hovered instead: "Speaker, uncertain", "Speaker,
        // overlap", "…, sounds like Jim". The hinted turn's own uncertainty gives way to its hint, as it did there.
        let uncertainty = Self.uncertainty(paragraph, excluding: hint?.turnID)
        speakerPopUp.setAccessibilityLabel((["Speaker"] + [uncertainty, hint.map { "sounds like \($0.name)" }]
            .compactMap { $0 }).joined(separator: ", "))
        let help = [Self.uncertaintyHelp(paragraph, excluding: hint?.turnID),
                    hint.map { AssignMenu.suggestionHelp($0, in: paragraph) }].compactMap { $0 }
        speakerPopUp.toolTip = help.isEmpty ? nil : help.joined(separator: " ")
        speakerPopUp.setAccessibilityHelp(speakerPopUp.toolTip)
        bodyText.show(text: text, words: words, color: textColor)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        timeButton.frame = NSRect(x: 4, y: 4, width: Self.timeWidth, height: 20)
        speakerPopUp.frame = NSRect(x: 4 + Self.timeWidth + Self.gap, y: 2, width: Self.popUpWidth, height: 22)
        // The row is `measured + 10` tall (`TurnListView.tableView(_:heightOfRow:)`): 5 above the text, 5 below.
        let width = Self.textViewWidth(forTextWidth: bounds.width - Self.textX - 4)
        let frame = NSRect(x: Self.textX + Self.textInset, y: 5, width: width, height: max(18, height - 10))
        guard bodyText.frame != frame else { return }
        bodyText.frame = frame
        bodyText.window?.invalidateCursorRects(for: bodyText)
    }

    /// "overlap", "uncertain", or nil: a paragraph is uncertain when any of its turns (but `excluded`, a turn whose
    /// hint the pop-up offers) is, of an overlap when one of those overlaps. For VoiceOver; nothing shows on the row.
    static func uncertainty(_ paragraph: ReviewParagraph, excluding excluded: String? = nil) -> String? {
        let uncertain = paragraph.turns.filter { $0.uncertain && $0.id != excluded }
        guard !uncertain.isEmpty else { return nil }
        return uncertain.contains(where: \.overlap) ? "overlap" : "uncertain"
    }

    /// Why: the pop-up's tooltip and VoiceOver help.
    static func uncertaintyHelp(_ paragraph: ReviewParagraph, excluding excluded: String? = nil) -> String? {
        let uncertain = paragraph.turns.filter { $0.uncertain && $0.id != excluded }
        guard !uncertain.isEmpty else { return nil }
        if uncertain.contains(where: \.overlap) { return "Someone else spoke at the same time." }
        if paragraph.speakerID == nil { return "No speaker was found for this text." }
        return "The speaker is uncertain here."
    }
}
