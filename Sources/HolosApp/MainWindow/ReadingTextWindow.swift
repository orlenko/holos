import AppKit
import HolosContent

/// Show Text (docs/design.md "Reading section"): the text a reading reads, as it was saved when the reading was loaded,
/// in a window of its own to read along with the voice: to select or copy, never to edit. The sentence being spoken is
/// highlighted, and the text scrolls to follow it.
///
/// Invariants:
/// 1. The text is never changed by following: the highlight is a rendering attribute, so selection and copied text are
///    left alone.
/// 2. Following stops when the person scrolls or selects (the place they are reading is theirs) and resumes only from
///    Follow Voice; the highlight goes on moving meanwhile.
/// 3. A reading without a timeline shows its text with no highlight, and Follow Voice is off and says why.
@MainActor
final class ReadingTextWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let entryID: UUID
    let text: String
    private let timeline: ReadingTimeline?
    private let length: Double?
    private let body = ReadingTextView(usingTextLayoutManager: true)
    private let scroll = NSScrollView()
    private let primary = NSButton(title: "▶ Play", target: nil, action: nil)
    private let seekBar = ReadingSeekBar()
    private let follow = NSButton(checkboxWithTitle: "Follow Voice", target: nil, action: nil)
    private var scrollObserver: NSObjectProtocol?
    /// The range highlighted now, as the rendering attribute covers it.
    private var highlight: (range: NSRange, textRange: NSTextRange)?

    /// Play or Space pressed.
    var onPlay: (() -> Void)?
    /// The seek bar moved.
    var onSeek: ((Double) -> Void)?
    /// The window closed.
    var onClose: (() -> Void)?

    /// `length`: the reading's duration, shown until it is loaded in the player.
    init(entryID: UUID, title: String, text: String, timeline: ReadingTimeline?, length: Double?) {
        self.entryID = entryID
        self.text = text
        self.timeline = timeline
        self.length = length
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                              defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 320)
        window.setFrameAutosaveName("ReadingText")
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent(title: title)
        window.initialFirstResponder = body
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeContent(title: String) -> NSView {
        body.isEditable = false
        body.isSelectable = true
        body.isRichText = false
        body.drawsBackground = true
        body.backgroundColor = .textBackgroundColor
        body.textContainerInset = NSSize(width: 16, height: 14)
        body.autoresizingMask = [.width]
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.minSize = .zero
        body.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        body.textContainer?.widthTracksTextView = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        body.defaultParagraphStyle = paragraph
        body.font = .systemFont(ofSize: 15)
        body.textColor = .labelColor
        body.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph,
                                 .foregroundColor: NSColor.labelColor]
        body.string = text
        body.setAccessibilityLabel("Text of \(title)")
        body.delegate = self
        body.onSpace = { [weak self] in self?.onPlay?() }
        body.onKeyboardScroll = { [weak self] in self?.stopFollowing() }

        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopFollowing() }
        }

        primary.target = self
        primary.action = #selector(playPressed)
        primary.toolTip = "Play or pause (Space)"
        seekBar.setSubject(title)
        seekBar.onSeek = { [weak self] time in self?.onSeek?(time) }
        follow.target = self
        follow.action = #selector(followPressed)
        follow.state = timeline == nil ? .off : .on
        follow.isEnabled = timeline != nil
        follow.toolTip = timeline == nil
            ? "This reading's timing was not kept, so the text cannot follow the voice."
            : "Keep the sentence being spoken in view. Scrolling or selecting turns this off."
        let copy = NSButton(title: "Copy Text", target: self, action: #selector(copyText))
        copy.toolTip = "Copy the whole text"
        let controls = NSStackView(views: [primary, seekBar, follow, copy])
        controls.spacing = 10
        controls.alignment = .centerY
        controls.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        for button in [primary, follow, copy] { button.setContentHuggingPriority(.required, for: .horizontal) }

        let stack = NSStackView(views: [scroll, controls])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for view in [scroll, controls] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// The player's state for this reading (nil: another reading, or none, is loaded).
    func show(_ playback: ReadingRowView.Playback?) {
        primary.title = playback?.playing == true ? "❚❚ Pause" : "▶ Play"
        seekBar.show(current: playback?.current ?? 0, duration: playback?.duration ?? length ?? 0)
        guard playback != nil, let current = playback?.current, let span = timeline?.span(at: current) else {
            setHighlight(nil)
            return
        }
        guard highlight?.range != span.range else { return }
        setHighlight(span.range)
        if isFollowing { body.reveal(span.range) }
    }

    private var isFollowing: Bool { follow.state == .on }

    /// Invariant 1.
    private func setHighlight(_ range: NSRange?) {
        guard let manager = body.textLayoutManager else { return }
        if let old = highlight { manager.removeRenderingAttribute(.backgroundColor, for: old.textRange) }
        highlight = nil
        guard let range, let textRange = body.textRange(range) else { return }
        manager.addRenderingAttribute(.backgroundColor, value: Self.highlightColor, for: textRange)
        highlight = (range, textRange)
    }

    private static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.35)

    /// Invariant 2.
    private func stopFollowing() {
        follow.state = .off
    }

    @objc private func followPressed() {
        if isFollowing, let range = highlight?.range { body.reveal(range) }
    }

    @objc private func playPressed() { onPlay?() }

    /// Copy Text: the user's choice, so the clipboard gets the text.
    @objc func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if body.selectedRange().length > 0 { stopFollowing() }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    isolated deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// For tests.
    var highlightedRange: NSRange? { highlight?.range }
    var textView: NSTextView { body }
    var followsVoice: Bool { isFollowing }
    var followButton: NSButton { follow }
    var seek: ReadingSeekBar { seekBar }
    var primaryTitle: String { primary.title }
    func userScrolledForTesting() {
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    }
}

/// The reading window's text: Space plays or pauses, and the keys that scroll say so.
@MainActor
private final class ReadingTextView: NSTextView {
    var onSpace: (() -> Void)?
    var onKeyboardScroll: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if event.charactersIgnoringModifiers == " ", modifiers.isEmpty {
            onSpace?()
            return
        }
        if [.pageUp, .pageDown, .upArrow, .downArrow, .home, .end].contains(event.specialKey) { onKeyboardScroll?() }
        super.keyDown(with: event)
    }

    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let content = textLayoutManager?.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Scrolls `range` to the upper part of the view, unless it is well in view already: reading is not disturbed by
    /// every sentence moving the page.
    func reveal(_ range: NSRange) {
        guard let manager = textLayoutManager, let target = textRange(range) else { return }
        manager.ensureLayout(for: target)
        var frame: CGRect?
        manager.enumerateTextSegments(in: target, type: .highlight, options: .rangeNotRequired) { _, rect, _, _ in
            frame = frame?.union(rect) ?? rect
            return true
        }
        guard let frame else { return }
        let visible = self.visibleRect
        let top = frame.minY + textContainerOrigin.y
        let bottom = frame.maxY + textContainerOrigin.y
        if top >= visible.minY + visible.height * 0.1, bottom <= visible.minY + visible.height * 0.75 { return }
        scroll(NSPoint(x: visible.minX, y: max(0, top - visible.height * 0.25)))
    }
}
