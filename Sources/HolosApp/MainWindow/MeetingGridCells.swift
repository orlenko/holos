import AppKit

/// The Meetings grid's columns, left to right: the name (with its badges, renamed in place), when the meeting started
/// and how long it is, a one-line description, and the row's buttons.
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

    /// Below this width of the list, the When column is hidden so the name, the description and the buttons fit
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

/// One line of secondary text: the When and Description cells. The whole text is in the tooltip when it is cut.
///
/// Invariants:
/// 1. The label, tooltip and VoiceOver label are those of the last `showing` call.
@MainActor
final class MeetingTextCell: NSTableCellView {
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

/// The row's buttons: Open (the meeting screen, where speakers are named), View (the Markdown transcript in the app
/// that opens Markdown), Delete Audio, and Copy Path (the meeting's folder, for an agent or Terminal). Each button
/// acts on its own row, whatever is selected.
///
/// Invariants:
/// 1. A click calls the `onAction` of the meeting the cell was last shown for; a reused cell calls none until shown
///    again.
/// 2. Each button is on exactly when the last `show(enabled:)` named it.
@MainActor
final class MeetingRowActionsView: NSTableCellView {
    enum Kind: CaseIterable {
        case open, view, deleteAudio, copyPath

        var symbol: String {
            switch self {
            case .open: "pencil"
            case .view: "magnifyingglass"
            case .deleteAudio: "speaker.slash"
            case .copyPath: "doc.on.clipboard"
            }
        }

        var title: String {
            switch self {
            case .open: "Open"
            case .view: "View Transcript"
            case .deleteAudio: "Delete Audio"
            case .copyPath: "Copy Path"
            }
        }

        var help: String {
            switch self {
            case .open: "Opens the meeting, where you name its speakers and correct the transcript."
            case .view: "Opens the Markdown transcript in your Markdown app."
            case .deleteAudio: "Deletes the meeting's audio for good; the transcript and speaker names stay."
            case .copyPath: "Copies the path of the meeting's folder."
            }
        }
    }

    static let width: CGFloat = 112

    /// The row's meeting and which button was clicked.
    var onAction: ((Kind) -> Void)?
    private var buttons: [Kind: NSButton] = [:]

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let stack = NSStackView()
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for kind in Kind.allCases {
            let image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title) ?? NSImage()
            let button = NSButton(image: image, target: self, action: #selector(clicked(_:)))
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.toolTip = kind.help
            button.setAccessibilityLabel(kind.title)
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            buttons[kind] = button
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The buttons in `enabled` are on; the others are off, with `reasons` (when given) as their tooltip.
    func show(enabled: Set<Kind>, reasons: [Kind: String] = [:]) {
        for (kind, button) in buttons {
            button.isEnabled = enabled.contains(kind)
            button.toolTip = button.isEnabled ? kind.help : (reasons[kind] ?? kind.help)
        }
    }

    /// The cell for a row: `enabled` buttons on, and `action` called with the clicked one; returns the cell.
    func showing(_ enabled: Set<Kind>, action: @escaping (Kind) -> Void) -> Self {
        show(enabled: enabled)
        onAction = action
        return self
    }

    func button(_ kind: Kind) -> NSButton? { buttons[kind] }

    @objc private func clicked(_ sender: NSButton) {
        guard let kind = buttons.first(where: { $0.value === sender })?.key else { return }
        onAction?(kind)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
    }
}
