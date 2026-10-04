import AppKit
import Foundation
import Testing
@testable import HolosApp

/// Settings in the real main window (`MainWindowController`, its split view and section container), laid out offscreen
/// at several window sizes; the window is never shown. Guards the blank Settings page of PR #80: the separator under
/// the search field had no height of its own and, in some windows, took all the height and left the page none.
@MainActor
struct SettingsEmbeddingTests {
    /// Window content sizes: the default, the minimum, and tall ones like the user's (900 × 950 points and larger).
    nonisolated static let sizes = [NSSize(width: 1280, height: 800), NSSize(width: 900, height: 560),
                        NSSize(width: 900, height: 950), NSSize(width: 1000, height: 1300),
                        NSSize(width: 1600, height: 1900)]

    @Test(arguments: sizes)
    func thePageFillsTheSectionAndShowsItsCards(size: NSSize) throws {
        let (window, pane) = try Self.settings(size: size)
        // Settings never pulls the window's content in from the window's edges.
        let content = try #require(window.contentView)
        #expect(content.frame.size == window.contentRect(forFrameRect: window.frame).size)
        let scroll = try #require(Self.pageScrollView(in: pane.view))
        let field = try #require(pane.searchField)
        // The page takes everything below the search field (and its hairline).
        #expect(scroll.frame.height > pane.view.bounds.height - field.frame.height - 60)
        #expect(scroll.frame.width == pane.view.bounds.width)
        let document = try #require(scroll.documentView)
        #expect(document.frame.width > 0)
        #expect(document.frame.height > scroll.frame.height)
        // Empty query: every card shows, and the first ones are in view.
        let cards = Self.cards(in: document)
        #expect(cards.count == SettingsChapter.allCases.count)
        for card in cards {
            #expect(!card.isHiddenOrHasHiddenAncestor)
            // As wide as the page allows, up to 760 points, with 28-point margins.
            #expect(card.frame.width == min(760, document.frame.width - 56))
            #expect(card.frame.height > 0)
        }
        #expect(cards.contains { scroll.contentView.documentVisibleRect.intersects($0.convert($0.bounds, to: document)) })
        // The hairline stays a horizontal line.
        let separator = try #require(pane.view.subviews.first { $0 is NSBox })
        let line = separator.alignmentRect(forFrame: separator.frame)
        #expect(line.height <= 1.5)
        #expect(line.width == pane.view.bounds.width)
        Self.render(window, name: "settings-\(Int(size.width))x\(Int(size.height))")
    }

    @Test(arguments: [SettingsChapter.meetings, .history])
    func aChosenChapterIsOnScreen(chapter: SettingsChapter) throws {
        let (window, pane) = try Self.settings(size: NSSize(width: 900, height: 950))
        pane.show(chapter: chapter, animated: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.pageScrollView(in: pane.view))
        let document = try #require(scroll.documentView)
        let visible = scroll.contentView.documentVisibleRect
        #expect(visible.height > 0)
        #expect(Self.cards(in: document).contains { visible.intersects($0.convert($0.bounds, to: document)) })
        Self.render(window, name: "settings-chapter-\(chapter.title)")
    }

    @Test func clearingASearchShowsEveryCardAgain() throws {
        let (window, pane) = try Self.settings(size: NSSize(width: 900, height: 950))
        let field = try #require(pane.searchField)
        field.stringValue = "audio"
        _ = field.sendAction(field.action, to: field.target)
        field.stringValue = ""
        _ = field.sendAction(field.action, to: field.target)
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.pageScrollView(in: pane.view))
        let document = try #require(scroll.documentView)
        #expect(scroll.frame.height > 0)
        let cards = Self.cards(in: document)
        #expect(cards.count == SettingsChapter.allCases.count)
        #expect(cards.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
    }

    // MARK: - Helpers

    /// The main window on Settings, laid out but never shown.
    static func settings(size: NSSize) throws -> (NSWindow, SettingsPane) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let noop = SettingsPane.Callbacks(perform: { _ in }, opacity: { _ in }, language: { _ in },
                                          shortcut: { _ in }, retention: { _ in }, appearance: { _ in })
        let controller = MainWindowController { section in
            section == .settings ? SettingsPane(callbacks: noop) : NSViewController()
        }
        controller.window.setContentSize(size)
        controller.select(.settings)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let pane = try #require(controller.existingController(for: .settings) as? SettingsPane)
        retained.append(controller)
        return (controller.window, pane)
    }

    /// Controllers stay alive for the run: a window closing while AppKit still lays it out is not what is tested.
    static var retained: [MainWindowController] = []

    static func pageScrollView(in view: NSView) -> NSScrollView? {
        view.subviews.lazy.compactMap { $0 as? NSScrollView }.first
    }

    static func cards(in view: NSView) -> [CardView] {
        view.subviews.flatMap { ($0 as? CardView).map { [$0] } ?? cards(in: $0) }
    }

    /// With SETTINGS_RENDER_DIR set, writes the window (frame view included) as a PNG there.
    static func render(_ window: NSWindow, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"],
              let view = window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        window.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
