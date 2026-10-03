import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// The app's deep transcription queue and when it runs a pass (docs/meeting-design.md §4.16, "App"). Pure.

private let date = Date(timeIntervalSince1970: 1_800_000_000)

private func queue(_ ids: [String], runNow: Set<String> = []) -> DeepTranscriptionQueue {
    var queue = DeepTranscriptionQueue()
    for id in ids { queue.enqueue(sessionID: id, path: "/m/\(id).holos", at: date, runNow: runNow.contains(id)) }
    return queue
}

@Test func theQueueKeepsOrderAndUpgradesARunNow() throws {
    var items = queue(["A", "B"])
    items.enqueue(sessionID: "A", path: "/moved/A.holos", at: date.addingTimeInterval(5))
    #expect(items.items.map(\.sessionID) == ["A", "B"] && items.items[0].path == "/moved/A.holos")
    items.enqueue(sessionID: "B", path: "/m/B.holos", at: date, runNow: true)
    #expect(items.items[1].runNow)
    items.enqueue(sessionID: "C", path: "/m/C.holos", at: date)
    items.removeAutomatic()
    #expect(items.items.map(\.sessionID) == ["B"])
    items.remove("B")
    #expect(items.items.isEmpty)
    // Saved and read back; a damaged or newer one reads as empty.
    let saved = queue(["A"], runNow: ["A"])
    #expect(DeepTranscriptionQueue.decode(saved.encoded()) == saved)
    #expect(DeepTranscriptionQueue.decode(Data("{".utf8)).items.isEmpty)
    #expect(DeepTranscriptionQueue.decode(Data(#"{"schemaVersion":2,"items":[]}"#.utf8)).items.isEmpty)
    #expect(DeepTranscriptionQueue.decode(nil).items.isEmpty)
}

@Test func passesRunOneAtATimeOnACPowerWithTheModel() {
    let items = queue(["A", "B"])
    let ready = DeepTranscriptionSchedule.Situation(enabled: true, modelInstalled: true, power: .ac)
    #expect(DeepTranscriptionSchedule.next(items, ready) == .run("A"))
    var desktop = ready
    desktop.power = .unknown
    #expect(DeepTranscriptionSchedule.next(items, desktop) == .run("A"), "A Mac without a battery counts as AC.")
    var battery = ready
    battery.power = .battery
    #expect(DeepTranscriptionSchedule.next(items, battery) == .waitForPower)
    var running = ready
    running.running = "A"
    #expect(DeepTranscriptionSchedule.next(items, running) == .idle)
    var recording = ready
    recording.meetingBusy = true
    #expect(DeepTranscriptionSchedule.next(items, recording) == .idle)
    var noModel = ready
    noModel.modelInstalled = false
    #expect(DeepTranscriptionSchedule.next(items, noModel) == .idle)
    var busy = ready
    busy.inUse = ["A"]
    #expect(DeepTranscriptionSchedule.next(items, busy) == .run("B"), "A meeting in use waits its turn.")
    var off = ready
    off.enabled = false
    #expect(DeepTranscriptionSchedule.next(items, off) == .idle)
    #expect(DeepTranscriptionSchedule.next(DeepTranscriptionQueue(), ready) == .idle)
}

@Test func runNowGoesFirstWhateverThePower() {
    let items = queue(["A", "B"], runNow: ["B"])
    let situation = DeepTranscriptionSchedule.Situation(enabled: false, modelInstalled: true, power: .battery)
    #expect(DeepTranscriptionSchedule.next(items, situation) == .run("B"))
    var running = situation
    running.running = "B"
    #expect(DeepTranscriptionSchedule.next(items, running) == .idle)
}

@Test func onlyMeetingsInOneLanguageAreQueuedAfterRecording() {
    #expect(DeepTranscriptionSchedule.queuesAfterMeeting(enabled: true, modelInstalled: true, languages: 1))
    #expect(DeepTranscriptionSchedule.queuesAfterMeeting(enabled: true, modelInstalled: true, languages: 0))
    #expect(!DeepTranscriptionSchedule.queuesAfterMeeting(enabled: true, modelInstalled: true, languages: 2))
    #expect(!DeepTranscriptionSchedule.queuesAfterMeeting(enabled: false, modelInstalled: true, languages: 1))
    #expect(!DeepTranscriptionSchedule.queuesAfterMeeting(enabled: true, modelInstalled: false, languages: 1))
}

