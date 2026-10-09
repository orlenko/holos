import Foundation
import HolosCore
import HolosStorage

/// The one path that makes a new transcript current in a finished session (the languages, deep transcription, word
/// fix and live correction stages; Review's word edits, their undo, and an automatic fix's revert), or that carries the
/// speaker head over to the transcript already current (a repair).
///
/// Invariants:
/// 1. Everything runs under the writer lock (`SessionArchive.withMaintenanceArchive`) and then the speaker lock (the
///    order `docs/meeting-design.md §1.7` gives), both taken for one publication and released however it ends. The
///    caller's checks (`decide`) run with both held, so what they read cannot change before the writes.
/// 2. A publication writes in this order, and nothing after a step that throws: a cancellation check (seen with both
///    locks held, it publishes nothing); the retargeted speaker run (`SpeakerTranscriptRetarget.stage`, safe to leave
///    orphaned); a revision saved and journaled before the new transcript, if any; the event that explains the new
///    transcript, before its pointer, so a current transcript is always explained; the transcript pointer; the speaker
///    head on the retargeted run.
/// 3. A failure up to the pointer leaves the transcript and head as they were, and its error is thrown as it is. Once
///    the pointer names the new transcript, a failure (a save that throws after its rename, with `committed`; the
///    head) leaves the one incomplete state: the new transcript current, the old head published. The caller's error
///    says the transcript was published; the old head remains a complete snapshot, and a repair
///    (`Decision.repairHead`) publishes the retargeted head from it later.
enum TranscriptPublisher {
    /// A journal event: its kind (`MeetingEventKind`) and details.
    struct Event: Sendable, Equatable {
        var kind: String
        var details: [String: String]
    }

    /// A new current transcript and what is written with it (invariant 2).
    struct Change {
        var transcript: Transcript
        var event: Event
        /// The speaker run carried over to `transcript`: staged first, made head last. Nil publishes no head.
        var retarget: SpeakerTranscriptRetarget.Plan? = nil
        /// A revision saved without becoming current, and journaled, before `event` (the base a correction was
        /// rebased onto).
        var revision: (transcript: Transcript, event: Event)? = nil
        /// The head's `updatedAt`; nil takes the time it is written.
        var now: Date? = nil
        /// Saves through `TranscriptPointerSave`: a save that throws once the pointer names `transcript` throws this
        /// error instead, which says it was published. Nil saves directly and throws any save error as it is.
        var committed: ((any Error) -> any Error)? = nil
        /// The error thrown when the head cannot be published once `transcript` is current.
        var headFailed: (any Error) -> any Error = { $0 }
    }

    /// What `decide` asks for, with the value `publish` returns.
    enum Decision<Value> {
        /// Nothing is written.
        case keep(Value)
        /// The change is published (invariant 2).
        case publish(Change, Value)
        /// The current transcript stays; after the cancellation check, `plan` is staged and made head (`now` as in
        /// `Change`). Its errors are thrown as they are.
        case repairHead(SpeakerTranscriptRetarget.Plan, now: Date?, Value)
    }

    /// A write `publish` makes, in order (invariant 2).
    enum Step: Sendable, Equatable {
        case stage, revision, event, save, head
    }

    /// Test hook: while set (a task-local value), called before each step is written, as that step failing would throw.
    @TaskLocal static var beforeStep: (@Sendable (Step) throws -> Void)?

    /// Runs `decide` under the writer lock and then the speaker lock (invariant 1), and writes what it returns.
    static func publish<Value>(session: URL, lease: ProcessingLease,
                               _ decide: () throws -> Decision<Value>) async throws -> Value {
        try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { archive in
            try await SessionArchive.withSpeakerLockAsync(at: session) { () async throws -> Value in
                switch try decide() {
                case .keep(let value):
                    return value
                case .publish(let change, let value):
                    try await write(change, archive: archive, session: session)
                    return value
                case .repairHead(let plan, let now, let value):
                    try Task.checkCancellation()
                    try stage(plan, session: session)
                    try publishHead(plan, session: session, now: now)
                    return value
                }
            }
        }
    }

    private static func write(_ change: Change, archive: SessionArchive, session: URL) async throws {
        try Task.checkCancellation()
        if let plan = change.retarget { try stage(plan, session: session) }
        if let revision = change.revision {
            try beforeStep?(.revision)
            try await archive.saveTranscriptRevision(revision.transcript)
            try await archive.recordEvent(kind: revision.event.kind, details: revision.event.details)
        }
        try beforeStep?(.event)
        try await archive.recordEvent(kind: change.event.kind, details: change.event.details)
        try beforeStep?(.save)
        if let committed = change.committed {
            try await TranscriptPointerSave.save(change.transcript, archive: archive, session: session,
                                                 committed: committed)
        } else {
            try await archive.saveTranscript(change.transcript, writeLegacyExports: false)
        }
        if let plan = change.retarget {
            do {
                try publishHead(plan, session: session, now: change.now)
            } catch {
                throw change.headFailed(error)
            }
        }
    }

    private static func stage(_ plan: SpeakerTranscriptRetarget.Plan, session: URL) throws {
        try beforeStep?(.stage)
        try SpeakerTranscriptRetarget.stage(plan, session: session)
    }

    private static func publishHead(_ plan: SpeakerTranscriptRetarget.Plan, session: URL, now: Date?) throws {
        try beforeStep?(.head)
        try SpeakerTranscriptRetarget.publishHead(plan, session: session, now: now ?? Date())
    }
}
