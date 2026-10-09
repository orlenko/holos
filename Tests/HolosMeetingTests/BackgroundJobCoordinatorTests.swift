import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// `BackgroundJobCoordinator` with its three kinds, final transcripts, echo analyses and summaries
// (docs/meeting-design.md §4.16 "App", §4.17, §5.11 "Catching up in the app"): the order between them, the holds,
// preemption, retries and the lock.
// A fake runner stands for `CommandRunner` (no process starts) and an injected clock for the time; the meetings are
// invented IDs.

private let base = Date(timeIntervalSince1970: 1_800_000_000)

/// Starts nothing: records each command, and finishes it when a test says so.
@MainActor private final class FakeRunner: BackgroundJobRunner {
    final class Handle: BackgroundJobHandle {
        var signals = 0
        var exited = false
        func terminate() -> Bool {
            guard !exited else { return false }
            signals += 1
            return true
        }
    }

    struct Start {
        var command: BackgroundJobCommand
        var handle: Handle
        var finish: @MainActor (_ code: Int32, _ errors: String, _ outcome: Data?) -> Void
    }

    var starts: [Start] = []
    /// The next start throws (a transient process limit).
    var failNextStart = false
    var onStart: @MainActor (BackgroundJobCommand) -> Void = { _ in }

    func startJob<Outcome: Decodable & Sendable>(
        _ command: BackgroundJobCommand, as type: Outcome.Type,
        completion: @escaping @MainActor (CommandResult<Outcome>) -> Void) throws -> any BackgroundJobHandle {
        if failNextStart {
            failNextStart = false
            throw HolosError.io("Resource temporarily unavailable.")
        }
        let handle = Handle()
        starts.append(Start(command: command, handle: handle) { code, errors, outcome in
            handle.exited = true
            let decoded = outcome.flatMap { try? HolosJSON.decoder().decode(Outcome.self, from: $0) }
            completion(CommandResult(code: code, outcome: decoded, errors: errors))
        })
        onStart(command)
        return handle
    }

    /// "deep A" / "echo C" / "summary S" for each command started, in order.
    var started: [String] {
        starts.map { start in
            let kind = ["deep-transcribe": "deep", "echo-analyze": "echo"][start.command.arguments[1]] ?? "summary"
            return "\(kind) \(URL(fileURLWithPath: start.command.arguments[2]).deletingPathExtension().lastPathComponent)"
        }
    }

    func finishLast(_ code: Int32, errors: String = "", outcome: (any Encodable)? = nil) {
        starts.last?.finish(code, errors, outcome.flatMap { try? HolosJSON.encoder().encode($0) })
    }
}

/// The app around the coordinator: the meeting state, the meetings held, the lock, the summaries, and the clock.
@MainActor private final class World {
    var busy = false
    /// Meetings another command or Review holds.
    var held: Set<String> = []
    /// Meetings the jobs took (`beginUsing`).
    var taken: [String: String] = [:]
    var lock = DeepTranscriptionLock.State.free
    var now = base
    var conditions = DeepTranscriptionJobs.Conditions(enabled: true, modelInstalled: true, power: .ac)
    /// What happened, in order: "command echo C", "released deep A", "reported deep A", "scanned", "alert S".
    var events: [String] = []
    var saved: DeepTranscriptionQueue?
    /// Folders deleted from Meetings while queued.
    var deleted: Set<String> = []
    let runner = FakeRunner()
    private(set) var deep: DeepTranscriptionJobs!
    let echo: EchoCatchUpJobs
    let analysed = LockedValue<Set<String>>([])
    /// While set, the echo analysis's check waits for it; `checking` says it began, `checkedOffMain` where it ran.
    let gate = LockedValue<DispatchSemaphore?>(nil)
    let checking = LockedValue(false)
    let checkedOffMain = LockedValue<Bool?>(nil)
    /// The review hold each release carried, by meeting.
    var releasedHolds: [String: ReviewMaintenance.Hold] = [:]
    var reports: [DeepTranscriptionJobs.PassReport] = []
    private(set) var jobs: BackgroundJobCoordinator!
    /// Summaries: off until a test opens the way (`launchReady`); each scan finds `summaryScan`, after `scanGate`.
    let summaries: MeetingSummaryJobs
    let summaryScan = LockedValue(MeetingSummaryJobs.Scan.scanned([], gone: []))
    let scanGate = LockedValue<DispatchSemaphore?>(nil)
    let scans = LockedValue(0)
    var summaryConditions = MeetingSummaryJobs.Conditions(enabled: true, modelAvailable: true, onBattery: false)
    var savedRequests: [MeetingSummarySchedule.Request]?

