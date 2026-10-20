import HolosDictation
import Testing

@Test func wakeRestoresAnEnabledChoiceOnce() {
    var policy = DictationSessionPolicy()
    policy.suspend(for: .sleep, wasEnabled: true)
    #expect(policy.suspended)
    #expect(!policy.allowsSetupEnable(deferred: true))
    #expect(!policy.allowsSetupEnable(deferred: false))
    let resumed1 = policy.resume(from: .sleep)
    #expect(resumed1)
    #expect(!policy.suspended)
    let resumed2 = policy.resume(from: .sleep)
    #expect(!resumed2, "Repeated wake notifications do not enable again.")
}

@Test func aDisabledChoiceStaysOffAfterSleep() {
    var policy = DictationSessionPolicy()
    policy.suspend(for: .sleep, wasEnabled: false)
    let resumed3 = policy.resume(from: .sleep)
    #expect(!resumed3)
    #expect(!policy.suspended)
}

@Test(arguments: [true, false])
func sleepAndSessionChangesWaitForBothReturns(wakeFirst: Bool) {
    var policy = DictationSessionPolicy()
    policy.suspend(for: .sleep, wasEnabled: true)
    policy.suspend(for: .inactiveSession, wasEnabled: false)
    policy.suspend(for: .sleep, wasEnabled: false)
    let first: DictationSessionPolicy.Interruption = wakeFirst ? .sleep : .inactiveSession
    let last: DictationSessionPolicy.Interruption = wakeFirst ? .inactiveSession : .sleep
    let resumed4 = policy.resume(from: first)
    #expect(!resumed4)
    #expect(policy.suspended)
    #expect(!policy.allowsSetupEnable(deferred: true))
    let resumed5 = policy.resume(from: last)
    #expect(resumed5)
    #expect(!policy.suspended)
}

@Test func anExplicitOffChoiceCancelsTheRestoreRequest() {
    var policy = DictationSessionPolicy()
    policy.suspend(for: .inactiveSession, wasEnabled: true)
    policy.didDisable()
    policy.suspend(for: .sleep, wasEnabled: false)
    let resumed6 = policy.resume(from: .sleep)
    #expect(!resumed6)
    let resumed7 = policy.resume(from: .inactiveSession)
    #expect(!resumed7)
    #expect(!policy.suspended)
    let resumed8 = policy.resume(from: .inactiveSession)
    #expect(!resumed8)
}

@Test func anUnmatchedReturnCannotChangeAnActiveSession() {
    var policy = DictationSessionPolicy()
    let resumed9 = policy.resume(from: .sleep)
    #expect(!resumed9)
    let resumed10 = policy.resume(from: .inactiveSession)
    #expect(!resumed10)
    #expect(policy.allowsSetupEnable(deferred: true))
}

@Test func deferredSetupCanRetryAfterTheFinalReturnWithoutAReadyHotkey() {
    var policy = DictationSessionPolicy()
    policy.suspend(for: .sleep, wasEnabled: false)
    policy.suspend(for: .inactiveSession, wasEnabled: false)
    let woke = policy.resume(from: .sleep)
    #expect(!woke)
    #expect(!policy.allowsSetupEnable(deferred: true))
    let returned = policy.resume(from: .inactiveSession)
    #expect(!returned, "There was no ready hotkey to restore.")
    #expect(policy.allowsSetupEnable(deferred: true), "Return must retry the pending model-install enable separately.")
}
