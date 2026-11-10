import AppKit
import HolosCore
import HolosMeeting

/// A day header ("Today", "This Week", "September 2026").
@MainActor
final class MeetingGroupView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }
}

/// A meeting's Name cell: its title (bold) with its badges; VoiceOver also reads when it was, who spoke, and its
/// summary. In the list at its narrowest, a second line under the title says what the hidden Description column
/// would. While the meeting is renamed, an editor takes the place of the title and its badges: Return (or leaving it)
/// saves, Escape cancels.
///
/// Invariants:
/// 1. A rename ends once: `commit` or `cancel` is called at most once, and a reused cell cancels it unsaved.
/// 2. The second line shows exactly when the last `show` gave it.
@MainActor
final class MeetingRowView: NSTableCellView, NSTextFieldDelegate, IdentifiedCell {
    struct Content: Equatable {
        var title: String
        var detail: String
        var summary: String?
        var badges: [MeetingListFormat.Badge]
        var toolTip: String
        var progress: PostProcessingProgress? = nil
        /// In the list at its narrowest only: the line under the title (the summary, else the people).
        var secondLine: String? = nil
    }

    private let title = NSTextField(labelWithString: "")
    private let editor = NSTextField(string: "")
    private let badges = MeetingRowIndicators()
    /// While renaming: what Return (or leaving the editor) and Escape do. Each is called once per rename.
    private var onCommit: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    var isRenaming: Bool { onCommit != nil }
    private weak var header: NSStackView?
    /// Pushes the badges to the right; hidden while renaming, so the editor alone spans the line.
    private let spacer = NSView()
    /// The editor spans the title line while it shows (set when it is attached to the line).
    private var editorWidth: NSLayoutConstraint?
    private let secondLine = NSTextField(labelWithString: "")

