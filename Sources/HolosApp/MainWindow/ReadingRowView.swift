import AppKit
import HolosContent
import HolosSynthesis

/// A reading in the list: its title, then one detail line (where it came from and its length, voice and speed; its
/// progress while it is made; or what went wrong), and a fixed column of actions on the right: the main one (Play, Try
/// Again, Resume), Show Text, Share… (Stop or Resume while it is converted), and ··· with what is seldom needed (Show in
/// Finder, Chapter Files…, Delete…), which a right-click on the row offers too. A reading loaded in the player has a
/// seek bar under them.
///
/// Invariants:
/// 1. `show` sets every view from what it is given, so a reused row keeps nothing of the reading shown before.
/// 2. The seek bar shows only for a reading loaded in the player, and only then does the row keep room for it.
///    Playback's controls (Play or Pause, the bar) then stand together on that line, apart from those of the conversion
///    (Stop, Resume in the third column) above: they act on different things.
/// 3. An action always names the reading shown when it was pressed.
/// 4. In a row at least `compactWidth` wide, each column has the same width in every row, so the actions line up down
///    the list whichever of them a row offers.
@MainActor
final class ReadingRowView: NSTableCellView {
    enum Action: Equatable { case play, stop, retry, showText, share, reveal, chapterFiles, delete, seek(Double) }

    /// The player's state for the reading it has loaded.
    struct Playback {
        var playing: Bool
        /// Engaged, waiting for a part that is not made yet.
        var waiting = false
        var current: Double?
        var duration: Double?
        /// False while the reading is made: the duration is what is made so far.
        var final = true
    }

    var onAction: ((UUID, Action) -> Void)?
    private var entryID: UUID?
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let seekBar = ReadingSeekBar()
    /// The first column: Play, Try Again, Resume, or Stop for a reading still waiting its turn.
    private let primary = NSButton(title: "", target: nil, action: nil)
    private var primaryAction: Action = .play
    private let textButton = NSButton(title: "Show Text", target: nil, action: nil)
    /// The third column: Share… for a made reading; Stop or Resume for its conversion.
    private let third = NSButton(title: "", target: nil, action: nil)
    private var thirdAction: Action?
    private let moreButton = NSButton(title: "", target: nil, action: nil)
    /// Play or Pause on the seek bar's line, for the reading loaded.
    private let transport = NSButton(title: "", target: nil, action: nil)
    private let buttonRow = NSStackView()
    /// What ··· and the right-click menu offer below the row's own buttons, for the reading shown.
    private var maintenance: [(String, Action)] = []
    /// The actions of the menu shown last, by item tag.
    private var menuActions: [Action] = []
    /// The columns' widths in a wide row (invariant 4).
    private var columnWidths: [NSLayoutConstraint] = []
    /// Show Text and Share… show only their symbols, in a row narrower than `compactWidth`.
    private var compact = false
    /// The reading shown is loaded in the player.
    private var showsSeekBar = false
    private var playbackLine: NSStackView?
    /// Keeps the title and buttons in the row's part above the seek bar.
    private var contentBottom: NSLayoutConstraint?
    /// A row's height, and how much taller one with the seek bar is.
    static let height: CGFloat = 56
    static let seekBarHeight: CGFloat = 30
    /// Narrower than this (the window beside a call's), Show Text and Share… are symbols, so the title keeps some room.
    static let compactWidth: CGFloat = 600
    private static let compactSymbols = ["Show Text": "doc.plaintext", "Share…": "square.and.arrow.up"]
    /// Every title a column can show, to size it for the longest.
    private static let columnTitles = [["▶ Play", "❚❚ Pause", "Try Again", "Resume", "Stop"], ["Show Text"],
                                       ["Share…", "Stop", "Resume"]]

