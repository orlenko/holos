import Foundation
import Testing
@testable import HolosCore

@Test func supportRootHonoursEnvironment() async {
    // The variable is set in a child process's own environment, so the environment this process shares with
    // tests running in parallel is never changed.
    await #expect(processExitsWith: .success) {
        let folder = "/private/tmp/holos-support-root-test"
        guard setenv("HOLOS_SUPPORT_DIR", folder, 1) == 0, HolosPaths.supportRoot.path == folder else { exit(1) }
        guard setenv("HOLOS_SUPPORT_DIR", "", 1) == 0,
              HolosPaths.supportRoot == HolosPaths.applicationSupport else { exit(2) }
        guard unsetenv("HOLOS_SUPPORT_DIR") == 0,
              HolosPaths.supportRoot == HolosPaths.applicationSupport else { exit(3) }
    }

    #expect(HolosPaths.supportRoot(environment: ["HOLOS_SUPPORT_DIR": "~/holos-support"]).path ==
            ("~/holos-support" as NSString).expandingTildeInPath)
    #expect(HolosPaths.supportRoot(environment: [:]) == HolosPaths.applicationSupport)
    // scripts/test.sh points the suite at a temporary folder; the real Application Support folder stays untouched.
    if let value = ProcessInfo.processInfo.environment["HOLOS_SUPPORT_DIR"], !value.isEmpty {
        #expect(HolosPaths.supportRoot.standardizedFileURL.path ==
                URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path)
        #expect(HolosPaths.supportRoot.standardizedFileURL != HolosPaths.applicationSupport.standardizedFileURL)
    }
}
