import AppKit
import Foundation
import HolosContent
import HolosCore
import HolosMeeting
import HolosStorage
import Testing
@testable import HolosApp

/// The main window at its narrowest, so it can sit beside a call's window: every section laid out offscreen in the
/// real window (`MainWindowController`) at the minimum width, with the sidebar hidden and shown; the window is never
/// shown. A section must fit: no required constraint broken, none holding the window wider, no button squeezed or
/// pushed out of view, no wrapped text cut off. Also the sidebar itself: hidden from the View menu (⌃⌘S) or the
/// toolbar, remembered for the next window, and never keeping the keyboard focus once hidden.
@MainActor
struct MainWindowNarrowTests {
    @Test(arguments: MainSection.allCases, [true, false])
    func everySectionFitsTheNarrowestWindow(section: MainSection, sidebarHidden: Bool) throws {
        let controller = try Self.window(on: section, sidebarHidden: sidebarHidden)
        let window = controller.window
        let content = try #require(window.contentView)
        let width = Self.minimumWidth(controller, sidebarHidden: sidebarHidden)
        // Nothing in the section holds the window, or its content, wider than the minimum.
        #expect(window.contentRect(forFrameRect: window.frame).width == width)
        #expect(content.frame.width == width)
        let pane = try #require(controller.existingController(for: section)).view
        let frame = try #require(pane.superview).convert(pane.frame, to: content)
        #expect(frame.maxX <= content.bounds.width + 0.5)
        #expect(frame.width >= MainWindowController.contentMinimumWidth - 1)
        let broken = Self.brokenConstraints(in: content)
        #expect(broken.isEmpty, "Broken constraints: \(broken)")
        let problems = Self.layoutProblems(in: pane)
        #expect(problems.isEmpty, "\(section): \(problems)")
        SettingsEmbeddingTests.render(window, name: "narrow-\(section.storageName)-\(sidebarHidden ? "hidden" : "sidebar")")
    }

