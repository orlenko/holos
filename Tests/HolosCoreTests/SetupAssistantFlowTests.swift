import Testing
@testable import HolosCore

private let granted = SetupAssistantFacts(microphone: "authorized", accessibility: true, speechModel: "supported",
                                          speakerModels: "notInstalled")

private func state(_ items: [SetupAssistantItem], _ kind: SetupAssistantItem.Kind) -> SetupAssistantItem.State? {
    items.first { $0.kind == kind }?.state
}

// MARK: - Launch

@Test func aFreshInstallShowsTheAssistant() {
    #expect(SetupAssistantFlow.launch(done: nil, awaitingReopenCheck: false, dictationEnabled: false,
                                      microphoneGranted: false, accessibility: false) == .assistant)
    // Only one of the two permissions is not an existing install.
    #expect(SetupAssistantFlow.launch(done: nil, awaitingReopenCheck: false, dictationEnabled: false,
                                      microphoneGranted: true, accessibility: false) == .assistant)
}

@Test func anInstallSetUpBeforeTheAssistantIsMarkedDoneSilently() {
    #expect(SetupAssistantFlow.launch(done: nil, awaitingReopenCheck: false, dictationEnabled: true,
                                      microphoneGranted: false, accessibility: false) == .markDone)
    #expect(SetupAssistantFlow.launch(done: nil, awaitingReopenCheck: false, dictationEnabled: false,
                                      microphoneGranted: true, accessibility: true) == .markDone)
}

@Test func anUnfinishedAssistantShowsAgainAndAFinishedOneNever() {
    // Started on an earlier launch (the key is false) and closed midway: shown again, even with permissions granted.
    #expect(SetupAssistantFlow.launch(done: false, awaitingReopenCheck: false, dictationEnabled: true,
                                      microphoneGranted: true, accessibility: true) == .assistant)
    #expect(SetupAssistantFlow.launch(done: true, awaitingReopenCheck: false, dictationEnabled: false,
                                      microphoneGranted: false, accessibility: false) == .normal)
}

@Test func theLaunchAfterTheAssistantsReopenShowsTheCheck() {
    #expect(SetupAssistantFlow.launch(done: true, awaitingReopenCheck: true, dictationEnabled: true,
                                      microphoneGranted: true, accessibility: true) == .verify)
}

// MARK: - Pages

@Test func thePagesComeInOrder() {
    var flow = SetupAssistantFlow()
    #expect(flow.step == .welcome)
    flow.start()
    #expect(flow.step == .basics)
    flow.next(granted)
    #expect(flow.step == .accessibility)
    flow.next(granted)
    #expect(flow.step == .reopen)  // system audio is not granted
    flow.next(granted)
    #expect(flow.step == .finish)
    flow.next(granted)
    #expect(flow.step == .finish)
}

@Test func basicsNeedsTheMicrophoneAndAKnownLanguage() {
    var flow = SetupAssistantFlow()
    flow.start()
    var facts = granted
    facts.microphone = "notDetermined"
    #expect(!flow.canContinue(facts))
    #expect(flow.offersContinueWithout(facts))
    #expect(flow.next(facts).isEmpty)
    #expect(flow.step == .basics)
    facts.microphone = "authorized"
    facts.languageKnown = false
    #expect(!flow.canContinue(facts))
    #expect(!flow.offersContinueWithout(facts))  // the language is settled first either way
    facts.languageKnown = true
    #expect(flow.canContinue(facts))
    #expect(!flow.offersContinueWithout(facts))
}

@Test func leavingBasicsStartsTheDownloads() {
    var flow = SetupAssistantFlow()
    flow.start()
    #expect(flow.next(granted) == [.installSpeechModel, .installSpeakerModels])
    #expect(flow.startedInstalls)

    // Nothing to download: installed already, or already downloading.
    var other = SetupAssistantFlow()
    other.start()
    var facts = granted
    facts.speechModel = "installed"
    facts.speakerModels = "verified"
    #expect(other.next(facts).isEmpty)
    other.back(facts)
    facts.speechModel = "supported"
    facts.installingSpeechModel = true
    facts.speakerModels = "installing"
    #expect(other.next(facts).isEmpty)
}

