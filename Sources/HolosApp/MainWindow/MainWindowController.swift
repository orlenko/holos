import AppKit
import Quartz

/// The sections of the main window, in sidebar order (docs/design.md "Main window").
enum MainSection: Int, CaseIterable {
    case history, corrections, meetings, people, reading, settings

    var title: String {
        switch self {
        case .history: "History"
        case .corrections: "Corrections"
        case .meetings: "Meetings"
        case .people: "People"
        case .reading: "Reading"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .corrections: "text.badge.checkmark"
        case .meetings: "waveform"
        case .people: "person.2"
        case .reading: "book"
        case .settings: "gearshape"
        }
    }

    /// The key equivalent with Command: ⌘1 … ⌘5, ⌘,.
    var keyEquivalent: String {
        switch self {
        case .history: "1"
        case .corrections: "2"
        case .meetings: "3"
        case .people: "4"
        case .reading: "5"
        case .settings: ","
        }
    }
}

/// What a section's view controller can do for the window; every method is optional.
@MainActor
protocol MainSectionContent: AnyObject {
    /// The section is now on screen (selected while the window is visible, or the window opened on it).
    func sectionDidShow()
    /// The section left the screen (another was selected, or the window closed).
    func sectionDidHide()
    /// The window became key while the section shows.
    func sectionWindowDidBecomeKey()
    /// ⌘F: the section's search field, if it has one.
    var searchField: NSSearchField? { get }
    /// Where the keyboard focus goes when the section is chosen from the keyboard.
    var preferredFirstResponder: NSView? { get }
}

extension MainSectionContent {
    func sectionDidShow() {}
    func sectionDidHide() {}
    func sectionWindowDidBecomeKey() {}
    var searchField: NSSearchField? { nil }
    var preferredFirstResponder: NSView? { nil }
}

/// The dictation status card at the bottom of the sidebar.
struct MainStatus: Equatable {
    enum Tone { case ready, off, busy, paused, problem }
    var tone: Tone
    var title: String
    var message: String
}

