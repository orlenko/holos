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
    private let transcriptView: NSTextView
    private let learnButton = NSButton(title: "Learn Corrections", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Text", target: nil, action: nil)
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let listStack = NSStackView()
    private let heardField = NSTextField()
    private let meantField = NSTextField()
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private var positioned = false
    private var shown: [Correction] = []
    private var declined = DeclinedCorrectionQueue()
    /// The feedback lines shown above the declined-swap suggestion, so a refill can redraw them.
    private var reported: [String] = []

    init(onLearn: @escaping (String) -> LearnResult?,
         onAdd: @escaping (Correction, DeclinedCorrectionQueue.PendingEdit?) -> Bool,
         onRemove: @escaping (Correction) -> Bool) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
        self.onLearn = onLearn
        self.onAdd = onAdd
        self.onRemove = onRemove
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
        let addButton = NSButton(title: "Add", target: self, action: #selector(addManual))
        skipButton.target = self
        skipButton.action = #selector(skipDeclined)
        skipButton.toolTip = "Drop the suggested correction without adding it."
        skipButton.isHidden = true
        let addRow = NSStackView(views: [heardField, NSTextField(labelWithString: "→"), meantField, addButton,
                                         skipButton])
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
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeEntry(_:)))
            remove.bezelStyle = .inline
            remove.tag = index
            let row = NSStackView(views: [label, NSView(), remove])
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
        guard declined.prefill(heard: heardField.stringValue, meant: meantField.stringValue) != nil else { return }
        report(reported)
    }

    private static func describe(_ corrections: [Correction]) -> String {
        corrections.map { "\($0.heard) → \($0.meant)" }.joined(separator: "; ")
    }

    /// Fills the Add fields with the next declined swap when both are empty, and describes what is waiting.
    private func suggestDeclined() -> String? {
        skipButton.isHidden = declined.isEmpty
        guard let next = declined.pending.first else { return nil }
        if let fill = declined.prefill(heard: heardField.stringValue, meant: meantField.stringValue) {
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
        let correction = Correction(heard: heardField.stringValue, meant: meantField.stringValue)
        guard !correction.heard.trimmingCharacters(in: .whitespaces).isEmpty,
              !correction.meant.trimmingCharacters(in: .whitespaces).isEmpty else {
            feedbackLabel.stringValue = "Enter both the misheard phrase and the intended one."
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
        feedbackLabel.stringValue = "Removed: \(correction.heard) → \(correction.meant)"
    }
}

/// Scroll views lay out documents bottom-up unless the document is flipped.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
