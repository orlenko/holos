import AppKit

/// Hosts a review in its own window or inside the main meeting screen.
///
/// Invariants:
/// 1. The review content belongs to one presentation at a time.
/// 2. Closing an embedded review requests navigation; it never closes the main window.
/// 3. Keyboard handling applies only while the embedded content is visible in its host window.
@MainActor
final class ReviewSurface {
    let ownedWindow: ReviewKeyWindow
    private weak var host: NSWindow?
    private weak var content: NSView?
    private var onEmbeddedClose: (() -> Void)?
    private var keyMonitor: Any?
    var onCloseRefused: (() -> Void)?

    init(_ window: ReviewKeyWindow) { ownedWindow = window }

    var window: NSWindow { host ?? ownedWindow }
    var isEmbedded: Bool { host != nil }

    func embed(in host: NSWindow, onClose: @escaping () -> Void) -> NSView? {
        guard !isEmbedded, let content = ownedWindow.contentView else { return nil }
        ownedWindow.contentView = nil
        self.host = host
        self.content = content
        onEmbeddedClose = onClose
        // Invariants 1 and 3: the original handlers use the review's current host and first responder.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.host, let content = self.content,
                  content.window === self.host, !content.isHiddenOrHasHiddenAncestor else { return event }
            if self.ownedWindow.refuses(event, responder: self.host?.firstResponder)
                || self.ownedWindow.keyHandler?(event) == true { return nil }
            if event.keyCode == 53, let field = self.host?.firstResponder as? NSTextView, field.isEditable {
                field.keyDown(with: event)
                return nil
            }
            if self.ownedWindow.playbackKeyHandler?(event) == true { return nil }
            return event
        }
        return content
    }

    func close() {
        if isEmbedded {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            let onClose = onEmbeddedClose
            onEmbeddedClose = nil
            onClose?() // invariant 2
        } else {
            ownedWindow.close()
        }
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