    init(deep items: [String] = [], runNow: Set<String> = [], echo calls: [String] = []) {
        var queue = DeepTranscriptionQueue()
        for id in items { queue.enqueue(sessionID: id, path: "/m/\(id).holos", at: base, runNow: runNow.contains(id)) }
        let analysed = analysed, gate = gate, checking = checking, checkedOffMain = checkedOffMain
        echo = EchoCatchUpJobs { url in
            checkedOffMain.withLock { $0 = !Thread.isMainThread }
            checking.withLock { $0 = true }
            gate.value?.wait()
            return !analysed.withLock { $0.contains(url.lastPathComponent) }
        }
        echo.scanned = true
        echo.queue = calls.enumerated().map { index, id in
            EchoCatchUpSchedule.Candidate(sessionID: id, path: "/m/\(id).holos",
                                          createdAt: base.addingTimeInterval(-Double(index) * 3600))
        }
        let summaryScan = summaryScan, scanGate = scanGate, scans = scans
        summaries = MeetingSummaryJobs(requests: [], save: { _ in }) { _, _ in
            scanGate.value?.wait()
            _ = scans.withLock { $0 += 1 }
            return summaryScan.value
        }
        deep = DeepTranscriptionJobs(queue: queue, save: { [unowned self] in self.saved = $0 },
                                     conditions: { [unowned self] in self.conditions },
                                     exists: { [unowned self] in !self.deleted.contains($0) })
        deep.onEnded = { [unowned self] report in
            self.reports.append(report)
            self.events.append("reported deep \(report.sessionID)")
        }
        summaries.root = URL(fileURLWithPath: "/m")
        summaries.conditions = { [unowned self] in self.summaryConditions }
        summaries.onScanned = { [unowned self] in
            self.events.append("scanned")
            self.jobs.schedule()
        }
        summaries.onRequestFailed = { [unowned self] id, _ in self.events.append("alert \(id)") }
        runner.onStart = { [unowned self] _ in self.events.append("command \(self.runner.started.last ?? "")") }
        jobs = BackgroundJobCoordinator(runner: runner, kinds: [deep, echo, summaries], environment: .init(
            meetingBusy: { [unowned self] in self.busy },
            sessionsInUse: { [unowned self] in self.held.union(self.taken.keys) },
            beginUsing: { [unowned self] id, doing in
                guard self.taken[id] == nil else { return false }
                self.taken[id] = doing
                // As `MeetingController.onSessionsInUseChanged`: taking a meeting looks for jobs again.
                self.jobs.schedule()
                return true
            },
            lockState: { [unowned self] in self.lock },
            released: { [unowned self] kind, id, hold in
                self.taken[id] = nil
                self.releasedHolds[id] = hold
                self.events.append("released \(self.name(kind)) \(id)")
            },
            now: { [unowned self] in self.now }))
    }

    func name(_ kind: any BackgroundJobKind) -> String { kind === deep ? "deep" : kind === echo ? "echo" : "summary" }

    /// Waits for the echo analysis's check (off the main actor) to start its command or let the meeting go.
    func settle() async -> Bool {
        await eventually { self.taken.isEmpty || self.runner.starts.count(where: { !$0.handle.exited }) == 1 }
    }
}

private let busyMessage = "Error: \(DeepTranscriptionLock.busyMessage)\n"
private let leaseMessage = "Error: Another Voice is Local process is processing this session.\n"

// MARK: - Order

@Test(.timeLimit(.minutes(1)))
@MainActor func aMakeFinalTranscriptNowGoesFirstThenTheEchoAnalysisThenAnAutomaticPass() async {
    let world = World(deep: ["A", "B"], runNow: ["B"], echo: ["C"])
    world.jobs.schedule()
    #expect(world.runner.started == ["deep B"])
    #expect(world.runner.starts[0].command.arguments.contains("--force"), "Asked for: made again over edits.")
    world.runner.finishLast(0)
    #expect(await world.settle())
    #expect(world.runner.started == ["deep B", "echo C"])
    world.runner.finishLast(0)
    #expect(world.runner.started == ["deep B", "echo C", "deep A"])
    #expect(!world.runner.starts[2].command.arguments.contains("--force"))
    #expect(world.saved?.items.map(\.sessionID) == ["A"], "Every change to the queue is saved.")
}