@Test func withoutMeetingsTheSpeakerModelsAndSystemAudioAreLeftOut() {
    var flow = SetupAssistantFlow()
    flow.start()
    flow.setUpMeetings = false
    #expect(flow.next(granted) == [.installSpeechModel])
    #expect(!flow.offersSystemAudio(granted))
    flow.next(granted)
    #expect(flow.step == .finish)  // nothing needs a reopen
}

@Test func continuingWithoutMicrophoneStillDownloads() {
    var flow = SetupAssistantFlow()
    flow.start()
    var facts = granted
    facts.microphone = "denied"
    #expect(flow.next(facts, without: true) == [.installSpeechModel, .installSpeakerModels])
    #expect(flow.continuedWithoutMicrophone)
    #expect(flow.step == .accessibility)
}

@Test func accessibilityGatesNextUnlessContinuedWithout() {
    var flow = SetupAssistantFlow()
    flow.start()
    flow.next(granted)
    var facts = granted
    facts.accessibility = false
    #expect(!flow.canContinue(facts))
    flow.next(facts)
    #expect(flow.step == .accessibility)
    #expect(flow.offersContinueWithout(facts))
    flow.next(facts, without: true)
    #expect(flow.continuedWithoutAccessibility)
    #expect(flow.step == .reopen)

    var live = SetupAssistantFlow()
    live.start()
    live.next(granted)
    #expect(live.canContinue(granted))  // the poll saw it switched on
    #expect(!live.offersContinueWithout(granted))
}

@Test func theReopenPageIsPassedOverWhenNothingOnItIsNeeded() {
    var facts = granted
    facts.systemAudio = true
    var flow = SetupAssistantFlow()
    flow.start()
    flow.next(facts)
    flow.next(facts)
    #expect(flow.step == .finish)
    flow.back(facts)
    #expect(flow.step == .accessibility)
}

@Test func inputMonitoringJoinsTheReopenPageOnlyWhenTheTapWasRefused() {
    var facts = granted
    facts.systemAudio = true
    var flow = SetupAssistantFlow()
    #expect(!flow.offersInputMonitoring(facts))
    facts.inputMonitoringNeeded = true
    #expect(flow.offersInputMonitoring(facts))
    flow.start()
    flow.next(facts)
    flow.next(facts)
    #expect(flow.step == .reopen)
    facts.inputMonitoring = true
    #expect(!flow.offersInputMonitoring(facts))
}

@Test func theReopenPageSkipsUntilSomethingIsRequested() {
    var flow = SetupAssistantFlow()
    flow.start()
    flow.next(granted)
    flow.next(granted)
    #expect(flow.step == .reopen)
    #expect(flow.canContinue(granted))  // optional
    #expect(flow.continueSkips(granted))
    #expect(!flow.reopenNeeded)
    flow.requestedSystemAudioSettings()
    #expect(!flow.continueSkips(granted))
    #expect(flow.reopenNeeded)
    flow.next(granted)
    #expect(flow.step == .finish)
    // Back returns to the page it was requested on, even if the system now reports it granted.
    var facts = granted
    facts.systemAudio = true
    flow.back(facts)
    #expect(flow.step == .reopen)
}

@Test func reopeningIsNeededOnlyForARequestThisRun() {
    var flow = SetupAssistantFlow()
    #expect(!flow.reopenNeeded)
    flow.requestedInputMonitoringSettings()
    #expect(flow.reopenNeeded)
}

@Test func backWalksThePagesInReverse() {
    var flow = SetupAssistantFlow()
    flow.start()
    flow.next(granted)
    flow.next(granted)
    flow.next(granted)
    #expect(flow.step == .finish)
    flow.back(granted)
    #expect(flow.step == .reopen)
    flow.back(granted)
    #expect(flow.step == .accessibility)
    flow.back(granted)
    #expect(flow.step == .basics)
    flow.back(granted)
    #expect(flow.step == .welcome)
    flow.back(granted)
    #expect(flow.step == .welcome)
}

// MARK: - Finish

