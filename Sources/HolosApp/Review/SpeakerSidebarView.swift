import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers

/// The left pane of the review window (docs/meeting-design.md §5.10): one row per speaker with a name field (a combo
/// box of known people, most recently used first), talk time, the start of the speaker's two longest turns, Play
/// samples, "This is me", Merge into…, and the suggestion ("Maybe Maria" with Confirm / Not Maria) or automatic name
/// ("Jim (auto)" with Not Jim). Speakers without turns are not listed (except ones made in the window).
@MainActor
final class SpeakerSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
    /// What one row shows.
    struct Row: Equatable {
        let speaker: ProjectedSpeaker
        let previews: [String]
        /// Linked to the person who is you.
        let isSelf: Bool
        /// The person of an automatic name, for "Not Jim".
        let automaticProfileID: String?
        let canPlay: Bool

        var hasExtraLine: Bool { speaker.suggestion != nil || automaticProfileID != nil }
    }

    /// Return in the name field: (speaker ID, the text typed).
    var onName: ((String, String) -> Void)?
    /// A known person picked from the name list: (speaker ID, profile ID).
    var onPickPerson: ((String, String) -> Void)?
    var onPlaySamples: ((String) -> Void)?
    var onMarkSelf: ((String) -> Void)?
    /// (from, into).
    var onMerge: ((String, String) -> Void)?
    /// Confirm a suggestion: (speaker ID, profile ID).
    var onConfirm: ((String, String) -> Void)?
    /// "Not Maria" / "Not Jim".
    var onReject: ((String) -> Void)?
    var onConfirmAll: (() -> Void)?

    private let confirmAllButton = NSButton(title: "Confirm All", target: nil, action: nil)
    private let table = NSTableView()
    private var rows: [Row] = []
    private var people: [SpeakerProfile] = []
    private var editable = true
    /// A name field is being edited: updates wait until it ends, so typing is never interrupted.
    private var editing = false
    private var pending: (rows: [Row], people: [SpeakerProfile], editable: Bool, suggestions: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "SPEAKERS")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        confirmAllButton.bezelStyle = .push
        confirmAllButton.controlSize = .small
        confirmAllButton.target = self
        confirmAllButton.action = #selector(confirmAll)
        confirmAllButton.toolTip = "Name every suggested speaker at once (one undo takes it back)."
        let header = NSStackView(views: [title, NSView(), confirmAllButton])
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("speaker"))
        column.resizingMask = .autoresizingMask
        column.width = 300
        column.minWidth = 240
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.selectionHighlightStyle = .none
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `rows`; while a name is being typed the update waits until the field is left.
    func update(rows newRows: [Row], people newPeople: [SpeakerProfile], editable newEditable: Bool,
                suggestions: Int) {
        guard !editing, !nameFieldIsActive else {
            pending = (newRows, newPeople, newEditable, suggestions)
            return
        }
        pending = nil
        confirmAllButton.title = "Confirm All (\(suggestions))"
        confirmAllButton.isHidden = suggestions == 0
        confirmAllButton.isEnabled = newEditable
        let peopleChanged = newPeople != people || newEditable != editable
        let oldRows = rows
        rows = newRows
        people = newPeople
        editable = newEditable
        guard !peopleChanged, oldRows.count == newRows.count,
              zip(oldRows, newRows).allSatisfy({ $0.speaker.id == $1.speaker.id }) else {
            table.reloadData()
            return
        }
        var changed = IndexSet()
        var resized = IndexSet()
        for index in newRows.indices where oldRows[index] != newRows[index] {
            changed.insert(index)
            if oldRows[index].hasExtraLine != newRows[index].hasExtraLine { resized.insert(index) }
        }
        guard !changed.isEmpty else { return }
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return SpeakerCellView.baseHeight }
        return SpeakerCellView.baseHeight + (rows[row].hasExtraLine ? SpeakerCellView.extraHeight : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("speakerCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SpeakerCellView ?? {
            let cell = SpeakerCellView()
            cell.identifier = identifier
            cell.nameField.target = self
            cell.nameField.action = #selector(nameEntered(_:))
            cell.nameField.delegate = self
            cell.playButton.target = self
            cell.playButton.action = #selector(playSamples(_:))
            cell.selfButton.target = self
            cell.selfButton.action = #selector(markSelf(_:))
            cell.mergePopUp.target = self
            cell.mergePopUp.action = #selector(mergeChosen(_:))
            cell.confirmButton.target = self
            cell.confirmButton.action = #selector(confirmSuggestion(_:))
            cell.rejectButton.target = self
            cell.rejectButton.action = #selector(reject(_:))
            return cell
        }()
        cell.configure(rows[row], others: rows.map(\.speaker).filter { $0.id != rows[row].speaker.id },
                       people: people, editable: editable)
        return cell
    }

    // MARK: - Name field

    /// A name field of this list has the keyboard (its field editor is the first responder), typed in or not.
    private var nameFieldIsActive: Bool {
        guard let editor = window?.firstResponder as? NSTextView, let field = editor.delegate as? NSComboBox else {
            return false
        }
        return table.row(for: field) >= 0
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        editing = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        editing = false
        let field = notification.object as? NSComboBox
        // After the field editor has let go of the keyboard (it still has it while this is sent).
        Task { [weak self] in
            guard let self, !self.nameFieldIsActive else { return }
            if let pending = self.pending {
                self.update(rows: pending.rows, people: pending.people, editable: pending.editable,
                            suggestions: pending.suggestions)
            } else if let field {
                // Left without Return: show the speaker's name again.
                let row = self.table.row(for: field)
                if row >= 0, row < self.rows.count {
                    self.table.reloadData(forRowIndexes: [row], columnIndexes: [0])
                }
            }
        }
    }

    @objc private func nameEntered(_ sender: NSComboBox) {
        guard let speakerID = speakerID(for: sender) else { return }
        let text = sender.stringValue
        let index = sender.indexOfSelectedItem
        if index >= 0, index < people.count, people[index].displayName == text {
            onPickPerson?(speakerID, people[index].id)
        } else {
            onName?(speakerID, text)
        }
        // End editing so the labels shown next (and other rows' updates) appear.
        window?.makeFirstResponder(table)
    }

    // MARK: - Buttons

    @objc private func playSamples(_ sender: NSButton) {
        if let speakerID = speakerID(for: sender) { onPlaySamples?(speakerID) }
    }

    @objc private func markSelf(_ sender: NSButton) {
        if let speakerID = speakerID(for: sender) { onMarkSelf?(speakerID) }
    }

    @objc private func mergeChosen(_ sender: NSPopUpButton) {
        guard let speakerID = speakerID(for: sender),
              let target = sender.selectedItem?.representedObject as? String else { return }
        onMerge?(speakerID, target)
    }

    @objc private func confirmSuggestion(_ sender: NSButton) {
        guard let speakerID = speakerID(for: sender),
              let suggestion = rows.first(where: { $0.speaker.id == speakerID })?.speaker.suggestion else { return }
        onConfirm?(speakerID, suggestion.profileID)
    }

    @objc private func reject(_ sender: NSButton) {
        if let speakerID = speakerID(for: sender) { onReject?(speakerID) }
    }

    @objc private func confirmAll() { onConfirmAll?() }

    private func speakerID(for view: NSView) -> String? {
        let row = table.row(for: view)
        return row >= 0 && row < rows.count ? rows[row].speaker.id : nil
    }
}