@Test @MainActor func aMakeFinalTranscriptNowStillReadingItsLanguagesHoldsTheEchoAnalysisBack() {
    let world = World(deep: ["A"], echo: ["C"])
    var queue = world.deep.queue
    queue.reserveRunNow(sessionID: "P", path: "/m/P.holos", at: base)
    world.deep.queue = queue
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty, "The echo analysis waits, and the automatic pass waits for it.")
    // Without echo work, an automatic pass does not wait for the request.
    world.echo.queue = []
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aMakeFinalTranscriptNowWithoutTheModelHoldsNothingBack() async {
    let world = World(echo: ["C"])
    var queue = world.deep.queue
    queue.reserveRunNow(sessionID: "P", path: "/m/P.holos", at: base)
    world.deep.queue = queue
    world.conditions.modelInstalled = false
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started == ["echo C"])
}

@Test @MainActor func automaticWorkWaitsForTheFirstEchoScanOfTheLaunch() {
    let world = World(deep: ["A"])
    world.echo.scanned = false
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    world.echo.scanned = true
    world.echo.scanning = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty, "So does a scan after a meeting was saved.")
    world.echo.scanning = false
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
}

@Test @MainActor func aJobEndingLetsGoBeforeTheNextJobAndReportsLast() {
    let world = World(deep: ["A", "B"])
    world.jobs.schedule()
    world.events = []
    world.runner.finishLast(0)
    #expect(world.events == ["released deep A", "command deep B", "reported deep A"])
    #expect(world.reports.first?.end == .done)
}

@Test @MainActor func aMeetingDeletedWhileQueuedIsTakenOffAndTheNextOneRuns() {
    let world = World(deep: ["A", "B"])
    world.deleted = ["/m/A.holos"]
    world.jobs.schedule()
    #expect(world.runner.started == ["deep B"])
    #expect(world.deep.queue.items.map(\.sessionID) == ["B"])
}

// MARK: - Holds

@Test @MainActor func nothingStartsWhileAMeetingStartsRecordsOrSaves() {
    let world = World(deep: ["A"], runNow: ["A"], echo: ["C"])
    world.busy = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty && world.taken.isEmpty, "No meeting is even taken.")
    world.busy = false
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
    let calls = World(echo: ["C"])
    calls.busy = true
    calls.jobs.schedule()
    #expect(calls.taken.isEmpty, "Nor for an echo analysis.")
}

@Test(.timeLimit(.minutes(1)))
@MainActor func meetingsInUseOrUnderReviewWaitAndTheNextOneRuns() async {
    let world = World(deep: ["A", "B"], echo: ["C", "D"])
    world.held = ["C", "A"]
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started == ["echo D"])
    #expect(world.jobs.reviewHold(on: "D")?.command == .echoAnalysis, "Review of it opens read-only while it runs.")
    world.runner.finishLast(0)
    #expect(world.runner.started == ["echo D", "deep B"])
    #expect(world.jobs.reviewHold(on: "B") == nil, "Review waits for a final transcript instead.")
    world.runner.finishLast(0)
    #expect(world.runner.started.count == 2, "A and C wait for the command or the review.")
    world.held = []
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started.last == "echo C")
}

@Test @MainActor func aJobIsMarkedRunningBeforeItTakesItsMeeting() {
    // Taking the meeting looks for jobs again (as the app does): that look starts nothing else.
    let world = World(deep: ["A", "B"], runNow: ["A", "B"])
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
    #expect(world.taken == ["A": DeepTranscriptionJobs.runningText])
}

@Test @MainActor func aJobLeftRunningByAnotherProcessHoldsEveryJobBack() {
    let world = World(deep: ["A"], runNow: ["A"], echo: ["C"])
    world.lock = .held(.init(pid: 42, sessionID: "X", force: false))
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(world.jobs.lock.isDeepPass, "Queued meetings wait for another final transcript.")
    world.lock = .held(.init(pid: 42, sessionID: "X", force: false, kind: DeepTranscriptionLock.Holder.echoKind))
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(!world.jobs.lock.isDeepPass)
    world.lock = .free
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
}

// MARK: - Preemption

@Test @MainActor func aPassStoppedForAMeetingStaysQueuedAndRunsAgainOnceTheMeetingIsSaved() {
    let world = World(deep: ["A"])
    world.jobs.schedule()
    world.busy = true
    world.jobs.meetingStateChanged()
    world.jobs.meetingStateChanged()
    #expect(world.runner.starts[0].handle.signals == 1, "Signalled once.")
    world.runner.finishLast(DeepTranscriptionSchedule.terminatedExitCode)
    #expect(world.deep.queue.contains("A"))
    #expect(world.reports.first?.end == .keepPreempted)
    #expect(world.runner.started == ["deep A"], "The meeting has the Mac to itself.")
    world.busy = false
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A", "deep A"], "Neither failed nor delayed.")
}

