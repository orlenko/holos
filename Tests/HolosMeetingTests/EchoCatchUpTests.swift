import Foundation
import HolosAudio
import HolosCore
@testable import HolosMeeting
import HolosSpeakers
import HolosStorage
import Testing

// The app's echo catch-up (docs/meeting-design.md §5.11, "Catching up in the app"): which meetings get
// `voiceislocal session echo-analyze`, in what order, when, and what a run's end comes to. Invented meetings and
// short synthetic tracks in temporary folders; no process is started.

private let base = Date(timeIntervalSince1970: 1_790_953_200)

private func candidate(_ id: String, hoursAgo: Double = 1) -> EchoCatchUpSchedule.Candidate {
    EchoCatchUpSchedule.Candidate(sessionID: id, path: "/\(id).holos",
                                  createdAt: base.addingTimeInterval(-hoursAgo * 3600))
}

// MARK: - Selection and order

@Test func onlyFinishedMeetingsThatNeedTheAnalysisAreQueuedNewestFirst() {
    let found = [
        EchoCatchUpSchedule.Found(candidate: candidate("old", hoursAgo: 48), finished: true, needed: true),
        EchoCatchUpSchedule.Found(candidate: candidate("done", hoursAgo: 2), finished: true, needed: false),
        EchoCatchUpSchedule.Found(candidate: candidate("recording", hoursAgo: 0), finished: false, needed: true),
        EchoCatchUpSchedule.Found(candidate: candidate("new", hoursAgo: 1), finished: true, needed: true),
        EchoCatchUpSchedule.Found(candidate: candidate("b-tie", hoursAgo: 5), finished: true, needed: true),
        EchoCatchUpSchedule.Found(candidate: candidate("a-tie", hoursAgo: 5), finished: true, needed: true),
    ]
    #expect(EchoCatchUpSchedule.select(found).map(\.sessionID) == ["new", "a-tie", "b-tie", "old"])
    #expect(EchoCatchUpSchedule.select([]).isEmpty)
}

/// A finished meeting with the given tracks (a few seconds of quiet noise each), as a call unless `mode` says not.
private func meeting(in root: URL, tracks: [String], mode: MeetingMode = .call, finish: Bool = true) async throws
    -> URL {
    let archive = try SessionArchive.create(root: root, name: "Fixture", source: .microphoneAndSystem,
                                            locale: "en-CA", backend: .speech)
    try AtomicFile.writeJSON(MeetingInfo(sessionID: archive.id, mode: mode, othersInRoom: false,
                                         createdAt: SessionFixtures.date),
                             to: SessionPaths.meetingInfo(archive.directory))
    let writer = AudioChunkWriter(archive: archive)
    for (index, track) in tracks.enumerated() {
        let samples = (0..<32_000).map { Float(sin(Double($0 * (index + 3)) * 0.01)) * 0.01 }
        let frame = try PCMFrame(samples: samples, sampleRate: 16_000, channels: 1, startTime: 0)
        try await writer.append(CapturedAudio(track: track, frame: frame))
    }
    try await writer.finish()
    if finish { try await archive.finish(status: ArchiveStatus.complete) }
    return archive.directory
}

@Test(.timeLimit(.minutes(1)))
func theScanFindsCallsWithBothTracksAndNoSavedAnalysis() async throws {
    let temp = try TemporaryDirectory("echo-catch-up")
    defer { temp.remove() }
    let needing = try await meeting(in: temp.url, tracks: ["mic", "system"])
    let analysed = try await meeting(in: temp.url, tracks: ["mic", "system"])
    let micOnly = try await meeting(in: temp.url, tracks: ["mic"])
    let inPerson = try await meeting(in: temp.url, tracks: ["mic", "system"], mode: .inPerson)
    let unfinished = try await meeting(in: temp.url, tracks: ["mic", "system"], finish: false)
    // A saved verdict of this audio counts as done, also one that hides nothing.
    let manifest = try SessionArchive.readManifest(at: analysed)
    try EchoMaskStore.write(EchoMaskRecord(sessionID: manifest.id, audio: EchoMaskStore.audioKey(manifest: manifest),
                                           verdict: .noEcho),
                            mask: nil, session: analysed)

    #expect(EchoCatchUpSchedule.needsAnalysis(session: needing))
    #expect(!EchoCatchUpSchedule.needsAnalysis(session: analysed))
    #expect(!EchoCatchUpSchedule.needsAnalysis(session: micOnly), "No system track: nothing to compare.")
    #expect(!EchoCatchUpSchedule.needsAnalysis(session: inPerson), "Not a call.")
    let found = EchoCatchUpSchedule.scan(root: temp.url)
    #expect(found.map(\.path) == [needing.path],
            "The unfinished meeting waits for its own post-processing or Recover: \(unfinished.lastPathComponent)")
}

