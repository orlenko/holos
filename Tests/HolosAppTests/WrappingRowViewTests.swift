import AppKit
import Testing
@testable import HolosApp

@MainActor
struct WrappingRowViewTests {
    @Test func constrainedControlsReserveTheirFittingWidthsBeforeWrapping() {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let label = NSTextField(labelWithString: "")
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let preferred = label.widthAnchor.constraint(equalToConstant: 220)
        preferred.priority = .defaultLow
        preferred.isActive = true
        let row = WrappingRowView(views: [slider, label])
        row.frame = .init(x: 0, y: 0, width: 280, height: 100)
        row.layoutSubtreeIfNeeded()
        #expect(slider.frame.width == 160)
        #expect(label.frame.width >= 140)
        #expect(label.frame.minY >= slider.frame.maxY + row.rowSpacing)
        #expect(label.frame.maxX <= row.bounds.width)
        #expect(MainWindowNarrowTests.brokenConstraints(in: row).isEmpty)
    }
}