@Test(.timeLimit(.minutes(1)))
@MainActor func anEchoAnalysisStoppedForAMeetingStaysQueuedAndAFinishedOneEndsAsItDid() async {
    let world = World(echo: ["C", "D"])
    world.jobs.schedule()
    #expect(await world.settle())
    world.busy = true
    world.jobs.meetingStateChanged()
    world.runner.finishLast(DeepTranscriptionSchedule.terminatedExitCode)
    #expect(world.echo.queue.map(\.sessionID) == ["C", "D"])
    #expect(world.echo.failed.isEmpty)
    world.busy = false
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started == ["echo C", "echo C"])
    // The signal reaches a run that had already finished: its end stands.
    world.busy = true
    world.jobs.meetingStateChanged()
    world.runner.finishLast(0)
    #expect(world.echo.queue.map(\.sessionID) == ["D"])
}

@Test @MainActor func aJobIsStoppedOnlyWhileAMeetingIsBusy() {
    let world = World(deep: ["A"])
    world.busy = true
    world.jobs.meetingStateChanged()
    world.busy = false
    world.jobs.schedule()
    world.jobs.meetingStateChanged()
    #expect(world.runner.starts[0].handle.signals == 0, "Only while a meeting is busy.")
}

@Test @MainActor func cancellingAPassStoppedForAMeetingTakesItOffTheQueue() {
    let world = World(deep: ["A"], runNow: ["A"])
    world.jobs.schedule()
    world.busy = true
    world.jobs.meetingStateChanged()
    // Meetings › Cancel Final Transcript.
    world.jobs.cancel(world.deep, "A")
    var queue = world.deep.queue
    queue.remove("A")
    world.deep.queue = queue
    #expect(world.runner.starts[0].handle.signals == 2)
    world.runner.finishLast(DeepTranscriptionSchedule.terminatedExitCode)
    #expect(world.reports.first?.end == .done, "No longer counted as stopped for the meeting.")
    #expect(world.reports.first?.item == nil, "Cancelled: no alert.")
}

// MARK: - Retries

@Test(.timeLimit(.minutes(1)))
@MainActor func anEchoAnalysisTurnedDownWaitsLongerEachTimeAndTheOthersGoOn() async {
    let world = World(echo: ["C", "D"])
    world.jobs.schedule()
    #expect(await world.settle())
    world.runner.finishLast(1, errors: leaseMessage)
    #expect(await world.settle())
    #expect(world.runner.started == ["echo C", "echo D"], "D goes on meanwhile.")
    _ = world.analysed.withLock { $0.insert("D.holos") }
    world.runner.finishLast(0)
    world.now = base.addingTimeInterval(59)
    world.jobs.schedule()
    #expect(world.taken.isEmpty, "C waits a minute.")
    world.now = base.addingTimeInterval(60)
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started.last == "echo C")
    world.runner.finishLast(1, errors: busyMessage)
    world.now = base.addingTimeInterval(60 + 119)
    world.jobs.schedule()
    #expect(world.taken.isEmpty, "Then two minutes.")
    world.now = base.addingTimeInterval(60 + 120)
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started.count == 4)
}

@Test(.timeLimit(.minutes(1)))
@MainActor func anEchoWaitThatEndedDoesNotComeBackWhenTheClockIsSetBack() async {
    let world = World(echo: ["C"])
    world.jobs.schedule()
    #expect(await world.settle())
    world.runner.finishLast(1, errors: leaseMessage)
    world.now = base.addingTimeInterval(60)
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started == ["echo C", "echo C"])
    // The clock is set back, and a meeting stops the run: once the meeting is saved, C runs again at once.
    world.now = base.addingTimeInterval(10)
    world.busy = true
    world.jobs.meetingStateChanged()
    world.runner.finishLast(DeepTranscriptionSchedule.terminatedExitCode)
    world.busy = false
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started == ["echo C", "echo C", "echo C"])
}

