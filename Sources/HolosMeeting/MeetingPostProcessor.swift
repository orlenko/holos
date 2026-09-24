import Darwin
import Foundation
import HolosCore
import HolosStorage
import os

/// Runs post-processing for a finished session under `lease`. Never throws: failures come back as a
/// `.failed` record with a message.
public typealias PostProcessHook = @Sendable (_ session: URL, _ lease: ProcessingLease,
    _ progress: @escaping @Sendable (PostProcessingProgress) -> Void) async -> PostProcessingRecord

public struct PostProcessingOptions: Sendable, Equatable {
    public var speakers: SpeakerCountHint?
    /// Relabel even when the head run has edits. Names and links carry over (§4.9).
    public var force: Bool
    public var keepDerived: Bool
    /// Overrides meeting.json `othersInRoom` for this run.
    public var othersInRoom: Bool?
    /// Hidden engine settings for evaluation, e.g. ["exclusiveSegments": "true"]; recorded in the run.
    public var engineOverrides: [String: String]
    /// Write speakers/voice/<runID>.json even when "Remember voices" is off (hidden; evaluation sessions only).
    public var forceVoiceData: Bool
    /// The stop reason when called right after a recording; `diskLow` skips rendering.
    public var stopReason: StopReason?

    public init(speakers: SpeakerCountHint? = nil, force: Bool = false, keepDerived: Bool = false,
                othersInRoom: Bool? = nil, engineOverrides: [String: String] = [:], forceVoiceData: Bool = false,
                stopReason: StopReason? = nil) {
        self.speakers = speakers; self.force = force; self.keepDerived = keepDerived
        self.othersInRoom = othersInRoom; self.engineOverrides = engineOverrides
        self.forceVoiceData = forceVoiceData; self.stopReason = stopReason
    }
}

/// Speaker labelling and exports for a finished session (docs/meeting-design.md §4.7).
public struct MeetingPostProcessor: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    /// The message of the `.skipped` record this build returns.
    static let notAvailableMessage = "Speaker labelling is not available in this version of Holos."

    let diarizer: (any SpeakerDiarizer)?
    let options: PostProcessingOptions
    let freeSpace: any FreeSpaceProvider

    /// PR1: `run` returns a `.skipped` record and writes nothing. From PR7b: runs the stages below;
    /// `diarizer == nil` gives speaker-less exports and the setup hint.
    public init(diarizer: (any SpeakerDiarizer)? = nil, options: PostProcessingOptions = .init(),
                freeSpace: any FreeSpaceProvider = VolumeFreeSpace()) {
        self.diarizer = diarizer; self.options = options; self.freeSpace = freeSpace
    }

    /// Runs every stage for one finished session under `lease` (nil: acquire one, retry 1 s) and returns the
    /// final postprocess.json record. Throws only when it cannot start (still recording, lease held elsewhere,
    /// unreadable manifest); stage failures are recorded in the returned record.
    ///
    /// This build has no stages yet: it checks that it could start, then returns a `.skipped` record without
    /// writing anything (no postprocess.json, exports, or speaker files).
    public func run(session: URL, lease: ProcessingLease?,
                    progress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> PostProcessingRecord {
        let startedAt = Date()
        if try SessionArchive.isActive(at: session) {
            throw HolosError.unavailable("This meeting is still recording. Stop it before labelling speakers.")
        }
        // PR1 checks a caller's lease only as far as HolosStorage's public API allows: its folder must be this
        // session's (no symlinks), and some holder must have the lock (a released lease with no other holder
        // is refused). PR7b must do its lease-bound work through HolosStorage entry points that validate the
        // lease themselves (`ProcessingLease.beginUse(for:)` on main: openForMaintenance(at:lease:),
        // recover(at:lease:)), and then drop this local check.
        let owned: ProcessingLease?
        if let lease {
            guard Self.sameFolder(lease.session, session) else {
                throw HolosError.invalidInput("The processing lease belongs to another session.")
            }
            guard try SessionArchive.isProcessing(at: session) else {
                throw HolosError.invalidInput("The processing lease was already released; acquire a new one.")
            }
            owned = nil
        } else {
            owned = try SessionArchive.acquireProcessingLease(at: session)
        }
        defer { owned?.release() }
        let manifest = try SessionArchive.readManifest(at: session)
        Self.log.info("Post-processing skipped for session \(manifest.id, privacy: .public): no stages in this build")
        return PostProcessingRecord(sessionID: manifest.id, state: .skipped, pid: getpid(), startedAt: startedAt,
                                    updatedAt: Date(), message: Self.notAvailableMessage)
    }

    /// Whether two URLs name the same real folder (same device and inode). A symlink in place of either folder
    /// never matches (`lstat`).
    private static func sameFolder(_ first: URL, _ second: URL) -> Bool {
        var a = stat()
        var b = stat()
        guard first.isFileURL, second.isFileURL, lstat(first.path, &a) == 0, lstat(second.path, &b) == 0,
              (a.st_mode & S_IFMT) == S_IFDIR, (b.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
}
