import AppKit
import HolosMeeting
import HolosSpeakers

/// Where to split a row: its words in a read-only text; a click puts the caret where the second part starts. "Play
/// from Here" plays from that word. At a word that starts a turn of the row, nothing is split: the row only breaks
/// there.
@MainActor
final class SplitSheet: NSObject, NSTextViewDelegate {
    let panel: NSPanel
    private let words: [ReviewWord]
    /// Indices of words that start a turn (other than the first).
    private let turnStarts: Set<Int>
    /// Each word's range in the shown text.
    private var ranges: [NSRange] = []
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView {
        // `scrollableTextView()` always holds a text view.
        scroll.documentView as? NSTextView ?? NSTextView()
    }
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let splitButton = NSButton(title: "Split", target: nil, action: nil)
    private let playButton = NSButton(title: "Play from Here", target: nil, action: nil)
    private let onPlay: (Double) -> Void

    /// The first word of the second part (an index into `words`), when the caret is after the first word.
    private(set) var splitIndex: Int?

    init(words: [ReviewWord], turnStarts: Set<Int> = [], onPlay: @escaping (Double) -> Void) {
        self.words = words
        self.turnStarts = turnStarts
        self.onPlay = onPlay
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled],
                        backing: .buffered, defer: true)
        super.init()
        var text = ""
        for word in words {
            if !text.isEmpty { text += " " }
            let location = (text as NSString).length
            text += word.text
            ranges.append(NSRange(location: location, length: (word.text as NSString).length))
        }
        let title = NSTextField(labelWithString: "Click in the text where the second part starts.")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let textView = self.textView
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        splitButton.keyEquivalent = "\r"
        splitButton.target = self
        splitButton.action = #selector(split)
        playButton.target = self
        playButton.action = #selector(play)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [playButton, NSView(), cancel, splitButton])
        let stack = NSStackView(views: [title, scroll, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        panel.contentView = content
        panel.initialFirstResponder = textView
        update()
    }

    func textViewDidChangeSelection(_ notification: Notification) { update() }

    /// The word containing the caret (or the next one after it) starts the second part; never the first word.
    private func update() {
        let caret = textView.selectedRange().location
        let index = ranges.firstIndex { $0.location + $0.length > caret }
        if let index, index > 0 {
            splitIndex = index
            hint.stringValue = "The second part starts at “\(words[index].text)” (\(TimeFormat.clock(words[index].start)))."
                + (turnStarts.contains(index) ? " A turn already starts there, so the text only breaks there." : "")
        } else {
            splitIndex = nil
            hint.stringValue = "Click after the first word, where the second part starts."
        }
        splitButton.isEnabled = splitIndex != nil
        playButton.isEnabled = true
    }

    @objc private func split() {
        guard splitIndex != nil else { return }
        panel.sheetParent?.endSheet(panel, returnCode: .OK)
    }

    @objc private func cancel() {
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }

    @objc private func play() {
        let caret = textView.selectedRange().location
        let index = ranges.firstIndex { $0.location + $0.length > caret } ?? 0
        onPlay(words[index].start)
    }
}