@Test @MainActor func aPassTurnedDownForItsMeetingWaitsAMinuteAndTheOthersGoOn() {
    let world = World(deep: ["A", "B"])
    world.jobs.schedule()
    world.runner.finishLast(1, errors: leaseMessage)
    #expect(world.runner.started == ["deep A", "deep B"])
    world.runner.finishLast(0)
    world.now = base.addingTimeInterval(59)
    world.jobs.schedule()
    #expect(world.runner.started.count == 2)
    world.now = base.addingTimeInterval(60)
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A", "deep B", "deep A"])
    // Turned down again: a minute again, not longer.
    world.runner.finishLast(1, errors: leaseMessage)
    world.now = base.addingTimeInterval(120)
    world.jobs.schedule()
    #expect(world.runner.started.count == 4)
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aPassTheLockRefusedHoldsEveryPassForAMinuteButNotTheEchoAnalysis() async {
    let world = World(deep: ["A", "B"], echo: [])
    world.jobs.schedule()
    world.runner.finishLast(1, errors: busyMessage)
    #expect(world.runner.started == ["deep A"])
    world.echo.queue = [EchoCatchUpSchedule.Candidate(sessionID: "C", path: "/m/C.holos", createdAt: base)]
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started == ["deep A", "echo C"])
    world.runner.finishLast(0)
    world.now = base.addingTimeInterval(60)
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A", "echo C", "deep A"])
}

@Test(.timeLimit(.minutes(1)))
@MainActor func anEchoAnalysisThatFailedIsNotTriedAgainUntilTheNextLaunch() async {
    let world = World(echo: ["C"])
    world.jobs.schedule()
    #expect(await world.settle())
    world.runner.finishLast(1, errors: "Error: The audio is damaged.\n")
    #expect(world.echo.problems["C"] == .failed("The audio is damaged."))
    // A scan finds it again.
    world.echo.queue = [EchoCatchUpSchedule.Candidate(sessionID: "C", path: "/m/C.holos", createdAt: base)]
    world.jobs.schedule()
    // Let any launch the rescan made reach the runner before checking that none was made.
    #expect(await world.settle())
    #expect(world.runner.started == ["echo C"])
    #expect(!world.jobs.isRunning, "Nothing was started for it.")
    // The next launch.
    let next = World(echo: ["C"])
    next.jobs.schedule()
    #expect(await next.settle())
    #expect(next.runner.started == ["echo C"])
}

@Test @MainActor func aFailedPassLeavesTheQueue() {
    let world = World(deep: ["A"], runNow: ["A"])
    world.jobs.schedule()
    world.runner.finishLast(1, errors: "Error: The audio was deleted.\n")
    #expect(!world.deep.queue.contains("A"))
    #expect(world.reports.first?.item?.runNow == true, "The alert says why.")
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
}

@Test @MainActor func aStartThatFailsIsTriedAgainAfterAMinute() {
    let world = World(deep: ["A"])
    world.runner.failNextStart = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(world.deep.queue.contains("A") && world.taken.isEmpty, "Kept queued, the meeting let go of.")
    #expect(world.events == ["released deep A"])
    world.now = base.addingTimeInterval(59)
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    world.now = base.addingTimeInterval(60)
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
}

@Test @MainActor func aWaitThatEndedDoesNotComeBackWhenTheClockIsSetBack() {
    // A failed start holds every pass a minute; once a look finds the minute past, a clock set back does not.
    let world = World(deep: ["A", "B"])
    world.runner.failNextStart = true
    world.jobs.schedule()
    world.now = base.addingTimeInterval(60)
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
    world.now = base.addingTimeInterval(10)
    world.runner.finishLast(0)
    #expect(world.runner.started == ["deep A", "deep B"])
    // Nor does a meeting's, also when its minute passes while another pass runs: B is turned down, C runs, the minute
    // passes and the clock is set back before C ends.
    var queue = world.deep.queue
    queue.enqueue(sessionID: "C", path: "/m/C.holos", at: base)
    world.deep.queue = queue
    world.runner.finishLast(1, errors: leaseMessage)
    #expect(world.runner.started.last == "deep C")
    world.now = base.addingTimeInterval(70)
    world.jobs.schedule()
    world.now = base.addingTimeInterval(10)
    world.runner.finishLast(0)
    #expect(world.runner.started.suffix(2) == ["deep C", "deep B"])
    // And once it ran: turned down again, B runs once that minute is past, is stopped for a meeting with the clock set
    // back, and runs again at once.
    world.runner.finishLast(1, errors: leaseMessage)
    world.now = base.addingTimeInterval(70)
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A", "deep B", "deep C", "deep B", "deep B"])
    world.now = base.addingTimeInterval(10)
    world.busy = true
    world.jobs.meetingStateChanged()
    world.runner.finishLast(DeepTranscriptionSchedule.terminatedExitCode)
    world.busy = false
    world.jobs.schedule()
    #expect(world.runner.started.count == 6)
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aMakeFinalTranscriptNowAcceptedAfterAFailedStartRunsAtOnce() async {
    let world = World(deep: ["A"], runNow: ["A"])
    world.runner.failNextStart = true
    world.jobs.schedule()
    // While every pass waits after the failed start, the Make Final Transcript Now does not hold echo work back.
    world.echo.queue = [EchoCatchUpSchedule.Candidate(sessionID: "C", path: "/m/C.holos", createdAt: base)]
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started == ["echo C"])
    world.jobs.clearRetry(world.deep)
    world.runner.finishLast(0)
    #expect(world.runner.started == ["echo C", "deep A"])
}

