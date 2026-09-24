import AppKit

/// A non-activating preview. It must not steal the insertion target, and clicks on it pass through to
/// whatever is underneath. The close button lives in a separate tiny child panel over the top-right
/// corner, because a window cannot be click-through in only part of its area. Neither panel ever
/// becomes key or main, and clicking does not activate Holos.
@MainActor
final class DictationOverlay {
    private let panel: NSPanel
    private let closeButton = FirstMouseButton()
    private let closePanel: NSPanel
    private static let closeSize: CGFloat = 22
    /// Set by the close button; `show` stays quiet until the next dictation calls `allowShowing()`.
    private var dismissed = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private static let previewWidth: CGFloat = 520 - 36
    private static let previewLines: CGFloat = 4

    init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        closePanel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.closeSize, height: Self.closeSize),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        closePanel.level = .floating
        closePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        closePanel.isOpaque = false
        closePanel.backgroundColor = .clear
        closePanel.hasShadow = false
        closePanel.hidesOnDeactivate = false
        closePanel.isReleasedWhenClosed = false
        closePanel.becomesKeyOnlyIfNeeded = true
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
        previewLabel.maximumNumberOfLines = Int(Self.previewLines)
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.preferredMaxLayoutWidth = Self.previewWidth
        let stack = NSStackView(views: [titleLabel, previewLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        closeButton.toolTip = "Dismiss (dictation keeps going)"
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.frame = NSRect(x: 0, y: 0, width: Self.closeSize, height: Self.closeSize)
        closePanel.contentView = closeButton
        NSLayoutConstraint.activate([
            // Leave room for the close panel that sits over the top-right corner.
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: material.trailingAnchor,
                                                 constant: -(18 + Self.closeSize + 8)),
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: material.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: material.bottomAnchor, constant: -16),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = material
    }

    /// Shows or updates the preview. After the close button was clicked, updates stay hidden until
    /// `allowShowing()`; `force` is for messages the user must see (such as the rebuilt-app warning).
    func show(title: String, text: String, force: Bool = false) {
        if dismissed && !force { return }
        if force { dismissed = false }
        contentToken &+= 1
        titleLabel.stringValue = title
        previewLabel.stringValue = Self.latestWords(of: text, font: previewLabel.font ?? .systemFont(ofSize: 15))
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 70))
        }
        panel.orderFrontRegardless()
        let frame = panel.frame
        closePanel.setFrameOrigin(NSPoint(x: frame.maxX - 10 - Self.closeSize, y: frame.maxY - 10 - Self.closeSize))
        if closePanel.parent == nil { panel.addChildWindow(closePanel, ordered: .above) }
        closePanel.orderFrontRegardless()
    }

    /// The end of `text` that fits the preview, so the words just spoken stay visible; older words
    /// are dropped from the front at a word boundary and marked with an ellipsis.
    static func latestWords(of text: String, font: NSFont) -> String {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let limit = lineHeight * previewLines + 1
        func fits(_ candidate: String) -> Bool {
            (candidate as NSString).boundingRect(
                with: NSSize(width: previewWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height <= limit
        }
        guard !fits(text) else { return text }
        // Earliest start whose suffix fits; later starts give shorter suffixes, so fitting is monotonic.
        func earliestFitting(_ starts: [String.Index]) -> String.Index? {
            var low = 0, high = starts.count - 1
            var best: String.Index?
            while low <= high {
                let middle = (low + high) / 2
                if fits("…" + text[starts[middle]...]) { best = starts[middle]; high = middle - 1 } else { low = middle + 1 }
            }
            return best
        }
        let wordStarts = text.indices.filter { $0 > text.startIndex && text[text.index(before: $0)] == " " }
        // A single token longer than the preview (a long URL) has no fitting word start; cut mid-token.
        guard let start = earliestFitting(wordStarts) ?? earliestFitting(Array(text.indices.dropFirst())) else {
            return "…"
        }
        return "…" + text[start...]
    }

    var isVisible: Bool { panel.isVisible }
    /// Changes every time the panel shows new content, so a timer can tell whether its content is still up.
    private(set) var contentToken = 0

    /// Opacity of the preview (not of its close button, which stays fully visible).
    func setOpacity(_ value: Double) {
        panel.alphaValue = CGFloat(min(1, max(0.3, value)))
    }

    /// Called when a new dictation starts, so its preview appears again.
    func allowShowing() { dismissed = false }

    @objc private func dismiss() {
        dismissed = true
        hide()
    }

    func hide() {
        if closePanel.parent != nil { panel.removeChildWindow(closePanel) }
        closePanel.orderOut(nil)
        panel.orderOut(nil)
        titleLabel.stringValue = ""
        previewLabel.stringValue = ""
    }
}

/// Never key or main, so clicking the close button leaves keyboard focus in the field being dictated into.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Reacts to the first click even though its window is never key.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
