import Foundation
import HolosCore
import HolosTestSupport
import Testing
@testable import HolosMeeting

@MainActor
struct AudioCleanupJobsTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated private static let day: TimeInterval = 86_400

    nonisolated private static func meeting(_ id: String, daysOld: Double, chunks: Int = 4, state: SessionState = .complete,
                                speakers: SpeakerLabelState = .labelled, transcript: String? = "t",
                                audioDeleted: Bool = false, liveness: RecorderLiveness = .exited) -> SessionSummary {
        SessionSummary(id: id, directory: URL(fileURLWithPath: "/nowhere/\(id).holos"), name: id,
                       createdAt: now.addingTimeInterval(-daysOld * day), source: .system, state: state,
                       manifestStatus: "complete", savedSeconds: 600, chunkCount: chunks, transcriptID: transcript,
                       speakerState: speakers, liveness: liveness, audioDeleted: audioDeleted)
    }

    @Test func onlyFinishedMeetingsOldEnoughLoseTheirAudio() {
        func eligible(_ summary: SessionSummary, pending: Set<String> = []) -> Bool {
            AudioCleanupPolicy.eligible(summary, now: Self.now, days: 7, pending: pending)
        }
        #expect(eligible(Self.meeting("old", daysOld: 7)), "Exactly seven days old counts.")
        #expect(!eligible(Self.meeting("young", daysOld: 6.9)))
        #expect(!eligible(Self.meeting("unlabelled", daysOld: 30, speakers: .notLabelled)),
                "Speakers not labelled yet still need the audio.")
        #expect(!eligible(Self.meeting("no-transcript", daysOld: 30, transcript: nil)))
        #expect(!eligible(Self.meeting("interrupted", daysOld: 30, state: .interrupted)), "Recover needs the audio.")
        #expect(!eligible(Self.meeting("gone", daysOld: 30, audioDeleted: true)))
        #expect(!eligible(Self.meeting("none", daysOld: 30, chunks: 0)))
        #expect(!eligible(Self.meeting("busy", daysOld: 30, liveness: .maintenance)), "Another command holds it.")
        var unreadable = Self.meeting("unreadable", daysOld: 30)
        unreadable.metadataProblem = "damaged"
        #expect(!eligible(unreadable), "Unknown language or naming state keeps the audio.")
        #expect(!AudioCleanupPolicy.eligible(Self.meeting("recovered", daysOld: 30), now: Self.now, days: 7, pending: [],
                                             audioNeeded: "part of its audio was never transcribed"),
                "What the files show (a transcript leaving audio out, an unreadable journal) keeps the audio.")
        #expect(!eligible(Self.meeting("queued", daysOld: 30), pending: ["queued"]),
                "A final transcript or echo analysis still queued needs the audio.")
    }

    private static func holds(inUse: Set<String> = []) -> BackgroundJobHolds {
        BackgroundJobHolds(inUse: inUse, now: now)
    }

    private static func jobs(_ meetings: [SessionSummary], days: Int? = 7,
                             unfinished: Set<String> = []) async -> AudioCleanupJobs {
        let jobs = AudioCleanupJobs(list: { _, _ in meetings }, read: { session, _ in
            meetings.first { $0.directory == session } ?? meeting("missing", daysOld: 0, chunks: 0)
        }, deletionUnfinished: { session in unfinished.contains(session.deletingPathExtension().lastPathComponent) },
           clock: { now }, audioNeeded: { _, _ in nil })
        jobs.root = URL(fileURLWithPath: "/nowhere")
        jobs.olderThanDays = { days }
        var scanned = false
        jobs.onScanned = { scanned = true }
        jobs.lookForWork(holds())
        _ = await eventually { scanned }
        return jobs
    }

    @Test func nothingIsPickedWhileTheCleanupIsOff() async {
        let jobs = await Self.jobs([Self.meeting("a", daysOld: 30)])
        #expect(jobs.next(Self.holds()) != nil)
        jobs.olderThanDays = { nil }
        #expect(jobs.next(Self.holds()) == nil)
        #expect(jobs.preparation(for: BackgroundJobPick(sessionID: "a", path: "/nowhere/a.holos", priority: .automatic,
            command: .init(arguments: [], output: "", errors: nil, maxOutputBytes: 0)))?() == false)
    }

    @Test func theOldestMeetingGoesFirstAndNoneTwiceInALaunch() async throws {
        let jobs = await Self.jobs([Self.meeting("recent", daysOld: 10), Self.meeting("oldest", daysOld: 40),
                                    Self.meeting("open", daysOld: 50), Self.meeting("new", daysOld: 1)])
        let pick = try #require(jobs.next(Self.holds(inUse: ["open"])))
        #expect(pick.sessionID == "oldest", "The open meeting is skipped, and the oldest of the rest goes first.")
        #expect(pick.priority == .automatic)
        #expect(pick.command.arguments == ["session", "clean-audio", "/nowhere/oldest.holos", "--older-than", "7", "--json"],
                "The command decides again under the meeting's lease.")
        var deleted: [String] = []
        jobs.onDeleted = { deleted.append($0) }
        #expect(jobs.ended("oldest", result: CommandResult(code: 0, outcome: .init(sessionID: "x", result: .deleted)),
                           preempted: false) == .finished)
        #expect(deleted == ["oldest"])
        #expect(jobs.next(Self.holds(inUse: ["open"]))?.sessionID == "recent")
        #expect(jobs.ended("recent", result: CommandResult(code: 1, outcome: nil), preempted: false) == .finished)
        #expect(deleted == ["oldest"], "A failed run deletes nothing.")
        #expect(jobs.next(Self.holds(inUse: ["open"])) == nil, "Neither is tried again before the next launch.")
    }

    @Test func aMeetingChangedSinceTheScanIsLeftAlone() async throws {
        let jobs = await Self.jobs([Self.meeting("a", daysOld: 30)])
        let pick = try #require(jobs.next(Self.holds()))
        jobs.pending = { ["a"] }
        #expect(jobs.preparation(for: pick)?() == false, "A final transcript was queued on it since the scan.")
        #expect(jobs.nothingToDo("a") == .finished)
    }

    @Test func aDeletionLeftPartWayIsFinishedFirst() async throws {
        // Marked deleted with its audio still there (a quit during a deletion): young and unlabelled, it is finished
        // anyway, before an old meeting's new deletion.
        let leftover = Self.meeting("leftover", daysOld: 1, speakers: .notLabelled, audioDeleted: true)
        let jobs = await Self.jobs([Self.meeting("old", daysOld: 30), leftover], unfinished: ["leftover"])
        #expect(jobs.unfinished == ["leftover"])
        let pick = try #require(jobs.next(Self.holds()))
        #expect(pick.sessionID == "leftover")
        #expect(jobs.preparation(for: pick)?() == true)
        #expect(jobs.ended("leftover", result: CommandResult(code: 0, outcome: .init(sessionID: "x", result: .deleted)),
                           preempted: false) == .finished)
        #expect(jobs.unfinished.isEmpty)
        #expect(jobs.next(Self.holds())?.sessionID == "old")
    }

    @Test func aDeletionStoppedByAMeetingIsFinishedNextTime() async throws {
        let jobs = await Self.jobs([Self.meeting("a", daysOld: 30)])
        let pick = try #require(jobs.next(Self.holds()))
        #expect(jobs.ended(pick.sessionID, result: CommandResult(code: 143, outcome: nil), preempted: true) == .stopped)
        #expect(jobs.unfinished.isEmpty, "Nothing is assumed under way: the next scan reads the files.")
        let again = try #require(jobs.next(Self.holds()))
        #expect(again.sessionID == "a")
        #expect(jobs.preparation(for: again)?() == true,
                "Stopped before the marker: nothing to finish, so the meeting is judged as any other, and still goes.")
        #expect(jobs.next(Self.holds(inUse: ["a"])) == nil, "Never while the app works on it.")
    }

    @Test func aDeletionLeftPartWayWaitsWhileTheMeetingIsLive() async {
        let live = Self.meeting("live", daysOld: 30, audioDeleted: true, liveness: .maintenance)
        let jobs = await Self.jobs([live], unfinished: ["live"])
        #expect(jobs.unfinished == ["live"])
        #expect(jobs.next(Self.holds()) == nil)
        #expect(!AudioCleanupPolicy.finishes(live, unfinished: true))
        #expect(!AudioCleanupPolicy.finishes(Self.meeting("done", daysOld: 30, audioDeleted: true), unfinished: false),
                "Nothing left: nothing to finish.")
    }

    @Test func nothingIsPickedBeforeTheLaunchReconcilesAndAChangedSettingStopsAPick() async throws {
        let jobs = await Self.jobs([Self.meeting("a", daysOld: 30)])
        #expect(jobs.reviewHold == .deleteAudio, "A review open on it is held as for Delete Audio.")
        var waiting = true
        jobs.waiting = { waiting }
        #expect(jobs.next(Self.holds()) == nil, "Final transcripts may still be queued for meetings saved meanwhile.")
        waiting = false
        let pick = try #require(jobs.next(Self.holds()))
        #expect(jobs.stillWanted(pick))
        jobs.olderThanDays = { 14 }
        #expect(!jobs.stillWanted(pick), "The days changed while the meeting was read.")
        jobs.olderThanDays = { nil }
        #expect(!jobs.stillWanted(pick), "The cleanup was turned off.")
        jobs.olderThanDays = { 7 }
        jobs.pending = { ["a"] }
        #expect(!jobs.stillWanted(pick), "A final transcript was queued on it.")
        // A stopped run is not assumed under way: queued work still holds it.
        #expect(jobs.ended("a", result: CommandResult(code: 143, outcome: nil), preempted: true) == .stopped)
        #expect(jobs.next(Self.holds()) == nil, "Not picked while work is queued on it.")
        #expect(!jobs.stillWanted(pick))
        // A deletion the files show unfinished is finished even so: that audio is going anyway, and leaving it would
        // pick it forever.
        let leftover = await Self.jobs([Self.meeting("left", daysOld: 30, audioDeleted: true)], unfinished: ["left"])
        leftover.pending = { ["left"] }
        #expect(leftover.stillWanted(try #require(leftover.next(Self.holds()))))
    }
}