@Test func dictationTurnsOnWhenMicrophoneAccessibilityAndTheModelAllow() {
    var facts = granted
    facts.speechModel = "installed"
    #expect(SetupAssistantFlow().enable(facts) == .now)
    facts.speechModel = "supported"
    #expect(SetupAssistantFlow().enable(facts) == .afterSpeechModelInstall)
    facts.speechModel = "downloading"
    #expect(SetupAssistantFlow().enable(facts) == .afterSpeechModelInstall)
    facts.speechModel = "unsupported"
    #expect(SetupAssistantFlow().enable(facts) == .notPossible)
    facts.speechModel = "installed"
    facts.accessibility = false
    #expect(SetupAssistantFlow().enable(facts) == .notPossible)
    facts.accessibility = true
    facts.microphone = "denied"
    #expect(SetupAssistantFlow().enable(facts) == .notPossible)
    facts.dictationEnabled = true
    #expect(SetupAssistantFlow().enable(facts) == .alreadyOn)
}

@Test func requiredInputMonitoringIsAnEnablePrerequisite() {
    var facts = granted
    facts.speechModel = "installed"
    facts.inputMonitoringNeeded = true
    // The tap was refused and Input Monitoring is not allowed; the Reopen page was skipped: enabling would be refused.
    let skipped = SetupAssistantFlow()
    #expect(skipped.enable(facts) == .notPossible)
    let items = skipped.checklist(facts, verify: false, language: "English", shortcut: "Right Option")
    #expect(state(items, .inputMonitoring) == .missing)
    #expect(state(items, .dictation) == .missing)
    #expect(items.first { $0.kind == .dictation }?.detail.contains("Input Monitoring") == true)
    facts.speechModel = "supported"
    #expect(skipped.enable(facts) == .notPossible)  // not deferred to an install that could not turn it on

    // Allowed: required, and there.
    facts.speechModel = "installed"
    facts.inputMonitoring = true
    #expect(skipped.enable(facts) == .now)
    // Not needed on this Mac: ignored, granted or not.
    facts.inputMonitoringNeeded = false
    facts.inputMonitoring = false
    #expect(skipped.enable(facts) == .now)
}

@Test func inputMonitoringRequestedThisRunDefersEnablingToTheReopen() {
    var facts = granted
    facts.speechModel = "installed"
    facts.inputMonitoringNeeded = true
    var flow = SetupAssistantFlow()
    flow.requestedInputMonitoringSettings()
    #expect(flow.reopenNeeded)
    #expect(flow.enable(facts) == .afterReopen)
    let items = flow.checklist(facts, verify: false, language: "English", shortcut: "Right Option")
    #expect(state(items, .inputMonitoring) == .waiting)
    #expect(state(items, .dictation) == .waiting)
    // Still downloading: the install resumes after the reopen and enabling follows it.
    facts.speechModel = "downloading"
    #expect(flow.enable(facts) == .afterSpeechModelInstall)
    // Applied before the reopen: nothing left to wait for.
    facts.speechModel = "installed"
    facts.inputMonitoring = true
    #expect(flow.enable(facts) == .now)

    // The check after the reopen (a new run) reports the real outcome: still not allowed is missing.
    facts.inputMonitoring = false
    let check = SetupAssistantFlow().checklist(facts, verify: true, language: "English", shortcut: "Right Option")
    #expect(state(check, .inputMonitoring) == .missing)
    #expect(state(check, .dictation) == .missing)
}

@Test func aLaunchResumesWhatTheAssistantStartedOrDeferred() {
    // Finished while the speech model downloaded, then reopened: the install resumes and dictation follows it.
    #expect(SetupAssistantFlow.resumeAtLaunch(enableAfterSpeechModel: true, speakerModelsPending: false,
                                              dictationEnabled: false) == [.installSpeechModel])
    // The speaker models the assistant asked for had not finished.
    #expect(SetupAssistantFlow.resumeAtLaunch(enableAfterSpeechModel: false, speakerModelsPending: true,
                                              dictationEnabled: false) == [.installSpeakerModels])
    #expect(SetupAssistantFlow.resumeAtLaunch(enableAfterSpeechModel: true, speakerModelsPending: true,
                                              dictationEnabled: false) == [.installSpeechModel, .installSpeakerModels])
    // Dictation is on already: nothing waits for the speech model.
    #expect(SetupAssistantFlow.resumeAtLaunch(enableAfterSpeechModel: true, speakerModelsPending: false,
                                              dictationEnabled: true).isEmpty)
    #expect(SetupAssistantFlow.resumeAtLaunch(enableAfterSpeechModel: false, speakerModelsPending: false,
                                              dictationEnabled: false).isEmpty)
}

