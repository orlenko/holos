import AppKit
import HolosCore

/// A list row: time, app, badge, and a two-line preview.
@MainActor
final class HistoryRowView: NSTableCellView {
    private let time = NSTextField(labelWithString: "")
    private let app = NSTextField(labelWithString: "")
    private let badge = BadgeLabel()
    private let preview = NSTextField(wrappingLabelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        app.font = .systemFont(ofSize: 12, weight: .semibold)
        app.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.truncatesLastVisibleLine = true
        textField = preview
        let header = NSStackView(views: [app, badge, NSView(), time])
        header.spacing = 6
        header.alignment = .centerY
        app.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let width = max(100, bounds.width - 12)
        if preview.preferredMaxLayoutWidth != width { preview.preferredMaxLayoutWidth = width }
    }

    func show(_ record: DictationRecord, time text: String) {
        time.stringValue = text
        app.stringValue = record.app ?? "Unknown app"
        preview.stringValue = record.text.replacingOccurrences(of: "\n", with: " ")
        badge.show(record.badge, warning: record.badge != nil && record.badge != "Fixed")
        var label = "\(record.app ?? "Unknown app"), \(text)"
        if let badge = record.badge { label += ", \(badge)" }
        setAccessibilityLabel(label + ". " + record.text)
    }
}

/// A small rounded badge ("Fixed", "Not inserted").
@MainActor
final class BadgeLabel: NSTextField {
    private var warning = false

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 10, weight: .semibold)
        wantsLayer = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 10, height: size.height + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = warning ? .systemOrange : .controlAccentColor
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let text = NSAttributedString(string: stringValue, attributes: [
            .font: font ?? .systemFont(ofSize: 10), .foregroundColor: color,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    func show(_ text: String?, warning: Bool) {
        self.warning = warning
        stringValue = text ?? ""
        isHidden = text == nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}
