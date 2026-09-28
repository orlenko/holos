import Foundation

/// The Setup Assistant's pages, in order (docs/design.md "First-launch setup"): permissions that need no System
/// Settings first, then the ones System Settings grants without a reopen, then the ones that take effect only after
/// Voice is Local reopens, grouped so the app reopens once, at the end.
public enum SetupAssistantStep: Int, CaseIterable, Comparable, Sendable {
    /// What will be set up; Start, or skip to Settings in the main window.
    case welcome
    /// Dictation language, microphone (macOS's own prompt), and "Also set up meetings".
    case basics
    /// Accessibility, granted in System Settings; takes effect at once.
    case accessibility
    /// Screen & System Audio Recording, and Input Monitoring when the hotkey tap needs it: take effect after a reopen.
    case reopen
    /// Everything re-checked; Done, or Reopen Voice is Local.
    case finish

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the Setup Assistant reads from the system and the app each time it refreshes.
public struct SetupAssistantFacts: Equatable, Sendable {
    /// `AudioCapture.microphonePermission`: "authorized", "notDetermined", "denied", "restricted".
    public var microphone: String
    /// `AXIsProcessTrusted()`, which changes as soon as the user switches Voice is Local on.
    public var accessibility: Bool
    /// The dictation language is known: a saved choice, or the supported languages have loaded.
    public var languageKnown: Bool
    /// The dictation language's speech model: "installed", "supported" (not installed), "downloading",
    /// "unsupported", another status, or nil while it is checked.
    public var speechModel: String?
    /// Voice is Local is installing the speech model.
    public var installingSpeechModel: Bool
    /// As `voiceislocal doctor --json` reports them ("verified", "notInstalled", …), "installing" during the install,
    /// nil before the first check.
    public var speakerModels: String?
    /// `CGPreflightScreenCaptureAccess()`, which usually turns true only after Voice is Local reopens.
    public var systemAudio: Bool
    /// macOS refused the hotkey's event tap although Accessibility is granted, so Input Monitoring is needed too
    /// (`GlobalHotkeyMonitor`); normally false.
    public var inputMonitoringNeeded: Bool
    /// `CGPreflightListenEventAccess()`.
    public var inputMonitoring: Bool
    /// Hold-to-talk dictation is on.
    public var dictationEnabled: Bool

    public init(microphone: String = "notDetermined", accessibility: Bool = false, languageKnown: Bool = true,
                speechModel: String? = nil, installingSpeechModel: Bool = false, speakerModels: String? = nil,
                systemAudio: Bool = false, inputMonitoringNeeded: Bool = false, inputMonitoring: Bool = false,
                dictationEnabled: Bool = false) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.languageKnown = languageKnown
        self.speechModel = speechModel
        self.installingSpeechModel = installingSpeechModel
        self.speakerModels = speakerModels
        self.systemAudio = systemAudio
        self.inputMonitoringNeeded = inputMonitoringNeeded
        self.inputMonitoring = inputMonitoring
        self.dictationEnabled = dictationEnabled
    }

    public var microphoneGranted: Bool { microphone == "authorized" }

    /// The speech model is being downloaded, by Voice is Local or by macOS.
    public var speechModelDownloading: Bool { installingSpeechModel || speechModel == "downloading" }
}

/// Work a page change starts in the background.
public enum SetupAssistantEffect: Equatable, Sendable {
    /// Download and install the dictation language's speech model (the language is settled once Basics is left).
    case installSpeechModel
    /// `voiceislocal setup --speakers`, for meetings' speaker labels.
    case installSpeakerModels
}

/// Whether dictation can be turned on when the assistant finishes.
public enum SetupAssistantEnable: Equatable, Sendable {
    case alreadyOn
    case now
    /// Microphone and Accessibility are granted; dictation turns on once the speech model is installed (after the
    /// reopen too: the install resumes at launch, `SetupAssistantFlow.resumeAtLaunch`).
    case afterSpeechModelInstall
    /// The speech model is installed, and Input Monitoring, which the hotkey needs on this Mac, was requested this run:
    /// it takes effect after the reopen, so the reopened app turns dictation on and its check reports the outcome.
    case afterReopen
    /// Microphone or Accessibility is missing, Input Monitoring is needed and was not requested, or the language has no
    /// speech model on this Mac.
    case notPossible
}

/// What a launch shows.
public enum SetupAssistantLaunch: Equatable, Sendable {
    /// The assistant, from where it was (in memory) or from Welcome.
    case assistant
    /// The one-page check after the assistant reopened Voice is Local.
    case verify
    /// An install set up before the assistant existed: it is marked done without being shown, then `normal`.
    case markDone
    /// Today's behaviour: dictation turns on when it was on, else Settings opens in the main window.
    case normal
}

