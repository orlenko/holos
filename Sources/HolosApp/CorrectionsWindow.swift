import AppKit
import HolosCore

/// Fix the last dictation here; Holos compares it with what it wrote and keeps the word swaps.
@MainActor
final class CorrectionsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    /// Returns the learned pairs, or nil when the change could not be saved.
    struct LearnResult {
        var learned: [Correction]
        /// Single common-word swaps with no neighbouring word to anchor them; offered for manual adding.
        var declined: [Correction]
    }

    private let onLearn: (String) -> LearnResult?
    private let onAdd: (Correction) -> Bool
    private let onRemove: (Correction) -> Bool
    private let transcriptView: NSTextView
    private let learnButton = NSButton(title: "Learn Corrections", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Text", target: nil, action: nil)
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let listStack = NSStackView()
    private let heardField = NSTextField()
    private let meantField = NSTextField()
    private var positioned = false
    private var shown: [Correction] = []

    init(onLearn: @escaping (String) -> LearnResult?, onAdd: @escaping (Correction) -> Bool,
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
        let addButton = NSButton(title: "Add", target: self, action: #selector(addManual))
        let addRow = NSStackView(views: [heardField, NSTextField(labelWithString: "→"), meantField, addButton])
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
        feedbackLabel.stringValue = hasTranscript ? "" : "No dictation yet. You can still add corrections below."
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
        var lines: [String] = []
        if !result.learned.isEmpty {
            lines.append("Learned: " + result.learned.map { "\($0.heard) → \($0.meant)" }.joined(separator: "; "))
        }
        if let first = result.declined.first {
            let pairs = result.declined.map { "\($0.heard) → \($0.meant)" }.joined(separator: "; ")
            lines.append("Not learned automatically: \(pairs). \(first.heard) is a common word with no word next to it, "
                + "so a rule could change unrelated text. It is filled in below; choose Add to use it everywhere.")
            heardField.stringValue = first.heard
            meantField.stringValue = first.meant
        }
        feedbackLabel.stringValue = lines.isEmpty
            ? "No changed words found. Edit a misheard word above, then Learn."
            : lines.joined(separator: "\n")
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
        guard onAdd(correction) else {
            feedbackLabel.stringValue = Self.saveFailure
            return
        }
        heardField.stringValue = ""
        meantField.stringValue = ""
        feedbackLabel.stringValue = "Added: \(correction.heard) → \(correction.meant)"
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
