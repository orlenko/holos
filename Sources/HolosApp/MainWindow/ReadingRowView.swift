import AppKit
import HolosContent
import HolosSynthesis

/// A reading in the list: its title and source, then either its progress with Stop, or its details with Play,
/// Show Text, Share…, Show in Finder, and Delete… (and, loaded in the player, a seek bar under them), or its error with
/// Try Again.
///
/// Invariants:
/// 1. `show` sets every view from what it is given, so a reused row keeps nothing of the reading shown before.
/// 2. The seek bar shows only for a reading loaded in the player, and only then does the row keep room for it.
/// 3. An action always names the reading shown when it was pressed.
@MainActor
final class ReadingRowView: NSTableCellView {
    enum Action { case play, stop, retry, showText, share, reveal, delete, seek(Double) }

    /// The player's state for the reading it has loaded.
    struct Playback {
        var playing: Bool
        var current: Double?
        var duration: Double?
    }

    var onAction: ((UUID, Action) -> Void)?
    private var entryID: UUID?
    private let title = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let seekBar = ReadingSeekBar()
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let textButton = NSButton(title: "Show Text", target: nil, action: nil)
    private let shareButton = NSButton(title: "Share…", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private var primaryAction: Action = .play
    /// Show Text, Share…, Show in Finder and Delete… show only their symbols, in a row narrower than `compactWidth`.
    private var compact = false
    /// Keeps the title and buttons in the row's part above the seek bar.
    private var contentBottom: NSLayoutConstraint?
    /// A row's height, and how much taller one with the seek bar is.
    static let height: CGFloat = 72
    static let seekBarHeight: CGFloat = 26
    /// Narrower than this (the window beside a call's), Show Text, Share…, Show in Finder and Delete… are symbols, so
    /// the title keeps some room.
    static let compactWidth: CGFloat = 600
    private static let compactSymbols: [String: String] = ["Show Text": "doc.plaintext",
                                                           "Share…": "square.and.arrow.up",
                                                           "Show in Finder": "folder", "Delete…": "trash"]

    var shareAnchor: NSView { shareButton }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        source.font = .systemFont(ofSize: 11)
        source.textColor = .secondaryLabelColor
        source.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 140).isActive = true
        seekBar.onSeek = { [weak self] time in self?.send(.seek(time)) }
        for (button, selector) in [(primary, #selector(primaryPressed)), (textButton, #selector(textPressed)),
                                   (shareButton, #selector(sharePressed)), (revealButton, #selector(revealPressed)),
                                   (deleteButton, #selector(deletePressed))] {
            button.target = self
            button.action = selector
            button.bezelStyle = .push
            button.controlSize = .small
        }
        textButton.toolTip = "Read or copy the text this reading reads"
        shareButton.toolTip = "Send the audio file with AirDrop, Messages, Mail… (⇧⌘S)"
        revealButton.toolTip = "Show the audio file in Finder"
        deleteButton.toolTip = "Delete this reading and its audio file (⌫)"
        textField = title

        let statusRow = NSStackView(views: [progress, status])
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        let text = NSStackView(views: [title, source, statusRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let buttons = NSStackView(views: [primary, textButton, shareButton, revealButton, deleteButton])
        buttons.spacing = 6
        buttons.alignment = .centerY
        buttons.setHuggingPriority(.required, for: .horizontal)
        for view in [text, buttons, seekBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let content = NSLayoutGuide()
        addLayoutGuide(content)
        let contentBottom = content.bottomAnchor.constraint(equalTo: bottomAnchor)
        self.contentBottom = contentBottom
        for label in [title, source, status] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.topAnchor.constraint(equalTo: topAnchor),
            contentBottom,
            text.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            seekBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            seekBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            seekBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        setCompact(bounds.width < Self.compactWidth)
    }

    private func setCompact(_ compact: Bool) {
        guard compact != self.compact else { return }
        self.compact = compact
        for button in [textButton, shareButton, revealButton, deleteButton] {
            let name = fullTitle(button)
            button.title = compact ? "" : name
            button.image = compact
                ? Self.compactSymbols[name].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: name) }
                : nil
            button.imagePosition = compact ? .imageOnly : .noImage
        }
    }

    /// A button's title, also while it shows only its symbol.
    private func fullTitle(_ button: NSButton) -> String {
        if button === textButton { return "Show Text" }
        if button === shareButton { return "Share…" }
        if button === revealButton { return "Show in Finder" }
        if button === deleteButton { return "Delete…" }
        return button.title
    }

    func show(_ entry: ReadingEntry, activity: ReadingController.Activity?, fileProblem: ReadingController.FileProblem?,
              size: Int64?, playback: Playback?) {
        entryID = entry.id
        title.stringValue = entry.title
        source.stringValue = entry.source.label
        status.textColor = .secondaryLabelColor
        progress.isHidden = true
        var showsSeekBar = false
        var buttons: [NSButton] = []
        switch entry.state {
        case .queued:
            status.stringValue = "Waiting — starts when the reading before it is made"
            setPrimary("Stop", .stop, help: "Take this reading out of the queue; Resume adds it back")
            buttons = [primary]
        case .rendering:
            switch activity {
            case .rendering(let part, let total)?:
                status.stringValue = "Rendering part \(part) of \(total)"
                progress.isHidden = false
                progress.doubleValue = Double(part - 1) / Double(max(1, total))
            case .joining(let parts)?:
                status.stringValue = "Joining \(parts) \(parts == 1 ? "part" : "parts") into one file…"
                progress.isHidden = false
                progress.doubleValue = 1
            case .loading?, nil:
                switch entry.source {
                case .web: status.stringValue = "Loading the page…"
                case .file: status.stringValue = "Reading the file…"
                case .selection: status.stringValue = "Preparing…"
                }
            }
            setPrimary("Stop", .stop, help: "Stop making this reading; Resume continues where it stopped")
            buttons = [primary]
        case .done where fileProblem == .checking:
            status.stringValue = "Checking its file…"
            buttons = [deleteButton]
        case .done where fileProblem == .missing:
            status.stringValue = "The file made for it is no longer at "
                + "\(entry.output.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "its place")."
            status.textColor = .systemOrange
            buttons = [deleteButton]
        case .done where fileProblem != nil:
            // Delete refuses until the file can be looked for, so it stays offered for when the drive is back.
            if case .unavailable(let reason)? = fileProblem {
                status.stringValue = "Unavailable — \(reason)."
            }
            status.textColor = .systemOrange
            buttons = [deleteButton]
        case .done:
            var details: [String] = []
            if let duration = entry.duration { details.append(ReadingLibrary.durationText(duration)) }
            if let chapters = entry.chapters, chapters > 0 { details.append("\(chapters) \(chapters == 1 ? "chapter" : "chapters")") }
            if let size { details.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
            if let voice = entry.voiceName { details.append(voice) }
            if abs(entry.speed - ReadingSpeed.standard) > 0.001 { details.append(ReadingSpeed.label(entry.speed)) }
            status.stringValue = details.joined(separator: " · ")
            if let message = entry.message {
                status.stringValue += " — \(message)"
            }
            let playing = playback?.playing ?? false
            setPrimary(playing ? "❚❚ Pause" : "▶ Play", .play, help: "Play or pause here (Space)")
            if let current = playback?.current, let duration = playback?.duration {
                showsSeekBar = true
                seekBar.show(current: current, duration: duration)
            }
            buttons = [primary, textButton, shareButton, revealButton, deleteButton]
        case .failed:
            status.stringValue = entry.message ?? "The reading failed."
            status.textColor = .systemOrange
            setPrimary("Try Again", .retry, help: "Make it again; parts already rendered are kept")
            buttons = [primary, deleteButton]
        case .stopped:
            var text = "Stopped"
            if let part = entry.part, let parts = entry.parts { text += " at part \(part) of \(parts)" }
            status.stringValue = text + (entry.message.map { ". \($0)" } ?? ".")
            setPrimary("Resume", .retry, help: "Continue where it stopped")
            buttons = [primary, deleteButton]
        }
        for button in [primary, textButton, shareButton, revealButton, deleteButton] {
            button.isHidden = !buttons.contains(button)
        }
        seekBar.isHidden = !showsSeekBar
        seekBar.setSubject(entry.title)
        contentBottom?.constant = showsSeekBar ? -Self.seekBarHeight : 0
        status.toolTip = status.stringValue
        let label = [entry.title, entry.source.label, status.stringValue].joined(separator: ", ")
        setAccessibilityLabel(label)
        for button in buttons { button.setAccessibilityLabel("\(fullTitle(button)) — \(entry.title)") }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { seekBar.setEmphasized(backgroundStyle == .emphasized) }
    }

    private func setPrimary(_ title: String, _ action: Action, help: String) {
        primary.title = title
        primaryAction = action
        primary.toolTip = help
    }

    @objc private func primaryPressed() { send(primaryAction) }
    @objc private func textPressed() { send(.showText) }
    @objc private func sharePressed() { send(.share) }
    @objc private func revealPressed() { send(.reveal) }
    @objc private func deletePressed() { send(.delete) }

    private func send(_ action: Action) {
        guard let entryID else { return }
        onAction?(entryID, action)
    }
}
