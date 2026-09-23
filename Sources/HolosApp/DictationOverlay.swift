import AppKit

/// A non-activating, mouse-transparent preview. It must not steal the insertion target.
@MainActor
final class DictationOverlay {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let material = NSVisualEffectView(frame: panel.contentView!.bounds)
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = .systemFont(ofSize: 15)
        previewLabel.maximumNumberOfLines = 4
        previewLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleLabel, previewLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: material.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: material.bottomAnchor, constant: -16),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = material
    }

    func show(title: String, text: String) {
        titleLabel.stringValue = title
        previewLabel.stringValue = String(text.suffix(500))
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 70))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        titleLabel.stringValue = ""
        previewLabel.stringValue = ""
    }
}
