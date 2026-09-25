import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// What `voiceislocal session import` does (docs/meeting-design.md §5.5 PR7c), as a library call: the CLI parses its
/// arguments, prints, and handles signals; the import, the labelling under the import's lease, and the exit status
/// are tested here (as `SessionDiarizeCommand` is for `voiceislocal session diarize`).
public enum SessionImportCommand {
    public struct Request: Sendable {
        public var file: URL
        public var name: String
        public var root: URL
        public var locale: String
        public var backend: SpeechBackend
        public var vocabulary: [String]
        public var transcribe: Bool
        /// Label speakers after the import; ignored without `transcribe`.
        public var postprocess: Bool

        public init(file: URL, name: String, root: URL, locale: String, backend: SpeechBackend,
                    vocabulary: [String] = [], transcribe: Bool = true, postprocess: Bool = true) {
            self.file = file; self.name = name; self.root = root; self.locale = locale; self.backend = backend
            self.vocabulary = vocabulary; self.transcribe = transcribe; self.postprocess = postprocess
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// The imported session.
        public var session: URL
        /// 0: imported, and labelled or not asked to be (labelling without speaker models counts: the exports are
        /// written without speakers and `summary` has the setup hint). 3: imported, but labelling failed, was
        /// skipped for another reason, or was cancelled.
        public var exitCode: Int32
        /// One line for stderr about the labelling; nil when there was none.
        public var summary: String?
        /// The post-processing record, when post-processing ran to an end.
        public var postProcessing: PostProcessingRecord?
    }

    /// Imports `request.file` with `SessionImporter`, then, unless told not to, labels its speakers as a
    /// recording's own post-processing does (`diarizer == nil`: speaker-less exports and the setup hint) under the
    /// processing lease the import took before its writer lock was released, so no other process can start on the
    /// session in between. The lease is released before this returns.
    ///
    /// Throws when nothing was imported: the importer's error, or
    /// `HolosError.incomplete("The import was cancelled; nothing was imported.")` when cancelled during the import.
    /// A labelling failure or cancellation does not throw; the session is kept and the outcome's exit code is 3.
    /// `profiles` is passed to the post-processor (voice suggestions, PR10).
    public static func run(_ request: Request, diarizer: (any SpeakerDiarizer)?,
                           makeSpeech: LiveSpeechFactory? = nil, timeouts: StopTimeouts = .standard,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           profiles: SpeakerProfileStore? = nil,
                           importProgress: @escaping @Sendable (Double) -> Void = { _ in },
                           labellingProgress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> Outcome {
        let imported: SessionImporter.ImportedSession
        do {
            imported = try await SessionImporter.importSession(
                from: request.file, name: request.name, root: request.root, locale: request.locale,
                backend: request.backend, vocabulary: request.vocabulary, transcribe: request.transcribe,
                makeSpeech: makeSpeech, timeouts: timeouts, progress: importProgress)
        } catch is CancellationError {
            throw HolosError.incomplete("The import was cancelled; nothing was imported.")
        }
        let session = imported.directory
        let lease = imported.lease
        defer { lease.release() }
        guard request.transcribe, request.postprocess else {
            return Outcome(session: session, exitCode: 0, summary: nil, postProcessing: nil)
        }
        do {
            let processor = MeetingPostProcessor(diarizer: diarizer, options: PostProcessingOptions(),
                                                 freeSpace: freeSpace, profiles: profiles)
            let record = try await processor.run(session: session, lease: lease, progress: labellingProgress)
            // The audio and transcript are saved either way: a labelling problem is a warning (§1.4).
            let code: Int32 = SessionDiarizeCommand.exitCode(record.state) == 0 ? 0 : 3
            return Outcome(session: session, exitCode: code,
                           summary: SessionDiarizeCommand.summary(record, session: session), postProcessing: record)
        } catch is CancellationError {
            return Outcome(session: session, exitCode: 3,
                           summary: "Speaker labelling was cancelled. The imported session is saved; label its "
                               + "speakers with voiceislocal session diarize.",
                           postProcessing: nil)
        } catch {
            return Outcome(session: session, exitCode: 3,
                           summary: "Speakers were not labelled: \(error.localizedDescription) The imported session "
                               + "is saved; label its speakers with voiceislocal session diarize.",
                           postProcessing: nil)
        }
    }
}
