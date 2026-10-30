import Foundation
import HolosCore
import HolosStorage
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

    @Test func anEligibleMeetingLosesItsAudioUnderItsLease() async throws {
        let temp = try TemporaryDirectory("clean-audio", permissions: 0o700)
        defer { temp.remove() }
        let (session, id) = try await Self.meeting(temp)
        let outcome = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 7, now: Self.now),
                                                         read: { url, _ in Self.summary(url, id: id) })
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
                                                         read: { url, _ in Self.summary(url, id: id, speakers: .notLabelled) })
        #expect(outcome.result == .kept)
        #expect(outcome.reason == "speakers not labelled")
        #expect(outcome.exitCode == 3)
        #expect(!FileManager.default.fileExists(atPath: SessionPaths.audioDeleted(session).path))
        let young = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 60, now: Self.now),
                                                       read: { url, _ in Self.summary(url, id: id) })
        #expect(young.result == .kept, "Thirty days old is younger than sixty.")
    }

    @Test func aDeletionLeftPartWayIsFinishedWhateverTheAge() async throws {
        let temp = try TemporaryDirectory("clean-audio-finish", permissions: 0o700)
        defer { temp.remove() }
        let (session, id) = try await Self.meeting(temp)
        try Data("{}".utf8).write(to: SessionPaths.audioDeleted(session))
        let outcome = try SessionAudioCleanupCommand.run(.init(session: session, olderThanDays: 365, now: Self.now),
                                                         read: { url, _ in Self.summary(url, id: id, audioDeleted: true) })
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
                                               read: { url, _ in Self.summary(url, id: id) })
        }
        #expect(!FileManager.default.fileExists(atPath: SessionPaths.audioDeleted(session).path))
    }
}