// MARK: - The echo analysis's check

@Test(.timeLimit(.minutes(1)))
@MainActor func anEchoAnalysisMadeSinceTheScanIsNotRunAndTheNextOneStartsByItself() async {
    let world = World(echo: ["C", "D"])
    _ = world.analysed.withLock { $0.insert("C.holos") }
    world.jobs.schedule()
    #expect(await eventually { world.runner.started == ["echo D"] })
    #expect(world.events.contains("released echo C"))
    #expect(world.echo.queue.map(\.sessionID) == ["D"] && world.echo.failed == ["C"])
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aPassThatCannotStartLetsTheEchoAnalysisGoByItself() async {
    let world = World(deep: ["A"], runNow: ["A"], echo: ["C"])
    world.runner.failNextStart = true
    world.jobs.schedule()
    #expect(await eventually { world.runner.started == ["echo C"] })
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aMeetingStartingWhileTheEchoCheckRunsLeavesTheCallQueued() async {
    let world = World(echo: ["C"])
    let gate = DispatchSemaphore(value: 0)
    world.gate.withLock { $0 = gate }
    world.jobs.schedule()
    // The check has begun (off the main actor) when the meeting starts.
    #expect(await eventually { world.checking.value })
    world.busy = true
    gate.signal()
    #expect(await eventually { world.events.contains("released echo C") })
    #expect(world.checkedOffMain.value == true)
    #expect(world.runner.started.isEmpty)
    #expect(world.echo.queue.map(\.sessionID) == ["C"] && world.echo.failed.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
@MainActor func anEchoAnalysisHoldsItsReviewFromItsCheckUntilItLetsGo() async {
    let world = World(echo: ["C", "D", "E"])
    _ = world.analysed.withLock { $0.insert("D.holos") }
    let gate = DispatchSemaphore(value: 0)
    world.gate.withLock { $0 = gate }
    world.jobs.schedule()
    #expect(await eventually { world.checking.value })
    let hold = world.jobs.reviewHold(on: "C")
    #expect(hold?.command == .echoAnalysis, "Held while its check runs.")
    world.gate.withLock { $0 = nil }
    gate.signal()
    #expect(await world.settle())
    #expect(world.jobs.reviewHold(on: "C") == hold, "And while its command runs.")
    // Completion lets go of it with that hold; D has nothing to do, and lets go of its own.
    world.runner.failNextStart = true
    world.runner.finishLast(0)
    #expect(world.releasedHolds["C"] == hold && hold != nil)
    #expect(await eventually { world.releasedHolds["D"] != nil && world.releasedHolds["E"] != nil })
    #expect(world.releasedHolds["D"]?.command == .echoAnalysis, "Nothing to do.")
    #expect(world.releasedHolds["E"]?.command == .echoAnalysis, "A failed start.")
    #expect(world.runner.started == ["echo C"])
    #expect(["C", "D", "E"].allSatisfy { world.jobs.reviewHold(on: $0) == nil })
}

// MARK: - Summaries

private func summaryCandidate(_ id: String, hoursAgo: Double = 1, current: Bool = false,
                              answers: String? = nil) -> MeetingSummarySchedule.Candidate {
    MeetingSummarySchedule.Candidate(sessionID: id, path: "/m/\(id).holos",
                                     createdAt: base.addingTimeInterval(-hoursAgo * 3600), transcriptID: "T-\(id)",
                                     summaryTranscriptID: current ? "T-\(id)" : nil, idle: true,
                                     summaryAnswersRequest: answers)
}

private func summaryOutcome(_ status: SessionSummarizeCommand.Status, code: Int32,
                            message: String = "") -> SessionSummarizeCommand.Outcome {
    SessionSummarizeCommand.Outcome(sessionID: nil, status: status, message: message, exitCode: code)
}

extension World {
    /// Summaries may start, and each scan finds `candidates` (and `gone`).
    func summarize(_ candidates: [MeetingSummarySchedule.Candidate], gone: Set<String> = []) {
        summaries.launchReady = true
        summaryScan.withLock { $0 = .scanned(candidates, gone: gone) }
    }

    /// Looks, and waits for the scan that look starts to end.
    func lookAndScan() async -> Bool {
        let before = scans.value
        jobs.schedule()
        return await eventually { self.scans.value > before && !self.summaries.scanning }
    }
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aSummarizeAgainGoesFirstAndHoldsAutomaticWorkWhileItsScanRuns() async {
    let world = World(deep: ["A"], echo: ["C"])
    world.summarize([summaryCandidate("S")])
    world.summaries.requests = [MeetingSummarySchedule.Request(sessionID: "S", id: "R1")]
    let gate = DispatchSemaphore(value: 0)
    world.scanGate.withLock { $0 = gate }
    world.jobs.schedule()
    #expect(world.summaries.scanning)
    #expect(world.runner.started.isEmpty, "The scan may start the Summarize Again: echo and automatic work wait.")
    world.scanGate.withLock { $0 = nil }
    gate.signal()
    #expect(await eventually { !world.runner.started.isEmpty })
    #expect(world.runner.started == ["summary S"])
    let arguments = world.runner.starts[0].command.arguments
    #expect(arguments.contains("--force") && arguments.suffix(2) == ["--answers-request", "R1"])
    #expect(world.taken["S"] == MeetingSummaryJobs.runningText)
}

@Test(.timeLimit(.minutes(1)))
@MainActor func anAutomaticSummaryWaitsForEchoWorkAndComesAfterAnAutomaticPass() async {
    let world = World(deep: ["A"])
    world.summarize([summaryCandidate("S"), summaryCandidate("Q", hoursAgo: 0.5)])
    world.summaryConditions.finalTranscriptQueued = ["Q"]
    world.echo.scanned = false
    #expect(await world.lookAndScan())
    #expect(world.runner.started.isEmpty, "Echo work is not known yet.")
    world.echo.scanned = true
    world.echo.queue = [EchoCatchUpSchedule.Candidate(sessionID: "C", path: "/m/C.holos", createdAt: base)]
    world.jobs.schedule()
    #expect(await world.settle())
    #expect(world.runner.started == ["echo C"])
    world.runner.finishLast(0)
    #expect(world.runner.started == ["echo C", "deep A"])
    world.runner.finishLast(0)
    #expect(await eventually { world.runner.started.count == 3 })
    #expect(world.runner.started.last == "summary S", "Q is summarized after its final transcript.")
}

@Test(.timeLimit(.minutes(1)))
@MainActor func summariesLookOnlyOnceTheLaunchIsReadyAndNoReconciliationOrMeetingRuns() async {
    let world = World()
    world.summaryScan.withLock { $0 = .scanned([summaryCandidate("S")], gone: []) }
    world.jobs.schedule()
    world.summaries.reconcileStarted()
    world.summaries.reconcileEnded()
    #expect(world.summaries.launchReady, "A reconciliation's end opens the way at launch.")
    world.summaries.reconcileStarted()
    world.jobs.schedule()
    world.busy = true
    world.summaries.reconcileEnded()
    world.jobs.schedule()
    #expect(world.scans.value == 0 && !world.summaries.scanning)
    world.busy = false
    #expect(await world.lookAndScan())
    #expect(world.runner.started == ["summary S"])
    // A reconciliation stops the summary going on, which is made again a minute later.
    world.summaries.reconcileStarted()
    world.jobs.preempt(world.summaries)
    #expect(world.runner.starts[0].handle.signals == 1)
    world.summaries.reconcileEnded()
    world.runner.finishLast(DeepTranscriptionSchedule.terminatedExitCode)
    world.now = base.addingTimeInterval(59)
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 1)
    world.now = base.addingTimeInterval(60)
    #expect(await world.lookAndScan())
    #expect(world.runner.started == ["summary S", "summary S"])
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aSummaryTurnedDownWaitsAMinuteAndOneSavedWithoutItsFilesFiveMinutes() async {
    let world = World()
    world.summarize([summaryCandidate("S")])
    world.summaries.requests = [MeetingSummarySchedule.Request(sessionID: "S", id: "R1")]
    #expect(await world.lookAndScan())
    world.runner.finishLast(1, outcome: summaryOutcome(.busy, code: 1))
    #expect(world.summaries.requested == ["S"], "A request stays.")
    world.now = base.addingTimeInterval(59)
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 1)
    world.now = base.addingTimeInterval(60)
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 2)
    world.runner.finishLast(3, outcome: summaryOutcome(.written, code: 3))
    #expect(world.summaries.requests.isEmpty)
    world.now = base.addingTimeInterval(60 + 299)
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 2)
    world.now = base.addingTimeInterval(60 + 300)
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 3, "Its files are rewritten later.")
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aSummarizeAgainThatFailsSaysWhyAndIsNotTriedAgainForTheSameTranscript() async {
    let world = World()
    world.summarize([summaryCandidate("S")])
    world.summaries.requests = [MeetingSummarySchedule.Request(sessionID: "S", id: "R1")]
    #expect(await world.lookAndScan())
    world.events = []
    world.runner.finishLast(1, outcome: summaryOutcome(.failed, code: 1, message: "Unsupported language."))
    #expect(world.events.prefix(2) == ["alert S", "released summary S"], "Said before the meeting is let go of.")
    #expect(world.summaries.requests.isEmpty && world.summaries.attempted["S"] == "T-S")
    world.now = base.addingTimeInterval(3_600)
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 1, "Not tried again for this transcript and these names.")
    world.summaries.attempted = [:]
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 2, "Turning the setting on again tries it once more.")
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aSummaryThatCannotStartHoldsOnlyItsMeetingBack() async {
    let world = World()
    world.summarize([summaryCandidate("S", hoursAgo: 1), summaryCandidate("T", hoursAgo: 2)])
    world.runner.failNextStart = true
    #expect(await world.lookAndScan())
    #expect(await eventually { world.runner.started == ["summary T"] }, "S waits a minute; T goes on.")
    #expect(world.taken["S"] == nil)
}