/// One line of the Finish page and of the check after reopening.
public struct SetupAssistantItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case microphone, accessibility, inputMonitoring, speechModel, speakerModels, systemAudio, dictation
    }

    public enum State: Equatable, Sendable {
        case done
        /// In progress, or takes effect after the reopen.
        case waiting
        /// Needed and not there.
        case missing
        /// Optional and off; meetings still work without it.
        case off
    }

    public let kind: Kind
    public let state: State
    public let detail: String

    public init(_ kind: Kind, _ state: State, _ detail: String) {
        self.kind = kind
        self.state = state
        self.detail = detail
    }
}

/// The Setup Assistant's decisions, free of AppKit so they can be tested: which page comes next, whether Next is
/// enabled, whether the app must reopen, what a launch shows, and what the Finish page and the check after reopening
/// list. The progress lives in memory: closing the window keeps it for this run, and the next launch starts again at
/// Welcome while `setupAssistantDone` is not true.
public struct SetupAssistantFlow: Equatable, Sendable {
    /// UserDefaults key: absent before the assistant ever ran, false once it started, true once finished or skipped.
    public static let doneKey = "setupAssistantDone"
    /// UserDefaults key: the assistant reopened Voice is Local; the next launch shows the check, then clears it.
    public static let awaitingReopenCheckKey = "setupAssistantAwaitingReopenCheck"
    /// UserDefaults key: the assistant finished before the speech model was installed, so dictation turns on once it
    /// is. Kept across a quit and the planned reopen (the launch resumes the install); cleared once dictation is on,
    /// when the install fails, or when the assistant finishes again without deferring.
    public static let enableAfterSpeechModelKey = "setupAssistantEnableAfterSpeechModel"
    /// UserDefaults key: the assistant started the speaker-model install ("Also set up meetings") and this app has not
    /// seen it end; the next launch resumes it. Cleared when the install ends.
    public static let speakerModelsPendingKey = "setupAssistantSpeakerModelsPending"

    public private(set) var step: SetupAssistantStep = .welcome
    /// "Also set up meetings": installs the speaker models and offers system audio. On by default.
    public var setUpMeetings = true
    /// The user left Basics or Accessibility without the permission ("Continue Without").
    public private(set) var continuedWithoutMicrophone = false
    public private(set) var continuedWithoutAccessibility = false
    /// Open Settings was clicked this run for a permission that takes effect after a reopen.
    public private(set) var requestedSystemAudio = false
    public private(set) var requestedInputMonitoring = false
    /// Basics was left once, so the speech model install was started.
    public private(set) var startedInstalls = false

    public init() {}

    // MARK: - Launch

    /// What a launch shows. `done` is the `doneKey` value (nil when absent). An install that predates the assistant,
    /// with dictation on or Microphone and Accessibility granted, is marked done silently so its user never sees it.
    public static func launch(done: Bool?, awaitingReopenCheck: Bool, dictationEnabled: Bool, microphoneGranted: Bool,
                              accessibility: Bool) -> SetupAssistantLaunch {
        if awaitingReopenCheck { return .verify }
        switch done {
        case true?: return .normal
        case false?: return .assistant  // started on an earlier launch and not finished
        case nil: return dictationEnabled || (microphoneGranted && accessibility) ? .markDone : .assistant
        }
    }

    /// The work a launch resumes that the assistant started or deferred and a quit (the planned reopen included) cut
    /// short: the speech model install when dictation waits for it (`enableAfterSpeechModelKey`), and the speaker
    /// models when their install had not ended (`speakerModelsPendingKey`).
    public static func resumeAtLaunch(enableAfterSpeechModel: Bool, speakerModelsPending: Bool,
                                      dictationEnabled: Bool) -> [SetupAssistantEffect] {
        var effects: [SetupAssistantEffect] = []
        if enableAfterSpeechModel && !dictationEnabled { effects.append(.installSpeechModel) }
        if speakerModelsPending { effects.append(.installSpeakerModels) }
        return effects
    }

    // MARK: - Pages

    /// Whether the Reopen page is shown: something on it is still missing, or was requested this run (so Back
    /// returns to it).
    public func reopenStepNeeded(_ facts: SetupAssistantFacts) -> Bool {
        requestedSystemAudio || requestedInputMonitoring || offersSystemAudio(facts) || offersInputMonitoring(facts)
    }

    /// System audio is offered on the Reopen page for meetings, until it is granted.
    public func offersSystemAudio(_ facts: SetupAssistantFacts) -> Bool {
        (setUpMeetings && !facts.systemAudio) || requestedSystemAudio
    }

