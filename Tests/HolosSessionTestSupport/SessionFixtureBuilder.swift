import Foundation
import HolosCore
import HolosStorage

/// An on-disk `.holos` session for a test, written through `SessionArchive` as a recording would leave it.
/// Configure what the session holds, then `create` it (an open writer, nothing else written) or have it
/// `finished` (meeting.json, the transcript, then the final status).
public struct SessionFixtureBuilder: Sendable {
    public var name: String
    public var source: AudioSource
    public var locale: String
    public var backend: SpeechBackend
    /// Written to meeting.json when set, with the new session's ID in place of its own `sessionID`.
    public var meetingInfo: MeetingInfo?
    /// Saved as the current transcript when set.
    public var transcript: Transcript?
    public var legacyExports: Bool
    public var status: String

    public init(name: String = "Fixture", source: AudioSource = .microphone, locale: String = "en-CA",
                backend: SpeechBackend = .speech, meetingInfo: MeetingInfo? = nil, transcript: Transcript? = nil,
                legacyExports: Bool = false, status: String = ArchiveStatus.complete) {
        self.name = name
        self.source = source
        self.locale = locale
        self.backend = backend
        self.meetingInfo = meetingInfo
        self.transcript = transcript
        self.legacyExports = legacyExports
        self.status = status
    }

    /// A new session in `root`, still recording: its writer holds the session lock.
    public func create(in root: URL) throws -> SessionArchive {
        try SessionArchive.create(root: root, name: name, source: source, locale: locale, backend: backend)
    }

    /// A session in `root` ended with `status`, its lock released.
    @discardableResult
    public func finished(in root: URL) async throws -> (session: URL, id: String) {
        let archive = try create(in: root)
        if var meetingInfo {
            meetingInfo.sessionID = archive.id
            try AtomicFile.writeJSON(meetingInfo, to: SessionPaths.meetingInfo(archive.directory))
        }
        if let transcript { try await archive.saveTranscript(transcript, writeLegacyExports: legacyExports) }
        try await archive.finish(status: status)
        return (archive.directory, archive.id)
    }
}
