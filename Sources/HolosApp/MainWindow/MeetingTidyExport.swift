import AppKit
import HolosCore
import HolosStorage
import UniformTypeIdentifiers

@MainActor
enum MeetingTidyExport {
    static func save(_ text: String, title: String, in window: NSWindow,
                     report: @escaping @MainActor (String) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = String(title.replacingOccurrences(of: "/", with: "-").prefix(100)) + " — Tidied.txt"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached {
                        let folder = destination.deletingLastPathComponent().resolvingSymlinksInPath()
                        guard !folder.pathComponents.contains(where: SessionPaths.isSessionFolderName) else {
                            throw HolosError.invalidInput("Save the tidied copy outside the meeting folder.")
                        }
                        let target = folder.appendingPathComponent(destination.lastPathComponent)
                        try AtomicFile.write(Data(text.utf8), to: target, permissions: 0o600)
                    }.value
                    report("Saved the tidied transcript.")
                } catch {
                    report(error.localizedDescription)
                }
            }
        }
    }
}