@Test func theMeetingsListSaysWhereAPassStands() {
    let items = queue(["A", "B"], runNow: ["B"])
    #expect(DeepTranscriptionSchedule.stateText(sessionID: "A", queue: items, running: "A", power: .ac)
        == "Final transcript in progress…")
    #expect(DeepTranscriptionSchedule.stateText(sessionID: "A", queue: items, running: nil, power: .battery)
        == "Final transcript waits for power")
    #expect(DeepTranscriptionSchedule.stateText(sessionID: "B", queue: items, running: nil, power: .battery)
        == "Final transcript queued")
    #expect(DeepTranscriptionSchedule.stateText(sessionID: "A", queue: items, running: nil, power: .ac)
        == "Final transcript queued")
    #expect(DeepTranscriptionSchedule.stateText(sessionID: "C", queue: items, running: nil, power: .ac) == nil)
}

@Test func aPassStillRunningFromBeforeARelaunchBlocksTheOthers() {
    let items = queue(["A", "B"], runNow: ["B"])
    var situation = DeepTranscriptionSchedule.Situation(enabled: true, modelInstalled: true, power: .ac,
                                                        waitingFor: "A")
    #expect(DeepTranscriptionSchedule.next(items, situation) == .run("A"), "Only A is tried until it can be had.")
    situation.inUse = ["A"]
    #expect(DeepTranscriptionSchedule.next(items, situation) == .idle)
    #expect(DeepTranscriptionSchedule.isLeaseConflict(
        "Error: Another Voice is Local process is processing this session."))
    #expect(!DeepTranscriptionSchedule.isLeaseConflict("Error: This session has no saved audio."))
}

@Test func reviewOwnsItsMeetingUntilItCloses() {
    let items = queue(["A"])
    let situation = DeepTranscriptionSchedule.Situation(enabled: true, modelInstalled: true, power: .ac,
                                                        inUse: ["A"])
    #expect(DeepTranscriptionSchedule.next(items, situation) == .idle)
}

@Test func onlyFinishedMeetingsCanBeTranscribedAgain() {
    for state in [SessionState.complete, .transcriptionIncomplete, .recovered, .audioOnly] {
        #expect(DeepTranscriptionSchedule.isFinished(state, audioDeleted: false))
        #expect(!DeepTranscriptionSchedule.isFinished(state, audioDeleted: true))
    }
    for state in [SessionState.recording, .processing, .interrupted, .incomplete, .failed, .damaged] {
        #expect(!DeepTranscriptionSchedule.isFinished(state, audioDeleted: false))
    }
}

@Test func meetingsThatFinishedWhileTheAppWasClosedAreQueuedOnce() {
    func candidate(_ id: String, after seconds: Double, finished: Bool = true, languages: Int = 1,
                   deep: Bool = false) -> DeepTranscriptionSchedule.Candidate {
        .init(sessionID: id, path: "/m/\(id).holos", createdAt: date.addingTimeInterval(seconds), finished: finished,
              languages: languages, hasDeepTranscript: deep)
    }
    let candidates = [
        candidate("before", after: -60), candidate("A", after: 60), candidate("live", after: 70, finished: false),
        candidate("two", after: 80, languages: 2), candidate("done", after: 90, deep: true),
        candidate("seen", after: 100), candidate("queued", after: 110), candidate("B", after: 120),
    ]
    let found = DeepTranscriptionSchedule.reconcile(candidates, enabledSince: date, considered: ["seen"],
                                                    queue: queue(["queued"]))
    #expect(found.map(\.sessionID) == ["A", "B"])
    #expect(DeepTranscriptionSchedule.reconcile(candidates, enabledSince: nil, considered: [],
                                                queue: DeepTranscriptionQueue()).isEmpty, "Never turned on.")
}
