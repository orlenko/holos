// Compile with the UI-only component; renders synthetic controls without launching Holos or capturing a screen:
// swiftc -parse-as-library Sources/HolosApp/MeetingScreenChoiceView.swift scripts/preview-screen-choice.swift -o <temp>/preview
// <temp>/preview <temp>/images
// Writes settings-{light,dark}.png (Settings › Meetings' screen row, styled like SettingsPane's checkbox and note)
// and panel-{light,dark}-{on,off,denied}.png (the start panel's "Screen" row).
import AppKit

@main struct ScreenChoicePreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let mode = dark ? "dark" : "light"
            try render(settingsRow(), size: NSSize(width: 640, height: 150), appearance: appearance,
                       to: folder.appendingPathComponent("settings-\(mode).png"))
            for (name, enabled, allowed) in [("on", true, true), ("off", false, true), ("denied", true, false)] {
                let choice = MeetingScreenChoiceView()
                choice.reset(enabled: enabled, allowed: allowed)
                try render(panelRow(choice), size: NSSize(width: 460, height: 90), appearance: appearance,
                           to: folder.appendingPathComponent("panel-\(mode)-\(name).png"))
            }
        }
    }

    /// As SettingsPane's Meetings card lays it out: the checkbox, then an 11-point secondary note 560 wide.
    @MainActor static func settingsRow() -> NSView {
        let toggle = NSButton(checkboxWithTitle: MeetingScreenText.settingTitle, target: nil, action: nil)
        toggle.state = .on
        let note = NSTextField(wrappingLabelWithString: MeetingScreenText.settingCaption)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 560
        note.widthAnchor.constraint(equalToConstant: 560).isActive = true
        let stack = NSStackView(views: [toggle, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    /// As MeetingStartPanel's grid shows it: a trailing semibold "Screen" title beside the choice.
    @MainActor static func panelRow(_ choice: NSView) -> NSView {
        let title = NSTextField(labelWithString: "Screen")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let grid = NSGridView(views: [[title, choice]])
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 80
        grid.row(at: 0).rowAlignment = .firstBaseline
        return grid
    }

    @MainActor static func render(_ view: NSView, size: NSSize, appearance: NSAppearance, to url: URL) throws {
        NSApplication.shared.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        view.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2,
            pixelsHigh: Int(size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        appearance.performAsCurrentDrawingAppearance {
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            graphics.cgContext.scaleBy(x: 2, y: 2)
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            content.displayIgnoringOpacity(NSRect(origin: .zero, size: size), in: graphics)
            NSGraphicsContext.restoreGraphicsState()
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
