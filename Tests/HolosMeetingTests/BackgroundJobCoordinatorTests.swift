import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// `BackgroundJobCoordinator` with its two kinds, final transcripts and echo analyses (docs/meeting-design.md §4.16
// "App", §4.17, §5.11 "Catching up in the app"): the order between them, the holds, preemption, retries and the lock.
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
        var finish: @MainActor (_ code: Int32, _ errors: String) -> Void
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
        starts.append(Start(command: command, handle: handle) { code, errors in
            handle.exited = true
            completion(CommandResult(code: code, outcome: nil, errors: errors))
        })
        onStart(command)
        return handle
    }

    /// "deep A" / "echo C" for each command started, in order.
    var started: [String] {
        starts.map { start in
            let kind = start.command.arguments[1] == "deep-transcribe" ? "deep" : "echo"
            return "\(kind) \(URL(fileURLWithPath: start.command.arguments[2]).deletingPathExtension().lastPathComponent)"
        }
    }

    func finishLast(_ code: Int32, errors: String = "") {
        starts.last?.finish(code, errors)
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
    var summaryRunning = false
    var summaryRequestScan = false
    var now = base
    var conditions = DeepTranscriptionJobs.Conditions(enabled: true, modelInstalled: true, power: .ac)
    /// What happened, in order: "summaries", "started echo C", "released deep A", "reported deep A".
    var events: [String] = []
    var saved: DeepTranscriptionQueue?
    /// Folders deleted from Meetings while queued.
    var deleted: Set<String> = []
    let runner = FakeRunner()
    private(set) var deep: DeepTranscriptionJobs!
    let echo: EchoCatchUpJobs
    let analysed = LockedValue<Set<String>>([])
    var reports: [DeepTranscriptionJobs.PassReport] = []
    private(set) var jobs: BackgroundJobCoordinator!

    init(deep items: [String] = [], runNow: Set<String> = [], echo calls: [String] = []) {
        var queue = DeepTranscriptionQueue()
        for id in items { queue.enqueue(sessionID: id, path: "/m/\(id).holos", at: base, runNow: runNow.contains(id)) }
        let analysed = analysed
        echo = EchoCatchUpJobs { url in !analysed.withLock { $0.contains(url.lastPathComponent) } }
        echo.scanned = true
        echo.queue = calls.enumerated().map { index, id in
            EchoCatchUpSchedule.Candidate(sessionID: id, path: "/m/\(id).holos",
                                          createdAt: base.addingTimeInterval(-Double(index) * 3600))
        }
        deep = DeepTranscriptionJobs(queue: queue, save: { [unowned self] in self.saved = $0 },
                                     conditions: { [unowned self] in self.conditions },
                                     exists: { [unowned self] in !self.deleted.contains($0) })
        deep.onEnded = { [unowned self] report in
            self.reports.append(report)
            self.events.append("reported deep \(report.sessionID)")
        }
        runner.onStart = { [unowned self] _ in self.events.append("command \(self.runner.started.last ?? "")") }
        jobs = BackgroundJobCoordinator(runner: runner, kinds: [deep, echo], environment: .init(
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
            otherJobRunning: { [unowned self] in self.summaryRunning },
            summaryRequestScan: { [unowned self] in self.summaryRequestScan },
            scheduleOthers: { [unowned self] in self.events.append("summaries") },
            started: { [unowned self] kind, id in self.events.append("started \(self.name(kind)) \(id)") },
            released: { [unowned self] kind, id in
                self.taken[id] = nil
                self.events.append("released \(self.name(kind)) \(id)")
            },
            now: { [unowned self] in self.now }))
    }

    func name(_ kind: any BackgroundJobKind) -> String { kind === deep ? "deep" : "echo" }

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
    #expect(world.jobs.askedForWorkWaiting())
    // Without echo work, an automatic pass does not wait for the request.
    world.echo.queue = []
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
    world.conditions.modelInstalled = false
    #expect(!world.jobs.askedForWorkWaiting(), "Not without the model.")
}

@Test @MainActor func automaticWorkWaitsForTheFirstEchoScanOfTheLaunch() {
    let world = World(deep: ["A"])
    world.echo.scanned = false
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(world.jobs.catchUpReady(), "An automatic summary waits too.")
    world.echo.scanned = true
    #expect(!world.jobs.catchUpReady())
    world.echo.scanning = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty, "So does a scan after a meeting was saved.")
    world.echo.scanning = false
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
}

@Test @MainActor func aSummarizeAgainScanHoldsCatchUpAndAutomaticWorkUntilItEnds() {
    let world = World(deep: ["A"], echo: ["C"])
    world.summaryRequestScan = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(world.jobs.waitsForSummaryScan)
    // The scan started the summary asked for: it is another job, so nothing starts at the scan's end.
    world.summaryRequestScan = false
    world.summaryRunning = true
    world.jobs.summaryScanEnded()
    #expect(world.runner.started.isEmpty)
    #expect(!world.jobs.waitsForSummaryScan)
    world.summaryRunning = false
    world.jobs.schedule()
    #expect(world.taken["C"] == EchoCatchUpSchedule.runningText, "Then the echo analysis.")
}

@Test @MainActor func theEndOfASummarizeAgainScanThatStartedNothingStartsTheHeldPass() {
    let world = World(deep: ["A"])
    world.summaryRequestScan = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    // The scan ends without starting a summary (the meeting asked for was not ready): the pass goes on by itself.
    world.summaryRequestScan = false
    world.jobs.summaryScanEnded()
    #expect(world.runner.started == ["deep A"])
}

@Test @MainActor func aMakeFinalTranscriptNowDoesNotWaitForASummarizeAgainScan() {
    let world = World(deep: ["A"], runNow: ["A"], echo: ["C"])
    world.summaryRequestScan = true
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
    #expect(world.jobs.isRunning, "Summaries count it as a job running.")
}

@Test @MainActor func aJobEndingLooksForSummariesBeforeTheNextJobAndReportsLast() {
    let world = World(deep: ["A", "B"])
    world.jobs.schedule()
    world.events = []
    world.runner.finishLast(0)
    #expect(world.events == ["released deep A", "summaries", "started deep B", "command deep B", "reported deep A"])
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
    #expect(world.events.contains("started echo D"), "Review of it opens read-only while it runs.")
    world.runner.finishLast(0)
    #expect(world.runner.started == ["echo D", "deep B"])
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
    world.summaryRunning = true
    world.lock = .free
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty, "This app's summary is another job.")
    world.summaryRunning = false
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
    #expect(world.runner.started == ["echo C"])
    #expect(!world.jobs.catchUpReady(), "Automatic work does not wait for it.")
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
    #expect(world.events == ["started deep A", "released deep A", "summaries"],
            "The other schedulers look for their next jobs.")
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

@Test @MainActor func aMakeFinalTranscriptNowAcceptedAfterAFailedStartRunsAtOnce() {
    let world = World(deep: ["A"])
    world.runner.failNextStart = true
    world.jobs.schedule()
    var queue = world.deep.queue
    queue.enqueue(sessionID: "A", path: "/m/A.holos", at: base, runNow: true)
    world.deep.queue = queue
    #expect(!world.jobs.askedForWorkWaiting(), "Not while every pass waits after the failed start.")
    world.jobs.clearRetry(world.deep)
    #expect(world.jobs.askedForWorkWaiting())
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
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
    world.jobs.schedule()
    world.busy = true
    #expect(await eventually { world.events.contains("released echo C") })
    #expect(world.runner.started.isEmpty)
    #expect(world.echo.queue.map(\.sessionID) == ["C"] && world.echo.failed.isEmpty)
}
