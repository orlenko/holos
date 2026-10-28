import AppKit
import Testing
@testable import HolosApp

@MainActor @Suite struct ReadingTextSheetTests {
    @Test func theSheetShowsTheTextSelectableButNotEditable() throws {
        let sheet = ReadingTextSheet(title: "A Guide", text: "First words.\n\nSecond paragraph.")
        let views = Self.allViews(sheet.view)
        let body = try #require(views.compactMap { $0 as? NSTextView }.first)
        #expect(body.string == "First words.\n\nSecond paragraph.")
        #expect(body.isSelectable && !body.isEditable)
        #expect(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "A Guide" })
        #expect(views.compactMap { $0 as? NSButton }.contains { $0.title == "Copy Text" })
    }

    private static func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }
}
