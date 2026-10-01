// Compile with the UI-only component; renders synthetic controls without launching Holos or capturing a screen:
// swiftc -parse-as-library Sources/HolosApp/MeetingScreenChoiceView.swift scripts/preview-screen-choice.swift -o <temp>/preview
// <temp>/preview <temp>/images
import AppKit

@main struct ScreenChoicePreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            for enabled in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                NSApplication.shared.appearance = appearance
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 250),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = appearance
                let view = MeetingScreenChoiceView()
                view.reset(enabled: enabled)
                view.setWindows([.init(id: 1, owner: 1, title: "Synthetic Meeting App — Invented slides")])
                view.frame = NSRect(x: 20, y: 20, width: 440, height: 210)
                window.contentView!.addSubview(view)
                window.contentView!.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 500,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                appearance.performAsCurrentDrawingAppearance {
                    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = graphics
                    graphics.cgContext.scaleBy(x: 2, y: 2)
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(x: 0, y: 0, width: 480, height: 250).fill()
                    window.contentView!.displayIgnoringOpacity(NSRect(x: 0, y: 0, width: 480, height: 250), in: graphics)
                    NSGraphicsContext.restoreGraphicsState()
                }
                let data = bitmap.representation(using: .png, properties: [:])!
                try data.write(to: folder.appendingPathComponent("screen-\(dark ? "dark" : "light")-\(enabled ? "on" : "off").png"))
            }
        }
    }
}
