import AppKit
import HolosContent
import UniformTypeIdentifiers

/// The Reading section's root: takes dropped files and links anywhere on it (highlighted while one is over it), and
/// ⌘⇧S (Share…).
@MainActor
final class ReadingDropView: NSView {
    var accepts: ((NSPasteboard) -> Bool)?
    var onDrop: ((NSPasteboard) -> Bool)?
    var onShareKey: (() -> Bool)?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = accepts?(sender.draggingPasteboard) ?? false
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        highlighted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        return onDrop?(sender.draggingPasteboard) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10)
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s" {
            if onShareKey?() == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
