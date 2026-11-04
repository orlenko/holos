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
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    /// What to do next, beside the title; it gives way to the title when both do not fit.
    private let hintLabel = NSTextField(labelWithString: "")
    /// Marks content that needs the user, so a failure never looks like listening.
    private let attentionIcon = NSImageView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let material = NSVisualEffectView()
    private let stack = NSStackView()
    private static let panelWidth: CGFloat = 520
    private static let margin: CGFloat = 18
    private static let verticalMargin: CGFloat = 14
    private static let previewWidth: CGFloat = panelWidth - margin * 2
    private static let previewLines: CGFloat = 4
    private static let titleLines = 3

    init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 80),
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

        material.frame = panel.contentView!.bounds
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = Self.titleLines
        titleLabel.lineBreakMode = .byWordWrapping
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)
        attentionIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                      accessibilityDescription: "Needs attention")
        attentionIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        attentionIcon.contentTintColor = .systemOrange
        attentionIcon.setContentHuggingPriority(.required, for: .horizontal)
        attentionIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        previewLabel.font = .systemFont(ofSize: 15)
        previewLabel.maximumNumberOfLines = Int(Self.previewLines)
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.preferredMaxLayoutWidth = Self.previewWidth
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [attentionIcon, titleLabel, spacer, hintLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        stack.setViews([header, previewLabel], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
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
            header.trailingAnchor.constraint(equalTo: material.trailingAnchor,
                                             constant: -(Self.margin + Self.closeSize + 4)),
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: Self.margin),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -Self.margin),
            stack.topAnchor.constraint(equalTo: material.topAnchor, constant: Self.verticalMargin),
            previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = material
    }

    /// Shows or updates the preview. After the close button was clicked, updates stay hidden until
    /// `allowShowing()`; `force` is for messages the user must see (such as the rebuilt-app warning). `hint`: what to
    /// do next, beside the title. `attention`: content that needs the user, marked with a warning sign.
    func show(title: String, hint: String? = nil, text: String, force: Bool = false, attention: Bool = false) {
        if dismissed && !force { return }
        if force { dismissed = false }
        contentToken &+= 1
        showingAttention = attention
        let height = fill(title: title, hint: hint, text: text, attention: attention)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        // The bottom edge stays put, so the words being spoken do not move as the panel grows.
        let origin = (screen?.visibleFrame)
            .map { NSPoint(x: $0.midX - Self.panelWidth / 2, y: $0.minY + 70) } ?? panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: height)), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        let frame = panel.frame
        closePanel.setFrameOrigin(NSPoint(x: frame.maxX - 10 - Self.closeSize, y: frame.maxY - 10 - Self.closeSize))
        if closePanel.parent == nil { panel.addChildWindow(closePanel, ordered: .above) }
        closePanel.orderFrontRegardless()
    }

    /// Puts the content in place and returns the panel's height for it: the title and the words, at least one line of
    /// them. Nothing goes on screen.
    func fill(title: String, hint: String?, text: String, attention: Bool) -> CGFloat {
        titleLabel.stringValue = title
        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = hint == nil
        attentionIcon.isHidden = !attention
        previewLabel.stringValue = Self.latestWords(of: text, font: previewLabel.font ?? .systemFont(ofSize: 15))
        let reserved = Self.closeSize + 4 + (attentionIcon.isHidden ? 0 : 22)
            + (hintLabel.isHidden ? 0 : min(hintLabel.intrinsicContentSize.width, Self.previewWidth / 2) + 8)
        titleLabel.preferredMaxLayoutWidth = Self.previewWidth - reserved
        material.layoutSubtreeIfNeeded()
        let oneLine = NSTextField(labelWithString: "X")
        oneLine.font = previewLabel.font
        let words = max(oneLine.intrinsicContentSize.height, previewLabel.intrinsicContentSize.height)
        let title = titleLabel.intrinsicContentSize.height
        return ceil(title + stack.spacing + words + Self.verticalMargin * 2)
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
    /// What the panel shows (tests).
    var isMarkedForAttention: Bool { !attentionIcon.isHidden }
    var shownHint: String? { hintLabel.isHidden ? nil : hintLabel.stringValue }
    /// Changes every time the panel shows new content, so a timer can tell whether its content is still up.
    private(set) var contentToken = 0
    /// Whether the content on screen needs the user (a failure, text that could not be written, a warning).
    private(set) var showingAttention = false

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
        showingAttention = false
        if closePanel.parent != nil { panel.removeChildWindow(closePanel) }
        closePanel.orderOut(nil)
        panel.orderOut(nil)
        titleLabel.stringValue = ""
        hintLabel.stringValue = ""
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