    /// The live transcript beside a call: the header keeps ‹ (back), the meeting's name (at least
    /// `titleMinimumWidth`), its state, and the finished meeting's button; the edit bar keeps Correct Text… and Name
    /// Speaker….
    @Test(arguments: [true, false], [LiveMeetingPhase.recording, .saved])
    func theLiveTranscriptStaysUsable(sidebarHidden: Bool, phase: LiveMeetingPhase) throws {
        let controller = try Self.window(on: .meetings, sidebarHidden: sidebarHidden)
        let pane = try #require(controller.existingController(for: .meetings) as? MeetingsPane)
        let session = try LiveMeetingViewTests.recordingSession()
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        pane.showLive(sessionID: LiveMeetingViewTests.sessionID, directory: session)
        let live = try #require(pane.children.compactMap { $0 as? LiveMeetingViewController }.first)
        let name = "Quarterly planning with the whole design team"
        let detail = phase == .saved ? "Saved — 1:02:03" : "0:12:34"
        live.update(header: LiveMeetingHeader(name: name, phase: phase, detail: detail),
                    finishedAction: phase == .saved ? "Open Review…" : nil)
        let window = controller.window
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let width = Self.minimumWidth(controller, sidebarHidden: sidebarHidden)
        #expect(content.frame.width == width)
        #expect(Self.brokenConstraints(in: content).isEmpty)
        #expect(Self.layoutProblems(in: live.view).isEmpty, "\(Self.layoutProblems(in: live.view))")

        let views = Self.allViews(live.view).filter { !$0.isHiddenOrHasHiddenAncestor }
        let buttons = views.compactMap { $0 as? NSButton }
        let back = try #require(buttons.first { $0.accessibilityLabel() == "Back to Meetings" })
        var whole = [back, try #require(buttons.first { $0.title == "Correct Text…" }),
                     try #require(buttons.first { $0.title == "Name Speaker…" })]
        if phase == .saved { whole.append(try #require(buttons.first { $0.title == "Open Review…" })) }
        for button in whole {
            #expect(button.frame.width >= button.intrinsicContentSize.width - 1, "\(button.title) is squeezed")
            let frame = try #require(button.superview).convert(button.frame, to: live.view)
            #expect(frame.minX >= 0 && frame.maxX <= live.view.bounds.width, "\(button.title) is cut off")
        }
        let labels = views.compactMap { $0 as? NSTextField }
        let title = try #require(labels.first { $0.stringValue == name })
        #expect(title.frame.width >= LiveMeetingViewController.titleMinimumWidth - 1)
        let status = try #require(labels.first { $0.stringValue == detail })
        // The clock while recording shows whole; a longer state keeps some room.
        if phase == .recording {
            #expect(status.frame.width >= status.intrinsicContentSize.width - 1)
        } else {
            #expect(status.frame.width > 30)
        }
        SettingsEmbeddingTests.render(window, name: "narrow-live-\(phase)-\(sidebarHidden ? "hidden" : "sidebar")")
    }

    /// A finished reading's row in the Reading list at the window's narrowest: Share… and Show in Finder become
    /// symbols (still named for VoiceOver), every button fits, and the title keeps some room; wide, they have titles.
    @Test(arguments: [CGFloat(316), 700])
    func aReadingRowFitsTheNarrowestWindow(width: CGFloat) throws {
        var entry = ReadingEntry(source: .web(try #require(URL(string: "https://example.com/story"))),
                                 requestedVoice: nil, speed: 1)
        entry.title = "A long story about planning the next quarter"
        entry.state = .done
        entry.duration = 192
        let row = ReadingRowView(identifier: NSUserInterfaceItemIdentifier("reading"))
        row.frame = NSRect(x: 0, y: 0, width: width, height: 52)
        row.show(entry, activity: nil, fileProblem: nil, size: 1_200_000,
                 playback: .init(playing: true, current: 12, duration: 192))
        row.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()  // the compact titles change on the first pass
        let buttons = Self.allViews(row).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        #expect(buttons.count == 4)
        for button in buttons {
            let frame = try #require(button.superview).convert(button.frame, to: row)
            #expect(frame.minX >= 0 && frame.maxX <= row.bounds.width, "\(button.title) is cut off")
            #expect(button.frame.width >= button.intrinsicContentSize.width - 1)
        }
        let labels = Self.allViews(row).compactMap { $0 as? NSTextField }
        let title = try #require(labels.first { $0.stringValue == entry.title })
        #expect(title.frame.width > 60)
        let compact = width < ReadingRowView.compactWidth
        #expect(buttons.contains { $0.title == "Share…" } == !compact)
        #expect(buttons.contains { $0.title == "Show in Finder" } == !compact)
        #expect(buttons.contains { $0.accessibilityLabel() == "Show in Finder — \(entry.title)" })
        #expect(Self.brokenConstraints(in: row).isEmpty)
    }

    /// The window's minimum: the section's minimum with the sidebar hidden, the sidebar's and the section's with it.
    @Test func theWindowGoesNarrowerOnlyWithTheSidebarHidden() throws {
        let controller = try Self.window(on: .history, sidebarHidden: false)
        let window = controller.window
        let content = try #require(window.contentView)
        #expect(window.contentMinSize.width == MainWindowController.contentMinimumWidth)
        #expect(window.contentMinSize.height == MainWindowController.minimumHeight)
        // Shown, the sidebar's and the section's minimum widths hold the content wider than the window asked.
        window.setContentSize(NSSize(width: MainWindowController.contentMinimumWidth,
                                     height: MainWindowController.minimumHeight))
        content.layoutSubtreeIfNeeded()
        #expect(content.frame.width >= MainWindowController.contentMinimumWidth
                + MainWindowController.sidebarMinimumWidth)
        // Hidden, the section alone.
        controller.sidebarItem.isCollapsed = true
        window.setContentSize(NSSize(width: MainWindowController.contentMinimumWidth,
                                     height: MainWindowController.minimumHeight))
        content.layoutSubtreeIfNeeded()
        #expect(content.frame.width == MainWindowController.contentMinimumWidth)
        #expect(controller.sidebarCollapsed)
    }

    /// ⌘1–⌘5, ⌘, and the menus choose sections through `select`: with the sidebar hidden each still comes on screen.
    @Test func everySectionShowsWithTheSidebarHidden() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = MainWindowController(autosave: nil) { _ in FocusSection() }
        SettingsEmbeddingTests.retained.append(controller)
        controller.sidebarItem.isCollapsed = true
        controller.window.setContentSize(NSSize(width: 500, height: 600))
        for section in MainSection.allCases {
            controller.select(section)
            controller.window.contentView?.layoutSubtreeIfNeeded()
            #expect(controller.current == section)
            let view = try #require(controller.existingController(for: section)).view
            #expect(view.window === controller.window)
            #expect(!view.isHiddenOrHasHiddenAncestor)
            #expect(view.frame.width >= MainWindowController.contentMinimumWidth)
        }
        #expect(controller.sidebarCollapsed)
    }

    /// Hiding the sidebar while it has the keyboard focus moves the focus to the section, never leaving it in a
    /// view no one sees.
    @Test func hidingTheSidebarTakesTheFocusOutOfIt() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = MainWindowController(autosave: nil) { _ in FocusSection() }
        SettingsEmbeddingTests.retained.append(controller)
        controller.window.setContentSize(NSSize(width: 900, height: 600))
        controller.select(.history)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let table = try #require(Self.allViews(controller.sidebar.view).first { $0 is NSTableView })
        #expect(controller.window.makeFirstResponder(table))
        controller.sidebarItem.isCollapsed = true
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let focused = try #require(controller.window.firstResponder as? NSView)
        #expect(!focused.isDescendant(of: controller.sidebar.view))
        let section = try #require(controller.existingController(for: .history) as? FocusSection)
        #expect(focused === section.preferredFirstResponder)
    }

    /// A hidden sidebar stays hidden in the next window (the next launch), and a shown one shown.
    @Test func theHiddenSidebarIsRememberedForTheNextWindow() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "VoiceIsLocalMainSplitTest-\(UUID().uuidString)"
        let autosave = MainWindowController.Autosave(split: name, sidebarHidden: "\(name)-hidden")
        defer {
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(name)")
            UserDefaults.standard.removeObject(forKey: autosave.sidebarHidden)
        }
        func make() -> MainWindowController {
            let controller = MainWindowController(autosave: autosave) { _ in FocusSection() }
            SettingsEmbeddingTests.retained.append(controller)
            controller.window.setContentSize(NSSize(width: 900, height: 600))
            controller.select(.history)
            controller.window.contentView?.layoutSubtreeIfNeeded()
            return controller
        }
        let first = make()
        #expect(!first.sidebarCollapsed)
        first.sidebarItem.isCollapsed = true
        first.window.contentView?.layoutSubtreeIfNeeded()
        let second = make()
        #expect(second.sidebarCollapsed)
        second.sidebarItem.isCollapsed = false
        second.window.contentView?.layoutSubtreeIfNeeded()
        let third = make()
        #expect(!third.sidebarCollapsed)
    }