/// The one main window: a sidebar of sections and the selected section's content (NSSplitViewController). Sections
/// are created on first use (`makeSection`) and kept, so each keeps its state while another is shown. The window
/// remembers its frame; closing it keeps everything for the next opening.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: PreviewingWindow
    private let split = NSSplitViewController()
    private let sidebar: SidebarViewController
    private let container = SectionContainerViewController()
    private let makeSection: (MainSection) -> NSViewController
    private var sections: [MainSection: NSViewController] = [:]
    private(set) var current: MainSection?
    /// Called when a section comes on screen, and with nil when the window closes.
    var onSectionChange: ((MainSection?) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { window.isVisible }
    var isKey: Bool { window.isKeyWindow }

    init(makeSection: @escaping (MainSection) -> NSViewController) {
        self.makeSection = makeSection
        sidebar = SidebarViewController()
        window = PreviewingWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
        super.init()
        window.title = "Voice is Local"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "VoiceIsLocalMainToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.hidesOnDeactivate = false
        window.autorecalculatesKeyViewLoop = true

        sidebar.onSelect = { [weak self] section in self?.show(section, focus: false) }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = false
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 600
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "VoiceIsLocalMainSplit"
        window.contentViewController = split

        // Frame: the saved one, else 1280 × 800 (or what fits the screen), centred.
        if !window.setFrameUsingName(Self.frameName) {
            let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
            window.setContentSize(NSSize(width: min(1280, visible.width - 40), height: min(800, visible.height - 40)))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
    }

    private static let frameName = "VoiceIsLocalMainWindow"

    /// Shows the window on `section`. `focus` moves the keyboard focus into the section (menu and keyboard use).
    func show(_ section: MainSection, focus: Bool = true) {
        let wasVisible = window.isVisible
        select(section)
        // First, so the app is a regular one (Dock, ⌘-Tab, menu bar) as the window comes forward.
        if !wasVisible { onVisibilityChange?(true) }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        if !wasVisible {
            sectionContent(section)?.sectionDidShow()
            onSectionChange?(section)
        }
        if focus, let responder = sectionContent(section)?.preferredFirstResponder {
            window.makeFirstResponder(responder)
        }
    }

    /// The section's view controller, created on first use.
    func controller(for section: MainSection) -> NSViewController {
        if let existing = sections[section] { return existing }
        let made = makeSection(section)
        sections[section] = made
        return made
    }

    /// The section's view controller if it was created.
    func existingController(for section: MainSection) -> NSViewController? { sections[section] }

    func updateStatus(_ status: MainStatus) {
        sidebar.updateStatus(status)
    }

    /// ⌘F: focuses the current section's search field.
    func focusSearch() -> Bool {
        guard let current, let field = sectionContent(current)?.searchField else { return false }
        window.makeFirstResponder(field)
        return true
    }

    func close() { window.performClose(nil) }

    private func sectionContent(_ section: MainSection) -> MainSectionContent? {
        sections[section] as? MainSectionContent
    }

    private func select(_ section: MainSection) {
        sidebar.select(section)
        guard section != current else { return }
        let previous = current
        let controller = controller(for: section)
        if let previous, window.isVisible { sectionContent(previous)?.sectionDidHide() }
        // Only Meetings takes the Quick Look panel; close it when leaving Meetings.
        if previous == .meetings { QLPreviewPanelCloser.closeIfVisible() }
        window.previewController = controller as? (NSObject & QLPreviewPanelDataSource & QLPreviewPanelDelegate)
        container.display(controller)
        current = section
        window.subtitle = section.title
        if window.isVisible {
            sectionContent(section)?.sectionDidShow()
            onSectionChange?(section)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let current { sectionContent(current)?.sectionDidHide() }
        _ = QLPreviewPanelCloser.closeIfVisible()
        onSectionChange?(nil)
        onVisibilityChange?(false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let current { sectionContent(current)?.sectionWindowDidBecomeKey() }
    }
}

/// Closes the shared Quick Look panel if it exists and is visible.
@MainActor
enum QLPreviewPanelCloser {
    @discardableResult
    static func closeIfVisible() -> Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else {
            return false
        }
        panel.orderOut(nil)
        return true
    }
}

// MARK: - Content container

/// Holds the selected section's view controller, pinned below the title bar (the window's safe area).
@MainActor
final class SectionContainerViewController: NSViewController {
    private var shown: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func display(_ controller: NSViewController) {
        guard controller !== shown else { return }
        if let shown {
            shown.view.removeFromSuperview()
            shown.removeFromParent()
        }
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        shown = controller
    }
}

// MARK: - Sidebar

/// The source list: "Dictation" (History, Corrections), "Meetings" (Meetings, People), "Listen" (Reading), then
/// Settings, and the dictation status card at the bottom.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case group(String)
        case spacer
        case section(MainSection)
    }

    private let rows: [Row] = [
        .group("Dictation"), .section(.history), .section(.corrections),
        .group("Meetings"), .section(.meetings), .section(.people),
        .group("Listen"), .section(.reading),
        .spacer, .section(.settings),
    ]
    private let table = NSTableView()
    private let statusCard = StatusCardView()
    var onSelect: ((MainSection) -> Void)?
    private var selecting = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Sections")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        statusCard.translatesAutoresizingMaskIntoConstraints = false

        // The split view starts the sidebar at this width; the user's width is saved (`autosaveName`).
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 600))
        root.addSubview(scroll)
        root.addSubview(statusCard)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusCard.topAnchor, constant: -8),
            statusCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            statusCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
    }

    func select(_ section: MainSection) {
        guard let index = rows.firstIndex(where: { if case .section(section) = $0 { true } else { false } }) else {
            return
        }
        _ = view
        guard table.selectedRow != index else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        selecting = false
    }

    func updateStatus(_ status: MainStatus) {
        _ = view
        statusCard.update(status)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .spacer: 12
        case .group: 26
        case .section: 28
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .spacer:
            return NSView()
        case .group(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let cell = NSTableCellView()
            cell.textField = label
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .section(let section):
            let cell = NSTableCellView()
            let image = NSImageView(image: NSImage(systemSymbolName: section.symbol,
                                                   accessibilityDescription: nil) ?? NSImage())
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let label = NSTextField(labelWithString: section.title)
            label.lineBreakMode = .byTruncatingTail
            let shortcut = NSTextField(labelWithString: "⌘" + section.keyEquivalent)
            shortcut.textColor = .tertiaryLabelColor
            shortcut.font = .systemFont(ofSize: 11)
            shortcut.setAccessibilityElement(false)
            cell.imageView = image
            cell.textField = label
            for view in [image, label, shortcut] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
                shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.setAccessibilityLabel(section.title)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, table.selectedRow >= 0, case .section(let section) = rows[table.selectedRow] else { return }
        onSelect?(section)
    }
}

/// "● Dictation ready" and the current message, in a rounded card.
@MainActor
final class StatusCardView: NSView {
    private let dot = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 4
        message.lineBreakMode = .byTruncatingTail
        message.preferredMaxLayoutWidth = 170
        let header = NSStackView(views: [dot, title])
        header.spacing = 6
        let stack = NSStackView(views: [header, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let width = max(80, bounds.width - 20)
        if message.preferredMaxLayoutWidth != width { message.preferredMaxLayoutWidth = width }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func update(_ status: MainStatus) {
        dot.contentTintColor = switch status.tone {
        case .ready: .systemGreen
        case .off: .tertiaryLabelColor
        case .busy: .systemBlue
        case .paused: .systemOrange
        case .problem: .systemOrange
        }
        title.stringValue = status.title
        message.stringValue = status.message
        message.isHidden = status.message.isEmpty || status.message == status.title
        setAccessibilityLabel("\(status.title). \(status.message)")
    }
}
