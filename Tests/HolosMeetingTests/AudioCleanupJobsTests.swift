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
        #expect(!eligible(Self.meeting("queued", daysOld: 30), pending: ["queued"]),
                "A final transcript or echo analysis still queued needs the audio.")
    }

    private static func holds(inUse: Set<String> = []) -> BackgroundJobHolds {
        BackgroundJobHolds(inUse: inUse, now: now)
    }

    private static func jobs(_ meetings: [SessionSummary], days: Int? = 7) async -> AudioCleanupJobs {
        let jobs = AudioCleanupJobs(list: { _, _ in meetings }, read: { session, _ in
            meetings.first { $0.directory == session } ?? meeting("missing", daysOld: 0, chunks: 0)
        })
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
        #expect(pick.command.arguments == ["session", "delete", "/nowhere/oldest.holos", "--audio-only", "--yes", "--json"])
        #expect(pick.command.arguments.contains("--audio-only"), "Never the whole meeting.")
        var deleted: [String] = []
        jobs.onDeleted = { deleted.append($0) }
        #expect(jobs.ended("oldest", result: CommandResult(code: 0, outcome: .init(deleted: "audio")),
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
}
