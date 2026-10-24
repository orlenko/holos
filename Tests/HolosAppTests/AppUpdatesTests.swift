import AppKit
import Foundation
import HolosAppModel
import Testing
@testable import HolosApp

/// In-app updates (`AppUpdates`): what each launch does before the user answers. None of these starts Sparkle, which
/// would look for updates to the test runner.
@MainActor
struct AppUpdatesTests {
    /// A bundle with only an Info.plist, with the update keys or without them.
    private static func bundle(feed: Bool) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdatesTest-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("Test.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "ca.orlenko.holos.updates-test", "CFBundlePackageType": "APPL"]
        if feed {
            info["SUFeedURL"] = "https://voiceislocal.com/downloads/appcast.xml"
            info["SUPublicEDKey"] = "Rudq/cCOJ+qirxsmdeEgQ4bfS2gbx0diVv0D8YFp3KE="
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return (try #require(Bundle(url: root.appendingPathComponent("Test.app"))), root)
    }

    @Test func aLocalBuildNeverOffersUpdates() throws {
        let suite = "VoiceIsLocalUpdatesTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (bundle, root) = try Self.bundle(feed: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let updates = AppUpdates(bundle: bundle, defaults: defaults)
        #expect(!updates.available)
        #expect(!updates.launch())
        #expect(!updates.launch())
        updates.checkNow()
        #expect(!updates.started)
        #expect(defaults.object(forKey: UpdateCheckConsent.launchedBeforeKey) == nil)
    }

    @Test func theSecondLaunchAsksAndNothingStartsBeforeTheAnswer() throws {
        let suite = "VoiceIsLocalUpdatesTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (bundle, root) = try Self.bundle(feed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AppUpdates(bundle: bundle, defaults: defaults).available)
        let first = AppUpdates(bundle: bundle, defaults: defaults)
        #expect(!first.launch())
        #expect(!first.started)
        let second = AppUpdates(bundle: bundle, defaults: defaults)
        #expect(second.launch())
        #expect(!second.started)
        #expect(!second.checksAutomatically)
        // No: saved as Sparkle's own setting, and never asked again.
        second.setChecksAutomatically(false)
        #expect(defaults.object(forKey: UpdateCheckConsent.automaticChecksKey) as? Bool == false)
        #expect(!second.started)
        let third = AppUpdates(bundle: bundle, defaults: defaults)
        #expect(!third.launch())
        #expect(!third.started)
    }
}
