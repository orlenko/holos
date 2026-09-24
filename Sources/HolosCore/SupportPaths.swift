import Foundation

extension HolosPaths {
    /// Root for Holos's Application Support files (speaker models, voice profiles):
    /// `$HOLOS_SUPPORT_DIR` when it is set and non-empty, else `applicationSupport`.
    /// Tests run with it pointing at a temporary folder (`scripts/test.sh`), so the suite never
    /// writes under the user's real Application Support folder.
    public static var supportRoot: URL {
        supportRoot(environment: ProcessInfo.processInfo.environment)
    }

    static func supportRoot(environment: [String: String]) -> URL {
        if let path = environment["HOLOS_SUPPORT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return applicationSupport
    }
}
