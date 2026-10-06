import AppKit
import Foundation
import Testing
@testable import HolosApp

/// Separator boxes (`NSBox.hairline`). A separator box has no height of its own under Auto Layout; twice one shipped
/// without a height and took all the height around it in tall windows (Settings, #82; the live transcript, #90).
@MainActor
struct HairlineTests {
    /// Every separator box in the sources is made by `NSBox.hairline()`. Checked on the source, so a separator in a
    /// screen, sheet, or state no layout test reaches is caught too.
    @Test func everySeparatorBoxIsAHairline() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let helper = sources.appendingPathComponent("HolosApp/Hairline.swift").standardizedFileURL.path
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "The sources were found.")
        #expect(files.contains { $0.standardizedFileURL.path == helper })
        var offenders: [String] = []
        for file in files where file.standardizedFileURL.path != helper {
            let text = try String(contentsOf: file, encoding: .utf8)
            offenders += try Self.separatorLines(in: text).map { "\(file.lastPathComponent):\($0)" }
        }
        #expect(offenders.isEmpty, "Make separator boxes with NSBox.hairline(): \(offenders)")
    }

    /// The lines (1-based) where `text` makes a separator box: `boxType = .separator`, `boxType: .separator`,
    /// `NSBox.BoxType.separator`, `BoxType.separator`, matched over the whole text so an assignment split across lines
    /// counts too.
    static func separatorLines(in text: String) throws -> [Int] {
        let pattern = try Regex(#"boxType\s*[:=]\s*(NSBox\.BoxType)?\.separator\b|BoxType\.separator\b"#)
        return text.matches(of: pattern).map { match in
            text[..<match.range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
    }

    @Test func theGuardFindsEverySpellingOfASeparatorBox() throws {
        let text = """
            let a = NSBox()
            a.boxType = .separator
            let b = NSBox()
            b.boxType =
                .separator
            let c = NSBox(); c.boxType = NSBox.BoxType.separator
            let d: NSBox.BoxType = .custom
            """
        #expect(try Self.separatorLines(in: text) == [2, 4, 6])
    }

    /// The hairline stays one point high between two views that have no height of their own, in a tall view, and in a
    /// vertical stack next to a view that hugs less.
    @Test(arguments: [200.0, 1300.0, 1900.0])
    func theHairlineStaysOnePointHigh(height: Double) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        let above = NSView()
        let below = NSView()
        let line = NSBox.hairline()
        for view in [above, line, below] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            above.topAnchor.constraint(equalTo: root.topAnchor),
            above.heightAnchor.constraint(equalToConstant: 40),
            line.topAnchor.constraint(equalTo: above.bottomAnchor),
            below.topAnchor.constraint(equalTo: line.bottomAnchor),
            below.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        #expect(line.boxType == .separator)
        #expect(line.alignmentRect(forFrame: line.frame).height <= 1.5)
        #expect(below.frame.height >= height - 42)

        let stacked = NSBox.hairline()
        let filler = NSView()
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = NSStackView(views: [filler, stacked])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        stack.layoutSubtreeIfNeeded()
        #expect(stacked.alignmentRect(forFrame: stacked.frame).height <= 1.5)
    }
}