// MARK: - When a run starts

@Test func meetingsInUseUnderReviewFailedOrDelayedWaitAndTheNextReadyOneRuns() {
    let queue = [candidate("A", hoursAgo: 1), candidate("B", hoursAgo: 2), candidate("C", hoursAgo: 3),
                 candidate("D", hoursAgo: 4)]
    #expect(EchoCatchUpSchedule.next(queue, .init(now: base)) == .run(queue[0]))
    // A command or a review holds A, B failed in this launch, C is turned down for a while: D runs.
    var situation = EchoCatchUpSchedule.Situation(inUse: ["A"], failed: ["B"],
                                                  delayedUntil: ["C": base.addingTimeInterval(60)], now: base)
    #expect(EchoCatchUpSchedule.ready(queue, situation).map(\.sessionID) == ["D"])
    #expect(EchoCatchUpSchedule.next(queue, situation) == .run(queue[3]))
    // Once C's delay is over it goes first again (newest first).
    situation.now = base.addingTimeInterval(60)
    #expect(EchoCatchUpSchedule.next(queue, situation) == .run(queue[2]))
    // Nothing ready: idle, whatever else goes on.
    let blocked = EchoCatchUpSchedule.Situation(meetingBusy: true, inUse: ["A", "B", "C", "D"], now: base)
    #expect(EchoCatchUpSchedule.next(queue, blocked) == .idle)
    #expect(EchoCatchUpSchedule.next([], .init(now: base)) == .idle)
}

@Test func oneJobAtATimeAndWorkTheUserAskedForGoesFirst() {
    let queue = [candidate("A")]
    #expect(EchoCatchUpSchedule.next(queue, .init(running: "A", now: base)) == .idle, "A run is going on.")
    #expect(EchoCatchUpSchedule.next(queue + [candidate("B", hoursAgo: 2)], .init(running: "A", now: base)) == .idle)
    #expect(EchoCatchUpSchedule.next(queue, .init(meetingBusy: true, now: base)) == .wait)
    #expect(EchoCatchUpSchedule.next(queue, .init(otherJobRunning: true, now: base)) == .wait)
    #expect(EchoCatchUpSchedule.next(queue, .init(askedForWorkWaiting: true, now: base)) == .wait)
    // Ready regardless: an automatic final transcript or summary waits for it.
    #expect(EchoCatchUpSchedule.ready(queue, .init(meetingBusy: true, otherJobRunning: true, now: base)) == queue)
}

// MARK: - How a run ends

@Test func aRunsExitDecidesWhatBecomesOfTheMeeting() {
    #expect(EchoCatchUpSchedule.runEnded(code: 0, summary: "Microphone echo found.", errors: "") == .done)
    // Another process held the meeting, or it records again: tried again later.
    #expect(EchoCatchUpSchedule.runEnded(
        code: 1, summary: nil, errors: "Error: Another Voice is Local process is processing this session.\n")
        == .retryLater)
    #expect(EchoCatchUpSchedule.runEnded(
        code: 1, summary: nil, errors: "Error: This meeting is still recording. Stop it before analysing its echo.\n")
        == .retryLater)
    // Refused for good in this launch, in the command's words (progress lines left out).
    #expect(EchoCatchUpSchedule.runEnded(
        code: 1, summary: nil,
        errors: "Preparing the system audio…\nError: Not enough disk space to prepare the audio. Free some space, "
            + "then try again.\n")
        == .failed("Not enough disk space to prepare the audio. Free some space, then try again."))
    #expect(EchoCatchUpSchedule.runEnded(code: 137, summary: nil, errors: "")
        == .failed("The command stopped unexpectedly (signal 9)."))
    // Saved, but the transcript files or a voice sample were not brought in step.
    #expect(EchoCatchUpSchedule.runEnded(code: 3, summary: "Saved. The transcript files could not be rewritten.",
                                         errors: "") == .partial("Saved. The transcript files could not be rewritten."))
}

