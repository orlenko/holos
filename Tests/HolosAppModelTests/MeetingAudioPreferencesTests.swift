import Foundation
import HolosAppModel
import Testing

struct MeetingAudioPreferencesTests {
    private static func preferences() throws -> (MeetingAudioPreferences, UserDefaults, String) {
        let suite = "holos-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (MeetingAudioPreferences(defaults: defaults), defaults, suite)
    }

    @Test func theCleanupIsOffWithSevenDaysPreset() throws {
        let (preferences, defaults, suite) = try Self.preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!preferences.cleansUp)
        #expect(preferences.cleanupDays == 7)
        #expect(preferences.cleanupAfterDays == nil)
        preferences.cleansUp = true
        #expect(preferences.cleanupAfterDays == 7)
    }

    @Test func theDaysStayWithinTheRange() throws {
        let (preferences, defaults, suite) = try Self.preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.cleanupDays = 0
        #expect(preferences.cleanupDays == 1)
        preferences.cleanupDays = 10_000
        #expect(preferences.cleanupDays == 365)
        defaults.set(-3, forKey: MeetingAudioPreferences.cleanupDaysKey)
        #expect(preferences.cleanupDays == 1, "A value written elsewhere is read within the range.")
    }
}