    /// The row's height: one line, with room for the editor; two lines in the list at its narrowest.
    static let height: CGFloat = 30
    static let twoLineHeight: CGFloat = 44

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        MeetingGridColumn.keepWidth(of: title)
        textField = title
        badges.spacing = 6
        badges.distribution = .fill
        badges.setContentHuggingPriority(.required, for: .horizontal)
        badges.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        clipsToBounds = true
        editor.font = .systemFont(ofSize: 13, weight: .semibold)
        editor.bezelStyle = .roundedBezel
        editor.lineBreakMode = .byTruncatingTail
        editor.usesSingleLineMode = true
        editor.cell?.isScrollable = true
        editor.cell?.wraps = false
        editor.delegate = self
        editor.isHidden = true
        editor.setAccessibilityLabel("Meeting name")
        editor.toolTip = "Return saves the name, Escape cancels. Leave it empty to use the title Apple Intelligence "
            + "wrote."
        editor.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, editor, spacer, badges])
        header.spacing = 6
        header.alignment = .centerY
        self.header = header
        secondLine.font = .systemFont(ofSize: 12)
        secondLine.textColor = .secondaryLabelColor
        secondLine.isHidden = true
        secondLine.setAccessibilityElement(false)  // The cell's label already reads the summary and the people.
        secondLine.lineBreakMode = .byTruncatingTail
        secondLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A hidden second line is detached, so a one-line row lays out its title line alone.
        let lines = NSStackView(views: [header, secondLine])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.detachesHiddenViews = true
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The selected row's text turns white on the accent colour, and so do its badges.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            for case let badge as MeetingBadgeView in badges.arrangedSubviews {
                badge.emphasized = backgroundStyle == .emphasized
            }
            secondLine.cell?.backgroundStyle = backgroundStyle
        }
    }

    func show(_ content: Content) {
        title.stringValue = content.title
        secondLine.stringValue = content.secondLine ?? ""
        secondLine.isHidden = content.secondLine?.isEmpty ?? true  // invariant 2
        for view in badges.arrangedSubviews {
            badges.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for badge in content.badges {
            let view = MeetingBadgeView(badge)
            view.emphasized = backgroundStyle == .emphasized
            badges.addArrangedSubview(view)
        }
        badges.showProgress(content.progress)
        toolTip = content.toolTip
        var label = content.title + ". " + content.detail
        if !content.badges.isEmpty { label += ". " + content.badges.map(\.text).joined(separator: ", ") }
        if let text = content.summary { label += ". " + text }
        setAccessibilityLabel(label)
    }

    // MARK: - Renaming

    /// Whether `point` (in window coordinates) is on the title's text, not the empty space after it.
    func titleTextContains(_ point: NSPoint) -> Bool {
        guard !isRenaming, !title.isHidden else { return false }
        let local = title.convert(point, from: nil)
        let width = min(title.bounds.width, title.attributedStringValue.size().width + 4)
        return local.x >= 0 && local.x <= width && local.y >= 0 && local.y <= title.bounds.height
    }

    /// Shows the editor in place of the title and its badges, with `text` selected and `placeholder` shown when it is
    /// emptied, and gives it the keyboard.
    func beginRenaming(_ text: String, placeholder: String, commit: @escaping (String) -> Void,
                       cancel: @escaping () -> Void) {
        onCommit = commit
        onCancel = cancel
        editor.stringValue = text
        editor.placeholderString = placeholder
        title.isHidden = true
        badges.isHidden = true
        spacer.isHidden = true
        editor.isHidden = false
        if editorWidth == nil, let header {
            editorWidth = editor.widthAnchor.constraint(equalTo: header.widthAnchor)
        }
        editorWidth?.isActive = true
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    /// Back to the title, without saving (the pane saves what `commit` was given).
    func endRenaming() {
        onCommit = nil
        onCancel = nil
        editorWidth?.isActive = false
        editor.isHidden = true
        title.isHidden = false
        badges.isHidden = false
        spacer.isHidden = false
    }

    /// A row scrolled away while it was renamed is cancelled before the view shows another meeting.
    override func prepareForReuse() {
        super.prepareForReuse()
        finish(saving: false)
    }

    private func finish(saving: Bool) {
        guard let commit = onCommit, let cancel = onCancel else { return }
        let text = editor.stringValue
        // Return or Escape: the keyboard goes back to the list. Leaving the editor by a click keeps it where it went.
        let hadKeyboard = (window?.firstResponder as? NSText)?.delegate === editor
        endRenaming()
        if hadKeyboard {
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            window?.makeFirstResponder(view)
        }
        if saving { commit(text) } else { cancel() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(saving: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            finish(saving: false)
            return true
        default:
            return false
        }
    }

    /// Leaving the editor (a click elsewhere, Tab) saves the name, as in the Finder.
    func controlTextDidEndEditing(_ notification: Notification) {
        finish(saving: true)
    }
}

/// A small rounded badge in the colour of its kind: red while recording, orange when paused, the accent colour for
/// work in progress, orange for what needs attention, grey for a plain fact.
///
/// Invariants:
/// 1. A change of `emphasized` redraws the badge; its text never draws outside its bounds.
@MainActor
final class MeetingBadgeView: NSTextField {
    private let kind: MeetingListFormat.Badge.Kind
    var emphasized = false {
        didSet { if emphasized != oldValue { needsDisplay = true } }
    }

    init(_ badge: MeetingListFormat.Badge) {
        kind = badge.kind
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 10, weight: .semibold)
        stringValue = badge.text
        toolTip = badge.text
        clipsToBounds = true
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setAccessibilityLabel(badge.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: size.height + 2)
    }

    private var color: NSColor {
        switch kind {
        case .live: .systemRed
        case .paused, .warning: .systemOrange
        case .progress: .controlAccentColor
        case .note: .secondaryLabelColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let foreground: NSColor = emphasized ? .white : color
        (emphasized ? NSColor.white.withAlphaComponent(0.22) : color.withAlphaComponent(0.16)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 4, yRadius: 4).fill()
        let text = NSAttributedString(string: stringValue, attributes: [
            .font: font ?? .systemFont(ofSize: 10), .foregroundColor: foreground,
        ])
        // A badge squeezed by a narrow Name column ends in "…" rather than running over the title.
        let size = text.size()
        let width = min(size.width, bounds.width - 10)
        text.draw(with: NSRect(x: (bounds.width - width) / 2, y: (bounds.height - size.height) / 2, width: width,
                               height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