    var shareAnchor: NSView { third }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 140).isActive = true
        seekBar.onSeek = { [weak self] time in self?.send(.seek(time)) }
        for (button, selector) in [(primary, #selector(primaryPressed)), (third, #selector(thirdPressed)),
                                   (transport, #selector(transportPressed)), (textButton, #selector(textPressed)),
                                   (moreButton, #selector(morePressed))] {
            button.target = self
            button.action = selector
            button.bezelStyle = .push
            button.controlSize = .small
        }
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        moreButton.imagePosition = .imageOnly
        transport.toolTip = "Play or pause here (Space)"
        textButton.toolTip = "Read or copy the text this reading reads"
        textField = title

        let statusRow = NSStackView(views: [progress, status])
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        let text = NSStackView(views: [title, statusRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for button in [primary, textButton, third, moreButton] { buttonRow.addArrangedSubview(button) }
        buttonRow.spacing = 6
        buttonRow.alignment = .centerY
        buttonRow.setHuggingPriority(.required, for: .horizontal)
        for (button, titles) in zip([primary, textButton, third], Self.columnTitles) {
            columnWidths.append(button.widthAnchor.constraint(equalToConstant: Self.width(of: titles)))
        }
        let playbackLine = NSStackView(views: [transport, seekBar])
        playbackLine.spacing = 8
        playbackLine.alignment = .centerY
        transport.setContentHuggingPriority(.required, for: .horizontal)
        self.playbackLine = playbackLine
        for view in [text, buttonRow, playbackLine] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let content = NSLayoutGuide()
        addLayoutGuide(content)
        let contentBottom = content.bottomAnchor.constraint(equalTo: bottomAnchor)
        self.contentBottom = contentBottom
        for label in [title, status] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.topAnchor.constraint(equalTo: topAnchor),
            contentBottom,
            text.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: buttonRow.leadingAnchor, constant: -12),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttonRow.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            playbackLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            playbackLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            playbackLine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        applyColumns()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The width a small push button needs for the longest of `titles`.
    private static func width(of titles: [String]) -> CGFloat {
        let probe = NSButton(title: "", target: nil, action: nil)
        probe.bezelStyle = .push
        probe.controlSize = .small
        return titles.map { title in
            probe.title = title
            return ceil(probe.intrinsicContentSize.width)
        }.max() ?? 0
    }

    override func layout() {
        super.layout()
        let compact = bounds.width < Self.compactWidth
        if compact != self.compact {
            self.compact = compact
            applyColumns()
        }
    }

    /// Wide: every column keeps its width, also when a row leaves it empty (invariant 4). Compact: the buttons take
    /// only what they need, and Show Text and Share… only their symbols.
    private func applyColumns() {
        buttonRow.detachesHiddenViews = compact
        for constraint in columnWidths { constraint.isActive = !compact }
        for button in [textButton, third] {
            let name = fullTitle(button)
            let symbol = compact ? Self.compactSymbols[name] : nil
            button.title = symbol == nil ? name : ""
            button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: name) }
            button.imagePosition = symbol == nil ? .noImage : .imageOnly
        }
    }

    /// A button's title, also while it shows only its symbol.
    private func fullTitle(_ button: NSButton) -> String {
        if button === textButton { return "Show Text" }
        if button === third {
            switch thirdAction {
            case .share?: return "Share…"
            case .retry?: return "Resume"
            case .stop?: return "Stop"
            default: return ""
            }
        }
        if button === moreButton { return "More" }
        return button.title
    }

    /// `playable`: a reading being made has its first part made, so Play can start it. `size`: its file's, for the
    /// detail line's tooltip.
    func show(_ entry: ReadingEntry, activity: ReadingController.Activity?, fileProblem: ReadingController.FileProblem?,
              size: Int64?, playback: Playback?, playable: Bool = false) {
        entryID = entry.id
        title.stringValue = entry.title
        status.textColor = .secondaryLabelColor
        progress.isHidden = true
        showsSeekBar = false
        thirdAction = nil
        maintenance = []
        // Whatever the conversion is doing, a reading in the player keeps its playback line (invariant 2).
        showPlayback(playback)
        let kind = entry.source.kind
        var buttons: [NSButton] = []
        switch entry.state {
        case .queued:
            status.stringValue = "Waiting — starts when the reading before it is made"
            setPrimary("Stop", .stop, help: "Take this reading out of the queue; Resume adds it back")
            buttons = [primary]
        case .rendering:
            switch activity {
            case .rendering(let part, let total)? where playback?.waiting == true:
                status.stringValue = "Waiting for part \(part) of \(total)…"
                progress.isHidden = false
                progress.doubleValue = Double(part - 1) / Double(max(1, total))
            case .rendering(let part, let total)?:
                status.stringValue = "Making · part \(part) of \(total)"
                    + (playable || playback != nil ? " · playable from the start" : "")
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
            if playable || playback != nil {
                setPlay(playback)
                setThird("Stop", .stop, help: Self.stopHelp)
                buttons = [primary, third]
            } else {
                setPrimary("Stop", .stop, help: Self.stopHelp)
                buttons = [primary]
            }
        case .done where fileProblem == .checking:
            status.stringValue = "\(kind) · Checking its file…"
            // A reading that goes on playing while its file is checked keeps its Pause.
            if playback != nil {
                setPlay(playback)
                buttons = [primary]
            }
            maintenance = [("Delete…", .delete)]
        case .done where fileProblem == .missing:
            status.stringValue = "\(kind) · The file made for it is no longer at "
                + "\(entry.output.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "its place")."
            status.textColor = .systemOrange
            maintenance = [("Delete…", .delete)]
        case .done where fileProblem != nil:
            // Delete refuses until the file can be looked for, so it stays offered for when the drive is back.
            if case .unavailable(let reason)? = fileProblem {
                status.stringValue = "\(kind) · Unavailable — \(reason)."
            }
            status.textColor = .systemOrange
            maintenance = [("Delete…", .delete)]
        case .done:
            var details = [kind]
            if let duration = entry.duration { details.append(ReadingLibrary.durationText(duration)) }
            if let chapters = entry.chapters, chapters > 0 { details.append("\(chapters) \(chapters == 1 ? "chapter" : "chapters")") }
            if let voice = entry.voiceName { details.append(voice) }
            if abs(entry.speed - ReadingSpeed.standard) > 0.001 { details.append(ReadingSpeed.label(entry.speed)) }
            status.stringValue = details.joined(separator: " · ")
            if let message = entry.message {
                status.stringValue += " — \(message)"
            }
            setPlay(playback)
            setThird("Share…", .share, help: "Send the audio file with AirDrop, Messages, Mail… (⇧⌘S)")
            buttons = [primary, textButton, third]
            maintenance = [("Show in Finder", .reveal)]
            // Only with chapters to split it by.
            if (entry.chapters ?? 0) >= 2 { maintenance.append(("Chapter Files…", .chapterFiles)) }
            maintenance.append(("Delete…", .delete))
        case .failed:
            status.stringValue = "\(kind) · " + (entry.message ?? "The reading failed.")
            status.textColor = .systemOrange
            if playback != nil {
                // What was made before it failed still plays; Try Again once it stops.
                setPlay(playback)
            } else {
                setPrimary("Try Again", .retry, help: "Make it again; parts already rendered are kept")
            }
            buttons = [primary]
            maintenance = [("Delete…", .delete)]
        case .stopped:
            var text = "\(kind) · Stopped"
            if let part = entry.part, let parts = entry.parts { text += " at part \(part) of \(parts)" }
            status.stringValue = text + (entry.message.map { ". \($0)" } ?? "")
            if playback != nil {
                // What is ready goes on playing.
                setPlay(playback)
                setThird("Resume", .retry,
                         help: "Continue converting where it stopped. This stops what is playing; press Play when part of it is ready.")
                buttons = [primary, third]
            } else {
                setPrimary("Resume", .retry, help: "Continue converting where it stopped")
                buttons = [primary]
            }
            maintenance = [("Delete…", .delete)]
        }
        // Playback's button stands on the bar's line, when there is one (invariant 2).
        if showsSeekBar, primaryAction == .play { buttons.removeAll { $0 === primary } }
        if !maintenance.isEmpty { buttons.append(moreButton) }
        for button in [primary, textButton, third, moreButton] {
            button.isHidden = !buttons.contains(button)
        }
        applyColumns()
        playbackLine?.isHidden = !showsSeekBar
        transport.setAccessibilityLabel("\(transport.title) — \(entry.title)")
        seekBar.setSubject(entry.title)
        contentBottom?.constant = showsSeekBar ? -Self.seekBarHeight : 0
        // The file's own name and size stay a hover away; the line names only its kind.
        let file = [entry.source.label] + [size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
            .compactMap { $0 }
        status.toolTip = file.joined(separator: " · ") + "\n" + status.stringValue
        moreButton.toolTip = maintenance.map(\.0).joined(separator: ", ")
        let label = [entry.title, entry.source.label, status.stringValue].joined(separator: ", ")
        setAccessibilityLabel(label)
        for button in buttons { button.setAccessibilityLabel("\(fullTitle(button)) — \(entry.title)") }
        moreButton.setAccessibilityLabel("More actions — \(entry.title)")
    }

    /// ▶ Play or ❚❚ Pause, on the row's buttons until the reading is loaded.
    private func setPlay(_ playback: Playback?) {
        setPrimary(Self.playTitle(playback), .play, help: "Play or pause here (Space)")
    }

    private static func playTitle(_ playback: Playback?) -> String {
        playback?.playing == true ? "❚❚ Pause" : "▶ Play"
    }

    /// The line of the reading loaded: Play or Pause, and its place on the seek bar ("4:10…" while it is converted).
    private func showPlayback(_ playback: Playback?) {
        guard let playback, let current = playback.current, let duration = playback.duration else { return }
        showsSeekBar = true
        transport.title = Self.playTitle(playback)
        seekBar.show(current: current, duration: duration, growing: !playback.final)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { seekBar.setEmphasized(backgroundStyle == .emphasized) }
    }

    private static let stopHelp = "Stop converting this text to audio. What is ready keeps playing; converting can resume."

    private func setThird(_ title: String, _ action: Action, help: String) {
        thirdAction = action
        third.title = title
        third.toolTip = help
    }

    private func setPrimary(_ title: String, _ action: Action, help: String) {
        primary.title = title
        primaryAction = action
        primary.toolTip = help
    }

    // MARK: - Menus

    /// What ··· shows: Show in Finder, Chapter Files…, Delete…, as the reading shown offers them.
    func moreMenu() -> NSMenu {
        menu(of: maintenance)
    }

    /// A right-click on the row: its buttons' actions, then what ··· has.
    override func menu(for event: NSEvent) -> NSMenu? {
        var items: [(String, Action)] = []
        if showsSeekBar { items.append((transport.title, .play)) }
        for button in [primary, textButton, third] where !button.isHidden {
            let action = button === primary ? primaryAction : button === textButton ? .showText : thirdAction
            if let action { items.append((fullTitle(button), action)) }
        }
        if !items.isEmpty, !maintenance.isEmpty { items.append(("", .play)) }  // a separator
        items += maintenance
        return items.isEmpty ? nil : menu(of: items)
    }

    /// Items acting on the reading shown now; an empty title is a separator. Each menu's actions replace the last's,
    /// which is closed by the time another opens.
    private func menu(of items: [(String, Action)]) -> NSMenu {
        let menu = NSMenu()
        menuActions = []
        for (title, action) in items {
            guard !title.isEmpty else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = menuActions.count
            // The pane's shortcuts, shown where they are offered.
            if action == .delete { item.keyEquivalent = "\u{8}"; item.keyEquivalentModifierMask = [] }
            if action == .share { item.keyEquivalent = "s"; item.keyEquivalentModifierMask = [.command, .shift] }
            menuActions.append(action)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuItemChosen(_ item: NSMenuItem) {
        guard menuActions.indices.contains(item.tag) else { return }
        send(menuActions[item.tag])
    }

    @objc private func morePressed() {
        let y = moreButton.isFlipped ? moreButton.bounds.maxY + 2 : -2
        moreMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: moreButton)
    }

    @objc private func primaryPressed() { send(primaryAction) }
    @objc private func thirdPressed() { if let thirdAction { send(thirdAction) } }
    @objc private func transportPressed() { send(.play) }
    @objc private func textPressed() { send(.showText) }

    private func send(_ action: Action) {
        guard let entryID else { return }
        onAction?(entryID, action)
    }
}
