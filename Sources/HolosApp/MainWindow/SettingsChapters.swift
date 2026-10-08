import AppKit

/// The chapters of Settings, one per card in page order; the sidebar lists them under Settings (docs/design.md
/// "Main window").
enum SettingsChapter: Int, CaseIterable {
    case general, permissions, dictation, meetings, reading, history

    var title: String {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .dictation: "Dictation"
        case .meetings: "Meetings"
        case .reading: "Reading"
        case .history: "Dictation history"
        }
    }
}

/// Settings' search outlines the best match (what Return goes to) with a tinted rounded box over it while the search
/// lasts, and the setting Return went to with one that fades out. It never takes clicks, so the setting under it
/// stays usable.
@MainActor
final class SettingsHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1.5
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Covers `frame` (a setting's frame in the superview), with a margin around it.
    func place(over frame: NSRect) {
        let covered = frame.insetBy(dx: -8, dy: -6)
        if self.frame != covered { self.frame = covered }
    }

    /// Shows a box over `frame` in `container` that fades out after a moment (Reduce Motion removes it without a
    /// fade).
    static func flash(_ frame: NSRect, in container: NSView, replacing previous: NSView?) -> SettingsHighlightView {
        previous?.removeFromSuperview()
        let view = SettingsHighlightView(frame: .zero)
        view.place(over: frame)
        container.addSubview(view)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let view else { return }
            guard !reduceMotion else {
                view.removeFromSuperview()
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.6
                view.animator().alphaValue = 0
            }, completionHandler: { [weak view] in
                MainActor.assumeIsolated { view?.removeFromSuperview() }
            })
        }
        return view
    }
}
