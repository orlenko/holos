import AppKit
import HolosCore
import HolosMeeting

extension ReviewWindow {
    func makeExportMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Export", action: nil, keyEquivalent: ""))
        for (title, action) in [("Save As…", #selector(saveAs)), ("Copy as Markdown", #selector(copyMarkdown)),
                                ("Tidy Transcript…", #selector(tidyTranscript))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func tidyTranscript() {
        perform { [weak self] review in
            guard let self, let app = NSApp.delegate as? HolosAppDelegate else { return }
            guard !review.isWorking, !self.turnList.editingWords else {
                throw HolosError.unavailable("Finish editing and saving words before tidying the transcript.")
            }
            let revision = review.revision
            let snapshot = review.snapshot
            let projection = review.projection
            let input = try await Task.detached {
                var document = snapshot.exportDocument()
                document.projection = projection
                let captured = MeetingTidySnapshot(document: document)
                guard !captured.blocks.isEmpty else {
                    throw HolosError.unavailable("The meeting has no transcript to tidy.")
                }
                return try TidyPane.MeetingInput(snapshot: captured)
            }.value
            guard review.revision == revision, !review.isWorking else {
                throw HolosError.unavailable("The transcript changed. Open Tidy Transcript again for the latest copy.")
            }
            try app.openMeetingTidy(input)
        }
    }
}

extension HolosAppDelegate {
    func openMeetingTidy(_ input: TidyPane.MeetingInput) throws {
        showMainWindow(.tidy)
        guard let pane = mainWindow?.existingController(for: .tidy) as? TidyPane else {
            throw HolosError.unavailable("Tidy Up could not open.")
        }
        try pane.loadMeeting(input)
    }
}
