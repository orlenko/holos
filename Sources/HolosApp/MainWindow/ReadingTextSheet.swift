import AppKit

/// Show Text (docs/design.md "Reading section"): the text a reading reads, as it was saved when the reading was loaded,
/// in a sheet over the main window, to read, select, or copy whole.
@MainActor
final class ReadingTextSheet: NSViewController {
    private let heading: String
    let text: String

    init(title: String, text: String) {
        self.heading = title
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        if let body = scroll.documentView as? NSTextView {
            body.isEditable = false
            body.isSelectable = true
            body.font = .systemFont(ofSize: 13)
            body.textContainerInset = NSSize(width: 6, height: 8)
            body.string = text
            body.setAccessibilityLabel("Text of \(heading)")
        }

        let copy = NSButton(title: "Copy Text", target: self, action: #selector(copyText))
        copy.toolTip = "Copy the whole text"
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .push
        done.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [copy, NSView(), done])

        let stack = NSStackView(views: [title, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [title, scroll, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 600).isActive = true
        view = stack
    }

    /// Copy Text: the user's choice, so the clipboard gets the text.
    @objc func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func close() {
        dismiss(self)
    }
}
