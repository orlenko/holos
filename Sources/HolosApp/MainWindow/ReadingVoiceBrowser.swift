import AppKit
import HolosSynthesis

/// Search, language filtering and a bounded list for `ReadingVoicePopup`.
///
/// Invariants:
/// 1. Search, filters and keyboard movement change only the visible rows and highlight, never the chosen voice.
/// 2. Return or a row click chooses an offered row; Escape dismisses without choosing.
/// 3. Automatic remains available independently of filters, including when there are no matching voices.
@MainActor
final class ReadingVoiceBrowser: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let search = NSSearchField()
    let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let table = ReadingVoiceTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No matching voices.\nTry another search or language.")
    private let naturalHint = NSTextField(wrappingLabelWithString: ReadingVoicePopup.naturalHint)
    private let automatic = NSButton(title: "Automatic", target: nil, action: nil)
    private var catalog: ReadingVoiceList
    private var selectedID: String?
    private(set) var visibleItems: [ReadingVoiceList.Item] = []
    var onChoose: ((String?) -> Void)?
    var onCancel: (() -> Void)?

    init(catalog: ReadingVoiceList, selectedID: String?, showNaturalHint: Bool) {
        self.catalog = catalog
        self.selectedID = selectedID
        super.init(nibName: nil, bundle: nil)
        view = makeContent()
        update(catalog: catalog, selectedID: selectedID, showNaturalHint: showNaturalHint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(catalog: ReadingVoiceList, selectedID: String?, showNaturalHint: Bool) {
        let language = languagePopup.selectedItem?.representedObject as? String
        self.catalog = catalog
        self.selectedID = selectedID
        languagePopup.removeAllItems()
        languagePopup.addItem(withTitle: "All languages")
        for entry in catalog.languages {
            languagePopup.addItem(withTitle: entry.name)
            languagePopup.lastItem?.representedObject = entry.code
        }
        if let index = languagePopup.itemArray.firstIndex(where: { $0.representedObject as? String == language }) {
            languagePopup.selectItem(at: index)
        }
        automatic.state = selectedID == nil ? .on : .off
        naturalHint.isHidden = !showNaturalHint
        refreshResults()
    }

    private func makeContent() -> NSView {
        search.placeholderString = "Search voices"
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.delegate = self
        search.setAccessibilityLabel("Search voices")
        search.toolTip = "Search by name, language, region, or quality"
        languagePopup.target = self
        languagePopup.action = #selector(filtersChanged)
        languagePopup.setAccessibilityLabel("Filter voices by language")
        let languageRow = NSStackView(views: [NSTextField(labelWithString: "Language"), languagePopup])
        languageRow.spacing = 8
        languageRow.alignment = .centerY
        languagePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        automatic.setButtonType(.radio)
        automatic.target = self
        automatic.action = #selector(chooseAutomatic)
        automatic.setAccessibilityHelp("Choose the best voice for the text's language")
        let automaticDetail = NSTextField(wrappingLabelWithString: "Best voice for the text’s language")
        automaticDetail.font = .systemFont(ofSize: 11)
        automaticDetail.textColor = .secondaryLabelColor

        let scroll = makeList()
        for label in [countLabel, naturalHint] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let stack = NSStackView(views: [search, languageRow, automatic, automaticDetail, scroll, countLabel, naturalHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: automatic)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 450))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 360),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        for row in [search, languageRow, automaticDetail, scroll, naturalHint] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return content
    }

    private func makeList() -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("voice"))
        column.width = 328
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 48
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseClickedRow)
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Matching voices")
        table.onReturn = { [weak self] in self?.chooseHighlighted() }
        table.onCancel = { [weak self] in self?.onCancel?() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 264).isActive = true
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -24),
        ])
        return scroll
    }

    func refreshResults() {
        let highlighted = visibleItems.indices.contains(table.selectedRow) ? visibleItems[table.selectedRow].id : selectedID
        visibleItems = catalog.matching(query: search.stringValue,
                                        language: languagePopup.selectedItem?.representedObject as? String)
        table.reloadData()
        emptyLabel.isHidden = !visibleItems.isEmpty
        countLabel.stringValue = "\(visibleItems.count) of \(catalog.items.count) voices"
        let index = visibleItems.firstIndex { $0.id == highlighted } ?? (visibleItems.isEmpty ? nil : 0)
        if let index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visibleItems[row]
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected") ?? NSImage())
        check.isHidden = item.id != selectedID
        check.contentTintColor = .controlAccentColor
        let cell = NSTableCellView()
        let rowView = NSStackView(views: [labels, check])
        rowView.spacing = 8
        rowView.alignment = .centerY
        rowView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            rowView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 16),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor),
            detail.widthAnchor.constraint(equalTo: labels.widthAnchor),
        ])
        cell.textField = name
        cell.toolTip = item.title
        cell.setAccessibilityElement(true)
        cell.setAccessibilityLabel(item.title)
        cell.setAccessibilityValue(item.id == selectedID ? "Selected" : "")
        return cell
    }

    func controlTextDidChange(_ notification: Notification) { refreshResults() }
    @objc private func filtersChanged() { refreshResults() }
    @objc private func chooseAutomatic() { onChoose?(nil) }
    @objc private func chooseClickedRow() {
        guard visibleItems.indices.contains(table.clickedRow) else { return }
        onChoose?(visibleItems[table.clickedRow].id)
    }

    func chooseHighlighted() {
        guard visibleItems.indices.contains(table.selectedRow) else { return }
        onChoose?(visibleItems[table.selectedRow].id)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard control === search else { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !visibleItems.isEmpty else { return true }
            let direction = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(visibleItems.count - 1, max(0, table.selectedRow + direction))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            chooseHighlighted()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default: return false
        }
    }
}

/// Return commits the keyboard highlight; Escape dismisses the picker.
///
/// Invariants:
/// 1. Keyboard arrows use the table's normal highlight movement; only Return calls `onReturn`.
@MainActor
final class ReadingVoiceTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}
