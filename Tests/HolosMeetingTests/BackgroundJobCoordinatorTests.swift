import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// `BackgroundJobCoordinator` with final transcripts (docs/meeting-design.md §4.16 "App", §4.17): the order beside the
// summaries and the echo catch-up, the holds, preemption, retries and the lock. A fake runner stands for
// `CommandRunner` (no process starts) and an injected clock for the time; the meetings are invented IDs.

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

    /// "deep A" for each command started, in order.
    var started: [String] {
        starts.map { "deep \(URL(fileURLWithPath: $0.command.arguments[2]).deletingPathExtension().lastPathComponent)" }
    }

    func finishLast(_ code: Int32, errors: String = "") {
        starts.last?.finish(code, errors)
    }
}

/// The app around the coordinator: the meeting state, the meetings held, the lock, the other schedulers (summaries,
/// the echo catch-up), and the clock.
@MainActor private final class World {
    var busy = false
    /// Meetings another command or Review holds.
    var held: Set<String> = []
    /// Meetings the jobs took (`beginUsing`).
    var taken: [String: String] = [:]
    var lock = DeepTranscriptionLock.State.free
    /// A summary or an echo analysis of this app runs.
    var otherRunning = false
    var summaryRequestScan = false
    /// Echo work is ready or not known yet.
    var echoReady = false
    var now = base
    var conditions = DeepTranscriptionJobs.Conditions(enabled: true, modelInstalled: true, power: .ac)
    /// What happened, in order: "others", "echo asked", "command deep A", "released deep A", "reported deep A".
    var events: [String] = []
    var saved: DeepTranscriptionQueue?
    /// Folders deleted from Meetings while queued.
    var deleted: Set<String> = []
    let runner = FakeRunner()
    private(set) var deep: DeepTranscriptionJobs!
    var reports: [DeepTranscriptionJobs.PassReport] = []
    private(set) var jobs: BackgroundJobCoordinator!

    init(deep items: [String] = [], runNow: Set<String> = []) {
        var queue = DeepTranscriptionQueue()
        for id in items { queue.enqueue(sessionID: id, path: "/m/\(id).holos", at: base, runNow: runNow.contains(id)) }
        deep = DeepTranscriptionJobs(queue: queue, save: { [unowned self] in self.saved = $0 },
                                     conditions: { [unowned self] in self.conditions },
                                     exists: { [unowned self] in !self.deleted.contains($0) })
        deep.onEnded = { [unowned self] report in
            self.reports.append(report)
            self.events.append("reported deep \(report.sessionID)")
        }
        runner.onStart = { [unowned self] _ in self.events.append("command \(self.runner.started.last ?? "")") }
        jobs = BackgroundJobCoordinator(runner: runner, kinds: [deep], environment: .init(
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
            otherJobRunning: { [unowned self] in self.otherRunning },
            summaryRequestScan: { [unowned self] in self.summaryRequestScan },
            otherCatchUpReady: { [unowned self] in self.echoReady },
            startOtherCatchUp: { [unowned self] in self.events.append("echo asked") },
            scheduleOthers: { [unowned self] in self.events.append("others") },
            released: { [unowned self] _, id in
                self.taken[id] = nil
                self.events.append("released deep \(id)")
            },
            now: { [unowned self] in self.now }))
    }
}

private let busyMessage = "Error: \(DeepTranscriptionLock.busyMessage)\n"
private let leaseMessage = "Error: Another Voice is Local process is processing this session.\n"

// MARK: - Order

@Test @MainActor func aMakeFinalTranscriptNowGoesBeforeAnAutomaticPass() {
    let world = World(deep: ["A", "B"], runNow: ["B"])
    world.jobs.schedule()
    #expect(world.runner.started == ["deep B"])
    #expect(world.runner.starts[0].command.arguments.contains("--force"), "Asked for: made again over edits.")
    world.runner.finishLast(0)
    #expect(world.runner.started == ["deep B", "deep A"])
    #expect(!world.runner.starts[1].command.arguments.contains("--force"))
    #expect(world.saved?.items.map(\.sessionID) == ["A"], "Every change to the queue is saved.")
}

@Test @MainActor func anAutomaticPassWaitsForEchoWorkAndAsksForItButAMakeFinalTranscriptNowDoesNot() {
    let world = World(deep: ["A"])
    world.echoReady = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(world.events == ["echo asked"])
    var queue = world.deep.queue
    queue.enqueue(sessionID: "B", path: "/m/B.holos", at: base, runNow: true)
    world.deep.queue = queue
    world.jobs.schedule()
    #expect(world.runner.started == ["deep B"])
}