@Test func aMeetingTurnedDownWaitsLongerEachTimeAndAFailureIsTriedOncePerLaunch() {
    #expect((1...7).map { EchoCatchUpSchedule.retryDelay(attempts: $0) } == [60, 120, 240, 480, 960, 1_800, 1_800])
    #expect(EchoCatchUpSchedule.retryDelay(attempts: 0) == 60)

    // A launch: A fails, so B runs next; A is still needed (a rescan finds it again) but not tried again.
    var queue = [candidate("A", hoursAgo: 1), candidate("B", hoursAgo: 2)]
    var failed: Set<String> = []
    guard case .run(let first) = EchoCatchUpSchedule.next(queue, .init(failed: failed, now: base)) else {
        Issue.record("A runs first")
        return
    }
    #expect(first.sessionID == "A")
    if case .failed = EchoCatchUpSchedule.runEnded(code: 1, summary: nil, errors: "Error: The audio is damaged.") {
        failed.insert("A")
        queue.removeAll { $0.sessionID == "A" }
    }
    #expect(EchoCatchUpSchedule.next(queue, .init(failed: failed, now: base)) == .run(candidate("B", hoursAgo: 2)))
    queue = [candidate("A", hoursAgo: 1)]
    #expect(EchoCatchUpSchedule.next(queue, .init(failed: failed, now: base)) == .idle)
    // The next launch starts with nothing failed: A is tried once more.
    #expect(EchoCatchUpSchedule.next(queue, .init(now: base)) == .run(candidate("A", hoursAgo: 1)))
}

// MARK: - What the Meetings list shows

@Test func theListShowsQueuedMeetingsAndRunsThatDidNotFinish() {
    let queue = [candidate("A"), candidate("B"), candidate("C")]
    #expect(EchoCatchUpSchedule.stateTexts(queue, running: "A", failed: ["C"]) == ["B": "Echo removal queued"])
    #expect(EchoCatchUpSchedule.problemText(.done) == nil)
    #expect(EchoCatchUpSchedule.problemText(.retryLater) == nil)
    #expect(EchoCatchUpSchedule.problemText(.failed("The audio is damaged")) == "The call's echo was not removed from this meeting. The audio is damaged. Voice is Local tries "
        + "again the next time it starts.")
    #expect(EchoCatchUpSchedule.problemText(.partial("The transcript files could not be rewritten."))?
        .hasPrefix("The call's echo was removed from this meeting, but") == true)

    let summary = SessionSummary(id: "A", directory: URL(fileURLWithPath: "/A.holos"), name: "Call", createdAt: base,
                                 source: .microphoneAndSystem, state: .complete, manifestStatus: "complete",
                                 transcriptID: "T", speakerState: .labelled, liveness: .exited)
    #expect(MeetingListFormat.badges(summary, livePhase: nil, working: nil, echoNotRemoved: true)
        == [MeetingListFormat.Badge("Echo not removed", .warning)])
    #expect(MeetingListFormat.badges(summary, livePhase: nil, working: "Removing echo…", echoNotRemoved: true)
        == [MeetingListFormat.Badge("Removing echo…", .progress)], "What runs now is said instead.")
    #expect(MeetingListFormat.badges(summary, livePhase: nil, working: nil).isEmpty)
}

@Test func aReviewOpenedWhileTheEchoIsAnalysedIsReadOnlyUntilItEnds() {
    guard case .readOnly(let banner) = ReviewMaintenance.response(to: .echoAnalysis) else {
        Issue.record("The echo catch-up makes a review read-only, then rereads it")
        return
    }
    #expect(banner.contains("echo"))
}