@Test(.timeLimit(.minutes(1)))
@MainActor func summarizeAgainRunsAtOnceAndCancelOnlyStopsTheRun() async {
    let world = World()
    world.summarize([summaryCandidate("S")])
    #expect(await world.lookAndScan())
    world.runner.finishLast(1, outcome: summaryOutcome(.changed, code: 1))
    // Summarize Again: no wait for the minute.
    world.summaries.requests.append(MeetingSummarySchedule.Request(sessionID: "S", id: "R2"))
    world.jobs.clearDelay(world.summaries, "S")
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 2)
    // Cancel Summarize: the request goes and the run stops; how it ends decides the rest.
    world.summaries.removeRequest("S")
    world.jobs.stop(world.summaries, "S")
    #expect(world.runner.starts[1].handle.signals == 1)
    world.runner.finishLast(DeepTranscriptionSchedule.terminatedExitCode, outcome: summaryOutcome(.cancelled, code: 143))
    #expect(world.summaries.requests.isEmpty)
    #expect(await world.lookAndScan())
    #expect(world.runner.started.count == 2, "Cancelled: tried again a minute later, as a busy one.")
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aScanDropsRequestsForMeetingsGoneOrAlreadyAnswered() async {
    let world = World()
    world.summaries.requests = [MeetingSummarySchedule.Request(sessionID: "G", id: "R1"),
                                MeetingSummarySchedule.Request(sessionID: "D", id: "R2"),
                                MeetingSummarySchedule.Request(sessionID: "S", id: "R3")]
    world.summarize([summaryCandidate("D", current: true, answers: "R2"), summaryCandidate("S", current: true)],
                    gone: ["G"])
    world.busy = false
    world.held = ["S"]
    #expect(await world.lookAndScan())
    #expect(world.summaries.requested == ["S"])
}

