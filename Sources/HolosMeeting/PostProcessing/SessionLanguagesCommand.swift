import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// What `voiceislocal session languages` does (docs/meeting-design.md §4.14), as a library call: the CLI parses its
/// arguments and prints the outcome. It runs the post-processor with the languages named, so the transcript is merged
/// from one transcription in each, then speakers are labelled again on it and the exports rewritten, as after a
/// recording (without speaker models the exports are speaker-less, as there).
public enum SessionLanguagesCommand {
    public struct Request: Sendable {
        public var session: URL
        /// The languages, the preferred one first (`DictationLanguage.meetingLanguagesProblem` must accept them).
        /// One language makes the transcript that language's alone.
        public var languages: [String]
        /// Replace a transcript whose speaker labels were edited (names carry over).
        public var force: Bool

        public init(session: URL, languages: [String], force: Bool = false) {
            self.session = session; self.languages = languages; self.force = force
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var record: PostProcessingRecord
        /// 0 succeeded; 3 partial (the exports were written, but a language could not be transcribed, or speaker
        /// labelling was skipped or failed); 1 failed.
        public var exitCode: Int32
        /// One line for the terminal: what the languages stage did, then the speaker labels and the exports' folder.
        /// Names no people and quotes no transcript text.
        public var summary: String
    }

    /// Throws, with nothing changed, when the languages are not a valid list, the session is still recording, or
    /// another process holds its processing lease.
    public static func run(_ request: Request, diarizer: (any SpeakerDiarizer)?,
                           freeSpace: any FreeSpaceProvider = VolumeFreeSpace(),
                           profiles: SpeakerProfileStore? = nil,
                           languages: LanguageDetectionDependencies = .live,
                           progress: @escaping @Sendable (PostProcessingProgress) -> Void = { _ in })
        async throws -> Outcome {
        if let problem = DictationLanguage.meetingLanguagesProblem(request.languages) {
            throw HolosError.invalidInput(problem)
        }
        let list = DictationLanguage.meetingLanguages(request.languages)
        let options = PostProcessingOptions(force: request.force, languages: list)
        let processor = MeetingPostProcessor(diarizer: diarizer, options: options, freeSpace: freeSpace,
                                             profiles: profiles, languages: languages)
        let record = try await processor.run(session: request.session, lease: nil, progress: progress)
        return Outcome(record: record, exitCode: SessionDiarizeCommand.exitCode(record.state),
                       summary: summary(record, session: request.session, languages: list))
    }

    /// The languages stage's message, then `SessionDiarizeCommand.summary` without the record's leading "Transcribed
    /// in …." note, which the stage's message already says.
    static func summary(_ record: PostProcessingRecord, session: URL, languages: [String]) -> String {
        var shown = record
        let note = LanguageStage.note(languages)
        if let message = shown.message, message.hasPrefix(note) {
            let rest = message.dropFirst(note.count).trimmingCharacters(in: .whitespaces)
            shown.message = rest.isEmpty ? nil : rest
        }
        let stage = record.stages.last { $0.stage == .languages }?.message
        return ([stage].compactMap { $0 } + [SessionDiarizeCommand.summary(shown, session: session)])
            .joined(separator: " ")
    }
}
