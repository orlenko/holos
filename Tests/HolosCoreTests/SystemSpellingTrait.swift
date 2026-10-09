import HolosCore
import HolosSpelling
import Testing

/// Installs the system spell checker (`SystemSpellChecker`), as the app and `voiceislocal` do at launch. It stays
/// installed for the rest of the test run.
func installSystemSpelling() {
    SystemSpelling.install(SystemSpellChecker())
}

/// `.systemSpelling`: the test judges words with the system spell checker (`Lexicon`, `DictationSeams`), so it runs
/// with it installed. A test without the trait passes with or without it.
struct SystemSpellingTrait: TestTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        installSystemSpelling()
        try await function()
    }
}

extension Trait where Self == SystemSpellingTrait {
    static var systemSpelling: Self { Self() }
}
