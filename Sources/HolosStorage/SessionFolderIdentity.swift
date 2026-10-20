import Darwin
import Foundation
import HolosCore

/// The folder a short session operation intends to change, independent of its processing lease.
public struct SessionFolderIdentity: Sendable {
    private let folder: FileIdentity

    public init(at session: URL) throws {
        let descriptor = try SessionLockFile.openSessionFolder(session)
        defer { Darwin.close(descriptor) }
        folder = try FileIdentity(descriptor: descriptor)
    }

    /// Throws when the path no longer names the original folder, including a replacement with the same session ID.
    public func verify(for session: URL) throws {
        let descriptor = try SessionLockFile.openSessionFolder(session)
        defer { Darwin.close(descriptor) }
        guard try FileIdentity(descriptor: descriptor) == folder else {
            throw HolosError.invalidInput("This meeting's folder was moved or replaced; try again.")
        }
    }
}

extension SessionArchive {
    /// Transient contention for the short naming/publication lock, distinct from unreadable metadata.
    public struct SpeakerLockBusy: LocalizedError, Sendable {
        public var errorDescription: String? { "This meeting is saving a change; try again in a moment." }
    }

    /// Holds the existing speaker lock in the intended folder and verifies its path after acquiring the lock.
    /// Metadata and exports share this short lock; transcription does not hold it during inference.
    /// Caller checks `identity` again before every publication made by path. Not re-entrant.
    public nonisolated static func withVerifiedSpeakerLockAsync<T>(
        at session: URL, matching identity: SessionFolderIdentity, timeout: Duration = .seconds(2),
        _ body: () async throws -> T
    ) async throws -> T {
        try identity.verify(for: session)
        let folder = try SessionLockFile.openSessionFolder(session)
        defer { Darwin.close(folder) }
        guard let descriptor = try SessionLockFile.acquire(SessionLockFile.speakers, inFolder: folder,
                                                           timeout: timeout) else {
            throw SpeakerLockBusy()
        }
        defer { SessionLockFile.unlockAndClose(descriptor) }
        try identity.verify(for: session)
        return try await body()
    }
}

/// Atomic naming metadata updates. Caller holds the session's speaker lock (docs/conventions.md §1.7).
public enum SessionNamingStore {
    /// The canonical name when this session has one. A status heartbeat can fall back on a read failure.
    public static func name(session: URL, sessionID: String) throws -> String? {
        guard let meeting = try VersionedFile<MeetingInfo>("meeting.json", current: 1, maxBytes: 1 << 20)
            .read(SessionPaths.meetingInfo(session)) else { return nil }
        guard meeting.sessionID == sessionID else {
            throw HolosError.invalidInput("The naming metadata belongs to another meeting.")
        }
        return meeting.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    public static func writeLocked(name: String, source: MeetingNameSource, session: URL,
                                   meeting: MeetingInfo, identity: SessionFolderIdentity) throws {
        try identity.verify(for: session)
        let url = SessionPaths.meetingInfo(session)
        let data = try AtomicFile.readIfPresent(url, maxBytes: 1 << 20)
            ?? HolosJSON.encoder().encode(meeting)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HolosError.invalidInput("The meeting metadata is not a JSON object.")
        }
        object["name"] = name
        object["nameSource"] = source.rawValue
        let updated = try JSONSerialization.data(withJSONObject: object,
                                                 options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        try identity.verify(for: session)
        try AtomicFile.write(updated, to: url)
    }
}
