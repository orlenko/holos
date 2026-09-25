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

/// The turn table: space and the number keys go to the window, everything else to the table.
final class TurnTableView: NSTableView {
    var onSpace: (() -> Void)?
    /// 1–9: assign the selection to the speaker with that number.
    var onDigit: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers {
            if characters == " " {
                onSpace?()
                return
            }
            if characters.count == 1, let digit = Int(characters), (1...9).contains(digit) {
                onDigit?(digit)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// The right pane of the review window (docs/meeting-design.md §5.10): one row per turn with a timestamp button that
/// plays from there, the speaker pop-up, a warning for uncertain turns, and the wrapping text. Several turns can be
/// selected with ⇧ and ⌘.
@MainActor
final class TurnListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onPlay: ((Double) -> Void)?
    var onAssign: (([String], ReviewAssignTarget) -> Void)?
    var onNewSpeaker: (([String]) -> Void)?
    var onSelectionChange: (() -> Void)?

    let table = TurnTableView()
    private let scroll = NSScrollView()
    private(set) var turns: [ProjectedTurn] = []
    private var labels: [String: String] = [:]
    private var speakers: [ProjectedSpeaker] = []
    private var people: [SpeakerProfile] = []
    private var editable = true
    private var text: (ProjectedTurn) -> String = { _ in "" }
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
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Data

    /// Shows `turns`, keeping the selected turns selected (by ID, after `resolve`) and reloading only what changed
    /// when the rows are the same turns.
    func update(turns newTurns: [ProjectedTurn], speakers newSpeakers: [ProjectedSpeaker], people newPeople: [SpeakerProfile],
                editable newEditable: Bool, text: @escaping (ProjectedTurn) -> String, resolve: (String) -> String) {
        let selected = selectedTurnIDs.map(resolve)
        let oldTurns = turns
        let oldLabels = labels
        let menusChanged = newSpeakers != speakers || newPeople.map(\.id) != people.map(\.id)
            || newPeople.map(\.displayName) != people.map(\.displayName) || newEditable != editable
        turns = newTurns
        speakers = newSpeakers
        people = newPeople
        editable = newEditable
        self.text = text
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
        let measured = (text(turn) as NSString).boundingRect(
            with: NSSize(width: max(40, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Self.textFont])
        let height = max(28, ceil(measured.height) + 10)
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
            return cell
        }()
        let turn = turns[row]
        cell.configure(turn: turn, text: text(turn),
                       menu: AssignMenu.items(speakers: speakers, people: people), editable: editable)
        return cell
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
/// wrapping text), matching `TurnListView`'s row heights.
@MainActor
final class TurnCellView: NSTableCellView {
    static let timeWidth: CGFloat = 72
    static let popUpWidth: CGFloat = 176
    static let warningWidth: CGFloat = 86
    static let gap: CGFloat = 6
    static var textX: CGFloat { 4 + timeWidth + gap + popUpWidth + gap + warningWidth + gap }

    let timeButton = NSButton(title: "", target: nil, action: nil)
    let speakerPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let warningLabel = NSTextField(labelWithString: "")
    let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var menuSignature: [String] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        timeButton.bezelStyle = .inline
        timeButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeButton.toolTip = "Play from here"
        speakerPopUp.controlSize = .small
        speakerPopUp.font = .systemFont(ofSize: 12)
        warningLabel.textColor = .systemOrange
        warningLabel.font = .systemFont(ofSize: 11)
        bodyLabel.font = TurnListView.textFont
        bodyLabel.isSelectable = false
        bodyLabel.maximumNumberOfLines = 0
        for view in [timeButton, speakerPopUp, warningLabel, bodyLabel] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    func configure(turn: ProjectedTurn, text: String, menu items: [NSMenuItem], editable: Bool) {
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
        bodyLabel.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        timeButton.frame = NSRect(x: 4, y: 4, width: Self.timeWidth, height: 20)
        speakerPopUp.frame = NSRect(x: 4 + Self.timeWidth + Self.gap, y: 2, width: Self.popUpWidth, height: 22)
        warningLabel.frame = NSRect(x: 4 + Self.timeWidth + Self.gap + Self.popUpWidth + Self.gap, y: 6,
                                    width: Self.warningWidth, height: 16)
        bodyLabel.frame = NSRect(x: Self.textX, y: 5, width: max(40, bounds.width - Self.textX - 4),
                                 height: max(18, height - 8))
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
