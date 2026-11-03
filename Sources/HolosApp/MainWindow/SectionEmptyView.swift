import AppKit

/// What a section shows with nothing in it: a symbol, a headline, a sentence, and at most the section's one action.
/// A message with no symbol is only the sentence (a search with no matches), so it reads as a note rather than a welcome.
@MainActor
final class SectionEmptyView: NSView {
    struct Content: Equatable {
        var symbol: String?
        var title: String?
        var text: String
        var action: String?
        /// The action is what the section is for, so it takes the accent color.
        var prominent = false

        init(symbol: String? = nil, title: String? = nil, text: String, action: String? = nil, prominent: Bool = false) {
            self.symbol = symbol
            self.title = title
            self.text = text
            self.action = action
            self.prominent = prominent
        }
    }

    var onAction: (() -> Void)?
    private let image = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private static let textWidth: CGFloat = 340

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        image.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        textLabel.alignment = .center
        textLabel.textColor = .secondaryLabelColor
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(actionPressed)
        let stack = NSStackView(views: [image, titleLabel, textLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: image)
        stack.setCustomSpacing(14, after: textLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth),
            textLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        let width = min(Self.textWidth, max(80, bounds.width))
        if textLabel.preferredMaxLayoutWidth != width { textLabel.preferredMaxLayoutWidth = width }
        super.layout()
    }

    /// Replaces what shows; `enabled` is the action's state.
    func show(_ content: Content, enabled: Bool = true) {
        image.image = content.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        image.isHidden = image.image == nil
        titleLabel.stringValue = content.title ?? ""
        titleLabel.isHidden = content.title == nil
        textLabel.stringValue = content.text
        button.title = content.action ?? ""
        button.isHidden = content.action == nil
        button.isEnabled = enabled
        button.bezelColor = content.prominent ? .controlAccentColor : nil
    }

    @objc private func actionPressed() { onAction?() }
}
