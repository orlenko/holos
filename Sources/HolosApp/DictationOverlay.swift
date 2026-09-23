import AppKit

/// A non-activating, mouse-transparent preview. It must not steal the insertion target.
@MainActor
final class DictationOverlay {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private static let previewWidth: CGFloat = 520 - 36
    private static let previewLines: CGFloat = 4

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
        previewLabel.maximumNumberOfLines = Int(Self.previewLines)
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.preferredMaxLayoutWidth = Self.previewWidth
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
        previewLabel.stringValue = Self.latestWords(of: text, font: previewLabel.font ?? .systemFont(ofSize: 15))
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 70))
        }
        panel.orderFrontRegardless()
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

    func hide() {
        panel.orderOut(nil)
        titleLabel.stringValue = ""
        previewLabel.stringValue = ""
    }
}