/// One speaker row, laid out by hand at the heights `SpeakerSidebarView` gives.
@MainActor
final class SpeakerCellView: NSTableCellView {
    static let baseHeight: CGFloat = 96
    static let extraHeight: CGFloat = 28

    private let ordinalLabel = NSTextField(labelWithString: "")
    let nameField = NSComboBox()
    private let talkLabel = NSTextField(labelWithString: "")
    private let previewLabels = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    let playButton = NSButton(title: "▶ Play samples", target: nil, action: nil)
    let selfButton = NSButton(title: "This is me", target: nil, action: nil)
    let mergePopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let extraLabel = NSTextField(labelWithString: "")
    let confirmButton = NSButton(title: "Confirm", target: nil, action: nil)
    let rejectButton = NSButton(title: "", target: nil, action: nil)
    private var mergeSignature: [String]?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        ordinalLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ordinalLabel.textColor = .secondaryLabelColor
        ordinalLabel.alignment = .right
        nameField.completes = true
        nameField.numberOfVisibleItems = 10
        nameField.usesDataSource = false
        // Only Return (or a pick from the list) names the speaker; leaving the field does not.
        nameField.cell?.sendsActionOnEndEditing = false
        nameField.font = .systemFont(ofSize: 13)
        talkLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        talkLabel.textColor = .secondaryLabelColor
        talkLabel.alignment = .right
        talkLabel.toolTip = "Talk time"
        for label in previewLabels {
            label.font = NSFontManager.shared.convert(.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        for button in [playButton, selfButton, confirmButton, rejectButton] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        mergePopUp.controlSize = .small
        mergePopUp.font = .systemFont(ofSize: 11)
        extraLabel.font = .systemFont(ofSize: 12, weight: .medium)
        extraLabel.lineBreakMode = .byTruncatingTail
        let views: [NSView] = [ordinalLabel, nameField, talkLabel] + previewLabels
            + [playButton, selfButton, mergePopUp, extraLabel, confirmButton, rejectButton]
        for view in views { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: SpeakerSidebarView.Row, others: [ProjectedSpeaker], people: [SpeakerProfile],
                   editable: Bool) {
        let speaker = row.speaker
        ordinalLabel.stringValue = (1...9).contains(speaker.ordinal) ? "\(speaker.ordinal)" : ""
        ordinalLabel.toolTip = (1...9).contains(speaker.ordinal)
            ? "Press \(speaker.ordinal) in the turn list to give the selected turns to this speaker." : nil
        nameField.removeAllItems()
        nameField.addItems(withObjectValues: people.map(\.displayName))
        // An unnamed speaker shows "Speaker 3" as a placeholder, so Return on it never makes a person of that name.
        let named = speaker.explicitName != nil || speaker.profileID != nil || speaker.isAutomatic
        nameField.stringValue = named ? speaker.name : ""
        nameField.placeholderString = speaker.name
        nameField.isEnabled = editable
        nameField.toolTip = "Type a name and press Return, or choose a person. An empty name clears it."
        talkLabel.stringValue = TimeFormat.duration(speaker.talkSeconds)
        for (index, label) in previewLabels.enumerated() {
            guard index < row.previews.count else {
                label.stringValue = ""
                continue
            }
            // Previews are the first 60 characters; a full-length one was probably cut.
            let preview = row.previews[index]
            label.stringValue = preview.count >= 60 ? "“\(preview)…”" : "“\(preview)”"
        }
        playButton.isEnabled = row.canPlay
        selfButton.isHidden = row.isSelf
        selfButton.isEnabled = editable
        // Replaced only when it changed, so an update never swaps a menu that is open.
        let signature = others.map { $0.id + "\u{1f}" + AssignMenu.title(of: $0) }
        if signature != mergeSignature {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(NSMenuItem(title: "Merge into…", action: nil, keyEquivalent: ""))
            for other in others {
                let item = NSMenuItem(title: AssignMenu.title(of: other), action: nil, keyEquivalent: "")
                item.representedObject = other.id
                menu.addItem(item)
            }
            mergePopUp.menu = menu
            mergeSignature = signature
        }
        mergePopUp.isEnabled = editable && !others.isEmpty
        mergePopUp.toolTip = "Move every turn of this speaker to another speaker, who keeps their name."

        if let suggestion = speaker.suggestion {
            extraLabel.stringValue = "Maybe \(suggestion.profileName)"
            extraLabel.textColor = .systemBlue
            confirmButton.isHidden = false
            rejectButton.title = "Not \(suggestion.profileName)"
        } else if row.automaticProfileID != nil {
            extraLabel.stringValue = speaker.label
            extraLabel.textColor = .labelColor
            confirmButton.isHidden = true
            rejectButton.title = "Not \(speaker.name)"
        }
        let extra = row.hasExtraLine
        extraLabel.isHidden = !extra
        rejectButton.isHidden = !extra
        if !extra { confirmButton.isHidden = true }
        confirmButton.isEnabled = editable
        rejectButton.isEnabled = editable
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        ordinalLabel.frame = NSRect(x: 2, y: 8, width: 14, height: 16)
        talkLabel.frame = NSRect(x: width - 56, y: 8, width: 52, height: 16)
        nameField.frame = NSRect(x: 20, y: 4, width: max(80, width - 20 - 60), height: 24)
        previewLabels[0].frame = NSRect(x: 22, y: 32, width: max(40, width - 26), height: 15)
        previewLabels[1].frame = NSRect(x: 22, y: 47, width: max(40, width - 26), height: 15)
        playButton.sizeToFit()
        selfButton.sizeToFit()
        playButton.frame.origin = NSPoint(x: 18, y: 66)
        var x = playButton.frame.maxX + 4
        if !selfButton.isHidden {
            selfButton.frame.origin = NSPoint(x: x, y: 66)
            x = selfButton.frame.maxX + 4
        }
        mergePopUp.frame = NSRect(x: x, y: 66, width: max(90, min(150, width - x - 4)), height: 22)
        let extraY = Self.baseHeight - 2
        confirmButton.sizeToFit()
        rejectButton.sizeToFit()
        var right = width - 4
        rejectButton.frame.origin = NSPoint(x: right - rejectButton.frame.width, y: extraY)
        right = rejectButton.frame.minX - 4
        if !confirmButton.isHidden {
            confirmButton.frame.origin = NSPoint(x: right - confirmButton.frame.width, y: extraY)
            right = confirmButton.frame.minX - 4
        }
        extraLabel.frame = NSRect(x: 22, y: extraY + 4, width: max(40, right - 26), height: 16)
    }
}