@Test(.timeLimit(.minutes(1)))
@MainActor func aSummaryIsAJobLikeTheOthersAndAMeetingStopsIt() async {
    let world = World(deep: ["A"])
    world.summarize([summaryCandidate("S")])
    world.summaries.requests = [MeetingSummarySchedule.Request(sessionID: "S", id: "R1")]
    #expect(await world.lookAndScan())
    #expect(world.runner.started == ["summary S"])
    world.jobs.schedule()
    #expect(world.runner.started == ["summary S"], "One job at a time.")
    world.busy = true
    world.jobs.meetingStateChanged()
    #expect(world.runner.starts[0].handle.signals == 1)
    // No result: stopped for the meeting, so made again a minute later, and the request stays.
    world.runner.finishLast(DeepTranscriptionSchedule.terminatedExitCode)
    #expect(world.summaries.requested == ["S"])
}

@Test(.timeLimit(.minutes(1)))
@MainActor func anAutomaticPassGoesBeforeAnAutomaticSummaryReadyAtTheSameLook() async {
    let world = World(deep: ["A"])
    world.summarize([summaryCandidate("S")])
    world.held = ["A"]
    let gate = DispatchSemaphore(value: 0)
    world.scanGate.withLock { $0 = gate }
    world.jobs.schedule()
    // A is let go of while the scan runs: the look its end makes has both.
    world.held = []
    world.scanGate.withLock { $0 = nil }
    gate.signal()
    #expect(await eventually { !world.runner.started.isEmpty })
    #expect(world.runner.started == ["deep A"])
}
