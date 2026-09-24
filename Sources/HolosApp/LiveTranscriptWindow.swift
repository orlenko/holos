import AppKit
import HolosCore
import HolosMeeting
import HolosStorage

/// The phrases transcribed so far (docs/meeting-design.md §5.8 "Live transcript window"): the last 500
/// `transcriptFinalized` events of `events.jsonl` as `[01:02:03] Mic: …`, read-only, refreshed every second, and
/// kept scrolled to the end unless the user scrolled up.
@MainActor
final class LiveTranscriptWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let textView: NSTextView
    private let scroll: NSScrollView
    private let onClose: () -> Void
    private var tail: TranscriptTail?
    private var refreshTask: Task<Void, Never>?
    private var reading = false
    private var positioned = false

    var isVisible: Bool { window.isVisible }

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()
        window.title = "Live Transcript"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 360, height: 200)
        window.delegate = self
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        window.contentView = scroll
    }

    /// Shows the transcript of `session`, reading from the start when it is a different session.
    func show(session: URL, name: String?) {
        follow(session: session, name: name)
        if !positioned {
            window.center()
            positioned = true
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.window.isVisible else { return }
                self.refresh()
            }
        }
    }

    /// Switches to `session` when the menu bar follows another meeting.
    func follow(session: URL, name: String?) {
        window.title = name.map { "Live Transcript — \($0)" } ?? "Live Transcript"
        guard tail?.session != session else { return }
        tail = TranscriptTail(session: session)
        textView.string = ""
    }

    /// Reads what was appended since the last read, off the main actor.
    private func refresh() {
        guard !reading, let current = tail else { return }
        reading = true
        Task { [weak self] in
            let updated = await Task.detached { () -> TranscriptTail in
                var next = current
                next.read()
                return next
            }.value
            guard let self else { return }
            self.reading = false
            // The window may have switched sessions meanwhile.
            guard self.tail?.session == updated.session else { return }
            let changed = updated.revision != self.tail?.revision
            self.tail = updated
            if changed { self.render(updated.lines) }
        }
    }

    private func render(_ lines: [String]) {
        let clip = scroll.contentView
        let atEnd = clip.bounds.maxY >= textView.frame.height - 24
        textView.string = lines.joined(separator: "\n")
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
        onClose()
    }
}

/// The finalized phrases of one session's `events.jsonl`, read incrementally: each read continues where the last
/// one stopped, keeps a partial last line for the next read, and starts over if the journal got shorter (a repaired
/// torn tail).
struct TranscriptTail: Sendable {
    static let maxLines = 500
    /// At most this much is read at once, so a long meeting's first read stays bounded.
    static let maxRead = 32 << 20

    let session: URL
    private(set) var lines: [String] = []
    /// Changes whenever `lines` does.
    private(set) var revision = 0
    private var offset: UInt64 = 0
    private var partial = Data()

    init(session: URL) {
        self.session = session
    }

    mutating func read() {
        guard let handle = try? AtomicFile.openForReading(SessionPaths.events(session)) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset {
            offset = 0
            partial = Data()
            lines = []
            revision += 1
        }
        guard size > offset else { return }
        // A first read of a long journal skips to its last part; the first line there may be cut.
        var start = offset
        var skipFirst = false
        if size - offset > UInt64(Self.maxRead) {
            start = size - UInt64(Self.maxRead)
            partial = Data()
            skipFirst = true
        }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return }
        offset = start + UInt64(data.count)
        var buffer = partial + data
        partial = Data()
        if let last = buffer.lastIndex(of: 0x0A) {
            partial = buffer.suffix(from: buffer.index(after: last))
            buffer = buffer.prefix(through: last)
        } else {
            partial = buffer
            return
        }
        let decoder = HolosJSON.decoder()
        let marker = Data(MeetingEventKind.transcriptFinalized.utf8)
        var added = false
        for (index, line) in buffer.split(separator: 0x0A).enumerated() {
            if skipFirst && index == 0 { continue }
            guard line.range(of: marker) != nil,
                  let event = try? decoder.decode(ArchiveEvent.self, from: Data(line)),
                  event.kind == MeetingEventKind.transcriptFinalized,
                  let text = event.details["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            let start = event.details["start"].flatMap(Double.init) ?? 0
            let track = event.details["track"] == "system" ? "System" : "Mic"
            lines.append("[\(Self.clock(start))] \(track): \(text)")
            added = true
        }
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        if added { revision += 1 }
    }

    /// 01:02:03.
    static func clock(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, min(seconds, 1e9))) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
