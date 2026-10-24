import AppKit

/// The views Settings builds its cards from: a row's title and detail, a note under a setting, a checkbox that wraps.
extension SettingsPane {
    static func labels(_ title: String) -> (NSStackView, title: NSTextField, detail: NSTextField) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        let preferred = text.widthAnchor.constraint(equalToConstant: textWidth)
        preferred.priority = NSLayoutConstraint.Priority(260)
        preferred.isActive = true
        // Below this the control gives way first (`addControlRow`), so the detail never wraps a word a line.
        let readable = text.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        readable.priority = NSLayoutConstraint.Priority(280)
        readable.isActive = true
        return (text, titleLabel, detail)
    }

    /// A note under a setting; it wraps at the width it gets (the card's).
    static func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        return note
    }

    /// A checkbox whose title wraps when the card is narrower than it (the window beside a call's window).
    static func wrapsTitle(_ checkbox: NSButton) {
        checkbox.lineBreakMode = .byWordWrapping
        checkbox.usesSingleLineMode = false
        checkbox.cell?.wraps = true
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}
