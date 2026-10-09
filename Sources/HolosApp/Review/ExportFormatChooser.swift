import AppKit
import HolosSpeakers
import UniformTypeIdentifiers

/// Keeps the save panel's extension in step with the chosen export format.
@MainActor
final class ExportFormatChooser: NSObject {
    private weak var panel: NSSavePanel?
    private weak var popup: NSPopUpButton?

    init(panel: NSSavePanel, popup: NSPopUpButton) {
        self.panel = panel
        self.popup = popup
    }

    static func format(at index: Int) -> ExportFormat {
        switch index {
        case 1: .txt
        case 2: .json
        default: .md
        }
    }

    @objc func changed() {
        guard let panel, let popup else { return }
        let format = Self.format(at: popup.indexOfSelectedItem)
        let type: UTType = switch format {
        case .txt: .plainText
        case .json: .json
        case .md: UTType(filenameExtension: "md") ?? .plainText
        }
        panel.allowedContentTypes = [type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + format.rawValue
    }
}