@Test func theCheckAfterReopeningSaysADeferredEnableFollowsTheResumedDownload() {
    var facts = granted
    facts.installingSpeechModel = true
    let check = SetupAssistantFlow().checklist(facts, verify: true, language: "English", shortcut: "Right Option")
    #expect(state(check, .dictation) == .waiting)
    #expect(check.first { $0.kind == .dictation }?.detail == "Turns on once the speech model is installed")
}

@Test func theFinishPageListsWhatIsDoneAndWhatIsNot() {
    var flow = SetupAssistantFlow()
    flow.start()
    flow.next(granted)
    flow.requestedSystemAudioSettings()
    var facts = granted
    facts.installingSpeechModel = true
    facts.speakerModels = "installing"
    let items = flow.checklist(facts, verify: false, language: "French (Canada)", shortcut: "Right Option")
    #expect(items.map(\.kind) == [.microphone, .accessibility, .speechModel, .speakerModels, .systemAudio, .dictation])
    #expect(state(items, .microphone) == .done)
    #expect(state(items, .accessibility) == .done)
    #expect(state(items, .speechModel) == .waiting)
    #expect(items.first { $0.kind == .speechModel }?.detail.hasPrefix("French (Canada)") == true)
    #expect(state(items, .speakerModels) == .waiting)
    #expect(state(items, .systemAudio) == .waiting)  // requested; takes effect after the reopen
    #expect(state(items, .dictation) == .waiting)    // turns on once the model is installed
}

@Test func aFailedSpeakerInstallIsMissingOnFinishButOptionalInTheCheck() {
    var flow = SetupAssistantFlow()
    flow.start()
    flow.next(granted)
    let finish = flow.checklist(granted, verify: false, language: "English", shortcut: "Right Option")
    #expect(state(finish, .speakerModels) == .missing)
    #expect(state(finish, .systemAudio) == .off)  // not requested: meetings record the microphone only
    let check = SetupAssistantFlow().checklist(granted, verify: true, language: "English", shortcut: "Right Option")
    #expect(state(check, .speakerModels) == .off)
}

@Test func theCheckAfterReopeningShowsTheRealState() {
    var facts = granted
    facts.speechModel = "installed"
    facts.speakerModels = "verified"
    facts.systemAudio = true
    facts.dictationEnabled = true
    let flow = SetupAssistantFlow()
    let items = flow.checklist(facts, verify: true, language: "English", shortcut: "Right Option")
    #expect(items.allSatisfy { $0.state == .done })
    #expect(!items.contains { $0.kind == .inputMonitoring })

    // System audio still off after the reopen: reported as off, not as waiting for a reopen.
    facts.systemAudio = false
    facts.inputMonitoringNeeded = true
    let check = flow.checklist(facts, verify: true, language: "English", shortcut: "Right Option")
    #expect(state(check, .systemAudio) == .off)
    #expect(state(check, .inputMonitoring) == .missing)
    facts.inputMonitoring = true
    #expect(state(flow.checklist(facts, verify: true, language: "English", shortcut: "Right Option"),
                  .inputMonitoring) == .done)
}

@Test func missingPermissionsAreMissingInTheList() {
    let facts = SetupAssistantFacts(microphone: "denied", accessibility: false, speechModel: "installed")
    let items = SetupAssistantFlow().checklist(facts, verify: false, language: "English", shortcut: "Right Option")
    #expect(state(items, .microphone) == .missing)
    #expect(state(items, .accessibility) == .missing)
    #expect(state(items, .dictation) == .missing)
}

// MARK: - Reopening

@Test func theReopenCommandPassesThePidAndPathAsArguments() {
    let command = SetupAssistantFlow.reopenCommand(waitingFor: 4242, bundlePath: "/Applications/Voice \"is\" Local.app")
    #expect(command.executable == "/bin/sh")
    #expect(command.arguments.count == 5)
    #expect(command.arguments[0] == "-c")
    #expect(command.arguments[1] == "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"")
    #expect(Array(command.arguments[2...]) == ["sh", "4242", "/Applications/Voice \"is\" Local.app"])
}
