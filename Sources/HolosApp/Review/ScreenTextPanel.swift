import AppKit
import HolosStorage

/// Read-only OCR and vocabulary suggestions. No implicit word-list/clipboard writes or playback.
@MainActor final class ScreenTextPanel: NSObject, NSWindowDelegate {
    let window: NSPanel
    private let record: ScreenContextRecord
    private let known: [String]
    private let onSeek: (Double) -> Void
    private let frames = NSPopUpButton()
    private let text = NSTextView()

    init(record: ScreenContextRecord, known: [String], onSeek: @escaping (Double) -> Void) {
        self.record = record; self.known = known; self.onSeek = onSeek
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.title = "Screen Text — On-Device OCR"
        window.isReleasedWhenClosed = false
        window.delegate = self
        frames.target = self; frames.action = #selector(chosen)
        frames.setAccessibilityLabel("Saved screen snapshot time")
        for frame in record.frames {
            frames.addItem(withTitle: "\(Self.time(frame.start))–\(Self.time(frame.end))")
        }
        let note = NSTextField(wrappingLabelWithString: "OCR is supporting evidence, not what was spoken. "
            + "Candidates below are not added automatically; review them in Corrections › Word List. "
            + "Choosing a snapshot seeks without starting playback.")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
        let close = NSButton(title: "Close", target: self, action: #selector(closePanel))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 13); text.textColor = .labelColor
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        let stack = NSStackView(views: [frames, note, scroll, close])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        window.contentView = content
        showFrame(seek: false)
    }

    private static func time(_ seconds: Double) -> String {
        let seconds = Int(max(0, seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    @objc private func chosen() { showFrame(seek: true) }
    private func showFrame(seek: Bool) {
        let index = frames.indexOfSelectedItem
        guard record.frames.indices.contains(index) else { text.string = "No screen snapshots were saved."; return }
        let frame = record.frames[index]
        let candidates = ScreenContextRecord(sessionID: record.sessionID, frames: [frame])
            .candidates(excluding: known, from: frame.start, to: frame.end)
        text.string = "Recognized lines\n\n" + (frame.lines?.map(\.text).joined(separator: "\n") ?? "OCR is not available for this frame.")
            + "\n\nCandidates not in the word list (unverified)\n\n" + candidates.joined(separator: ", ")
        if seek { onSeek(frame.start) }
    }
    @objc private func closePanel() {
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closePanel(); return false }
}
