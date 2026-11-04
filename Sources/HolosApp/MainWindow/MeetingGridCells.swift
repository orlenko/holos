import AppKit

/// The Meetings grid's columns, left to right: the name (with its badges, renamed in place), when the meeting started
/// and how long it is, a one-line description, and the row's Open and ···.
@MainActor
enum MeetingGridColumn: String, CaseIterable {
    case name, when, description, actions

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("meeting." + rawValue) }

    init?(_ column: NSTableColumn?) {
        guard let raw = column?.identifier.rawValue, raw.hasPrefix("meeting.") else { return nil }
        self.init(rawValue: String(raw.dropFirst("meeting.".count)))
    }

    /// The column, at a width that fits the window at its narrowest (beside a call's window); the table's uniform
    /// resizing spreads the rest of a wider window over the name, the date and the description.
    func makeColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        switch self {
        case .name:
            column.title = "Name"
            column.minWidth = 110
            column.width = 150
        case .when:
            column.title = "When"
            column.minWidth = 80
            column.width = 100
            column.resizingMask = .userResizingMask
        case .description:
            column.title = "Description"
            column.minWidth = 60
            column.width = 110
        case .actions:
            column.title = ""
            column.width = MeetingRowActionsView.width
            column.minWidth = MeetingRowActionsView.width
            column.maxWidth = MeetingRowActionsView.width
            column.resizingMask = []
        }
        return column
    }

    /// The Name cell's title keeps 72 points above this priority: badges shrink first, and a progress bar's fixed width
    /// wins at the narrowest column.
    static let titleKept = NSLayoutConstraint.Priority.defaultHigh + 10

    /// Keeps the Name cell's `title` at least 72 points wide at `titleKept`.
    static func keepWidth(of title: NSView) {
        title.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).prioritized(titleKept).isActive = true
    }

    /// The cell of this column for a row: a reused one, else a new one.
    func cell<Cell: NSView & IdentifiedCell>(in table: NSTableView) -> Cell {
        table.makeView(withIdentifier: identifier, owner: nil) as? Cell ?? Cell(identifier: identifier)
    }

    /// Below this width of the list, the When column is hidden so the name, the description and the row's actions fit
    /// (the day headers still say when).
    static let whenHiddenBelow: CGFloat = 470

    /// Shows or hides the When column for the list's `width`, then fits the columns to it.
    static func fit(_ table: NSTableView, width: CGFloat) {
        guard let when = table.tableColumns.first(where: { MeetingGridColumn($0) == .when }) else { return }
        let hidden = width < whenHiddenBelow
        if when.isHidden != hidden { when.isHidden = hidden }
        table.sizeToFit()
    }
}

/// A grid cell made for a column's identifier.
@MainActor
protocol IdentifiedCell {
    init(identifier: NSUserInterfaceItemIdentifier)
}