@Test @MainActor func aMakeFinalTranscriptNowStillReadingItsLanguagesIsAskedForWork() {
    let world = World(deep: ["A"])
    #expect(!world.jobs.askedForWorkWaiting())
    var queue = world.deep.queue
    queue.reserveRunNow(sessionID: "P", path: "/m/P.holos", at: base)
    world.deep.queue = queue
    #expect(world.jobs.askedForWorkWaiting(), "Echo work and automatic summaries wait for it.")
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"], "An automatic pass does not.")
    world.conditions.modelInstalled = false
    #expect(!world.jobs.askedForWorkWaiting(), "Not without the model.")
}

@Test @MainActor func aSummarizeAgainScanHoldsAutomaticWorkUntilItEnds() {
    let world = World(deep: ["A"])
    world.summaryRequestScan = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(world.jobs.waitsForSummaryScan)
    // The scan started the summary asked for: it is another job, so nothing starts at the scan's end.
    world.summaryRequestScan = false
    world.otherRunning = true
    world.jobs.summaryScanEnded()
    #expect(world.runner.started.isEmpty)
    #expect(!world.jobs.waitsForSummaryScan)
    world.otherRunning = false
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
}

@Test @MainActor func aMakeFinalTranscriptNowDoesNotWaitForASummarizeAgainScan() {
    let world = World(deep: ["A"], runNow: ["A"])
    world.summaryRequestScan = true
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
    #expect(world.jobs.isRunning, "Summaries and the echo catch-up count it as a job running.")
}

@Test @MainActor func aJobEndingLooksForTheOtherSchedulersFirstAndReportsLast() {
    let world = World(deep: ["A", "B"])
    world.jobs.schedule()
    world.events = []
    world.runner.finishLast(0)
    #expect(world.events == ["released deep A", "others", "command deep B", "reported deep A"])
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
    let world = World(deep: ["A"], runNow: ["A"])
    world.busy = true
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty && world.taken.isEmpty, "No meeting is even taken.")
    world.busy = false
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
}

@Test @MainActor func meetingsInUseOrUnderReviewWaitAndTheNextOneRuns() {
    let world = World(deep: ["A", "B"])
    world.held = ["A"]
    world.jobs.schedule()
    #expect(world.runner.started == ["deep B"])
    world.runner.finishLast(0)
    #expect(world.runner.started.count == 1, "A waits for the command or the review.")
    world.held = []
    world.jobs.schedule()
    #expect(world.runner.started == ["deep B", "deep A"])
}

@Test @MainActor func aJobIsMarkedRunningBeforeItTakesItsMeeting() {
    // Taking the meeting looks for jobs again (as the app does): that look starts nothing else.
    let world = World(deep: ["A", "B"], runNow: ["A", "B"])
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A"])
    #expect(world.taken == ["A": DeepTranscriptionJobs.runningText])
}

@Test @MainActor func aJobLeftRunningByAnotherProcessOrAnotherSchedulerHoldsPassesBack() {
    let world = World(deep: ["A"], runNow: ["A"])
    world.lock = .held(.init(pid: 42, sessionID: "X", force: false))
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(world.jobs.lock.isDeepPass, "Queued meetings wait for another final transcript.")
    world.lock = .held(.init(pid: 42, sessionID: "X", force: false, kind: DeepTranscriptionLock.Holder.echoKind))
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty)
    #expect(!world.jobs.lock.isDeepPass)
    world.otherRunning = true
    world.lock = .free
    world.jobs.schedule()
    #expect(world.runner.started.isEmpty, "This app's summary or echo analysis is another job.")
    world.otherRunning = false
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

@Test @MainActor func aSignalThatReachesAFinishedPassLetsItsEndStand() {
    let world = World(deep: ["A"])
    world.jobs.schedule()
    world.busy = true
    world.jobs.meetingStateChanged()
    world.runner.finishLast(0)
    #expect(!world.deep.queue.contains("A"))
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

@Test @MainActor func aPassTheLockRefusedHoldsEveryPassForAMinute() {
    let world = World(deep: ["A", "B"])
    world.jobs.schedule()
    world.runner.finishLast(1, errors: busyMessage)
    #expect(world.runner.started == ["deep A"], "B waits too.")
    world.now = base.addingTimeInterval(59)
    world.jobs.schedule()
    #expect(world.runner.started.count == 1)
    world.now = base.addingTimeInterval(60)
    world.jobs.schedule()
    #expect(world.runner.started == ["deep A", "deep A"])
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
    #expect(world.events.contains("released deep A"))
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
