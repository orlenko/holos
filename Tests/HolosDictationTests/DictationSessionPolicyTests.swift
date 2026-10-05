import HolosDictation
import Testing

@Test func deferredSetupCompletionCannotEndSessionSuspension() {
    var policy = DictationSessionPolicy()
    #expect(policy.allowsSetupEnable(deferred: true))
    // A model download starts, then sleep/session resign disables the hotkey.
    policy.suspend()
    #expect(!policy.allowsSetupEnable(deferred: true))
    #expect(policy.suspended, "Download completion must not clear suspension.")
    // Meeting resume/save has no operation in this policy.
    #expect(!policy.allowsSetupEnable(deferred: true))
    // An explicit enable choice is allowed, but clears suspension only when enabling succeeds.
    #expect(policy.allowsSetupEnable(deferred: false))
    #expect(policy.suspended)
    policy.didEnable()
    #expect(!policy.suspended && policy.allowsSetupEnable(deferred: true))
    policy.suspend()
    #expect(!policy.allowsSetupEnable(deferred: true))
}
