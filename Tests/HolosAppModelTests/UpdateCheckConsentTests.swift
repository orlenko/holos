import Testing
@testable import HolosAppModel

@Test func theFirstLaunchWaitsAndTheNextOneAsks() {
    #expect(UpdateCheckConsent.launch(answer: nil, launchedBefore: false) == .wait)
    #expect(UpdateCheckConsent.launch(answer: nil, launchedBefore: true) == .ask)
}

@Test func anAnswerIsNeverAskedAgain() {
    // Settings can answer before the question comes, on the first launch too.
    for launchedBefore in [false, true] {
        #expect(UpdateCheckConsent.launch(answer: true, launchedBefore: launchedBefore) == .answered(automatic: true))
        #expect(UpdateCheckConsent.launch(answer: false, launchedBefore: launchedBefore)
            == .answered(automatic: false))
    }
}

@Test func theAnswerIsSparklesOwnKey() {
    // Sparkle reads and writes this key itself; a different one would leave its checks unaffected by the answer.
    #expect(UpdateCheckConsent.automaticChecksKey == "SUEnableAutomaticChecks")
}
