import AppKit
import HolosCore

/// The Corrections section's "Word list" card (docs/design.md "Word list"): terms the recognizer should expect, added
/// in the field (Return adds; a paste of several lines adds one term per line), removed with Remove or ⌫, found with
/// the search field. Each term's "Often heard as" words (real words the recognizer writes for it, such as "cloud" for
/// "Claude") are edited in place in their column, comma-separated. The app keeps the list (`words.json`); this view
/// shows it and reports what each change did.
@MainActor
final class WordListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct AddResult {
        /// The line to show: what was added, what the list had already, what could not be added.
        var message: String
        /// Terms neither added nor listed already: they stay in the field to fix or try again.
        var unadded: [String]
    }

    private static let termColumn = NSUserInterfaceItemIdentifier("term")
    private static let heardAsColumn = NSUserInterfaceItemIdentifier("heardAs")

    /// Adds the terms.
    private let onAdd: ([String]) -> AddResult
    /// Removes the terms; returns the line to show.
    private let onRemove: ([String]) -> String
    /// Makes the words the term's "often heard as" words; returns the line to show.
    private let onSetHeardAs: (_ term: String, _ phrases: [String]) -> String

    let searchField = NSSearchField()
    let addField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let table = KeyTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private var entries: [WordListEntry] = []
    /// `entries` matching the search, in list order.
    private var shown: [WordListEntry] = []
    /// The problem last shown, cleared once the list can be read again.
    private var shownProblem: String?

    init(onAdd: @escaping ([String]) -> AddResult, onRemove: @escaping ([String]) -> String,
         onSetHeardAs: @escaping (_ term: String, _ phrases: [String]) -> String) {
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onSetHeardAs = onSetHeardAs
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

        let column = NSTableColumn(identifier: Self.termColumn)
        column.title = "Term"
        column.resizingMask = .autoresizingMask
        column.width = 200
        table.addTableColumn(column)
        let heardAs = NSTableColumn(identifier: Self.heardAsColumn)
        heardAs.title = "Often heard as"
        heardAs.headerToolTip = "Words the recognizer writes for the term, comma-separated. Apple Intelligence's fix "
            + "puts the term there only where the context says it was meant."
        heardAs.resizingMask = .autoresizingMask
        table.addTableColumn(heardAs)
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
            fix counts them as real words. Double-click "Often heard as" to list real words the recognizer writes \
            for a term ("cloud, clot" for "Claude"): with Apple Intelligence's fix on, dictation and meetings get \
            the term there only where the context says it was meant. Also: voiceislocal words add Claude \
            --heard-as cloud,clot.
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
        update(entries: [], problem: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `entries` (oldest first); `problem` says why the list could not be read.
    func update(entries: [WordListEntry], problem: String?) {
        self.entries = entries
        showTerms()
        if let problem {
            feedbackLabel.stringValue = problem
        } else if shownProblem != nil, feedbackLabel.stringValue == shownProblem {
            feedbackLabel.stringValue = ""
        }
        shownProblem = problem
    }

    /// The terms matching the search (in the term or its "often heard as" words), the same ones still selected, and
    /// the count.
    private func showTerms() {
        let selected = Set(table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0].text : nil })
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        shown = query.isEmpty ? entries : entries.filter { entry in
            entry.text.localizedCaseInsensitiveContains(query)
                || (entry.heardAs ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(shown.indices.filter { selected.contains(shown[$0].text) }),
                               byExtendingSelection: false)
        let count = entries.count == 1 ? "1 term" : "\(entries.count) terms"
        countLabel.stringValue = shown.count == entries.count ? count : "\(shown.count) of \(count)"
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
        let chosen = table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0].text : nil }
        guard !chosen.isEmpty else { return }
        feedbackLabel.stringValue = onRemove(chosen)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let entry = shown[row]
        guard tableColumn?.identifier == Self.heardAsColumn else {
            let field = NSTextField(labelWithString: entry.text)
            field.lineBreakMode = .byTruncatingTail
            return field
        }
        // Edited in place: a double-click (or Return on the selected row) opens the field; leaving it saves.
        let field = HeardAsField(string: (entry.heardAs ?? []).joined(separator: ", "))
        field.term = entry.text
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = "Double-click to add, e.g. cloud, clot"
        field.toolTip = "Words the recognizer writes for \(entry.text), comma-separated."
        field.setAccessibilityLabel("Often heard as, for \(entry.text)")
        field.delegate = self
        return field
    }

    /// The "Often heard as" field of one term's row.
    private final class HeardAsField: NSTextField {
        var term = ""
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    /// Saves an edited "Often heard as" field when it is left (Return, Tab, or a click elsewhere), unless it did not
    /// change.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? HeardAsField,
              let entry = entries.first(where: { $0.text == field.term }) else { return }
        let term = field.term
        let phrases = WordList.heardAsList(field.stringValue)
        guard phrases != (entry.heardAs ?? []) else { return }
        feedbackLabel.stringValue = onSetHeardAs(term, phrases)
    }
}
