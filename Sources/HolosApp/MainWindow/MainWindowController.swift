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

    /// A stable name for UserDefaults (`MainWindowLaunch.lastSectionKey`), independent of the sidebar order.
    var storageName: String {
        switch self {
        case .history: "history"
        case .corrections: "corrections"
        case .meetings: "meetings"
        case .people: "people"
        case .reading: "reading"
        case .settings: "settings"
        }
    }

    init?(storageName: String) {
        guard let section = Self.allCases.first(where: { $0.storageName == storageName }) else { return nil }
        self = section
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
/// remembers its frame, the sidebar's width, and whether the sidebar is hidden; closing it keeps everything for the
/// next opening. The sidebar can be hidden (View ▸ Hide Sidebar ⌃⌘S, the toolbar's sidebar button, or a drag of the
/// divider), so the window can be narrow enough to sit beside a call's window.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    /// The narrowest the section content gets: the whole window's width with the sidebar hidden.
    static let contentMinimumWidth: CGFloat = 400
    static let sidebarMinimumWidth: CGFloat = 200
    static let minimumHeight: CGFloat = 560

    /// Where the window keeps the sidebar's width (the split view's autosave) and whether it is hidden (a
    /// UserDefaults key), for the next opening and the next launch.
    struct Autosave {
        /// The split view's autosave name (AppKit keeps it in the standard defaults); nil saves no divider position.
        var split: String?
        var sidebarHidden: String
        /// Where `sidebarHidden` is kept; tests pass a suite of their own.
        var defaults: UserDefaults = .standard
        static let standard = Autosave(split: "VoiceIsLocalMainSplit", sidebarHidden: "mainWindowSidebarHidden")
    }

    /// Internal so tests can lay a section out in the real window without showing it (`select(_:)`).
    let window: PreviewingWindow
    private let split = MainSplitViewController()
    /// Internal for tests, which hide and show the sidebar without the animation (`isCollapsed`).
    let sidebarItem: NSSplitViewItem
    let sidebar: SidebarViewController
    private let container = SectionContainerViewController()
    private let makeSection: (MainSection) -> NSViewController
    private var sections: [MainSection: NSViewController] = [:]
    private(set) var current: MainSection?
    /// Called when a section comes on screen, and with nil when the window closes.
    var onSectionChange: ((MainSection?) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    /// Called when the window becomes key (the user came back to it, from Terminal for example), with the section
    /// it shows.
    var onBecomeKey: ((MainSection?) -> Void)?

    var isVisible: Bool { window.isVisible }
    var isKey: Bool { window.isKeyWindow }
    /// Minimised to the Dock (then `isVisible` is false, but the window is still open).
    var isMiniaturized: Bool { window.isMiniaturized }

    /// Brings a minimised window back from the Dock; its section still counts as shown.
    func restoreFromDock() {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// `autosave`: where the sidebar's width and hidden state are kept (nil: not kept; tests).
    init(autosave: Autosave? = .standard, makeSection: @escaping (MainSection) -> NSViewController) {
        self.makeSection = makeSection
        sidebar = SidebarViewController()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        window = PreviewingWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
        super.init()
        window.title = "Voice is Local"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The width with the sidebar hidden; with it shown, the split view's constraints (sidebar and content minimum
        // widths) keep the window wider.
        window.contentMinSize = NSSize(width: Self.contentMinimumWidth, height: Self.minimumHeight)
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "VoiceIsLocalMainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.delegate = self
        window.toolbar = toolbar
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.hidesOnDeactivate = false
        window.autorecalculatesKeyViewLoop = true

        sidebar.onSelect = { [weak self] section in
            // The Settings row shows Settings from the top; ⌘, and the menus show it where it was left.
            if section == .settings {
                self?.showSettings(chapter: nil)
            } else {
                self?.show(section, focus: false)
            }
        }
        sidebar.onSelectChapter = { [weak self] chapter in self?.showSettings(chapter: chapter) }
        sidebarItem.minimumThickness = Self.sidebarMinimumWidth
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = Self.contentMinimumWidth
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = autosave?.split
        // Hidden as it was left (the split view's autosave is not relied on for that).
        if let autosave, autosave.defaults.bool(forKey: autosave.sidebarHidden) {
            sidebarItem.isCollapsed = true
        }
        split.onSidebarCollapsedChange = { [weak self] collapsed in
            if let autosave { autosave.defaults.set(collapsed, forKey: autosave.sidebarHidden) }
            if collapsed { self?.sidebarDidCollapse() }
        }
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

    /// Shows Settings scrolled to `chapter`'s card (nil: its top), smoothly when Settings was already on screen; the
    /// sidebar marks the chapter (the Settings row for nil).
    func showSettings(chapter: SettingsChapter?) {
        let onScreen = current == .settings && window.isVisible
        show(.settings, focus: false)
        sidebar.select(.settings, chapter: chapter)
        settingsPane?.show(chapter: chapter, animated: onScreen)
    }

    /// The section's view controller, created on first use.
    func controller(for section: MainSection) -> NSViewController {
        if let existing = sections[section] { return existing }
        let made = makeSection(section)
        sections[section] = made
        if let settings = made as? SettingsPane {
            settings.onChapterChange = { [weak self] chapter in
                guard let self, self.current == .settings else { return }
                self.sidebar.select(.settings, chapter: chapter)
            }
        }
        return made
    }

    private var settingsPane: SettingsPane? { sections[.settings] as? SettingsPane }

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

    /// Puts `section` in the window and marks it in the sidebar, without bringing the window forward (`show` does);
    /// tests use it to lay a section out offscreen.
    func select(_ section: MainSection) {
        // Settings as it was left: the sidebar marks the chapter it shows, or Settings itself at the top and while a
        // search is open (`sidebarMarkOnShow`). Already on Settings, the sidebar keeps what it marks.
        if section != .settings || current != .settings {
            let chapter = section == .settings ? settingsPane?.sidebarMarkOnShow : nil
            sidebar.select(section, chapter: chapter)
        }
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

    /// The sidebar is hidden.
    var sidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// The sidebar was hidden: the keyboard focus, if it was in the sidebar (or AppKit gave it to the window as the
    /// sidebar went), goes to the section (its preferred view, else the window, from where Tab enters the section),
    /// so it is never left in a view no one sees.
    private func sidebarDidCollapse() {
        let responder = window.firstResponder
        let inSidebar = (responder as? NSView)?.isDescendant(of: sidebar.view) == true
        guard inSidebar || responder === window else { return }
        let preferred = current.flatMap { sectionContent($0)?.preferredFirstResponder }
        if let preferred, !preferred.isHiddenOrHasHiddenAncestor, window.makeFirstResponder(preferred) { return }
        window.makeFirstResponder(nil)
    }

    // MARK: - NSToolbarDelegate

    /// The sidebar button over the sidebar (by the window's buttons when it is hidden), then the title.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// Only AppKit's own items, which it makes itself.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        nil
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
        onBecomeKey?(current)
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

// MARK: - Split view

/// The main window's split view controller: AppKit's, which answers View ▸ Hide Sidebar / Show Sidebar and the
/// toolbar's sidebar button (`toggleSidebar(_:)`), and tells when the sidebar was hidden or shown, by either of them
/// or by a drag of the divider.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    var onSidebarCollapsedChange: ((Bool) -> Void)?
    private var reportedCollapsed = false

    /// Showing the sidebar in a window narrower than the sidebar and the section need: the window grows to the left
    /// first, so the section keeps its place and its width (clamped to the screen). Growing it can make AppKit show
    /// a sidebar that narrowing the window hid; then it is already shown, and toggling would hide it again, so what
    /// was asked (shown or hidden, as decided before the resize) is what decides.
    override func toggleSidebar(_ sender: Any?) {
        guard let sidebar = splitViewItems.first else { return super.toggleSidebar(sender) }
        let show = sidebar.isCollapsed
        if show { makeRoom(for: sidebar) }
        guard sidebar.isCollapsed == show else { return }
        super.toggleSidebar(sender)
    }

    private func makeRoom(for sidebar: NSSplitViewItem) {
        guard let window = view.window, !window.styleMask.contains(.fullScreen) else { return }
        let needed = splitViewItems.reduce(0) { $0 + $1.minimumThickness } + splitView.dividerThickness
        let content = window.contentRect(forFrameRect: window.frame)
        guard content.width < needed else { return }
        var frame = window.frame
        frame.size.width += needed - content.width
        frame.origin.x -= needed - content.width
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, screen.minX), max(screen.minX, screen.maxX - frame.width))
        }
        window.setFrame(frame, display: true)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        reportCollapse()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        reportCollapse()
    }

    private func reportCollapse() {
        let collapsed = splitViewItems.first?.isCollapsed ?? false
        guard collapsed != reportedCollapsed else { return }
        reportedCollapsed = collapsed
        onSidebarCollapsedChange?(collapsed)
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
/// Settings with its chapters under it, and the dictation status card at the bottom.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case group(String)
        case spacer
        case section(MainSection)
        case chapter(SettingsChapter)
    }

    private let rows: [Row] = [
        .group("Dictation"), .section(.history), .section(.corrections),
        .group("Meetings"), .section(.meetings), .section(.people),
        .group("Listen"), .section(.reading),
        .spacer, .section(.settings),
    ] + SettingsChapter.allCases.map(Row.chapter)
    private let table = NSTableView()
    private let statusCard = StatusCardView()
    var onSelect: ((MainSection) -> Void)?
    var onSelectChapter: ((SettingsChapter) -> Void)?
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
        table.target = self
        table.action = #selector(rowClicked)
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

    /// Marks `section`, or one of Settings' chapters under it.
    func select(_ section: MainSection, chapter: SettingsChapter? = nil) {
        let index = rows.firstIndex { row in
            switch row {
            case .section(let candidate): chapter == nil && candidate == section
            case .chapter(let candidate): section == .settings && candidate == chapter
            case .group, .spacer: false
            }
        }
        guard let index else { return }
        _ = view
        guard table.selectedRow != index else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
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
        switch rows[row] {
        case .section, .chapter: true
        case .group, .spacer: false
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .spacer: 12
        case .group: 26
        case .section: 28
        case .chapter: 24
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
        case .chapter(let chapter):
            // Under Settings, lined up with its title.
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: chapter.title)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 30),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.setAccessibilityLabel("\(chapter.title) settings")
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, table.selectedRow >= 0 else { return }
        // A click changes the selection on mouse down; its action, on mouse up, must not go there a second time.
        if let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .leftMouseDragged {
            selectionChangedByClick = true
        }
        choose(table.selectedRow)
    }

    /// The selection changed during the click whose action comes next.
    private var selectionChangedByClick = false

    /// The table's action, on every click: a click on the row already selected goes there again, so Settings and
    /// a chapter scroll back to their top (the selection does not change, so `tableViewSelectionDidChange` is not
    /// called).
    @objc private func rowClicked() {
        defer { selectionChangedByClick = false }
        guard !selectionChangedByClick, table.clickedRow >= 0, table.clickedRow == table.selectedRow else { return }
        switch rows[table.clickedRow] {
        case .section(.settings), .chapter: choose(table.clickedRow)
        case .section, .group, .spacer: break
        }
    }

    private func choose(_ row: Int) {
        switch rows[row] {
        case .section(let section): onSelect?(section)
        case .chapter(let chapter): onSelectChapter?(chapter)
        case .group, .spacer: break
        }
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
