import AppKit
import HolosCore

/// Fix the last dictation here; Holos compares it with what it wrote and keeps the word swaps.
@MainActor
final class CorrectionsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let window: NSWindow
    struct LearnResult {
        var learned: [Correction]
        /// Single common-word swaps with no neighbouring word to anchor them; offered for manual adding.
        var declined: [Correction]
        /// The edit to keep once one of `declined` is added; nil when Learn already kept it.
        var edit: DeclinedCorrectionQueue.PendingEdit?
    }

    /// Returns the learned and declined pairs, or nil when the change could not be saved.
    private let onLearn: (String) -> LearnResult?
    /// Adds a rule, with the edit of the declined swap it resolves (if any). False means not saved.
    private let onAdd: (Correction, DeclinedCorrectionQueue.PendingEdit?) -> Bool
    private let onRemove: (Correction) -> Bool
    /// Replaces the first rule with the second in place, with the edit of the declined swap it resolves (if any).
    /// False means not saved.
    private let onReplace: (Correction, Correction, DeclinedCorrectionQueue.PendingEdit?) -> Bool
    private let transcriptView: NSTextView
    private let learnButton = NSButton(title: "Learn Corrections", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Text", target: nil, action: nil)
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let listStack = NSStackView()
    private let heardField = NSTextField()
    private let meantField = NSTextField()
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let cancelEditButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// The rule being edited in the fields below the list; Add becomes Save while it is set.
    private var editing: Correction?
    private var positioned = false
    private var shown: [Correction] = []
    private var declined = DeclinedCorrectionQueue()
    /// The feedback lines shown above the declined-swap suggestion, so a refill can redraw them.
    private var reported: [String] = []

    init(onLearn: @escaping (String) -> LearnResult?,
         onAdd: @escaping (Correction, DeclinedCorrectionQueue.PendingEdit?) -> Bool,
         onRemove: @escaping (Correction) -> Bool,
         onReplace: @escaping (Correction, Correction, DeclinedCorrectionQueue.PendingEdit?) -> Bool) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
        self.onLearn = onLearn
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onReplace = onReplace
        let transcriptScroll = NSTextView.scrollableTextView()
        transcriptView = transcriptScroll.documentView as! NSTextView
        super.init()
        window.title = "Holos Corrections"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 480, height: 480)

        transcriptView.isRichText = false
        transcriptView.font = .systemFont(ofSize: 14)
        transcriptView.textContainerInset = NSSize(width: 6, height: 6)
        // The user is fixing recognition, not asking for more automatic edits.
        transcriptView.isAutomaticSpellingCorrectionEnabled = false
        transcriptView.isAutomaticTextReplacementEnabled = false
        transcriptView.isAutomaticQuoteSubstitutionEnabled = false
        transcriptView.isAutomaticDashSubstitutionEnabled = false
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        learnButton.target = self
        learnButton.action = #selector(learn)
        learnButton.keyEquivalent = "\r"
        copyButton.target = self
        copyButton.action = #selector(copyText)
        let actions = NSStackView(views: [learnButton, copyButton])
        actions.spacing = 8
        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.textColor = .secondaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let listDocument = FlippedView()
        listDocument.translatesAutoresizingMaskIntoConstraints = false
        listDocument.addSubview(listStack)
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.documentView = listDocument
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listDocument.leadingAnchor, constant: 8),
            listStack.trailingAnchor.constraint(equalTo: listDocument.trailingAnchor, constant: -8),
            listStack.topAnchor.constraint(equalTo: listDocument.topAnchor, constant: 8),
            listStack.bottomAnchor.constraint(equalTo: listDocument.bottomAnchor, constant: -8),
            listDocument.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        heardField.placeholderString = "Heard (e.g. bull request)"
        meantField.placeholderString = "Meant (e.g. pull request)"
        heardField.delegate = self
        meantField.delegate = self
        // Return in either field adds (or saves an edit) rather than pressing the default Learn button.
        for field in [heardField, meantField] {
            field.target = self
            field.action = #selector(addManual)
        }
        addButton.target = self
        addButton.action = #selector(addManual)
        cancelEditButton.target = self
        cancelEditButton.action = #selector(cancelEdit)
        cancelEditButton.isHidden = true
        skipButton.target = self
        skipButton.action = #selector(skipDeclined)
        skipButton.toolTip = "Drop the suggested correction without adding it."
        skipButton.isHidden = true
        let addRow = NSStackView(views: [heardField, NSTextField(labelWithString: "→"), meantField, addButton,
                                         cancelEditButton, skipButton])
        addRow.spacing = 8
        heardField.widthAnchor.constraint(equalTo: meantField.widthAnchor).isActive = true

        let note = NSTextField(wrappingLabelWithString: """
            Holos replaces these phrases in new dictations and tells the recognizer to expect the \
            corrected words. Changes here do not edit text already inserted into other apps.
            """)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            heading("Last dictation — fix any misheard words, then Learn"), transcriptScroll, actions,
            feedbackLabel, heading("Corrections"), listScroll, addRow, note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: feedbackLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        for view in [transcriptScroll, feedbackLabel, listScroll, addRow, note] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView = content
    }

    func show(lastTranscript: String, corrections: [Correction]) {
        transcriptView.string = lastTranscript
        let hasTranscript = !lastTranscript.isEmpty
        transcriptView.isEditable = hasTranscript
        learnButton.isEnabled = hasTranscript
        copyButton.isEnabled = hasTranscript
        report(hasTranscript ? [] : ["No dictation yet. You can still add corrections below."])
        update(corrections: corrections)
        if !positioned {
            window.center()
            positioned = true
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        if hasTranscript { window.makeFirstResponder(transcriptView) }
    }

    func update(corrections: [Correction]) {
        shown = corrections
        for view in listStack.arrangedSubviews { view.removeFromSuperview() }
        if corrections.isEmpty {
            let empty = NSTextField(labelWithString: "No corrections yet.")
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
        }
        for (index, correction) in corrections.enumerated() {
            let label = NSTextField(labelWithString: "\(correction.heard)  →  \(correction.meant)")
            label.lineBreakMode = .byTruncatingTail
            let edit = NSButton(title: "Edit", target: self, action: #selector(editEntry(_:)))
            edit.bezelStyle = .inline
            edit.tag = index
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeEntry(_:)))
            remove.bezelStyle = .inline
            remove.tag = index
            let row = NSStackView(views: [label, NSView(), edit, remove])
            row.spacing = 8
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private static let saveFailure = "Corrections could not be saved; see the Holos status in the menu."

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    @objc private func learn() {
        guard let result = onLearn(transcriptView.string) else {
            feedbackLabel.stringValue = Self.saveFailure
            return
        }
        declined.receive(result.declined, edit: result.edit)
        var lines: [String] = []
        if !result.learned.isEmpty {
            lines.append("Learned: " + Self.describe(result.learned))
        }
        if !result.declined.isEmpty {
            lines.append("Not learned automatically: \(Self.describe(result.declined)). A common word with no word "
                + "next to it could make a rule change unrelated text, so add it only if you want it everywhere.")
        }
        if lines.isEmpty {
            lines.append("No changed words found. Edit a misheard word above, then Learn.")
        }
        report(lines)
    }

    /// Shows `lines`, then what declined swaps are waiting (filling the Add fields when both are blank).
    private func report(_ lines: [String]) {
        reported = lines
        feedbackLabel.stringValue = (lines + [suggestDeclined()].compactMap { $0 }).joined(separator: "\n")
    }

    /// Clearing both Add fields by hand fills in the next waiting swap, as the suggestion says.
    func controlTextDidChange(_ notification: Notification) {
        guard editing == nil,
              declined.prefill(heard: heardField.stringValue, meant: meantField.stringValue) != nil else { return }
        report(reported)
    }

    private static func describe(_ corrections: [Correction]) -> String {
        corrections.map { "\($0.heard) → \($0.meant)" }.joined(separator: "; ")
    }

    /// Fills the Add fields with the next declined swap when both are empty, and describes what is waiting.
    private func suggestDeclined() -> String? {
        skipButton.isHidden = declined.isEmpty || editing != nil
        guard let next = declined.pending.first else { return nil }
        if editing == nil, let fill = declined.prefill(heard: heardField.stringValue, meant: meantField.stringValue) {
            heardField.stringValue = fill.heard
            meantField.stringValue = fill.meant
        }
        let waiting = "Waiting to add: \(Self.describe(declined.pending))."
        if heardField.stringValue == next.heard, meantField.stringValue == next.meant {
            return waiting + " \(next.heard) → \(next.meant) is filled in below; choose Add, or Skip to drop it."
        }
        return waiting + " Add or clear what is in the fields below to fill in \(next.heard) → \(next.meant), "
            + "or Skip to drop it."
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(transcriptView.string, forType: .string)
        feedbackLabel.stringValue = copied ? "Copied the corrected text." : "Clipboard write failed."
    }

    @objc private func addManual() {
        if let original = editing {
            saveEdit(of: original)
            return
        }
        let correction = Correction(heard: heardField.stringValue, meant: meantField.stringValue)
        guard !correction.heard.trimmingCharacters(in: .whitespaces).isEmpty,
              !correction.meant.trimmingCharacters(in: .whitespaces).isEmpty else {
            feedbackLabel.stringValue = "Enter both the misheard phrase and the intended one."
            return
        }
        // CorrectionList.add ignores a pair whose two sides are the same, so refuse it here, before the
        // queue is touched or the edited transcript is committed.
        guard correction.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                != correction.meant.trimmingCharacters(in: .whitespacesAndNewlines) else {
            feedbackLabel.stringValue = "The misheard and intended text are the same, so there is nothing to add."
            return
        }
        var remaining = declined
        let resolved = remaining.resolve(added: correction)
        guard onAdd(correction, resolved?.edit) else {
            feedbackLabel.stringValue = Self.saveFailure
            return
        }
        declined = remaining
        heardField.stringValue = ""
        meantField.stringValue = ""
        report(["Added: \(correction.heard) → \(correction.meant)"])
    }

    @objc private func skipDeclined() {
        guard let skipped = declined.skip() else { return }
        if heardField.stringValue == skipped.heard, meantField.stringValue == skipped.meant {
            heardField.stringValue = ""
            meantField.stringValue = ""
        }
        report(["Skipped: \(skipped.heard) → \(skipped.meant)"])
    }

    @objc private func removeEntry(_ sender: NSButton) {
        guard shown.indices.contains(sender.tag) else { return }
        let correction = shown[sender.tag]
        guard onRemove(correction) else {
            feedbackLabel.stringValue = Self.saveFailure
            return
        }
        if editing == correction {
            endEditing(["Removed: \(correction.heard) → \(correction.meant)"])
            return
        }
        feedbackLabel.stringValue = "Removed: \(correction.heard) → \(correction.meant)"
    }

    /// Loads a rule into the fields below the list; Save replaces it in place.
    @objc private func editEntry(_ sender: NSButton) {
        guard shown.indices.contains(sender.tag) else { return }
        let correction = shown[sender.tag]
        // Never drop unsaved changes to the rule being edited by loading another one over them.
        if let current = editing, current != correction,
           heardField.stringValue != current.heard || meantField.stringValue != current.meant {
            feedbackLabel.stringValue = "Save or Cancel the change to \(current.heard) → \(current.meant) first."
            return
        }
        editing = correction
        heardField.stringValue = correction.heard
        meantField.stringValue = correction.meant
        addButton.title = "Save"
        cancelEditButton.isHidden = false
        skipButton.isHidden = true
        feedbackLabel.stringValue = "Editing \(correction.heard) → \(correction.meant). Change it below, then Save."
        window.makeFirstResponder(meantField)
    }

    @objc private func cancelEdit() {
        endEditing([])
    }

    private func saveEdit(of original: Correction) {
        let changed = Correction(heard: heardField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                 meant: meantField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !changed.heard.isEmpty, !changed.meant.isEmpty else {
            feedbackLabel.stringValue = "Enter both the misheard phrase and the intended one, or Remove the rule."
            return
        }
        guard changed.heard != changed.meant else {
            feedbackLabel.stringValue = "The misheard and intended text are the same; change one, or Remove the rule."
            return
        }
        // An unchanged rule that is still listed needs no save; one removed or replaced meanwhile is saved again.
        guard changed != original || !shown.contains(original) else {
            endEditing(["No change to \(original.heard) → \(original.meant)."])
            return
        }
        let replaced = CorrectionList(entries: shown).conflicts(replacing: original, with: changed)
        // Saving a rule a declined swap asks for resolves that swap, and keeps its edit, as Add does.
        var remaining = declined
        let resolved = remaining.resolve(added: changed)
        guard onReplace(original, changed, resolved?.edit) else {
            feedbackLabel.stringValue = Self.saveFailure
            return
        }
        declined = remaining
        var lines = ["Changed: \(original.heard) → \(original.meant) is now \(changed.heard) → \(changed.meant)."]
        if !replaced.isEmpty {
            lines.append("It replaces the other rule for the same phrase: \(Self.describe(replaced)).")
        }
        endEditing(lines)
    }

    /// Leaves edit mode, clears the fields, and redraws the feedback (which may refill a waiting swap).
    private func endEditing(_ lines: [String]) {
        editing = nil
        addButton.title = "Add"
        cancelEditButton.isHidden = true
        heardField.stringValue = ""
        meantField.stringValue = ""
        report(lines)
    }
}

/// Scroll views lay out documents bottom-up unless the document is flipped.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
