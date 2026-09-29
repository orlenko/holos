import AppKit
import HolosCore

/// The Corrections section's "Word list" card (docs/design.md "Word list"): terms the recognizer should expect, added
/// in the field (Return adds; a paste of several lines adds one term per line), removed with Remove or ⌫, found with
/// the search field. The app keeps the list (`words.json`); this view shows it and reports what each change did.
@MainActor
final class WordListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct AddResult {
        /// The line to show: what was added, what the list had already, what could not be added.
        var message: String
        /// Terms neither added nor listed already: they stay in the field to fix or try again.
        var unadded: [String]
    }

    /// Adds the terms.
    private let onAdd: ([String]) -> AddResult
    /// Removes the terms; returns the line to show.
    private let onRemove: ([String]) -> String

    let searchField = NSSearchField()
    let addField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let table = KeyTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private var terms: [String] = []
    /// `terms` matching the search, in list order.
    private var shown: [String] = []
    /// The problem last shown, cleared once the list can be read again.
    private var shownProblem: String?

    init(onAdd: @escaping ([String]) -> AddResult, onRemove: @escaping ([String]) -> String) {
        self.onAdd = onAdd
        self.onRemove = onRemove
        super.init(frame: .zero)

        let heading = NSTextField(labelWithString: "Word list")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        searchField.placeholderString = "Search the word list"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search the word list")
        let header = NSStackView(views: [heading, countLabel, NSView(), searchField])
        header.spacing = 8
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("term"))
        column.title = "Term"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Word list")
        table.onDelete = { [weak self] in self?.removeSelected() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        addField.placeholderString = "Add a term (e.g. Keycloak), or paste one per line"
        addField.setAccessibilityLabel("Term to add")
        // A paste of several lines keeps its line breaks: each line is a term.
        addField.cell?.usesSingleLineMode = false
        addField.cell?.wraps = false
        addField.cell?.isScrollable = true
        // Return adds rather than pressing the section's default button.
        addField.target = self
        addField.action = #selector(add)
        addButton.target = self
        addButton.action = #selector(add)
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.toolTip = "Remove the selected terms (⌫)."
        removeButton.isEnabled = false
        let addRow = NSStackView(views: [addField, addButton, removeButton])
        addRow.spacing = 8

        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString: """
            Words the recognizer should expect: names, products, jargon. Add each as you write it ("Keycloak", \
            "Urban Sky"). New dictations and meetings use the list; the recognizer gets its first \
            \(RecognizerVocabulary.maximumStrings) terms, ahead of the words of corrections. Apple Intelligence's \
            fix counts them as real words. Also: voiceislocal words add "Urban Sky".
            """)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header, scroll, addRow, feedbackLabel, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in [header, scroll, addRow, feedbackLabel, note] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        update(terms: [], problem: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `terms` (oldest first); `problem` says why the list could not be read.
    func update(terms: [String], problem: String?) {
        self.terms = terms
        showTerms()
        if let problem {
            feedbackLabel.stringValue = problem
        } else if shownProblem != nil, feedbackLabel.stringValue == shownProblem {
            feedbackLabel.stringValue = ""
        }
        shownProblem = problem
    }

    /// The terms matching the search, the same ones still selected, and the count.
    private func showTerms() {
        let selected = Set(table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0] : nil })
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        shown = query.isEmpty ? terms : terms.filter { $0.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        table.selectRowIndexes(IndexSet(shown.indices.filter { selected.contains(shown[$0]) }),
                               byExtendingSelection: false)
        let count = terms.count == 1 ? "1 term" : "\(terms.count) terms"
        countLabel.stringValue = shown.count == terms.count ? count : "\(shown.count) of \(count)"
        updateButtons()
    }

    private func updateButtons() {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    @objc private func searchChanged() {
        showTerms()
    }

    @objc private func add() {
        let lines = WordList.lines(in: addField.stringValue)
        guard !lines.isEmpty else {
            feedbackLabel.stringValue = "Type a term to add, or paste several, one per line."
            return
        }
        let result = onAdd(lines)
        feedbackLabel.stringValue = result.message
        addField.stringValue = result.unadded.joined(separator: "\n")
    }

    @objc private func removeSelected() {
        let chosen = table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0] : nil }
        guard !chosen.isEmpty else { return }
        feedbackLabel.stringValue = onRemove(chosen)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: shown.indices.contains(row) ? shown[row] : "")
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