    /// View ▸ Hide Sidebar (⌃⌘S), the one item with that key, answered and named by the window's split view
    /// controller; the toolbar has the sidebar button.
    @Test func theViewMenuAndTheToolbarHideTheSidebar() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)  // `NSApp`, which the menu's Window items need
        let menu = AppKeyboard.mainMenu()
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        let toggle = try #require(items.first { $0.action == #selector(NSSplitViewController.toggleSidebar(_:)) })
        #expect(menu.items.first { $0.submenu?.items.contains(toggle) == true }?.title == "View")
        #expect(toggle.keyEquivalent == "s")
        #expect(toggle.keyEquivalentModifierMask == [.command, .control])
        let same = items.filter {
            $0.keyEquivalent == toggle.keyEquivalent && $0.keyEquivalentModifierMask == toggle.keyEquivalentModifierMask
        }
        #expect(same.count == 1, "⌃⌘S is not used by another item")

        let controller = try Self.window(on: .history, sidebarHidden: false)
        let split = try #require(controller.window.contentViewController as? NSSplitViewController)
        #expect(split.validateUserInterfaceItem(toggle))
        #expect(toggle.title == "Hide Sidebar")
        controller.sidebarItem.isCollapsed = true
        #expect(split.validateUserInterfaceItem(toggle))
        #expect(toggle.title == "Show Sidebar")

        let toolbar = try #require(controller.window.toolbar)
        #expect(toolbar.delegate === controller)
        #expect(controller.toolbarDefaultItemIdentifiers(toolbar).contains(.toggleSidebar))
    }

    // MARK: - Fixture

    /// A section with a view that takes the keyboard focus.
    final class FocusSection: NSViewController, MainSectionContent {
        let focus = FocusView()
        override func loadView() {
            view = NSView()
            focus.frame = NSRect(x: 10, y: 10, width: 40, height: 20)
            view.addSubview(focus)
        }
        var preferredFirstResponder: NSView? { focus }
    }

    final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    static func minimumWidth(_ controller: MainWindowController, sidebarHidden: Bool) -> CGFloat {
        guard !sidebarHidden, let split = controller.window.contentViewController as? NSSplitViewController else {
            return MainWindowController.contentMinimumWidth
        }
        return MainWindowController.contentMinimumWidth + MainWindowController.sidebarMinimumWidth
            + split.splitView.dividerThickness
    }

    /// The main window on `section` at its minimum size (the sidebar hidden or shown), laid out but never shown.
    static func window(on section: MainSection, sidebarHidden: Bool) throws -> MainWindowController {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let made = try Self.section(section)
        let controller = MainWindowController(autosave: nil) { candidate in
            candidate == section ? made : NSViewController()
        }
        controller.sidebarItem.isCollapsed = sidebarHidden
        controller.window.setContentSize(NSSize(width: minimumWidth(controller, sidebarHidden: sidebarHidden),
                                                height: MainWindowController.minimumHeight))
        controller.select(section)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        SettingsEmbeddingTests.retained.append(controller)
        return controller
    }

    /// Each section as the app makes it, on made-up data in a temporary folder.
    static func section(_ section: MainSection) throws -> NSViewController {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("narrow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        switch section {
        case .history:
            let actions = HistoryPane.Actions(copy: { _ in true }, correct: { _ in }, delete: { _ in }, clear: {},
                                              audioURL: { _ in nil },
                                              rerun: { _ in throw CancellationError() }, update: { _, _ in })
            let pane = HistoryPane(actions: actions)
            let record = DictationRecord(id: UUID(), date: Date(), app: "Notes", language: "en-US",
                                         text: "the budget looks fine for the next quarter",
                                         heard: "the budget looks fine for the next quarter",
                                         outcome: .init(kind: .inserted), seconds: 2)
            pane.update(records: [record], retention: .standard, problem: nil, hidden: 0, unreadable: false)
            return pane
        case .corrections:
            let words = WordListView(onAdd: { _ in .init(message: "", unadded: []) }, onRemove: { _ in "" },
                                     onSetHeardAs: { _, _ in "" })
            let pane = CorrectionsPane(onLearn: { _, _, _ in nil }, onAdd: { _, _ in true }, onRemove: { _ in true },
                                       onReplace: { _, _, _ in true }, wordList: words, onShow: {})
            pane.load(transcript: "the budget looks fine", recognized: "the budget looks fine", dictation: nil,
                      title: "Last dictation — fix any misheard words, then Learn", corrections: [])
            return pane
        case .meetings:
            return MeetingsPane(root: temp, perform: { _, _ in }, openReview: { _ in },
                                beginUsing: { _, _ in true }, endUsing: { _ in },
                                liveHeader: { _, _ in
                                    LiveMeetingHeader(name: "Weekly planning", phase: .recording, detail: "0:01:00")
                                })
        case .people:
            return PeoplePane(store: SpeakerProfileStore(directory: temp.appendingPathComponent("Speakers")),
                              sessionsRoot: temp)
        case .reading:
            return ReadingPane(controller: ReadingController())
        case .settings:
            let noop = SettingsPane.Callbacks(perform: { _ in }, opacity: { _ in }, language: { _ in },
                                              shortcut: { _ in }, retention: { _ in }, appearance: { _ in })
            return SettingsPane(callbacks: noop)
        }
    }

    // MARK: - Checks

    static func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    /// Required constraints the laid-out frames do not satisfy (AppKit broke them to recover), within a point. The
    /// content-size constraints (a control's intrinsic size, which compression resistance governs) are left out.
    static func brokenConstraints(in root: NSView) -> [String] {
        var problems: [String] = []
        for view in allViews(root) where !view.isHiddenOrHasHiddenAncestor {
            for constraint in view.constraints where constraint.isActive && constraint.priority == .required
                && String(describing: type(of: constraint)) != "NSContentSizeLayoutConstraint" {
                guard let first = value(constraint.firstItem, constraint.firstAttribute, in: root) else { continue }
                let second = constraint.secondItem == nil ? 0
                    : value(constraint.secondItem, constraint.secondAttribute, in: root)
                guard let second else { continue }
                let target = second * constraint.multiplier + constraint.constant
                let satisfied = switch constraint.relation {
                case .equal: abs(first - target) <= 1
                case .lessThanOrEqual: first <= target + 1
                case .greaterThanOrEqual: first >= target - 1
                @unknown default: true
                }
                if !satisfied { problems.append("\(constraint) is \(first), not \(target)") }
            }
        }
        return problems
    }

    /// An attribute of a view or layout guide in `root`'s coordinates (alignment rects, measured down from the top as
    /// constraints are); nil for baselines and for items hidden or outside `root`.
    static func value(_ item: AnyObject?, _ attribute: NSLayoutConstraint.Attribute, in root: NSView) -> CGFloat? {
        var rect: NSRect
        if let view = item as? NSView {
            guard view === root || view.isDescendant(of: root), !view.isHiddenOrHasHiddenAncestor else { return nil }
            if view === root {
                rect = root.bounds
            } else {
                guard let superview = view.superview else { return nil }
                rect = superview.convert(view.alignmentRect(forFrame: view.frame), to: root)
            }
        } else if let guide = item as? NSLayoutGuide, let owner = guide.owningView {
            guard owner === root || owner.isDescendant(of: root), !owner.isHiddenOrHasHiddenAncestor else { return nil }
            rect = owner.convert(guide.frame, to: root)
        } else {
            return nil
        }
        if !root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
        return switch attribute {
        case .left, .leading: rect.minX
        case .right, .trailing: rect.maxX
        case .top: rect.minY
        case .bottom: rect.maxY
        case .width: rect.width
        case .height: rect.height
        case .centerX: rect.midX
        case .centerY: rect.midY
        default: nil
        }
    }

    /// Controls cut off at the side of the section (or of the scrolling page they are on), buttons and segmented
    /// controls narrower than they need (a pop-up truncates its title by design), and wrapped text or checkbox
    /// titles with less height than their lines need. Table rows are left to their tables.
    static func layoutProblems(in pane: NSView) -> [String] {
        var problems: [String] = []
        for view in allViews(pane) where !view.isHiddenOrHasHiddenAncestor && !Self.inTable(view) {
            // A table scrolls its columns sideways inside its scroll view.
            guard view is NSControl, !(view is NSTableView), let superview = view.superview else { continue }
            let container = view.enclosingScrollView?.contentView ?? pane
            let frame = superview.convert(view.frame, to: container)
            let visible = container.bounds
            if frame.minX < visible.minX - 0.5 || frame.maxX > visible.maxX + 0.5 {
                problems.append("cut off: \(describe(view)) at \(frame.minX)–\(frame.maxX) of \(visible.width)")
            }
            let intrinsic = view.intrinsicContentSize.width
            if let button = view as? NSButton, !(view is NSPopUpButton), button.cell?.wraps != true,
               intrinsic != NSView.noIntrinsicMetric, view.frame.width < intrinsic - 1 {
                problems.append("squeezed: \(describe(view)) \(view.frame.width) of \(intrinsic)")
            }
            // A segmented control may be narrower than it asks, as long as each segment holds its label.
            if let segmented = view as? NSSegmentedControl, segmented.segmentCount > 0 {
                let font = segmented.font ?? .systemFont(ofSize: NSFont.systemFontSize)
                let widest = (0..<segmented.segmentCount).map {
                    ((segmented.label(forSegment: $0) ?? "") as NSString).size(withAttributes: [.font: font]).width
                }.max() ?? 0
                let segment = segmented.frame.width / CGFloat(segmented.segmentCount)
                if segment < widest + 8 {
                    problems.append("squeezed: \(describe(view)) segments \(segment) wide for labels \(widest)")
                }
            }
            let wraps = (view as? NSTextField).map { $0.cell?.wraps == true && !$0.stringValue.isEmpty }
                ?? ((view as? NSButton)?.cell?.wraps == true)
            if wraps, let cell = (view as? NSControl)?.cell, view.frame.width > 0 {
                let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: view.frame.width,
                                                             height: .greatestFiniteMagnitude)).height
                if view.frame.height < needed - 1.5 {
                    problems.append("cut short: \(describe(view)) \(view.frame.height) high of \(needed)")
                }
            }
        }
        return problems
    }

    static func inTable(_ view: NSView) -> Bool {
        var current = view.superview
        while let ancestor = current {
            if ancestor is NSTableView { return true }
            current = ancestor.superview
        }
        return false
    }

    static func describe(_ view: NSView) -> String {
        if let button = view as? NSButton { return "\(type(of: view)) \"\(button.title)\"" }
        if let field = view as? NSTextField { return "\(type(of: view)) \"\(field.stringValue.prefix(40))\"" }
        return "\(type(of: view))"
    }
}