extension NSLayoutConstraint {
    /// The constraint at `priority`, for activating in one expression.
    func prioritized(_ priority: Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// One line of secondary text: the When and Description cells. The whole text is in the tooltip when it is cut.
///
/// Invariants:
/// 1. The label, tooltip and VoiceOver label are those of the last `showing` call.
@MainActor
final class MeetingTextCell: NSTableCellView, IdentifiedCell {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `text`, with `toolTip` (else the text itself) on hover; returns the cell.
    func showing(_ text: String, toolTip: String? = nil) -> Self {
        label.stringValue = text
        self.toolTip = (toolTip?.isEmpty == false ? toolTip : nil) ?? (text.isEmpty ? nil : text)
        setAccessibilityLabel(text)
        return self
    }
}

/// A meeting's row: its Open and ··· show only while it is the one selected or under the pointer, so a list at rest is
/// names, and several selected rows do not each offer an action for one. The table gets a new one each time it rebuilds
/// the rows.
///
/// Invariants:
/// 1. The row's `MeetingRowActionsView` is revealed exactly when the row is the only one selected or under the pointer,
///    also when the cell arrives after the row or the list scrolls under a pointer that does not move. The selection's
///    size changes without this row's `isSelected` changing: the pane calls `revealActions` then.
@MainActor
final class MeetingTableRowView: NSTableRowView {
    private var pointerInside = false { didSet { revealActions() } }
    private var tracking: NSTrackingArea?
    private weak var table: NSTableView?

    init(table: NSTableView) {
        self.table = table
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isSelected: Bool { didSet { revealActions() } }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        revealActions()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        checkPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        checkPointer()
    }

    /// The list is rebuilt every 2 s, under a pointer that does not move and so enters nothing.
    private func checkPointer() {
        guard let window, window.isKeyWindow else { return }
        pointerInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }

    override func mouseExited(with event: NSEvent) { pointerInside = false }

    func revealActions() {
        let onlySelected = isSelected && table?.numberOfSelectedRows == 1
        for case let actions as MeetingRowActionsView in subviews {
            actions.revealed = onlySelected || pointerInside
        }
    }
}

/// The row's actions: Open (the meeting screen, where speakers are named), and a ··· with View Transcript (the Markdown
/// transcript in the app that opens Markdown), Copy Path (the meeting's folder, for an agent or Terminal), Delete Audio…
/// and Delete Meeting…. Each acts on its own row, whatever is selected. Return, a double-click, the row's right-click
/// menu and VoiceOver's actions on the row reach the meeting while they are not revealed (`MeetingTableRowView`).
///
/// Invariants:
/// 1. A click calls the `onAction` of the meeting the cell was last shown for; a reused cell calls none until shown
///    again.
/// 2. A menu's choice acts on the meeting the cell showed when the menu opened, even if the list was rebuilt and the
///    cell reused for another meeting meanwhile (the list is rebuilt every 2 s, also under an open menu).
/// 3. Each action is on exactly when the last `show(enabled:)` named it.
@MainActor
final class MeetingRowActionsView: NSTableCellView, IdentifiedCell {
    enum Kind: CaseIterable {
        case open, view, copyPath, deleteAudio, deleteMeeting

        var title: String {
            switch self {
            case .open: "Open"
            case .view: "View Transcript"
            case .copyPath: "Copy Path"
            case .deleteAudio: "Delete Audio…"
            case .deleteMeeting: "Delete Meeting…"
            }
        }

        var help: String {
            switch self {
            case .open: "Opens the meeting, where you name its speakers and correct the transcript."
            case .view: "Opens the Markdown transcript in your Markdown app."
            case .copyPath: "Copies the path of the meeting's folder."
            case .deleteAudio: "Deletes the meeting's audio for good; the transcript and speaker names stay."
            case .deleteMeeting: "Moves the meeting's folder to the Trash."
            }
        }
    }

    static let width: CGFloat = 92

    /// The row's meeting and which action was chosen.
    var onAction: ((Kind) -> Void)?
    /// Whether Open and ··· show (`MeetingTableRowView`).
    var revealed = false { didSet { stack.isHidden = !revealed } }
    let openButton = NSButton(title: Kind.open.title, target: nil, action: nil)
    let moreButton = MeetingActionsButton()
    private let stack = NSStackView()
    private var enabled: Set<Kind> = []

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        openButton.bezelStyle = .push
        openButton.controlSize = .small
        openButton.toolTip = Kind.open.help
        openButton.target = self
        openButton.action = #selector(openClicked)
        moreButton.controlSize = .small
        moreButton.makeMenu = { [weak self] in self?.menu() }
        stack.spacing = 4
        stack.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(openButton)
        stack.addArrangedSubview(moreButton)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The actions in `enabled` are on; the others are off.
    func show(enabled: Set<Kind>) {
        self.enabled = enabled
        openButton.isEnabled = enabled.contains(.open)
    }

    /// The cell for the row of the meeting `title`, which tells its buttons from other rows' for VoiceOver: `enabled`
    /// actions on, and `action` called with the chosen one; returns the cell.
    func showing(_ enabled: Set<Kind>, title: String, action: @escaping (Kind) -> Void) -> Self {
        show(enabled: enabled)
        openButton.setAccessibilityLabel("Open \(title)")
        moreButton.setAccessibilityLabel("More actions for \(title)")
        onAction = action
        return self
    }

    /// What ··· opens: every action but Open, on this row's meeting now (invariant 2).
    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let action = onAction
        for kind in Kind.allCases where kind != .open {
            if kind == .deleteAudio { menu.addItem(.separator()) }
            let choice = MenuChoice { action?(kind) }
            let item = NSMenuItem(title: kind.title, action: #selector(MenuChoice.chosen), keyEquivalent: "")
            item.target = choice
            item.representedObject = choice  // A menu item's target is weak.
            item.isEnabled = enabled.contains(kind)
            item.toolTip = kind.help
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openClicked() { onAction?(.open) }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        revealed = false
    }
}

/// What a row's menu item does, kept by the item.
@MainActor
private final class MenuChoice: NSObject {
    private let run: () -> Void

    init(run: @escaping () -> Void) {
        self.run = run
    }

    @objc func chosen() { run() }
}
