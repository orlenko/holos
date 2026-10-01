import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// What `voiceislocal session fix-words` does (docs/design.md "Meeting word fixes"), as a library call: the CLI parses
/// its arguments and prints the outcome. It runs the post-processor with the word-fix stage asked for by name, so the
/// meeting's misheard words are fixed again with today's corrections and word list from the transcript before any fix,
/// then speakers are labelled again on the new text and the exports rewritten, as after a recording (without speaker
/// models the exports are speaker-less, as there). When the transcript stays as it was (already fixed with these
/// corrections and terms, or kept after a failure), its speaker labels stay too, edited or not.
public enum SessionWordFixesCommand {
    public struct Request: Sendable {
        public var session: URL
        /// Replace a transcript whose speaker labels were edited (names carry over).
        public var force: Bool

        public init(session: URL, force: Bool = false) {
            self.session = session; self.force = force
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var record: PostProcessingRecord
        /// 0 succeeded; 3 partial (the exports were written, but the words could not be fixed, or speaker labelling
        /// was skipped or failed); 1 failed.
        public var exitCode: Int32
        /// One line for the terminal: what the word-fix stage did, then the speaker labels and the exports' folder.
        /// Names no people and quotes no transcript text.
        public var summary: String
    }

    /// Throws, with nothing changed, when the session is still recording or another process holds its processing
    /// lease.
    public static func run(_ request: Request, diarizer: (any SpeakerDiarizer)?,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           profiles: SpeakerProfileStore? = nil,
                           languages: LanguageDetectionDependencies = .live,
                           wordFixes: WordFixDependencies,
                           progress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> Outcome {
        let options = PostProcessingOptions(force: request.force, fixWords: true)
        let processor = MeetingPostProcessor(diarizer: diarizer, options: options, freeSpace: freeSpace,
                                             profiles: profiles, languages: languages, wordFixes: wordFixes)
        let record = try await processor.run(session: request.session, lease: nil, progress: progress)
        return Outcome(record: record, exitCode: SessionDiarizeCommand.exitCode(record.state),
                       summary: summary(record, session: request.session))
    }

    /// The word-fix stage's message, then `SessionDiarizeCommand.summary` without the record's "Fixed … misheard
    /// words." note, which the stage's message already says.
    static func summary(_ record: PostProcessingRecord, session: URL) -> String {
        var shown = record
        if let message = shown.message, message.hasPrefix("Fixed "), let end = message.range(of: "words.")
            ?? message.range(of: "word.") {
            let rest = message[end.upperBound...].trimmingCharacters(in: .whitespaces)
            shown.message = rest.isEmpty ? nil : rest
        }
        let stage = record.stages.last { $0.stage == .wordFixes }?.message
        return ([stage].compactMap { $0 } + [SessionDiarizeCommand.summary(shown, session: session)])
            .joined(separator: " ")
    }
}
