import AppKit
import HolosCore
import HolosMeeting

extension HolosAppDelegate {
    func compareRecognition(_ summary: SessionSummary, in window: NSWindow) {
        guard let commands = meeting.commands, let controller = meeting.controller else {
            window.presentError(HolosError.unavailable("The meeting helper is unavailable."))
            return
        }
        let choice = NSAlert()
        choice.messageText = "Compare recognition for \(summary.displayTitle)?"
        choice.informativeText = "Parakeet Ultra reads saved audio on this Mac and shows its words alongside the current transcript. The optional model download is about 632 MB."
        choice.addButton(withTitle: "Compare")
        choice.addButton(withTitle: "Download & Compare")
        choice.addButton(withTitle: "Cancel")
        choice.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            guard controller.beginUsing(summary.id, for: "Comparing recognition…") else {
                window.presentError(HolosError.unavailable("The meeting is busy. Try again when its current task finishes."))
                return
            }
            let download = response == .alertSecondButtonReturn
            let progress = NSAlert()
            progress.messageText = download ? "Preparing Parakeet Ultra…" : "Comparing recognition…"
            progress.informativeText = summary.displayTitle
            progress.addButton(withTitle: "Cancel")
            let task = Task {
                defer { controller.endUsing(summary.id) }
                do {
                    if download {
                        let setup = try await commands.run(["setup", "--parakeet"], output: "out", errors: "err",
                                                           maxOutputBytes: 4096, decode: { _ in true })
                        try Task.checkCancellation()
                        guard setup.code == 0 else {
                            throw HolosError.unavailable(setup.lastErrorLine ?? "Could not install Parakeet Ultra.")
                        }
                        progress.messageText = "Comparing recognition…"
                    }
                    let result = try await commands.run(
                        ["session", "compare-recognition", summary.directory.path, "--json"], output: "json", errors: "err",
                        maxOutputBytes: 32 << 20, as: SessionCompareRecognitionCommand.Outcome.self)
                    try Task.checkCancellation()
                    guard result.code == 0, let comparison = result.outcome else {
                        throw HolosError.unavailable(result.lastErrorLine ?? "Could not read the recognition comparison.")
                    }
                    window.endSheet(progress.window, returnCode: .OK)
                    Self.showComparison(comparison, name: summary.displayTitle, in: window)
                } catch {
                    if progress.window.sheetParent != nil { window.endSheet(progress.window, returnCode: .OK) }
                    if !Task.isCancelled { window.presentError(error) }
                }
            }
            progress.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { task.cancel() } }
        }
    }

    private static func showComparison(_ outcome: SessionCompareRecognitionCommand.Outcome, name: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = name
        alert.addButton(withTitle: "Done")
        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.spacing = 12
        for (title, text) in [("Current transcript", outcome.current ?? "No current transcript."),
                              ("Parakeet Ultra", outcome.candidate)] {
            let scroll = NSTextView.scrollableTextView()
            let view = scroll.documentView as? NSTextView
            view?.isEditable = false
            view?.font = .systemFont(ofSize: NSFont.systemFontSize)
            view?.string = text
            view?.setAccessibilityLabel(title)
            let column = NSStackView(views: [NSTextField(labelWithString: title), scroll])
            column.orientation = .vertical
            column.alignment = .leading
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 326).isActive = true
            columns.addArrangedSubview(column)
        }
        columns.frame.size = NSSize(width: min(760, window.frame.width * 0.8), height: 360)
        alert.accessoryView = columns
        alert.beginSheetModal(for: window)
    }
}
