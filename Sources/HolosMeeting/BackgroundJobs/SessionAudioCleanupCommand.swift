import Foundation
import HolosCore
import HolosStorage

/// What `voiceislocal session clean-audio` does (docs/design.md "Automatic audio cleanup"), as a library call: the
/// meeting's audio is deleted as Delete Audio does, only if `AudioCleanupPolicy` allows it as the meeting is now, read
/// under its processing lease, or a deletion of it that began and did not finish is finished. The app's automatic
/// audio cleanup runs it; nothing about the meeting is decided outside the lease.
public enum SessionAudioCleanupCommand {
    public struct Request: Sendable {
        public var session: URL
        /// The meeting must be at least this many days old.
        public var olderThanDays: Int
        /// The background-job lock held for the whole run (`DeepTranscriptionLock`, kind `audioCleanup`), so it runs
        /// alone with final transcripts, summaries and echo analyses, also across an app relaunch. Nil takes none
        /// (tests).
        public var jobLock: URL?
        public var now: Date

        public init(session: URL, olderThanDays: Int, jobLock: URL? = nil, now: Date = Date()) {
            self.session = session; self.olderThanDays = olderThanDays; self.jobLock = jobLock; self.now = now
        }
    }

    /// What `voiceislocal session clean-audio --json` prints, and what the app reads from it.
    public struct Outcome: Sendable, Equatable, Codable {
        public enum Result: String, Sendable, Codable {
            /// The audio was deleted now.
            case deleted
            /// A deletion left part-way was finished.
            case finished
            /// The audio stays (`reason`).
            case kept
        }

        public var sessionID: String
        public var result: Result
        /// Why the audio stays (`AudioCleanupPolicy.refusal`); nil otherwise.
        public var reason: String?

        public init(sessionID: String, result: Result, reason: String? = nil) {
            self.sessionID = sessionID; self.result = result; self.reason = reason
        }

        /// 0 when the audio is gone, 3 when it stays.
        public var exitCode: Int32 { result == .kept ? 3 : 0 }

        /// One line for the terminal; names no people.
        public var summary: String {
            switch result {
            case .deleted: "Deleted the audio; the transcript, speaker labels and transcript files are kept."
            case .finished: "Finished deleting the audio that an earlier deletion left."
            case .kept: "Kept the audio: \(reason ?? "the meeting does not qualify")."
            }
        }
    }

    /// Runs under the background-job lock (`Request.jobLock`) and the meeting's processing lease; throws, with nothing
    /// changed, when another job holds the lock (`DeepTranscriptionLock.busyMessage`), the meeting records, or its
    /// lease is held.
    public static func run(_ request: Request,
                           read: (URL, Date) -> SessionSummary = { SessionCatalog.summary(session: $0, now: $1) })
        throws -> Outcome {
        let session = request.session
        let sessionID = (try? SessionArchive.readManifest(at: session).id)
            ?? session.deletingPathExtension().lastPathComponent
        var held: DeepTranscriptionLock.Taken?
        if let jobLock = request.jobLock {
            guard let taken = try DeepTranscriptionLock.take(
                DeepTranscriptionLock.Holder(pid: getpid(), sessionID: sessionID, force: false,
                                             kind: DeepTranscriptionLock.Holder.audioCleanupKind), at: jobLock) else {
                throw HolosError.unavailable(DeepTranscriptionLock.busyMessage)
            }
            held = taken
        }
        defer { held?.release() }
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording.")
        }
        let lease = try SessionArchive.acquireProcessingLease(at: session)
        defer { lease.release() }
        // Decided under the lease: no relabel, recovery or other command can change the meeting from here on.
        let summary = read(session, request.now)
        let result: Outcome.Result
        if summary.audioDeleted {
            guard SessionDeletion.audioDeletionUnfinished(session: session) else {
                return Outcome(sessionID: sessionID, result: .kept, reason: "its audio is already deleted")
            }
            result = .finished
        } else if let reason = AudioCleanupPolicy.refusal(summary, now: request.now, days: request.olderThanDays,
                                                         pending: [], underOwnLease: true) {
            return Outcome(sessionID: sessionID, result: .kept, reason: reason)
        } else {
            result = .deleted
        }
        try SessionDeletion.deleteAudio(session: session, lease: lease)
        return Outcome(sessionID: sessionID, result: result)
    }
}
