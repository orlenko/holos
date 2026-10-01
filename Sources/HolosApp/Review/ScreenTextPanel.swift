import AppKit
import HolosStorage

/// Read-only text/candidates and explicit resumable OCR batches. No word-list/clipboard writes or playback.
@MainActor final class ScreenTextPanel: NSObject, NSWindowDelegate {
    let window: NSPanel
    private var record: ScreenContextRecord
    private let known: [String]?
    private let onSeek: (Double) -> Void
    private let onRecognize: (ScreenTextPanel) -> Void
    private let frames = NSPopUpButton()
    private let text = NSTextView()
    private let recognize = NSButton(title: "Recognize Next Batch", target: nil, action: nil)
    private let progress = NSTextField(wrappingLabelWithString: "")

    init(record: ScreenContextRecord, known: [String]?, onSeek: @escaping (Double) -> Void,
         onRecognize: @escaping (ScreenTextPanel) -> Void) {
        self.record = record; self.known = known; self.onSeek = onSeek; self.onRecognize = onRecognize
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.title = "Screen Text — On-Device OCR"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 560)
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
        recognize.target = self; recognize.action = #selector(recognizeBatch)
        recognize.bezelStyle = .push
        progress.font = .systemFont(ofSize: 11); progress.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 13); text.textColor = .labelColor
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        let stack = NSStackView(views: [frames, note, scroll, recognize, progress, close])
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
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        window.contentView = content
        showFrame(seek: false)
        updateProgress()
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
        let candidates = known.map { ScreenContextRecord(sessionID: record.sessionID, frames: [frame])
            .candidates(excluding: $0, from: frame.start, to: frame.end) }
        text.string = "Recognized lines\n\n" + (frame.lines?.map(\.text).joined(separator: "\n") ?? "OCR is not available for this frame.")
            + "\n\nCandidates not in the word list (unverified)\n\n"
            + (candidates?.joined(separator: ", ") ?? "Candidates unavailable: the word list could not be read. Saved OCR is unaffected.")
        if seek { onSeek(frame.start) }
    }
    func setProcessing() { recognize.isEnabled = false; progress.stringValue = "Recognizing a bounded batch on this Mac…" }
    func failed(_ message: String) { updateProgress(); progress.stringValue = message }
    func update(_ record: ScreenContextRecord, problem: String? = nil) {
        self.record = record
        showFrame(seek: false)
        updateProgress()
        if let problem { progress.stringValue = problem }
    }
    private func updateProgress() {
        let completed = record.frames.filter { $0.lines != nil }.count
        progress.stringValue = "\(completed) of \(record.frames.count) snapshots recognized; unfinished frames stay available for another batch."
        recognize.isEnabled = completed < record.frames.count
    }
    @objc private func recognizeBatch() { onRecognize(self) }
    @objc private func closePanel() {
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closePanel(); return false }
}
