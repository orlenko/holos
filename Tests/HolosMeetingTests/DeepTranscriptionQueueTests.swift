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
    // The user acted on the meeting while its languages were read (Run Now, maybe cancelled since): left alone.
    #expect(!DeepTranscriptionSchedule.queuesAfterMeeting(enabled: true, modelInstalled: true, languages: 1,
                                                          queued: true))
    #expect(!DeepTranscriptionSchedule.queuesAfterMeeting(enabled: true, modelInstalled: true, languages: 1,
                                                          considered: true))
}

@Test func withTheSettingOffOnlyRunNowItemsAndTheRunningPassStay() {
    var items = queue(["A", "B", "C"], runNow: ["B"])
    // On: nothing is dropped.
    let on = items.dropAutomatic(enabled: true, running: nil)
    #expect(!on && items.items.count == 3)
    // Off while the app's pass on A runs: A stays until it ends.
    let whileRunning = items.dropAutomatic(enabled: false, running: "A")
    #expect(whileRunning && items.items.map(\.sessionID) == ["A", "B"])
    // Off with nothing of the app's running (at launch, on every tick, after a busy exit): every automatic item goes.
    let idle = items.dropAutomatic(enabled: false, running: nil)
    #expect(idle && items.items.map(\.sessionID) == ["B"])
    let again = items.dropAutomatic(enabled: false, running: nil)
    #expect(!again, "Nothing left to drop.")
}

@Test func runNowIsOfferedForAnAutomaticallyQueuedMeeting() {
    let items = queue(["A", "B"], runNow: ["B"])
    #expect(DeepTranscriptionSchedule.offersRunNow(sessionID: "A", queue: items, running: nil))
    #expect(!DeepTranscriptionSchedule.offersRunNow(sessionID: "B", queue: items, running: nil), "Already asked for.")
    #expect(DeepTranscriptionSchedule.offersRunNow(sessionID: "C", queue: items, running: nil), "Not queued.")
    #expect(!DeepTranscriptionSchedule.offersRunNow(sessionID: "A", queue: items, running: "A"), "Running.")
    // Asked for, the automatic item is upgraded in place.
    var upgraded = items
    upgraded.enqueue(sessionID: "A", path: "/m/A.holos", at: date, runNow: true)
    #expect(upgraded.items.map(\.sessionID) == ["A", "B"] && upgraded.items[0].runNow)
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

@Test func aCommandRefusedForAnotherProcessStaysQueued() {
    #expect(DeepTranscriptionSchedule.isBusyElsewhere(
        "Error: Another Voice is Local process is processing this session."))
    #expect(DeepTranscriptionSchedule.isBusyElsewhere("Error: " + DeepTranscriptionLock.busyMessage))
    #expect(!DeepTranscriptionSchedule.isBusyElsewhere("Error: This session has no saved audio."))
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

@Test func aQueueSavedByAnEarlierVersionIsReadWithoutItsProcessFields() throws {
    // Saved while a pass ran (pid and start time), and after an unseen end (started, verifyOnly).
    let old = Data(#"{"schemaVersion":1,"items":[{"sessionID":"A","path":"/m/A.holos","queuedAt":"2027-01-15T08:00:00Z","runNow":false,"pid":4242,"pidStart":77,"started":true},{"sessionID":"B","path":"/m/B.holos","queuedAt":"2027-01-15T08:00:00Z","runNow":true,"verifyOnly":true}]}"#.utf8)
    let read = DeepTranscriptionQueue.decode(old)
    #expect(read.items.map(\.sessionID) == ["A", "B"])
    let raw = String(decoding: try #require(read.encoded()), as: UTF8.self)
    #expect(!raw.contains("pid") && !raw.contains("started") && !raw.contains("verifyOnly"))
    #expect(DeepTranscriptionQueue.decode(read.encoded()) == read)
}

@Test func aPassCutShortRunsAgainWithTheFlagsItWasQueuedWith() {
    // A (automatic) and B (Run Now) were running or waiting when the app quit; nothing records which.
    let items = DeepTranscriptionQueue.decode(queue(["A", "B"], runNow: ["B"]).encoded())
    let ready = DeepTranscriptionSchedule.Situation(enabled: true, modelInstalled: true, power: .ac)
    // Run Now goes first and keeps --force (a pass of it that did finish before the quit is made again).
    #expect(DeepTranscriptionSchedule.next(items, ready) == .run("B"))
    #expect(DeepTranscriptionSchedule.forces(items.items[1]))
    // The automatic one runs without it: the command keeps a transcript the model already made.
    #expect(!DeepTranscriptionSchedule.forces(items.items[0]))
}

@Test func queuedMeetingsWaitForAnotherProcessesPass() {
    let items = queue(["A", "B"], runNow: ["B"])
    for id in ["A", "B"] {
        #expect(DeepTranscriptionSchedule.stateText(sessionID: id, queue: items, running: nil, power: .battery,
                                                    otherPassRunning: true)
            == "Waiting for another final transcript to finish")
    }
    #expect(DeepTranscriptionSchedule.stateText(sessionID: "C", queue: items, running: nil, power: .ac,
                                                otherPassRunning: true) == nil)
}

@Test func turningTheSettingOffKeepsTheRunningPassUntilItEnds() {
    var items = queue(["A", "B", "C"], runNow: ["C"])
    items.removeAutomatic(keeping: "A")
    #expect(items.items.map(\.sessionID) == ["A", "C"])
}

@Test func aFailedRunNowSaysWhy() {
    let record = PostProcessingRecord(sessionID: "S", state: .partial, stages: [
        StageOutcome(stage: .transcript, result: .skipped, message: "No transcript to label."),
        StageOutcome(stage: .deepTranscription, result: .failed, message: "Kept the transcript as it was. 1 stretch of audio could not be transcribed."),
        StageOutcome(stage: .diarize, result: .failed, message: "Speaker labelling failed."),
    ], pid: 1, startedAt: date, updatedAt: date)
    #expect(DeepTranscriptionSchedule.failureText(code: 3, record: record, errors: "")
        == "Kept the transcript as it was. 1 stretch of audio could not be transcribed.\nSpeaker labelling failed.")
    // Refused before it ran: the error, not the progress lines before it.
    let errors = "Loading the deep transcription model…\nTranscribing (microphone)… 10 %\nError: The deep transcription model is not installed.\n"
    #expect(DeepTranscriptionSchedule.failureText(code: 1, record: nil, errors: errors)
        == "The deep transcription model is not installed.")
    #expect(DeepTranscriptionSchedule.failureText(code: 137, record: nil, errors: "")
        == "The command stopped unexpectedly (signal 9).")
}
