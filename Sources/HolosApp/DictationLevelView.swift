import AppKit

/// The last few levels the microphone gave, newest on the right: proof the preview is hearing you before any words
/// appear. The audio itself is not kept here. Drawn with a semantic colour, so it follows light and dark.
///
/// Invariants:
/// 1. `levels` always holds `bars` values, oldest first, each from 0 to 1 (`DictationLevel`).
/// 2. Every change to `levels` asks for a redraw.
final class DictationLevelView: NSView {
    private static let bars = 5
    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 2
    private static let height: CGFloat = 12
    /// A silent bar stays visible, so the sign does not vanish between words.
    private static let lowest: CGFloat = 3

    private(set) var levels = [CGFloat](repeating: 0, count: bars)

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(Self.bars) * Self.barWidth + CGFloat(Self.bars - 1) * Self.gap, height: Self.height)
    }

    /// The bars stand on the text's baseline.
    override var firstBaselineOffsetFromTop: CGFloat { Self.height }
    override var lastBaselineOffsetFromBottom: CGFloat { 0 }

    /// Adds the newest level; the oldest drops off.
    func add(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(level)
        needsDisplay = true
    }

    func reset() {
        levels = [CGFloat](repeating: 0, count: Self.bars)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        for (index, level) in levels.enumerated() {
            let height = Self.lowest + (bounds.height - Self.lowest) * level
            let bar = NSRect(x: CGFloat(index) * (Self.barWidth + Self.gap), y: 0, width: Self.barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
        }
    }
}
