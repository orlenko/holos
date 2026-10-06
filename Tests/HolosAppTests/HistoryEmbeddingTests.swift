import AppKit
import Foundation
import HolosCore
import Testing
@testable import HolosApp

/// History in the real main window, laid out offscreen at several window sizes with a dictation selected; the window
/// is never shown. Every hairline stays a line: none takes height from the list, the detail, or the footer.
@MainActor
struct HistoryEmbeddingTests {
    @Test(arguments: SettingsEmbeddingTests.sizes)
    func everyHairlineStaysALine(size: NSSize) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let actions = HistoryPane.Actions(copy: { _ in true }, correct: { _ in }, delete: { _ in }, clear: {},
                                          audioURL: { _ in nil },
                                          rerun: { _ in throw CancellationError() }, update: { _, _ in })
        let pane = HistoryPane(actions: actions)
        let controller = MainWindowController { section in section == .history ? pane : NSViewController() }
        controller.window.setContentSize(size)
        controller.select(.history)
        let record = DictationRecord(id: UUID(), date: Date(), app: "Notes", language: "en-US",
                                     text: "the budget looks fine", heard: "the budget looks fine",
                                     outcome: .init(kind: .inserted), seconds: 2)
        pane.update(records: [record], retention: .standard, problem: nil, hidden: 0, unreadable: false)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        SettingsEmbeddingTests.retained.append(controller)

        let lines = Self.separators(in: pane.view)
        #expect(lines.count == 2, "The footer's hairline and the detail's.")
        for line in lines {
            #expect(line.alignmentRect(forFrame: line.frame).height <= 1.5)
            #expect(line.frame.width > 0)
        }
    }

    static func separators(in view: NSView) -> [NSBox] {
        view.subviews.flatMap { subview -> [NSBox] in
            if let box = subview as? NSBox, box.boxType == .separator { return [box] }
            return separators(in: subview)
        }
    }
}
