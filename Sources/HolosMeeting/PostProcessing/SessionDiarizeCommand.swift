import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// What `holos session diarize` does (docs/meeting-design.md §5.5 PR7b), as a library call: the CLI parses its
/// arguments and prints the outcome, so the lease hand-off, the model check, and the exit status are tested here.
public enum SessionDiarizeCommand {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")

    public struct Request: Sendable {
        public var session: URL
        public var options: PostProcessingOptions
        /// `--after-recording`: the recorder's post-processing run in a child. Waits up to `writerWait` for the
        /// writer lock to be released (unless `leaseDescriptor` is given), and without speaker models writes
        /// speaker-less exports with the setup hint instead of refusing.
        public var afterRecording: Bool
        /// `--lease-fd N`: a processing lease inherited from the parent (§4.1), adopted instead of acquired.
        public var leaseDescriptor: Int32?
        public var writerWait: Duration

        public init(session: URL, options: PostProcessingOptions = .init(), afterRecording: Bool = false,
                    leaseDescriptor: Int32? = nil, writerWait: Duration = .seconds(30)) {
            self.session = session; self.options = options; self.afterRecording = afterRecording
            self.leaseDescriptor = leaseDescriptor; self.writerWait = writerWait
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var record: PostProcessingRecord
        /// 0 succeeded; 3 partial (exports written, speaker labels skipped or failed); 1 failed or nothing to label.
        public var exitCode: Int32
        /// "Labelled 11 speakers in 343 turns (run 5C1D…). Kept 8 names. Exports: <path>/exports"
        public var summary: String
    }

    /// Runs `MeetingPostProcessor` for one session. Throws, with nothing changed, when it cannot start:
    /// `leaseDescriptor` is not this session's processing lease ("The inherited lock is not this session's
    /// processing lease."), `diarizer` is nil without `afterRecording` (the setup hint), the session is still
    /// recording, or another process holds the lease. An adopted lease is released (its descriptor closed) when the
    /// run ends. `profiles` is passed to the post-processor (voice suggestions, PR10).
    public static func run(_ request: Request, diarizer: (any SpeakerDiarizer)?,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           profiles: SpeakerProfileStore? = nil,
                           progress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> Outcome {
        let session = request.session
        var lease: ProcessingLease?
        if let descriptor = request.leaseDescriptor {
            lease = try SessionArchive.adoptProcessingLease(at: session, descriptor: descriptor)
        }
        defer { lease?.release() }
        if diarizer == nil, !request.afterRecording {
            throw HolosError.unavailable(SpeakerAnalysis.modelsMissing)
        }
        if request.afterRecording, lease == nil {
            try await waitForWriter(session, timeout: request.writerWait)
            lease = try SessionArchive.acquireProcessingLease(at: session)
        }
        let processor = MeetingPostProcessor(diarizer: diarizer, options: request.options, freeSpace: freeSpace,
                                             profiles: profiles)
        let record = try await processor.run(session: session, lease: lease, progress: progress)
        return Outcome(record: record, exitCode: exitCode(record.state),
                       summary: summary(record, session: session))
    }

    /// 0 succeeded; 3 partial; 1 otherwise.
    static func exitCode(_ state: PostProcessingState) -> Int32 {
        switch state {
        case .succeeded: 0
        case .partial: 3
        default: 1
        }
    }

    /// One line for the terminal. Names no people and quotes no transcript text.
    static func summary(_ record: PostProcessingRecord, session: URL) -> String {
        guard record.state == .succeeded || record.state == .partial else {
            return record.message ?? "Post-processing ended: \(record.state.rawValue)."
        }
        var parts: [String] = []
        let align = record.stages.last { $0.stage == .align }
        if align?.result == .succeeded, let runID = record.runID,
           let run = try? SessionSpeakerStore.readRun(id: runID, session: session) {
            parts.append(SpeakerAnalysis.labelledMessage(run, showingRun: true))
            if let note = align?.message { parts.append(note) }
        } else if let message = record.message {
            parts.append(message)
        }
        if let moved = record.stages.last(where: { $0.stage == .export && $0.result == .succeeded })?.message {
            parts.append(moved)
        }
        parts.append("Exports: \(SessionPaths.exports(session).path)")
        return parts.joined(separator: " ")
    }

    /// Polls the writer lock every 100 ms until it is free, for up to `timeout`.
    private static func waitForWriter(_ session: URL, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while try SessionArchive.isActive(at: session) {
            guard clock.now < deadline else {
                throw HolosError.unavailable("The recording is still being saved; label speakers once it has finished.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
