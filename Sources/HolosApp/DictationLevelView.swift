import AppKit
import HolosCore

/// How loud a stretch of microphone audio is, from 0 (silence) to 1 (loud speech), for the dictation preview.
enum DictationLevel {
    /// Below this, a room's noise; at the top, speech close to the microphone.
    private static let quietDecibels: Float = -55
    private static let loudDecibels: Float = -15

    static func level(of samples: [Float]) -> CGFloat {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        guard power.isFinite, power > 0 else { return 0 }
        let decibels = 10 * log10(power)
        return CGFloat(min(1, max(0, (decibels - quietDecibels) / (loudDecibels - quietDecibels))))
    }
}

/// The last few levels the microphone gave, newest on the right: proof the preview is hearing you before any words
/// appear. The audio itself is not kept here. Drawn with a semantic colour, so it follows light and dark.
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
