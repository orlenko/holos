import Foundation
import HolosCore

extension HolosPaths {
    /// `<supportRoot>/Models`: downloaded model folders (docs/meeting-design.md §2.2). Honours `HOLOS_SUPPORT_DIR`
    /// through `supportRoot`, so tests never touch the user's real Application Support folder.
    public static var models: URL {
        models(supportRoot: supportRoot)
    }

    static func models(supportRoot: URL) -> URL {
        supportRoot.appendingPathComponent("Models", isDirectory: true)
    }
}