    /// Input Monitoring is offered only when the hotkey tap was refused with Accessibility granted.
    public func offersInputMonitoring(_ facts: SetupAssistantFacts) -> Bool {
        (facts.inputMonitoringNeeded && !facts.inputMonitoring) || requestedInputMonitoring
    }

    /// Next (or Start, Done) is enabled.
    public func canContinue(_ facts: SetupAssistantFacts) -> Bool {
        switch step {
        case .welcome, .reopen, .finish: true
        case .basics: facts.languageKnown && facts.microphoneGranted
        case .accessibility: facts.accessibility
        }
    }

    /// "Continue Without" is offered: the page's permission is missing and the user may go on without it.
    public func offersContinueWithout(_ facts: SetupAssistantFacts) -> Bool {
        switch step {
        case .basics: facts.languageKnown && !facts.microphoneGranted
        case .accessibility: !facts.accessibility
        case .welcome, .reopen, .finish: false
        }
    }

    /// On the Reopen page, the main button skips it: nothing was sent to System Settings yet.
    public func continueSkips(_ facts: SetupAssistantFacts) -> Bool {
        step == .reopen && !requestedSystemAudio && !requestedInputMonitoring
    }

    /// Welcome's Start.
    public mutating func start() {
        guard step == .welcome else { return }
        step = .basics
    }

    /// Goes to the next page when `canContinue` (or `offersContinueWithout` with `without`), and returns the work
    /// that starts now. Leaving Basics settles the language: its speech model starts downloading, and the speaker
    /// models too when meetings are set up. The Reopen page is passed over when nothing on it is needed.
    @discardableResult
    public mutating func next(_ facts: SetupAssistantFacts, without: Bool = false) -> [SetupAssistantEffect] {
        guard without ? offersContinueWithout(facts) : canContinue(facts) else { return [] }
        var effects: [SetupAssistantEffect] = []
        switch step {
        case .welcome:
            step = .basics
        case .basics:
            if without { continuedWithoutMicrophone = true }
            // Each time, so a language changed after going Back gets its own model.
            if !["installed", "unsupported"].contains(facts.speechModel) && !facts.speechModelDownloading {
                effects.append(.installSpeechModel)
            }
            if setUpMeetings && !["verified", "installing"].contains(facts.speakerModels) {
                effects.append(.installSpeakerModels)
            }
            startedInstalls = true
            step = .accessibility
        case .accessibility:
            if without { continuedWithoutAccessibility = true }
            step = reopenStepNeeded(facts) ? .reopen : .finish
        case .reopen:
            step = .finish
        case .finish:
            break
        }
        return effects
    }

    public mutating func back(_ facts: SetupAssistantFacts) {
        switch step {
        case .welcome: break
        case .basics: step = .welcome
        case .accessibility: step = .basics
        case .reopen: step = .accessibility
        case .finish: step = reopenStepNeeded(facts) ? .reopen : .accessibility
        }
    }

    /// Open Settings on the Reopen page.
    public mutating func requestedSystemAudioSettings() { requestedSystemAudio = true }
    public mutating func requestedInputMonitoringSettings() { requestedInputMonitoring = true }

    // MARK: - Finish

    /// Finish offers "Reopen Voice is Local" instead of Done: a permission that takes effect after a reopen was
    /// requested this run. CGPreflightScreenCaptureAccess usually stays false until then, so the request counts, not
    /// the reported state.
    public var reopenNeeded: Bool { requestedSystemAudio || requestedInputMonitoring }

    /// Whether finishing turns dictation on now, once the speech model is installed, after the reopen, or not at all.
    /// Input Monitoring counts only when the hotkey tap was refused without it (`inputMonitoringNeeded`); requested
    /// this run, it is expected to take effect after the reopen, so enabling waits for that.
    public func enable(_ facts: SetupAssistantFacts) -> SetupAssistantEnable {
        if facts.dictationEnabled { return .alreadyOn }
        guard facts.microphoneGranted, facts.accessibility else { return .notPossible }
        let inputMonitoringMissing = facts.inputMonitoringNeeded && !facts.inputMonitoring
        if inputMonitoringMissing && !requestedInputMonitoring { return .notPossible }
        switch facts.speechModel {
        case "installed": return inputMonitoringMissing ? .afterReopen : .now
        case "unsupported": return .notPossible
        // Downloading, not installed yet, or still being checked. With Input Monitoring pending, the install resumes
        // after the reopen, so enabling follows it there.
        default: return .afterSpeechModelInstall
        }
    }

