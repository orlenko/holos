import AppKit

/// The system's round help button: its text shows in a popover when clicked, in a tooltip on hover, and to VoiceOver as
/// the button's help, so a one-line caption can keep the detail one click away.
@MainActor
final class HelpPopoverButton: NSButton {
    private static let textWidth: CGFloat = 320
    let text: String
    private var popover: NSPopover?

    init(text: String, label: String) {
        self.text = text
        super.init(frame: .zero)
        title = ""
        bezelStyle = .helpButton
        target = self
        action = #selector(showText)
        toolTip = text
        setAccessibilityLabel(label)
        setAccessibilityHelp(text)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func showText() {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = Self.textWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -10),
            label.widthAnchor.constraint(equalToConstant: Self.textWidth),
        ])
        let controller = NSViewController()
        controller.view = holder
        let shown = NSPopover()
        shown.behavior = .transient
        shown.contentViewController = controller
        popover = shown
        shown.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
}
