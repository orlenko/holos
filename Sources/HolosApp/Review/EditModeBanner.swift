import AppKit

/// The band under the toolbar while edit mode is on: a tint of the accent color and what to do, or a passing message.
final class EditModeBanner: NSView {
    static let usual = "Editing — click a word to change it. ⇧-click or drag for more words of the same turn. Return "
        + "saves, ⌥Return saves and adds it to the word list, Tab saves and edits the next word, Esc cancels. "
        + "Return at the start of a word (← first) splits the turn before it; at its end (→ first), after it. Space "
        + "still plays and pauses."
    let label = NSTextField(wrappingLabelWithString: EditModeBanner.usual)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Edit mode")
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { nil }

    /// `message` for now, or the usual text.
    func show(message: String?) {
        let text = message ?? Self.usual
        if label.stringValue != text { label.stringValue = text }
        label.textColor = message == nil ? .labelColor : .systemOrange
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