    /// The Finish page's list (`verify` false) or the check after reopening (`verify` true), each item with its real
    /// state. `language` names the dictation language; `shortcut` the hold-to-talk key.
    public func checklist(_ facts: SetupAssistantFacts, verify: Bool, language: String,
                          shortcut: String) -> [SetupAssistantItem] {
        var items: [SetupAssistantItem] = []
        items.append(facts.microphoneGranted
            ? .init(.microphone, .done, "Allowed")
            : .init(.microphone, .missing, "Not allowed — dictation cannot hear you. Open Settings to allow it."))
        items.append(facts.accessibility
            ? .init(.accessibility, .done, "Allowed")
            : .init(.accessibility, .missing,
                    "Not allowed — dictation cannot notice the key or type text. Open Settings to allow it."))
        if facts.inputMonitoringNeeded || requestedInputMonitoring {
            if facts.inputMonitoring {
                items.append(.init(.inputMonitoring, .done, "Allowed"))
            } else if requestedInputMonitoring && !verify {
                items.append(.init(.inputMonitoring, .waiting, "Takes effect after Voice is Local reopens"))
            } else {
                items.append(.init(.inputMonitoring, .missing,
                                   "Not allowed — macOS refuses the hold-to-talk key without it on this Mac"))
            }
        }
        items.append(speechModelItem(facts, language: language))
        items.append(speakerModelsItem(facts, verify: verify))
        if facts.systemAudio {
            items.append(.init(.systemAudio, .done, "Allowed — meetings record the computer's audio"))
        } else if requestedSystemAudio && !verify {
            items.append(.init(.systemAudio, .waiting, "Takes effect after Voice is Local reopens"))
        } else {
            items.append(.init(.systemAudio, .off, "Off — meetings record the microphone only"))
        }
        items.append(dictationItem(facts, verify: verify, shortcut: shortcut))
        return items
    }

    private func speechModelItem(_ facts: SetupAssistantFacts, language: String) -> SetupAssistantItem {
        if facts.speechModelDownloading {
            return .init(.speechModel, .waiting, "\(language): downloading — this can finish after setup")
        }
        switch facts.speechModel {
        case "installed": return .init(.speechModel, .done, "\(language): installed")
        case nil: return .init(.speechModel, .waiting, "\(language): checking…")
        case "unsupported": return .init(.speechModel, .missing, "\(language) is not supported on this Mac")
        default: return .init(.speechModel, .missing, "\(language): not installed — Open Settings to install it")
        }
    }

    private func speakerModelsItem(_ facts: SetupAssistantFacts, verify: Bool) -> SetupAssistantItem {
        switch facts.speakerModels {
        case "verified": return .init(.speakerModels, .done, "Installed — meetings get speaker labels")
        case "installing": return .init(.speakerModels, .waiting, "Downloading — this can finish after setup")
        case nil: return .init(.speakerModels, .waiting, "Checking…")
        default:
            // Asked for this run and not there: the install failed. Otherwise meetings simply go without labels.
            if setUpMeetings && startedInstalls && !verify {
                return .init(.speakerModels, .missing, "Not installed — Open Settings to try again")
            }
            return .init(.speakerModels, .off, "Not installed — meetings are saved without speaker labels")
        }
    }

    private func dictationItem(_ facts: SetupAssistantFacts, verify: Bool, shortcut: String) -> SetupAssistantItem {
        switch enable(facts) {
        case .alreadyOn:
            return .init(.dictation, .done, "On — hold \(shortcut), wait for Listening, speak, release")
        case .now:
            return .init(.dictation, .waiting, verify ? "Turns on when you click Done" : "Turns on when you finish")
        case .afterSpeechModelInstall:
            // After a reopen the launch has resumed the download, and dictation turns on when it ends.
            return .init(.dictation, .waiting, "Turns on once the speech model is installed")
        case .afterReopen:
            return .init(.dictation, .waiting, "Turns on after Voice is Local reopens, once Input Monitoring applies")
        case .notPossible:
            if facts.microphoneGranted && facts.accessibility && facts.inputMonitoringNeeded && !facts.inputMonitoring {
                return .init(.dictation, .missing,
                             "Stays off until Input Monitoring is allowed — Open Settings to allow it")
            }
            return .init(.dictation, .missing, "Stays off until Microphone, Accessibility and the speech model are ready")
        }
    }

    // MARK: - Reopening

    /// The detached command that reopens the app once this process has exited: `/bin/sh` waits for `pid` to end,
    /// then runs `/usr/bin/open` on the bundle. The pid and the path are passed as arguments, never pasted into the
    /// script, so a path with quotes or spaces stays one argument.
    public static func reopenCommand(waitingFor pid: Int32, bundlePath: String) -> (executable: String,
                                                                                     arguments: [String]) {
        ("/bin/sh", ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                     "sh", String(pid), bundlePath])
    }
}
