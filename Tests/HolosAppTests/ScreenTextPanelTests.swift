import AppKit
import Foundation
import HolosStorage
import Testing
@testable import HolosApp

/// Review's Screen Text sheet, built offscreen from invented keyframes (never shown, nothing captured): which display
/// a snapshot came from is said only when the meeting captured more than one.
@MainActor
struct ScreenTextPanelTests {
    @Test(.timeLimit(.minutes(1)))
    func snapshotsNameTheirDisplayOnlyWhenTheMeetingHadSeveral() {
        let main = ScreenDisplay(id: 4, number: 1, isMain: true), side = ScreenDisplay(id: 7, number: 2, isMain: false)
        let line = ScreenTextLine(text: "Quarterly roadmap", x: 0.1, y: 0.1, width: 0.5, height: 0.1, confidence: 0.9)
        let two = ScreenContextRecord(sessionID: "synthetic", frames: [
            ScreenKeyframe(start: 12, end: 40, lines: [line], display: side),
            ScreenKeyframe(start: 12, end: 40, display: main),
            ScreenKeyframe(start: 65, end: 70, display: side),
        ])
        let panel = ScreenTextPanel(record: two, known: [], onSeek: { _ in }, onRecognize: { _ in })
        #expect(panel.snapshotTitles == ["0:12–0:40 · Display 2", "0:12–0:40 · Main display", "1:05–1:10 · Display 2"])
        #expect(Self.text(panel).hasPrefix("Recognized lines on Display 2\n\nQuarterly roadmap"))

        let one = ScreenContextRecord(sessionID: "synthetic", frames: [
            ScreenKeyframe(start: 12, end: 40, lines: [line], display: main), ScreenKeyframe(start: 12, end: 40, display: main),
        ])
        let single = ScreenTextPanel(record: one, known: [], onSeek: { _ in }, onRecognize: { _ in })
        #expect(single.snapshotTitles == ["0:12–0:40", "0:12–0:40"], "same-titled snapshots are both listed")
        #expect(Self.text(single).hasPrefix("Recognized lines\n\nQuarterly roadmap"))

        let legacy = ScreenContextRecord(sessionID: "synthetic", frames: [ScreenKeyframe(start: 3, end: 9)])
        #expect(ScreenTextPanel.titles(legacy) == ["0:03–0:09"], "a meeting saved before displays were named")
    }

    private static func text(_ panel: ScreenTextPanel) -> String {
        func find(_ view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let text = view as? NSTextView { return text }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return find(panel.window.contentView)?.string ?? ""
    }
}
