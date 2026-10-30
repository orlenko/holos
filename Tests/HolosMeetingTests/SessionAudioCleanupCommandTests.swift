import Foundation
import HolosCore
@testable import HolosStorage
import HolosTestSupport
import Testing
@testable import HolosMeeting

struct SessionAudioCleanupCommandTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The meeting as the catalog reads it under the command's own lease (shown as maintenance).
    private static func summary(_ session: URL, id: String, speakers: SpeakerLabelState = .labelled,
                                audioDeleted: Bool = false) -> SessionSummary {
        SessionSummary(id: id, directory: session, name: "Fixture", createdAt: now.addingTimeInterval(-30 * 86_400),
                       source: .microphone, state: .complete, manifestStatus: "complete", savedSeconds: 60,
                       chunkCount: 2, transcriptID: "t", speakerState: speakers, liveness: .maintenance,
                       audioDeleted: audioDeleted)
    }

    private static func meeting(_ temp: TemporaryDirectory) async throws -> (URL, String) {
        let archive = try SessionArchive.create(root: temp.url, name: "Fixture", source: .microphone, locale: "en-CA",
                                                backend: .speech)
        try await archive.finish(status: ArchiveStatus.complete)
        let (session, id) = (archive.directory, archive.id)
        try FileManager.default.createDirectory(at: session.appendingPathComponent("audio/mic", isDirectory: true),
                                                withIntermediateDirectories: true)
        return (session, id)
    }

    @Test func aDryRunDecidesTheSameAndDeletesNothing() async throws {
        let temp = try TemporaryDirectory("clean-audio-dry", permissions: 0o700)
        defer { temp.remove() }
        let (session, id) = try await Self.meeting(temp)
        let outcome = try SessionAudioCleanupCommand.run(
            .init(session: session, olderThanDays: 7, now: Self.now, dryRun: true),
            read: { url, _ in Self.summary(url, id: id) }, audioNeeded: { _, _ in nil })
        #expect(outcome.result == .wouldDelete)
        #expect(outcome.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: SessionPaths.audioDeleted(session).path))
    }

    @Test func anEligibleMeetingLosesItsAudioUnderItsLease() async throws {
        let temp = try TemporaryDirectory("clean-audio", permissions: 0o700)
        defer { temp.remove() }
        let (session, id) = try await Self.meeting(temp)
        let outcome = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 7, now: Self.now),
                                                         read: { url, _ in Self.summary(url, id: id) },
                                                         audioNeeded: { _, _ in nil })
        #expect(outcome == .init(sessionID: id, result: .deleted))
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: SessionPaths.audioDeleted(session).path))
        #expect(!SessionDeletion.audioDeletionUnfinished(session: session))
    }

    @Test func aMeetingChangedSinceThePickKeepsItsAudio() async throws {
        let temp = try TemporaryDirectory("clean-audio-kept", permissions: 0o700)
        defer { temp.remove() }
        let (session, id) = try await Self.meeting(temp)
        // A relabel started and cancelled since the app's scan: decided again under the lease, the audio stays.
        let outcome = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 7, now: Self.now),
                                                         read: { url, _ in Self.summary(url, id: id, speakers: .notLabelled) },
                                                         audioNeeded: { _, _ in nil })
        #expect(outcome.result == .kept)
        #expect(outcome.reason == "speakers not labelled")
        #expect(outcome.exitCode == 3)
        #expect(!FileManager.default.fileExists(atPath: SessionPaths.audioDeleted(session).path))
        let young = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 60, now: Self.now),
                                                       read: { url, _ in Self.summary(url, id: id) },
                                                       audioNeeded: { _, _ in nil })
        #expect(young.result == .kept, "Thirty days old is younger than sixty.")
    }

    @Test func aDeletionLeftPartWayIsFinishedWhateverTheAge() async throws {
        let temp = try TemporaryDirectory("clean-audio-finish", permissions: 0o700)
        defer { temp.remove() }
        let (session, id) = try await Self.meeting(temp)
        try Data("{}".utf8).write(to: SessionPaths.audioDeleted(session))
        let outcome = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 365, now: Self.now),
                                                         read: { url, _ in Self.summary(url, id: id, audioDeleted: true) },
                                                         audioNeeded: { _, _ in nil })
        #expect(outcome.result == .finished)
        #expect(!SessionDeletion.audioDeletionUnfinished(session: session))
    }

    @Test func anotherBackgroundJobKeepsItFromStarting() async throws {
        let temp = try TemporaryDirectory("clean-audio-lock", permissions: 0o700)
        defer { temp.remove() }
        let (session, id) = try await Self.meeting(temp)
        let lock = temp.url.appendingPathComponent("job.lock")
        let other = try #require(try DeepTranscriptionLock.take(.init(pid: getpid(), sessionID: "other", force: false),
                                                                at: lock))
        defer { other.release() }
        #expect(throws: HolosError.self) {
            try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 7, jobLock: lock, now: Self.now),
                                               read: { url, _ in Self.summary(url, id: id) }, audioNeeded: { _, _ in nil })
        }
        #expect(!FileManager.default.fileExists(atPath: SessionPaths.audioDeleted(session).path))
    }

    @Test func onlyWhatTheFilesShowLetsTheAudioGo() async throws {
        let temp = try TemporaryDirectory("clean-audio-evidence", permissions: 0o700)
        defer { temp.remove() }
        let (session, id) = try await Self.meeting(temp)
        #expect(AudioCleanupPolicy.audioNeeded(session: session, transcriptID: nil) == "no readable transcript")
        // No meeting.json: it reads as a one-language meeting, which is not evidence.
        #expect(AudioCleanupPolicy.audioNeeded(session: session, transcriptID: "t")
            == "its meeting.json is missing or cannot be read")
        var info = MeetingInfo(sessionID: id, mode: .call, othersInRoom: false)
        info.languages = ["en-CA", "fr-CA"]
        try AtomicFile.writeJSON(info, to: SessionPaths.meetingInfo(session))
        // A whole journal, but no speaker labels made for the transcript.
        #expect(AudioCleanupPolicy.audioNeeded(session: session, transcriptID: "t")
            == "its speaker labels are not for its transcript")
        // A meeting in several languages whose journal cannot be read: the catalog would show no language work left.
        try FileManager.default.removeItem(at: SessionPaths.events(session))
        #expect(AudioCleanupPolicy.audioNeeded(session: session, transcriptID: "t")
            == "its event journal is missing or damaged", "A missing journal reads as empty; it is not evidence.")
        try Data("{\"sequence\":1".utf8).write(to: SessionPaths.events(session))
        #expect(AudioCleanupPolicy.audioNeeded(session: session, transcriptID: "t")
            == "its event journal is missing or damaged", "A torn line is skipped on read; it is not evidence either.")
        let outcome = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 7, now: Self.now),
                                                         read: { url, _ in Self.summary(url, id: id) })
        #expect(outcome.result == .kept)
        #expect(outcome.reason == "its event journal is missing or damaged")
    }

    @Test func anUnreadableManifestKeepsTheAudio() async throws {
        let temp = try TemporaryDirectory("clean-audio-manifest", permissions: 0o700)
        defer { temp.remove() }
        let (session, _) = try await Self.meeting(temp)
        try Data("not json".utf8).write(to: SessionPaths.manifest(session))
        #expect(AudioCleanupPolicy.audioNeeded(session: session, transcriptID: "t") == "its manifest cannot be read")
    }

    @Test func aMeetingJsonOfAnotherMeetingKeepsTheAudio() async throws {
        let temp = try TemporaryDirectory("clean-audio-other-info", permissions: 0o700)
        defer { temp.remove() }
        let (session, _) = try await Self.meeting(temp)
        try AtomicFile.writeJSON(MeetingInfo(sessionID: "someone-else", mode: .call, othersInRoom: false),
                                 to: SessionPaths.meetingInfo(session))
        #expect(AudioCleanupPolicy.audioNeeded(session: session, transcriptID: "t")
            == "its meeting.json is missing or cannot be read")
    }

    @Test func labelsForATranscriptItWasCorrectedFromAreItsLabels() {
        func event(_ sequence: Int, _ kind: String, _ id: String, base: String) -> ArchiveEvent {
            ArchiveEvent(sequence: sequence, at: Self.now, kind: kind, details: ["transcriptID": id, "base": base])
        }
        let events = [event(1, MeetingEventKind.wordsFixed, "B", base: "A"),
                      event(2, MeetingEventKind.transcriptEdited, "C", base: "B")]
        #expect(WordFixStage.correctionChain("C", events: events) == ["C", "B", "A"])
        #expect(WordFixStage.correctionChain("X", events: events) == ["X"], "A transcript no correction made.")
    }
}
